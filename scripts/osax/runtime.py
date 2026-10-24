#!/usr/bin/env python3
"""Valid-command probes for the loaded Swift payload; only touches disposable windows/spaces.

Read doc/live-testing.md first. Run after compatibility.py setup, outside the command sandbox.
No malformed traffic is sent to Dock. Space reconciliation is disabled only during this probe.
"""
import argparse
import ctypes
import json
import math
import os
import pathlib
import socket
import struct
import subprocess
import sys
import time

wid = None
dock = None
daemon = None
skylight = None
cid = None


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


def opacity(alpha, duration=0):
    response = request(struct.pack("=BIff", 8 if duration else 7, wid, alpha, duration))
    assert response == b"\0", f"opacity reply {response!r}"


def alpha():
    result = ctypes.c_float()
    status = skylight.SLSGetWindowAlpha(cid, wid, ctypes.byref(result))
    assert status == 0, f"alpha read {status}"
    return result.value


def endpoint(expected):
    observed = alpha()
    assert abs(observed - expected) < 0.015, (observed, expected)
    return observed


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
        original_alpha,
        created_spaces,
        space_layout,
        *,
        restore_opacity,
        query_spaces,
        cli_command):
    """Attempt every independent restore step and return labelled errors for the caller."""
    errors = []
    try:
        restore_opacity(original_alpha)
    except Exception as error:
        errors.append(("window opacity", error))

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
    global wid, dock, daemon, skylight, cid

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--window", type=int, help="Match the same disposable TextEdit window across builds")
    args = parser.parse_args(argv)

    unlocked()
    expected_version = "2.1.37"
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
    skylight = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
    skylight.SLSMainConnectionID.restype = ctypes.c_int
    skylight.SLSGetWindowAlpha.argtypes = [ctypes.c_int, ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
    cid = skylight.SLSMainConnectionID()
    original_alpha = alpha()
    original_spaces = {space["id"] for space in query("--spaces")}
    created_spaces = set()
    space_layout = cli("config", "space_layout")
    report = {"core": "swift", "version": version, "dock": dock, "daemon": daemon, "fixture": fixture, "wid": wid, "checks": {}}
    blocks = []

    probe_error = None
    probe_traceback = None
    try:
        opacity(0.45)
        report["checks"]["immediate"] = endpoint(0.45)
        opacity(0.8, 0.12)
        time.sleep(0.22)
        report["checks"]["fade_endpoint"] = endpoint(0.8)
        opacity(0.2, 0.3)
        time.sleep(0.04)
        opacity(0.9, 0.08)
        time.sleep(0.4)
        report["checks"]["replacement"] = endpoint(0.9)
        opacity(0.1, 0.2)
        time.sleep(0.04)
        opacity(0.7)
        time.sleep(0.3)
        report["checks"]["immediate_cancellation"] = endpoint(0.7)
        for index in range(100):
            opacity(0.3 if index % 2 else 0.8, 0.1)
        opacity(0.95)
        time.sleep(0.2)
        report["checks"]["rapid_replacement"] = endpoint(0.95)
        response = request(struct.pack("=BIff", 7, 0xffffffff, 1, 0))
        # SkyLight may return success even for an unknown window. Record its acknowledgement;
        # never equate it with an observed effect. A nonexistent space has a detectable lookup failure.
        report["unknown_window_opacity_reply"] = response.hex()
        response = request(struct.pack("=BQ", 2, 0xffffffffffffffff))
        assert response == b"\3", f"missing native failure: {response!r}"
        report["checks"]["native_failure_reply"] = response.hex()
        for block in range(3):
            timings = []
            for index in range(250):
                started = time.perf_counter_ns()
                opacity(0.95 if index % 2 else 1)
                timings.append((time.perf_counter_ns() - started) / 1000)
            ordered = sorted(timings)
            blocks.append({"microseconds": timings, **{name: ordered[math.ceil(len(ordered) * p) - 1] for name, p in (("median", .5), ("p95", .95), ("p99", .99))}})
        report["opacity_roundtrips"] = blocks
        opacity(original_alpha)
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
        original_alpha,
        created_spaces,
        space_layout,
        restore_opacity=opacity,
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
    print(json.dumps({key: value for key, value in report.items() if key != "opacity_roundtrips"}, indent=2))
    print("Opacity round-trip median/p95/p99 (us):", [(block["median"], block["p95"], block["p99"]) for block in blocks])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
