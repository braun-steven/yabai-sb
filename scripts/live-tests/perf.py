#!/usr/bin/env python3
"""Repeatable live latency and footprint capture for matched yabai builds.

Run after live.py setup with the same fixture windows for each build:
    python3 perf.py <label> [--samples 50] [--out /tmp/yabai-perf.json]

The command metric includes CLI process startup for `cli-*`. `socket-*` times the
same framed protocol directly. Completion metrics include query polling overhead
and are reported separately from the command round trip.
"""
import argparse
import hashlib
import json
import os
import platform
import pathlib
import re
import socket
import statistics
import struct
import subprocess
import sys
import time

SOCKET = f"/tmp/yabai_{os.environ.get('USER', '')}.socket"
YABAI = os.path.expanduser("~/.local/bin/yabai")
TEST_APPS = ("TextEdit", "Script Editor", "Calculator")
SESSION_LOCK_CHECK = (
    'import CoreGraphics; guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { '
    'fputs("session state unavailable\\n", stderr); exit(2) }; '
    'let locked = (d["CGSSessionScreenIsLocked"] as? Int) == 1 || '
    '(d["CGSSessionScreenIsLocked"] as? Bool) == true; print(locked ? 1 : 0)'
)


def run(argv, timeout=10):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def require_unlocked_session():
    result = run(["swift", "-e", SESSION_LOCK_CHECK], timeout=30)
    if result.returncode or result.stdout.strip().splitlines()[-1:] != ["0"]:
        state = result.stdout.strip() or result.stderr.strip() or f"exit {result.returncode}"
        raise SystemExit(f"benchmark requires an unlocked desktop; session check returned {state}")


def cli(args, timeout=10):
    return run([YABAI, "-m", *args], timeout)


