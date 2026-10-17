#!/usr/bin/env python3
"""Exercise the SwiftPM build graph in a temporary copy of the working sources."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def snapshot(paths):
    return {
        path.name: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
        for path in paths
    }


class BuildCheck:
    def __init__(self, directory, swift):
        self.root = directory / "source"
        self.logs = directory / "logs"
        self.logs.mkdir()
        self.swift = shlex.split(swift)
        require(self.swift, "The Swift command is empty")
        self.environment = os.environ.copy()

        repository = Path(__file__).resolve().parent.parent
        self.root.mkdir()
        for name in ("Sources", "Plugins", "osax", "tests"):
            shutil.copytree(
                repository / name,
                self.root / name,
                ignore=shutil.ignore_patterns(
                    ".build", ".swiftpm", "__pycache__", "payload_bin.c", "loader_bin.c"
                ),
            )
        shutil.copy2(repository / "Package.swift", self.root / "Package.swift")
        (self.root / "assets").mkdir()
        shutil.copy2(repository / "assets/Info.plist", self.root / "assets/Info.plist")
        (self.root / "scripts").mkdir()
        for name in ("build-osax.sh", "osax-toolchain.sh"):
            shutil.copy2(repository / "scripts" / name, self.root / "scripts" / name)

    def run(self, name, arguments, environment=None):
        log = self.logs / (name + ".log")
        with log.open("w") as output:
            result = subprocess.run(
                arguments, cwd=self.root, env=environment or self.environment,
                stdout=output, stderr=subprocess.STDOUT,
            )
        text = log.read_text(errors="replace")
        diagnostics = re.findall(r"^.*(?:warning:|error:).*$", text, flags=re.I | re.M)
        require(
            result.returncode == 0 and not diagnostics,
            f"{name} failed (exit {result.returncode}); see {log}\n"
            + "\n".join(text.splitlines()[-35:]),
        )
        return text.strip()

    def build(self, name, environment=None, target=False):
        arguments = ["build", "--target", "OSAX"] if target else ["build", "--product", "yabai"]
        self.run(name, self.swift + arguments, environment)

    def unchanged(self, before, label):
        require(snapshot(self.artifacts) == before, f"{label}: native generation reran")

    def regenerated(self, before, label):
        after = snapshot(self.artifacts)
        for name in ("payload", "loader"):
            require(after[name][1] != before[name][1], f"{label}: {name} was not rebuilt")
            require(after[name][0] == before[name][0], f"{label}: {name} bytes changed")
        for name in ("payload_bin.c", "loader_bin.c"):
            require(after[name] == before[name], f"{label}: identical {name} was rewritten")

    def check(self):
        self.build("01-clean")
        outputs = list((self.root / ".build/plugins/outputs").rglob("payload_bin.c"))
        require(len(outputs) == 1, "Expected exactly one plugin-generated payload array")
        output = outputs[0].parent
        self.artifacts = [output / name for name in ("payload", "loader", "payload_bin.c", "loader_bin.c")]
        identity = output / "toolchain/Toolchain.h"
        require(identity.is_file(), "Missing native toolchain identity")
        require(not (self.root / "osax/payload_bin.c").exists(), "Generated C leaked into sources")
        require(not (self.root / "osax/loader_bin.c").exists(), "Generated C leaked into sources")
        binary_directory = Path(self.run("02-product-path", self.swift + ["build", "--show-bin-path"]))
        version = self.run("03-version", [str(binary_directory / "yabai"), "--version"])
        require(version.startswith("yabai-v"), "Built executable did not report its version")
        print("PASS clean build and embedded C linkage", flush=True)

        before = snapshot(self.artifacts)
        self.build("04-no-op")
        self.unchanged(before, "Second build")
        print("PASS no-op build", flush=True)

        header = self.root / "osax/common.h"
        header.write_bytes(header.read_bytes() + b"\n// Native-input smoke check.\n")
        self.build("05-native-input", target=True)
        self.regenerated(before, "Native input change")
        before = snapshot(self.artifacts)
        self.build("06-post-input-no-op", target=True)
        self.unchanged(before, "Build after native input change")
        print("PASS native input invalidation and timestamp preservation", flush=True)

        # Select the same Xcode explicitly (or through an equivalent path) to test invalidation
        # without requiring a second Xcode installation or changing system-wide xcode-select.
        changed = self.environment.copy()
        developer = changed.get("DEVELOPER_DIR")
        changed["DEVELOPER_DIR"] = (
            developer.rstrip("/") + "/." if developer else
            subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        )
        previous_identity = identity.read_bytes()
        self.build("07-toolchain-selection", changed, target=True)
        require(identity.read_bytes() != previous_identity, "Toolchain selection was not tracked")
        self.regenerated(before, "Toolchain selection change")
        before = snapshot(self.artifacts)
        self.build("08-post-toolchain-no-op", changed, target=True)
        self.unchanged(before, "Build after toolchain selection change")
        print("PASS toolchain selection invalidation and subsequent no-op", flush=True)

        self.run("09-tests", self.swift + ["test"])
        print("PASS Swift tests, including golden IPC", flush=True)
        print("Payload SHA-256: " + snapshot(self.artifacts)["payload"][0], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="xcrun swift", help="Swift command, parsed without a shell")
    parser.add_argument("--keep", action="store_true", help="Retain the temporary source copy and logs")
    options = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="yabai-build-check-"))
    print("Build checks: " + str(directory), flush=True)
    success = False
    try:
        BuildCheck(directory, options.swift).check()
        success = True
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), flush=True)
        print("Retained source copy and logs: " + str(directory), flush=True)
        return 1
    finally:
        if success and not options.keep:
            shutil.rmtree(directory)


if __name__ == "__main__":
    raise SystemExit(main())
