#!/usr/bin/env python3
"""Run GUI checks with a distinct application identity from the live launcher."""
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
source = ROOT / "dist/SpotFast.app"
smoke = ROOT / ".build/SpotFastSmoke.app"
if smoke.exists():
    shutil.rmtree(smoke)
shutil.copytree(source, smoke)
info = smoke / "Contents/Info.plist"
contents = plistlib.loads(info.read_bytes())
contents["CFBundleIdentifier"] = "local.spotfast.smoke"
contents["CFBundleName"] = "SpotFast Smoke"
info.write_bytes(plistlib.dumps(contents))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", smoke], check=True)
subprocess.run([smoke / "Contents/MacOS/SpotFast", "--ui-smoke-test"], cwd=ROOT, check=True)