def query(args):
    result = cli(["query", *args])
    if result.returncode:
        raise RuntimeError(f"query {' '.join(args)} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def _read_exact(sock, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("incomplete IPC response")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _read_reply(sock):
    magic, version, length = struct.unpack("!4sII", _read_exact(sock, 12))
    if magic != b"YBIP" or version != 2:
        raise RuntimeError("incompatible IPC protocol; restart yabai after upgrading")
    if not 0 < length <= 64 << 20:
        raise RuntimeError("invalid IPC response length")
    return json.loads(_read_exact(sock, length))


def socket_command(args):
    payload = json.dumps(
        {"type": "command", "arguments": args}, ensure_ascii=False,
        separators=(",", ":")).encode("utf-8")
    if not args or len(payload) > 1 << 20:
        raise ValueError("invalid or oversized IPC request")
    frame = struct.pack("!4sII", b"YBIP", 2, len(payload)) + payload
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(SOCKET)
        sock.sendall(frame)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            reply = _read_reply(sock)
            if reply["type"] == "error":
                raise RuntimeError(reply["message"])
            if reply["type"] == "complete":
                if not reply["ok"]:
                    raise RuntimeError("IPC command failed without an error")
                return b"".join(chunks)
            if reply["type"] != "output" or reply.get("command") != 1:
                raise RuntimeError("unexpected IPC response")
            if reply["format"] == "json":
                text = json.dumps(
                    reply["data"], ensure_ascii=False, sort_keys=True,
                    separators=(",", ":")) + "\n"
            elif reply["format"] == "text" and isinstance(reply["data"], str):
                text = reply["data"]
            else:
                raise RuntimeError("invalid IPC output format")
            chunks.append(text.encode("utf-8"))


def windows_on(space):
    return [w for w in query(["--windows", "--space", str(space)])
            if w.get("app") in TEST_APPS]


def focused_id():
    focused = query(["--windows", "--window"])
    return focused.get("id") if focused else None


def active_space():
    focused = query(["--spaces", "--space"])
    return focused.get("index") if focused else None


def daemon_pid():
    result = run(["pgrep", "-ox", "yabai"])
    return result.stdout.strip() if result.returncode == 0 else None


def rss_bytes(pid):
    if not pid:
        return None
    result = run(["ps", "-o", "rss=", "-p", pid])
    try:
        return int(result.stdout.strip()) * 1024
    except ValueError:
        return None


def vm_footprint_bytes(pid):
    if not pid:
        return None
    result = run(["vmmap", "-summary", pid], timeout=20)
    for line in result.stdout.splitlines():
        if "Physical footprint" not in line:
            continue
        match = re.search(r"([0-9.]+)\s*([KMG])", line, re.IGNORECASE)
        if match:
            amount = float(match.group(1))
            scale = {"K": 1024, "M": 1024**2, "G": 1024**3}[match.group(2).upper()]
            return int(amount * scale)
    return None


def percentile(values, fraction):
    ordered = sorted(values)
    # Nearest-rank percentile, stable for small samples and explicit in output.
    return ordered[max(0, min(len(ordered) - 1, int(len(ordered) * fraction + 0.999999) - 1))]


def summary(values):
    return {"samples": len(values), "failures": 0,
            "median_ms": statistics.median(values), "p90_ms": percentile(values, .90),
            "p95_ms": percentile(values, .95), "max_ms": max(values), "values_ms": values}


def measure(name, operation, count, warmup=5, pause=0.03):
    require_unlocked_session()
    failures = []
    for _ in range(warmup):
        try:
            operation()
        except Exception as error:
            failures.append(str(error))
    samples = []
    for index in range(count):
        started = time.perf_counter_ns()
        try:
            operation()
            samples.append((time.perf_counter_ns() - started) / 1e6)
        except Exception as error:
            failures.append(f"sample {index + 1}: {error}")
        if pause:
            time.sleep(pause)
    require_unlocked_session()
    result = summary(samples) if samples else {"samples": 0}
    result["failures"] = len(failures)
    if failures:
        result["failure_examples"] = failures[:5]
    print(f"{name:32} n={result['samples']:3} fail={result['failures']:2} "
          f"med={result.get('median_ms', float('nan')):8.2f} "
          f"p95={result.get('p95_ms', float('nan')):8.2f} "
          f"max={result.get('max_ms', float('nan')):8.2f}", flush=True)
    return result


def wait_until(predicate, timeout=2.0, interval=.005):
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def footprint(pid):
    return {"pid": pid, "rss_bytes": rss_bytes(pid),
            "physical_footprint_bytes": vm_footprint_bytes(pid)}


def dock_footprint():
    result = run(["pgrep", "-x", "Dock"])
    pid = result.stdout.splitlines()[0] if result.returncode == 0 and result.stdout.strip() else None
    return footprint(pid)


def window_server_rss():
    result = run(["pgrep", "-x", "WindowServer"])
    pid = result.stdout.splitlines()[0] if result.returncode == 0 and result.stdout.strip() else None
    return {"pid": pid, "rss_bytes": rss_bytes(pid), "scope": "system-wide, noisy process metric"}


def window_server_frame(window_id):
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bounds")
    result = run([helper, str(window_id)])
    if result.returncode:
        raise RuntimeError(f"bounds helper failed: {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) == 5 and int(fields[0]) == window_id:
            return tuple(float(value) for value in fields[1:])
    raise RuntimeError(f"window server has no bounds for window {window_id}")


def tree_leaves(node):
    if node.get("window"):
        yield node["window"]
    for child in node.get("nodes") or []:
        yield from tree_leaves(child)


def normalize_flat_row():
    tree = query(["--tree", "--space", "4"])
    anchors = [child["window"] for child in tree.get("nodes") or [] if child.get("window")]
    leaves = list(tree_leaves(tree))
    if anchors and leaves:
        result = cli(["window", str(anchors[0]), "--layout", "splith"])
        if result.returncode:
            raise RuntimeError(f"set root split layout: {result.stderr.strip()}")
        for window_id in leaves:
            if window_id not in anchors:
                result = cli(["window", str(window_id), "--warp", str(anchors[0])])
                if result.returncode:
                    raise RuntimeError(f"flatten window {window_id}: {result.stderr.strip()}")
        result = cli(["space", "4", "--balance"])
        if result.returncode:
            raise RuntimeError(f"balance space 4: {result.stderr.strip()}")


def tree_shape(node):
    return {"type": node.get("type"), "layout": node.get("layout"), "window": node.get("window"),
            "frame": node.get("frame"), "nodes": [tree_shape(child) for child in node.get("nodes") or []]}


def config_snapshot():
    keys = ("window_border", "window_border_width", "active_window_border_color",
            "normal_window_border_color", "focus_follows_mouse",
            "mouse_follows_focus", "tree_autotiling", "tree_workspace_layout", "tree_default_orientation",
            "tab_bar", "tab_bar_height", "tab_bar_backdrop")
    snapshot = {}
    for key in keys:
        result = cli(["config", key])
        snapshot[key] = result.stdout.strip() if result.returncode == 0 else f"ERROR: {result.stderr.strip()}"
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("--samples", type=int, default=50)
    parser.add_argument("--out", help="JSON output path; default is stdout summary only")
    parser.add_argument("--footprint-only", action="store_true",
                        help="capture daemon/Dock RSS and physical footprint for the current layout/config")
    args = parser.parse_args()
    if args.samples < 30:
        parser.error("--samples must be at least 30")
    if platform.system() != "Darwin":
        parser.error("live yabai benchmark requires macOS")
    require_unlocked_session()

    # Capture the requested idle/config states independently of live operations.
    if args.footprint_only:
        pid = daemon_pid()
        if not pid:
            raise SystemExit("yabai daemon is not running")
        result = {"label": args.label, "sampled_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "daemon": footprint(pid), "dock": dock_footprint(),
                  "window_server": window_server_rss(),
                  "active_space": active_space(), "config": config_snapshot(),
                  "space4_tree": query(["--tree", "--space", "4"]),
                  "window_count": len(query(["--windows"]))}
        require_unlocked_session()
        print(json.dumps(result, indent=2))
        if args.out:
            with open(args.out, "w", encoding="utf-8") as output:
                json.dump(result, output, indent=2)
                output.write("\n")
        return

    # Fail closed unless the documented disposable fixture is present.
    space4, space5, space12 = windows_on(4), windows_on(5), windows_on(12)
    if len(space4) < 3:
        raise SystemExit(f"fixture incomplete: only {len(space4)} test app windows on space 4")
    tiled4 = [w for w in space4 if not w.get("is-floating")]
    if len(tiled4) < 3:
        raise SystemExit(f"space 4 needs at least 3 tiled test windows; found {len(tiled4)}")
    first = tiled4[0]["id"]
    other = next((w["id"] for w in tiled4 if w["id"] != first), None)
    same_app = next((w["id"] for w in tiled4 if w["app"] == tiled4[0]["app"] and w["id"] != first), None)
    cross_app = next((w["id"] for w in tiled4 if w["app"] != tiled4[0]["app"]), None)
    if same_app is None or cross_app is None:
        raise SystemExit("space 4 fixture needs two tiled windows in one app and one in another app")

    original_tree = query(["--tree", "--space", "4"])
    if active_space() != 4:
        result = cli(["space", "--focus", "4"])
        if result.returncode:
            raise SystemExit(f"cannot activate benchmark space 4: {result.stderr.strip()}")
    normalize_flat_row()
    normalized_tree = query(["--tree", "--space", "4"])
    if normalized_tree.get("layout") != "splith" or len(normalized_tree.get("nodes") or []) != 5 or any(
        child.get("type") != "window" for child in normalized_tree.get("nodes") or []
    ):
        raise SystemExit("space 4 did not normalize to a flat splith root with five tiled windows")

    executable = os.path.realpath(YABAI)
    if not os.path.isfile(executable):
        raise SystemExit(f"installed yabai binary is missing: {executable}")
    record = {"label": args.label, "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "binary": executable,
              "binary_sha256": hashlib.sha256(pathlib.Path(executable).read_bytes()).hexdigest(),
              "binary_uuid": run(["dwarfdump", "--uuid", executable]).stdout.strip(),
              "version": run([executable, "--version"]).stdout.strip(), "daemon_pid": daemon_pid(),
              "host": {"macos": run(["sw_vers", "-productVersion"]).stdout.strip(),
                       "architecture": run(["uname", "-m"]).stdout.strip()},
              "initial_focused_window": focused_id(), "initial_active_space": active_space(),
              "original_setup_tree": original_tree, "initial_tree": normalized_tree,
              "fixture": {"space4": [w["id"] for w in space4], "space5": [w["id"] for w in space5],
                          "space12": [w["id"] for w in space12]}, "measurements": {}}
    record["footprint_start"] = {"daemon": footprint(record["daemon_pid"]), "dock": dock_footprint(),
                                  "window_server": window_server_rss(),
                                  "window_count": len(query(["--windows"])), "config": config_snapshot()}
    print(f"label={args.label} version={record['version']} daemon_pid={record['daemon_pid']} "
          f"fixture={record['fixture']}", flush=True)

    query_args = ["query", "--windows", "--space", "4"]
    def checked_cli(*arguments):
        result = cli(list(arguments))
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"exit {result.returncode}")
        return result

    def checked_socket(*arguments):
        return socket_command(list(arguments))

    cli_probe = checked_cli(*query_args).stdout.encode()
    socket_probe = checked_socket(*query_args)
    if not socket_probe or json.loads(socket_probe) != json.loads(cli_probe):
        raise RuntimeError("raw-socket preflight response was empty or differed from CLI query")

    def focus_command_pair(left, right):
        current = [focused_id()]
        def operation():
            target = right if current[0] == left else left
            checked_cli("window", "--focus", str(target))
            current[0] = target
        return operation

    rotator = [90]
    def rotate_alternating():
        angle = rotator[0]
        checked_cli("space", "4", "--rotate", str(angle))
        rotator[0] = 270 if angle == 90 else 90

    operations = {
        "cli-query-roundtrip": lambda: checked_cli(*query_args),
        "socket-query-roundtrip": lambda: checked_socket(*query_args),
        "focus-same-app-roundtrip": focus_command_pair(first, same_app),
        "focus-cross-app-roundtrip": focus_command_pair(first, cross_app),
        "focus-tab-roundtrip": focus_command_pair(first, other),
        "focus-split-roundtrip": focus_command_pair(first, other),
        "rotate-alternating-command": rotate_alternating,
    }
    for name, operation in operations.items():
        # Restore the tree layout before tab/split focus samples.
        if name == "focus-tab-roundtrip":
            checked_cli("window", "--focus", str(first))
            checked_cli("window", "--layout", "tabbed")
            time.sleep(.4)
        if name == "focus-split-roundtrip":
            checked_cli("window", str(first), "--layout", "splith")
            time.sleep(.4)
        record["measurements"][name] = measure(name, operation, args.samples)
        if name == "rotate-alternating-command" and rotator[0] == 270:
            checked_cli("space", "4", "--rotate", "270")
    # Move one disposable test window to space 12 and back after every sample so
    # membership and geometry return to the original state.
    mover = next((w["id"] for w in space4 if w["app"] == "TextEdit"), first)

    def send_to_12_and_back():
        checked_cli("window", str(mover), "--space", "12")
        deadline = time.perf_counter() + 2
        while time.perf_counter() < deadline:
            moved = query(["--windows", "--window", str(mover)])
            if moved and moved.get("space") == 12:
                break
            time.sleep(.01)
        else:
            raise RuntimeError(f"window {mover} did not arrive on space 12")
        checked_cli("window", str(mover), "--space", "4")
        deadline = time.perf_counter() + 2
        while time.perf_counter() < deadline:
            moved = query(["--windows", "--window", str(mover)])
            if moved and moved.get("space") == 4:
                return
            time.sleep(.01)
        raise RuntimeError(f"window {mover} did not return to space 4")

    record["measurements"]["send-to-space-12-roundtrip"] = measure(
        "send-to-space-12-roundtrip", send_to_12_and_back, args.samples, pause=.05)

    # TextEdit resizes freely; Calculator's floating frame can be fixed-size. Float a
    # disposable tiled TextEdit window temporarily and restore its tiled state later.
    float_id = next((w["id"] for w in tiled4 if w["app"] == "TextEdit"), None)
    if float_id is not None:
        checked_cli("window", str(float_id), "--toggle", "float")
        float_base = window_server_frame(float_id)

        def float_move_pair(observe):
            checked_cli("window", str(float_id), "--move", "rel:4:0")
            if observe and not wait_until(lambda: abs(window_server_frame(float_id)[0] - (float_base[0] + 4)) < 1):
                raise RuntimeError("window server did not show moved floating frame")
            checked_cli("window", str(float_id), "--move", "rel:-4:0")
            if observe and not wait_until(lambda: abs(window_server_frame(float_id)[0] - float_base[0]) < 1):
                raise RuntimeError("window server did not show restored floating frame")

        def float_resize_pair(observe):
            checked_cli("window", str(float_id), "--resize", "right:4:0")
            if observe and not wait_until(lambda: abs(window_server_frame(float_id)[2] - (float_base[2] + 4)) < 1):
                raise RuntimeError("window server did not show resized floating frame")
            checked_cli("window", str(float_id), "--resize", "right:-4:0")
            if observe and not wait_until(lambda: abs(window_server_frame(float_id)[2] - float_base[2]) < 1):
                raise RuntimeError("window server did not show restored floating frame")

        record["measurements"]["floating-move-command-pair"] = measure(
            "floating-move-command-pair", lambda: float_move_pair(False), args.samples, pause=.05)
        record["measurements"]["floating-move-window-server-pair"] = measure(
            "floating-move-window-server-pair", lambda: float_move_pair(True), args.samples, pause=.05)
        record["measurements"]["floating-resize-command-pair"] = measure(
            "floating-resize-command-pair", lambda: float_resize_pair(False), args.samples, pause=.05)
        record["measurements"]["floating-resize-window-server-pair"] = measure(
            "floating-resize-window-server-pair", lambda: float_resize_pair(True), args.samples, pause=.05)
        checked_cli("window", str(float_id), "--toggle", "float")
        checked_cli("space", "4", "--balance")
    else:
        record["measurements"]["floating-move-window-server-pair"] = {"samples": 0, "failures": 0,
                                                                       "skipped": "no tiled TextEdit fixture"}

    def alternating_focus_observed(left, right):
        current = [focused_id()]
        def operation():
            target = right if current[0] == left else left
            checked_cli("window", "--focus", str(target))
            if not wait_until(lambda: focused_id() == target):
                raise RuntimeError(f"window {target} did not become focused")
            current[0] = target
        return operation

    record["measurements"]["focus-same-app-observed"] = measure(
        "focus-same-app-observed", alternating_focus_observed(first, same_app), args.samples, pause=.06)
    record["measurements"]["focus-cross-app-observed"] = measure(
        "focus-cross-app-observed", alternating_focus_observed(first, cross_app), args.samples, pause=.06)

    def alternating_space_observed(left, right):
        current = [active_space()]
        def operation():
            target = right if current[0] == left else left
            checked_cli("space", "--focus", str(target))
            if not wait_until(lambda: active_space() == target):
                raise RuntimeError(f"space {target} did not become active")
            current[0] = target
        return operation

    def alternating_space_command(left, right):
        current = [active_space()]
        def operation():
            target = right if current[0] == left else left
            checked_cli("space", "--focus", str(target))
            current[0] = target
        return operation

    for label, pair in (("space-4-5-roundtrip", (4, 5)),
                        ("space-4-5-observed", (4, 5)),
                        ("space-4-12-roundtrip", (4, 12)),
                        ("space-4-12-observed", (4, 12))):
        record["measurements"][label] = measure(
            label, (alternating_space_observed(*pair) if label.endswith("observed")
                    else alternating_space_command(*pair)), args.samples, pause=.06)

    # Restore test layout/focus and check that the daemon remained the same process.
    if active_space() != 4:
        checked_cli("space", "--focus", "4")
    normalize_flat_row()
    if record["initial_focused_window"]:
        checked_cli("window", "--focus", str(record["initial_focused_window"]))
    time.sleep(1.0)
    current_pid = daemon_pid()
    if current_pid != record["daemon_pid"]:
        raise RuntimeError(f"daemon pid changed during block: {record['daemon_pid']} -> {current_pid}")

    # Focus, active-space, and command results are distinct observations. The query
    # polling values above include the observer query cost and 5 ms poll interval.
    record["footprint_end"] = {"daemon": footprint(record["daemon_pid"]), "dock": dock_footprint(),
                                "window_server": window_server_rss(),
                                "window_count": len(query(["--windows"])), "config": config_snapshot(),
                                "active_space": active_space(), "capture_point": "after 1 s cooldown",
                                "tree": query(["--tree", "--space", "4"])}
    record["tree_shape_restored"] = (
        tree_shape(record["initial_tree"]) == tree_shape(record["footprint_end"]["tree"]))
    require_unlocked_session()
    if args.out:
        with open(args.out, "w", encoding="utf-8") as output:
            json.dump(record, output, indent=2)
            output.write("\n")
        print(f"wrote {args.out}", flush=True)


if __name__ == "__main__":
    main()
