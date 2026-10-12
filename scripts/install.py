#!/usr/bin/env python3
"""Build, validate, install, and activate SpotFast in the current macOS user session."""
import argparse
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
USER_HOME = Path.home()
SUPPORT = USER_HOME / "Library/Application Support/SpotFast"
APP = USER_HOME / "Applications/SpotFast.app"
AGENTS = USER_HOME / "Library/LaunchAgents"
DOMAIN = f"gui/{os.getuid()}"
LABELS = ("local.spotfast.fsearch", "local.spotfast.launcher")
ACTIVATE = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
PREFS = "com.apple.symbolichotkeys"

def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)

def read_preferences(domain):
    result = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True)
    if result.returncode:
        # Distinguish a missing domain from inaccessible preferences.
        if b"does not exist" in result.stderr or b"does not exist" in result.stdout:
            return {}
        raise RuntimeError(f"Cannot read preferences for {domain}: {result.stderr.decode(errors='replace')}")
    return plistlib.loads(result.stdout)

def write_preferences(domain, value):
    run(["/usr/bin/defaults", "import", domain, "-"], input=plistlib.dumps(value))

def shortcut_preferences(current, enabled):
    # Merge only Spotlight's key 64. Preserve every other keyboard setting.
    value = plistlib.loads(plistlib.dumps(current))
    keys = value.setdefault("AppleSymbolicHotKeys", {})
    entry = keys.setdefault("64", {"value": {"parameters": [32, 49, 1048576], "type": "standard"}})
    entry["enabled"] = enabled
    return value

def private_directory(path, restrict=True):
    # Fail on symlinks and foreign-writable ancestors, including before creation.
    uid = os.getuid()
    for part in reversed((path, *path.parents)):
        if not part.exists() and not part.is_symlink():
            part.mkdir(mode=0o700)
        info = part.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, uid) or info.st_mode & 0o022:
            raise RuntimeError(f"Unsafe directory: {part}")
    if path.stat().st_uid != uid:
        raise RuntimeError(f"Directory belongs to another user: {path}")
    if restrict:
        path.chmod(0o700)

