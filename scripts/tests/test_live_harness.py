import importlib.util
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "live-tests" / "live.py"
SPEC = importlib.util.spec_from_file_location("live_harness", SCRIPT)
live = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live)


class LiveHarnessTests(unittest.TestCase):
    def test_check_commands_return_nonzero_for_recorded_failure(self):
        for command in ("run", "extra", "launch", "topology"):
            with self.subTest(command=command):
                def fail(label):
                    live.record("fake check", False, "fake dependency failure")

                live.results.clear()
                with mock.patch.object(live, "build_helpers"), mock.patch.object(live, command, fail):
                    status = live.main([command, "unit"])
                self.assertEqual(status, 1)

    def test_cleanup_keeps_focus_checkpoint_if_restore_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = Path(temporary) / ".focused-window"
            checkpoint.write_text("12345\n", encoding="utf-8")
            failed = types.SimpleNamespace(returncode=1, stderr="focus failed")
            success = types.SimpleNamespace(returncode=0, stderr="")

            def fake_y(command, *args, **kwargs):
                return failed if command == "window --focus 12345" else success

            with mock.patch.object(live, "STATE", str(checkpoint)), \
                    mock.patch.object(live, "osa"), \
                    mock.patch.object(live, "y", side_effect=fake_y), \
                    mock.patch.object(live.time, "sleep"):
                with self.assertRaisesRegex(RuntimeError, "checkpoint window 12345"):
                    live.cleanup()

            self.assertTrue(checkpoint.exists())

    def test_launch_failure_resumes_frozen_app_and_restores_debug_output(self):
        for original in ("off", "on"):
            with self.subTest(original=original):
                calls = []
                success = types.SimpleNamespace(returncode=0, stdout="", stderr="")

                def fake_sh(command, *args, **kwargs):
                    calls.append(("sh", command, kwargs))
                    if command == "pgrep -x TextEdit":
                        return types.SimpleNamespace(returncode=1, stdout="", stderr="")
                    if command.endswith("freeze com.apple.TextEdit"):
                        return types.SimpleNamespace(returncode=0, stdout="4321\n", stderr="")
                    return success

                def fake_y(command, *args, **kwargs):
                    calls.append(("y", command, kwargs))
                    if command == "config debug_output":
                        return types.SimpleNamespace(
                            returncode=0, stdout=f"{original}\n", stderr="")
                    return success

                with mock.patch.object(live, "sh", side_effect=fake_sh), \
                        mock.patch.object(live, "y", side_effect=fake_y), \
                        mock.patch.object(live, "timed", side_effect=RuntimeError("query failed")), \
                        mock.patch.object(live.os.path, "getsize", return_value=0), \
                        mock.patch.object(live.time, "sleep"), \
                        mock.patch.object(live, "LAUNCH_WATCH", 1), \
                        mock.patch.dict("os.environ", {"USER": "test-user"}):
                    with self.assertRaisesRegex(RuntimeError, "query failed"):
                        live.launch("unit")

                self.assertIn(("sh", "kill -CONT 4321", mock.ANY), calls)
                self.assertIn(("y", f"config debug_output {original}", mock.ANY), calls)

    def test_launch_does_not_change_debug_output_when_textedit_is_already_running(self):
        calls = []
        running = types.SimpleNamespace(returncode=0, stdout="4321\n", stderr="")

        def fake_sh(command, *args, **kwargs):
            calls.append(("sh", command))
            return running

        def fake_y(command, *args, **kwargs):
            calls.append(("y", command))
            return types.SimpleNamespace(returncode=0, stdout="on\n", stderr="")

        with mock.patch.object(live, "sh", side_effect=fake_sh), \
                mock.patch.object(live, "y", side_effect=fake_y):
            live.launch("unit")

        self.assertEqual(calls, [("sh", "pgrep -x TextEdit")])


if __name__ == "__main__":
    unittest.main()
