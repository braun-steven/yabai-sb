import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "cli-smoke.py"
SPEC = importlib.util.spec_from_file_location("cli_smoke", SCRIPT)
cli_smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli_smoke)


class CliSmokeTests(unittest.TestCase):
    def executable(self, directory):
        binary = Path(directory) / "yabai"
        binary.write_text("fake executable\n", encoding="utf-8")
        binary.chmod(0o755)
        return binary

    def test_main_accepts_version_and_config_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = self.executable(temporary)
            calls = []

            def fake_run(command, **options):
                calls.append((command, options))
                if command[1:] == ["--version"]:
                    return subprocess.CompletedProcess(command, 0, "yabai-v7.1.16\n", "")
                self.assertEqual(command[1], "--check-config")
                self.assertTrue(Path(command[2]).is_file())
                return subprocess.CompletedProcess(command, 0, "checked 1 settings, 0 failures\n", "")

            output = io.StringIO()
            with mock.patch.object(cli_smoke.subprocess, "run", side_effect=fake_run), \
                    mock.patch("sys.argv", [str(SCRIPT), str(binary)]), \
                    contextlib.redirect_stdout(output):
                status = cli_smoke.main()

        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 2)
        self.assertIn("PASS --version", output.getvalue())
        self.assertIn("PASS --check-config", output.getvalue())

    def test_main_reports_fake_subprocess_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = self.executable(temporary)
            output = io.StringIO()

            with mock.patch.object(
                    cli_smoke.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([str(binary), "--version"], 7, "", "fake failure")), \
                    mock.patch("sys.argv", [str(SCRIPT), str(binary)]), \
                    contextlib.redirect_stderr(output):
                status = cli_smoke.main()

        self.assertEqual(status, 1)
        self.assertIn("FAIL --version exited 7", output.getvalue())


if __name__ == "__main__":
    unittest.main()
