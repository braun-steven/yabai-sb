#!/usr/bin/env python3
"""Smoke-test CLI process startup without starting the daemon.

Run with an explicit built executable, for example:

    python3 scripts/cli-smoke.py "$(swift build --show-bin-path)/yabai"
"""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(binary, *arguments):
    try:
        return subprocess.run(
            [str(binary), *arguments], capture_output=True, text=True, timeout=10, check=False
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"command timed out: {binary} {' '.join(arguments)}") from error


def check(binary):
    version = run(binary, "--version")
    require(version.returncode == 0, f"--version exited {version.returncode}: {version.stderr!r}")
    require(
        re.fullmatch(r"yabai-v\S+\n?", version.stdout) is not None,
        f"unexpected --version output: {version.stdout!r}",
    )
    require(version.stderr == "", f"unexpected --version stderr: {version.stderr!r}")
    print("PASS --version")

    with tempfile.TemporaryDirectory(prefix="yabai-cli-smoke-") as temporary:
        config = Path(temporary) / "yabai.toml"
        config.write_text("[config]\nwindow_gap = 10\n", encoding="utf-8")

        checked = run(binary, "--check-config", str(config))
        require(
            checked.returncode == 0,
            f"--check-config exited {checked.returncode}: {checked.stdout!r} {checked.stderr!r}",
        )
        require(
            checked.stdout == "checked 1 settings, 0 failures\n",
            f"unexpected --check-config stdout: {checked.stdout!r}",
        )
        require(checked.stderr == "", f"unexpected --check-config stderr: {checked.stderr!r}")
        print("PASS --check-config with temporary config")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="path to the built yabai executable")
    options = parser.parse_args()

    try:
        binary = options.binary.resolve(strict=True)
        require(binary.is_file(), f"not a file: {binary}")
        require(binary.stat().st_mode & 0o111, f"not executable: {binary}")
        check(binary)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
