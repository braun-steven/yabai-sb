import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "osax" / "runtime.py"
SPEC = importlib.util.spec_from_file_location("osax_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class RuntimeRestoreTests(unittest.TestCase):
    def test_restore_attempts_config_after_space_errors(self):
        commands = []
        spaces = [
            {"id": 10, "index": 1, "windows": []},
            {"id": 20, "index": 2, "windows": []},
            {"id": 30, "index": 3, "windows": [999]},
            {"id": 40, "index": 4, "windows": []},
        ]

        def fake_cli(*words):
            commands.append(words)
            if words[:1] == ("space",):
                raise RuntimeError("space cleanup failed")
            return "restored"

        errors = runtime.restore_probe_state(
            {20, 30, 40},
            "15 10:5",
            query_spaces=lambda: spaces,
            cli_command=fake_cli,
        )

        self.assertEqual([command[:1] for command in commands], [("space",), ("space",), ("config",)])
        self.assertEqual(commands[-1], ("config", "space_layout", "15", "10:5"))
        self.assertEqual(
            [label for label, _ in errors],
            ["destroying disposable space 40", "destroying disposable space 20"],
        )

    def test_config_restore_is_attempted_when_space_query_fails(self):
        commands = []

        def fake_cli(*words):
            commands.append(words)

        def failed_query():
            raise RuntimeError("space query failed")

        errors = runtime.restore_probe_state(
            {20},
            "off",
            query_spaces=failed_query,
            cli_command=fake_cli,
        )

        self.assertEqual(commands, [("config", "space_layout", "off")])
        self.assertEqual([label for label, _ in errors], ["querying spaces for cleanup"])


if __name__ == "__main__":
    unittest.main()