def save_plist(path, value):
    # Installer files reside in a private directory. Refuse existing links.
    if path.is_symlink():
        raise RuntimeError(f"Refusing symlink: {path}")
    temporary = path.with_name(path.name + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            plistlib.dump(value, handle)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

def stop_jobs():
    for label in reversed(LABELS):
        target = f"{DOMAIN}/{label}"
        subprocess.run(["/bin/launchctl", "bootout", target], capture_output=True)
        # bootout can return before launchd releases the label. Do not copy an
        # app or bootstrap its replacement while the previous job still exists.
        deadline = time.monotonic() + 10
        while subprocess.run(["/bin/launchctl", "print", target], capture_output=True).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Previous job did not stop: {label}")
            time.sleep(0.1)

def load_agent(label):
    command = ["/bin/launchctl", "bootstrap", DOMAIN, str(AGENTS / f"{label}.plist")]
    deadline = time.monotonic() + 5
    while True:
        result = subprocess.run(command, capture_output=True)
        if result.returncode == 0:
            return
        if result.returncode != 5 or time.monotonic() >= deadline:
            raise RuntimeError(f"Cannot start {label}: {result.stderr.decode(errors='replace')}")
        time.sleep(0.2)

def load_jobs():
    for label in LABELS:
        load_agent(label)

def agent(label, executable, args, keepalive):
    return {"Label": label, "ProgramArguments": [str(executable), *args], "RunAtLoad": True,
        "KeepAlive": keepalive, "Umask": 0o077, "ProcessType": "Background" if args else "Interactive",
        "StandardOutPath": str(SUPPORT / f"{label}.log"),
        "StandardErrorPath": str(SUPPORT / f"{label}.log")}

def restore(backup):
    state = plistlib.loads((backup / "state.plist").read_bytes())
    stop_jobs()
    current = read_preferences(PREFS)
    keys = current.setdefault("AppleSymbolicHotKeys", {})
    if state["hadShortcut"]:
        keys["64"] = state["shortcut"]
    else:
        keys.pop("64", None)
    write_preferences(PREFS, current)
    settings = read_preferences("local.spotfast.launcher")
    for key in ("commandSpace", "useFSearch"):
        if key in state["appSettings"]:
            settings[key] = state["appSettings"][key]
        else:
            settings.pop(key, None)
    write_preferences("local.spotfast.launcher", settings)
    run([ACTIVATE, "-u"])
    if APP.exists():
        shutil.rmtree(APP)
    if (backup / "previous-app").exists():
        shutil.copytree(backup / "previous-app", APP)
    for label in LABELS:
        target = AGENTS / f"{label}.plist"
        target.unlink(missing_ok=True)
        old = backup / f"{label}.plist"
        if old.exists():
            shutil.copy2(old, target)
            if label in state["loadedJobs"]:
                load_agent(label)
    print("Restored the previous Command–Space settings and launcher installation.")

def ensure_tools(bootstrap):
    os.environ["PATH"] = str(USER_HOME / ".cargo/bin") + ":" + os.environ.get("PATH", "")
    if not shutil.which("cargo"):
        brew = shutil.which("brew") or ("/opt/homebrew/bin/brew" if Path("/opt/homebrew/bin/brew").exists() else None)
        if not bootstrap or not brew:
            raise RuntimeError("Rust is missing. Install Rust, or rerun with --bootstrap-tools to install it through Homebrew.")
        run([brew, "install", "rust"])
    if subprocess.run(["cargo", "audit", "--version"], capture_output=True).returncode:
        if not bootstrap:
            raise RuntimeError("cargo-audit is missing. Run cargo install cargo-audit --locked, or use --bootstrap-tools.")
        run(["cargo", "install", "cargo-audit", "--locked"])

def build(bootstrap):
    ensure_tools(bootstrap)
    manifest = ROOT / "vendor/fsearch/Cargo.toml"
    os.environ["CARGO_TARGET_DIR"] = str(ROOT / "vendor/fsearch/target")
    run(["cargo", "test", "--locked", "--release", "--manifest-path", manifest, "--", "--test-threads=1"], cwd=ROOT)
    run(["cargo", "audit", "--file", ROOT / "vendor/fsearch/Cargo.lock", "--deny", "warnings"], cwd=ROOT)
    run(["cargo", "build", "--locked", "--release", "--manifest-path", manifest], cwd=ROOT)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / ".build/clang-cache"))
    tests = run(["swift", "test", "--disable-sandbox", "--scratch-path", ".build", "--cache-path", ".build/cache"],
        cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(tests.stdout, flush=True)
    if re.search(r"with [1-9]\d* tests? skipped|Test skipped -", tests.stdout):
        raise RuntimeError("Socket tests were skipped. Run setup in an unrestricted user Terminal; no macOS settings changed.")
    run(["bash", ROOT / "scripts/build-app.sh", "--with-fsearch"], cwd=ROOT)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", ROOT / "dist/SpotFast.app"])

def install():
    private_directory(SUPPORT)
    private_directory(SUPPORT / "FSearch")
    private_directory(USER_HOME / "Applications", restrict=False)
    private_directory(AGENTS, restrict=False)
    original_backup = None
    installation = SUPPORT / "installation.plist"
    if installation.exists():
        record = plistlib.loads(installation.read_bytes())
        candidate = Path(record["backup"])
        if candidate.parent == SUPPORT and (candidate / "state.plist").is_file():
            original_backup = candidate
    if APP.is_symlink():
        raise RuntimeError("Refusing a symlinked SpotFast.app")
    for label in LABELS:
        if (AGENTS / f"{label}.plist").is_symlink():
            raise RuntimeError("Refusing a symlinked launch agent")
    backup = SUPPORT / ("backup-" + str(time.time_ns()))
    private_directory(backup)
    preferences = read_preferences(PREFS)
    keys = preferences.get("AppleSymbolicHotKeys", {})
    loaded = [label for label in LABELS if subprocess.run(["/bin/launchctl", "print", f"{DOMAIN}/{label}"], capture_output=True).returncode == 0]
    state = {"hadShortcut": "64" in keys, "shortcut": keys.get("64", {}), "loadedJobs": loaded,
        "appSettings": {k: v for k, v in read_preferences("local.spotfast.launcher").items() if k in ("commandSpace", "useFSearch")}}
    save_plist(backup / "state.plist", state)
    if APP.exists():
        shutil.copytree(APP, backup / "previous-app")
    for label in LABELS:
        target = AGENTS / f"{label}.plist"
        if target.exists():
            shutil.copy2(target, backup / target.name)
    print(f"Saved rollback state in {backup}", flush=True)
    try:
        stop_jobs()
        if APP.exists():
            shutil.rmtree(APP)
        shutil.copytree(ROOT / "dist/SpotFast.app", APP)
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", APP])
        binary = APP / "Contents/MacOS"
        save_plist(AGENTS / f"{LABELS[0]}.plist", agent(LABELS[0], binary / "fsearch", ["serve-spotfast"], True))
        save_plist(AGENTS / f"{LABELS[1]}.plist", agent(LABELS[1], binary / "SpotFast", [], {"SuccessfulExit": False}))
        load_agent(LABELS[0])
        deadline = time.monotonic() + 45
        while True:
            result = subprocess.run([str(binary / "SpotFast"), "--check-fsearch"], capture_output=True)
            if result.returncode == 0:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Hardened FSearch did not become available. See the FSearch log in Application Support/SpotFast.")
            time.sleep(0.5)
        settings = read_preferences("local.spotfast.launcher")
        settings.update(commandSpace=True, useFSearch=True)
        write_preferences("local.spotfast.launcher", settings)
        write_preferences(PREFS, shortcut_preferences(preferences, False))
        run([ACTIVATE, "-u"])
        (SUPPORT / "registration.plist").unlink(missing_ok=True)
        load_agent(LABELS[1])
        deadline = time.monotonic() + 15
        while True:
            try:
                registration = plistlib.loads((SUPPORT / "registration.plist").read_bytes())
                job = subprocess.run(["/bin/launchctl", "print", f"{DOMAIN}/{LABELS[1]}"], capture_output=True, text=True)
                if f"pid = {registration['pid']}\n" in job.stdout:
                    if registration["registered"] and registration["commandSpace"]:
                        break
                    raise RuntimeError("Command–Space registration failed; restoring the previous settings.")
            except FileNotFoundError:
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError("SpotFast did not report a registered Command–Space shortcut.")
            time.sleep(0.2)
        save_plist(SUPPORT / "installation.plist", {"backup": str(original_backup or backup), "previousBackup": str(backup), "app": str(APP)})
        print("Installed hardened FSearch and registered SpotFast on Command–Space. Both start at login.")
        print("Initial disk indexing runs in the background; Apple metadata remains available.")
    except BaseException:
        restore(backup)
        raise

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap-tools", action="store_true", help="Install missing Rust/cargo-audit tools")
    parser.add_argument("--build-only", action="store_true", help="Build and validate without changing macOS settings")
    parser.add_argument("--restore", type=Path, help="Restore a saved rollback directory")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.getuid() == 0:
        raise RuntimeError("Run this as your normal macOS user, without sudo.")
    if args.restore:
        restore(args.restore.resolve())
        return
    # Verify the user session before downloading tools or changing preferences.
    if not args.build_only:
        run(["/bin/launchctl", "print", DOMAIN], stdout=subprocess.DEVNULL)
        if not Path(ACTIVATE).exists():
            raise RuntimeError("macOS shortcut activation utility is unavailable; no settings changed.")
    build(args.bootstrap_tools)
    if not args.build_only:
        install()

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"SpotFast setup failed: {error}", file=sys.stderr)
        sys.exit(1)
