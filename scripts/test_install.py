import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("spotfast_install", Path(__file__).with_name("install.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class InstallTests(unittest.TestCase):
    def test_stop_waits_for_async_job_removal(self):
        completed = lambda code: subprocess.CompletedProcess([], code, b"", b"")
        # Launcher: bootout returns, job remains briefly, then disappears.
        # Daemon: already gone after bootout.
        with patch.object(installer.subprocess, "run", side_effect=[completed(0), completed(0), completed(113), completed(0), completed(113)]) as run, \
             patch.object(installer.time, "sleep") as sleep:
            installer.stop_jobs()
        self.assertEqual(run.call_count, 5)
        sleep.assert_called_once_with(0.1)

    def test_bootstrap_retries_only_transient_failure(self):
        failed = subprocess.CompletedProcess([], 5, b"", b"teardown pending")
        success = subprocess.CompletedProcess([], 0, b"", b"")
        with patch.object(installer.subprocess, "run", side_effect=[failed, success]), patch.object(installer.time, "sleep") as sleep:
            installer.load_agent(installer.LABELS[0])
            sleep.assert_called_once_with(0.2)
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 78, b"", b"invalid plist")):
            with self.assertRaises(RuntimeError):
                installer.load_agent(installer.LABELS[0])

    def test_shortcut_update_preserves_other_settings_and_custom_binding(self):
        current = {"Other": "keep", "AppleSymbolicHotKeys": {
            "64": {"enabled": True, "value": {"parameters": [99, 49, 1048576], "type": "standard"}},
            "65": {"enabled": True}, "123": {"enabled": False}}}
        snapshot = plistlib.dumps(current)
        result = installer.shortcut_preferences(current, False)
        self.assertFalse(result["AppleSymbolicHotKeys"]["64"]["enabled"])
        self.assertEqual(result["AppleSymbolicHotKeys"]["64"]["value"], current["AppleSymbolicHotKeys"]["64"]["value"])
        self.assertEqual(result["AppleSymbolicHotKeys"]["65"], current["AppleSymbolicHotKeys"]["65"])
        self.assertEqual(plistlib.dumps(current), snapshot)

    def test_default_spotlight_binding(self):
        result = installer.shortcut_preferences({}, False)
        self.assertEqual(result["AppleSymbolicHotKeys"]["64"]["value"]["parameters"], [32, 49, 1048576])

    def test_rollback_restores_only_changed_shortcut_and_preferences(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backup = root / "backup"
            backup.mkdir()
            agents = root / "agents"
            agents.mkdir()
            app = root / "SpotFast.app"
            app.mkdir()
            (app / "new").write_text("new app")
            (backup / "previous-app").mkdir()
            (backup / "previous-app/old").write_text("old app")
            state = {"hadShortcut": False, "shortcut": {}, "loadedJobs": [], "appSettings": {"commandSpace": False}}
            (backup / "state.plist").write_bytes(plistlib.dumps(state))
            writes = {}
            keyboard = {"AppleSymbolicHotKeys": {"64": {"enabled": False}, "65": {"enabled": False}}, "Untouched": 7}
            app_settings = {"commandSpace": True, "useFSearch": True, "Other": 9}
            with patch.object(installer, "APP", app), patch.object(installer, "AGENTS", agents), \
                 patch.object(installer, "stop_jobs"), patch.object(installer, "run"), \
                 patch.object(installer, "read_preferences", side_effect=[keyboard, app_settings]), \
                 patch.object(installer, "write_preferences", side_effect=lambda domain, value: writes.update({domain: value})):
                installer.restore(backup)
            self.assertNotIn("64", writes[installer.PREFS]["AppleSymbolicHotKeys"])
            self.assertFalse(writes[installer.PREFS]["AppleSymbolicHotKeys"]["65"]["enabled"])
            self.assertEqual(writes[installer.PREFS]["Untouched"], 7)
            self.assertFalse(writes["local.spotfast.launcher"]["commandSpace"])
            self.assertNotIn("useFSearch", writes["local.spotfast.launcher"])
            self.assertEqual(writes["local.spotfast.launcher"]["Other"], 9)
            self.assertTrue((app / "old").exists())
            self.assertFalse((app / "new").exists())

    def test_atomic_plist_writer_refuses_symlink_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.write_bytes(b"preserve")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises(RuntimeError):
                installer.save_plist(link, {"new": "data"})
            self.assertEqual(target.read_bytes(), b"preserve")

if __name__ == "__main__":
    unittest.main()
