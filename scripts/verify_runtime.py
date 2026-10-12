#!/usr/bin/env python3
"""Check the installed launcher and hardened daemon, including real file search."""
import json
import os
import re
import subprocess
import plistlib
import socket
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = Path.home() / "Library/Application Support/SpotFast"
SOCKET = SUPPORT / "FSearch/fsearch.sock"

def request(payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(3)
        stream.connect(str(SOCKET))
        stream.sendall(json.dumps(payload).encode() + b"\n")
        stream.shutdown(socket.SHUT_WR)
        line = stream.makefile("rb").readline(1_048_577)
        if len(line) > 1_048_576:
            raise RuntimeError("Oversized daemon response")
        return json.loads(line)

def registration_is_live(registration, job_output):
    match = re.search(r"(?m)^\s*pid = (\d+)\s*$", job_output)
    running = re.search(r"(?m)^\s*state = running\s*$", job_output)
    return bool(running and match and registration.get("registered")
        and registration.get("commandSpace") and int(match.group(1)) == registration.get("pid"))

def main():
    registration = plistlib.loads((SUPPORT / "registration.plist").read_bytes())
    job = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/local.spotfast.launcher"], capture_output=True, text=True)
    if job.returncode or not registration_is_live(registration, job.stdout):
        raise RuntimeError("SpotFast is stopped or its shortcut record is stale. Open SpotFast or restart its launcher login agent.")
    assert request({"op": "ping"}) == {"ok": True, "profile": "spotfast-names-v1"}
    assert request({"op": "save"})["ok"] is False, "Mutating operation was accepted"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(2)
        stream.connect(str(SOCKET))
        try:
            stream.sendall(b"x" * 8192 + b"\n")
        except BrokenPipeError:
            pass
        try:
            assert not stream.recv(1), "Oversized request was accepted"
        except ConnectionResetError:
            pass
    assert request({"op": "ping"})["ok"], "Daemon failed after rejecting the oversized request"
    fixture = ROOT / ".build/spotfast-runtime-probe.txt"
    fixture.write_text("SpotFast runtime file-search verification fixture.\n")
    deadline = time.monotonic() + 300
    try:
        while True:
            response = request({"q": "'spotfast-runtime-probe.txt", "limit": 30})
            if response.get("ok") and any(hit["path"] == str(fixture) for hit in response.get("hits", [])):
                print("Verified real filename search and Command–Space registration.", flush=True)
                break
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Filename search did not return the verification fixture: {response.get('error', 'no matching result')}")
            print(response.get("error", "Waiting for file events to appear"), flush=True)
            time.sleep(10)
        for bad in [{"q": "grep:secret"}, {"q": "hello", "offset": 999999}, {"q": "hello", "budget_ms": 0}]:
            assert request(bad)["ok"] is False, f"Unsafe query was accepted: {bad}"
        status = request({"op": "status"})["status"]
        assert status["content_docs"] == 0 and status["content_pending"] == 0
        assert not status["full_disk_access"]
        print(json.dumps({"entries": status["entries"], "dirs": status["dirs"], "index_bytes": status["index_bytes"],
            "full_disk_access": status["full_disk_access"], "content_docs": status["content_docs"]}), flush=True)
        print("Verified request rejection, daemon recovery, and filename-only restricted mode.", flush=True)
    finally:
        fixture.unlink(missing_ok=True)

if __name__ == "__main__":
    main()
