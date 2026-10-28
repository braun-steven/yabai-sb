#!/usr/bin/env python3
"""Valid-command probes for the loaded Swift payload; only touches disposable windows/spaces.

Read doc/live-testing.md first. Run after compatibility.py setup, outside the command sandbox.
No malformed traffic is sent to Dock. Space reconciliation is disabled only during this probe.
"""
import argparse
import json
import math
import os
import pathlib
import re
import socket
import struct
import subprocess
import sys
import time

# The payload version of this checkout; the loaded payload must be this one.
COMMON_H = pathlib.Path(__file__).resolve().parents[2] / "osax" / "common.h"

wid = None
dock = None
daemon = None


def cli(*words):
    return subprocess.check_output([os.path.expanduser("~/.local/bin/yabai"), "-m", *map(str, words)], text=True).strip()


def query(*words):
    return json.loads(cli("query", *words))


def request(body):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(f"/tmp/yabai-sa_{os.environ['USER']}.socket")
        connection.sendall(struct.pack("=H", len(body)) + body)
        return connection.recv(256)


def noop():
    # A layer message for window id 0: the payload validates and dispatches it, and do_window_layer accepts it
    # without touching a window. It measures the socket round trip without a visible effect.
    response = request(struct.pack("=BIi", 9, 0, 0))
    assert response == b"\0", f"no-op reply {response!r}"


def footprint():
    output = subprocess.check_output(["vmmap", "-summary", str(dock)], text=True, stderr=subprocess.DEVNULL)
    return [line.strip() for line in output.splitlines() if line.startswith("Physical footprint:")][0]


def unlocked():
    code = 'import CoreGraphics; print((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true ? 1 : 0)'
    assert subprocess.check_output(["swift", "-e", code], text=True).strip() == "0", "desktop locked; discard this run"


def cleanup_disposable_spaces(created_spaces, query_spaces, cli_command):
    errors = []
    try:
        spaces = list(query_spaces())
    except Exception as error:
        return [("querying spaces for cleanup", error)]

    # Never destroy a pre-existing/ambiguous space, or one that acquired a window during the probe.
    for space in reversed(spaces):
        if space["id"] in created_spaces and not space["windows"]:
            try:
                cli_command("space", space["index"], "--destroy")
            except Exception as error:
                errors.append((f"destroying disposable space {space['id']}", error))
    return errors


def restore_probe_state(
        created_spaces,
        space_layout,
        *,
        query_spaces,
        cli_command):
    """Attempt every independent restore step and return labelled errors for the caller."""
    errors = []
    try:
        errors.extend(cleanup_disposable_spaces(created_spaces, query_spaces, cli_command))
    except Exception as error:
        errors.append(("disposable spaces", error))
    try:
        cli_command("config", "space_layout", *space_layout.split())
    except Exception as error:
        errors.append(("space_layout config", error))
    return errors


def main(argv=None):
    global wid, dock, daemon

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--window", type=int, help="Match the same disposable TextEdit window across builds")
    args = parser.parse_args(argv)

    unlocked()
    expected_version = re.search(r'#define OSAX_VERSION "([^"]+)"', COMMON_H.read_text())[1]
    version = request(b"\1").split(b"\0", 1)[0].decode()
    assert version == expected_version, (version, expected_version)
    windows = query("--windows", "--space", 4)
    fixture = sorted(window["id"] for window in windows if window["app"] in ("TextEdit", "Script Editor", "Calculator"))
    assert len(fixture) == 6, fixture
    wid = next(window["id"] for window in windows if window["app"] == "TextEdit")
    if args.window is not None:
        assert any(window["id"] == args.window and window["app"] == "TextEdit" for window in windows)
        wid = args.window
    dock = int(subprocess.check_output(["pgrep", "-x", "Dock"], text=True))
    daemon = int(subprocess.check_output(["pgrep", "-ox", "yabai"], text=True))
    original_spaces = {space["id"] for space in query("--spaces")}
    created_spaces = set()
    space_layout = cli("config", "space_layout")
    report = {"core": "swift", "version": version, "dock": dock, "daemon": daemon, "fixture": fixture, "wid": wid, "checks": {}}
    blocks = []

    probe_error = None
    probe_traceback = None
    try:
        response = request(struct.pack("=BQ", 2, 0xffffffffffffffff))
        assert response == b"\3", f"missing native failure: {response!r}"
        report["checks"]["native_failure_reply"] = response.hex()
        for block in range(3):
            timings = []
            for index in range(250):
                started = time.perf_counter_ns()
                noop()
                timings.append((time.perf_counter_ns() - started) / 1000)
            ordered = sorted(timings)
            blocks.append({"microseconds": timings, **{name: ordered[math.ceil(len(ordered) * p) - 1] for name, p in (("median", .5), ("p95", .95), ("p99", .99))}})
        report["roundtrips"] = blocks
        cli("config", "space_layout", "off")
        memory = [footprint()]
        for block in range(5):
            for cycle in range(10):
                cli("space", 4, "--create")
                spaces = query("--spaces")
                added = [space for space in spaces if space["id"] not in original_spaces]
                # A concurrent user-created space makes ownership ambiguous. Leave it untouched.
                assert len(added) == 1, added
                created_spaces.add(added[0]["id"])
                assert not added[0]["windows"], added
                cli("space", added[0]["index"], "--destroy")
                assert {space["id"] for space in query("--spaces")} == original_spaces
            memory.append(footprint())
        report["checks"]["space_create_destroy_cycles"] = 50
        report["dock_footprints"] = memory
    except BaseException as error:
        probe_error = error
        probe_traceback = error.__traceback__

    restore_errors = restore_probe_state(
        created_spaces,
        space_layout,
        query_spaces=lambda: query("--spaces"),
        cli_command=cli,
    )
    if probe_error is not None:
        for label, error in restore_errors:
            print(f"restore error ({label}): {error}", file=sys.stderr)
        raise probe_error.with_traceback(probe_traceback)
    if restore_errors:
        details = "; ".join(f"{label}: {error}" for label, error in restore_errors)
        raise RuntimeError(f"probe restoration failed: {details}")

    unlocked()
    assert dock == int(subprocess.check_output(["pgrep", "-x", "Dock"], text=True)), "Dock restarted"
    assert daemon == int(subprocess.check_output(["pgrep", "-ox", "yabai"], text=True)), "daemon restarted"
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "roundtrips"}, indent=2))
    print("Round-trip median/p95/p99 (us):", [(block["median"], block["p95"], block["p99"]) for block in blocks])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
