#!/usr/bin/env python3
"""Run the existing live checks on empty spaces 4/5/13; keep user state in a snapshot.

This does not install or inject anything. Cleanup stops the test service before quitting apps;
immediately follow it with deploy.sh restore, then this script's restore action.
Read doc/live-testing.md first.
"""
import argparse
import importlib.util
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("live", ROOT / "scripts/live-tests/live.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
live.OTHER_SPACE = 13

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=["snapshot", "setup", "run", "extra", "cleanup", "restore"])
parser.add_argument("--state", type=pathlib.Path, required=True)
parser.add_argument("--label", default="osax")
args = parser.parse_args()
live.STATE = str(args.state) + ".focus"
settings = ["focus_follows_mouse", "mouse_follows_focus", "window_animation_duration",
            "tree_autotiling", "tree_workspace_layout", "tree_default_orientation"]


def unlocked():
    code = 'import CoreGraphics; if let d = CGSessionCopyCurrentDictionary() as? [String: Any] { print((d["CGSSessionScreenIsLocked"] as? Bool) == true ? 1 : 0) } else { exit(2) }'
    result = subprocess.run(["swift", "-e", code], capture_output=True, text=True, check=True)
    if result.stdout.strip() != "0":
        raise SystemExit("live checks require an unlocked desktop")


def checked(command):
    result = live.y(command)
    if result.returncode:
        raise RuntimeError(f"{command}: {result.stderr.strip()}")
    return result.stdout.strip()


def configure_fixture():
    # A deploy reapplies yabai.toml, which may turn autotiling back on. Hold the same controlled
    # settings across every reinsertion workload and restore the saved values afterward.
    for key, value in {"focus_follows_mouse": "off", "mouse_follows_focus": "off", "window_animation_duration": "0",
                       "tree_autotiling": "off", "tree_workspace_layout": "default", "tree_default_orientation": "horizontal"}.items():
        checked(f"config {key} {value}")


unlocked()
if args.action == "snapshot":
    if args.state.exists():
        raise SystemExit("snapshot already exists; restore it before starting another experiment")
    spaces = live.q("--spaces")
    for index in (4, 5, 13):
        space = next((space for space in spaces if space["index"] == index), None)
        if space is None or space["windows"]:
            raise SystemExit(f"space {index} must exist and be empty")
    for app in ("TextEdit", "Script Editor", "Calculator"):
        if subprocess.run(["pgrep", "-x", app], capture_output=True).returncode == 0:
            raise SystemExit(f"{app} is already running; do not reuse the user's app")
    state = {"config": {key: checked(f"config {key}") for key in settings},
             "visible": [space["index"] for space in spaces if space["is-visible"]],
             "layouts": {str(index): next(space["type"] for space in spaces if space["index"] == index) for index in (4, 5, 13)},
             "focus": (live.q("--windows --window") or {}).get("id")}
    args.state.write_text(json.dumps(state, indent=2) + "\n")
    print(f"Saved {args.state}")
    sys.exit(0)

state = json.loads(args.state.read_text())
live.RESTORE_OTHER = next((index for index in state["visible"] if 11 <= index <= 15), state["visible"][0])
if args.action == "setup":
    for app in ("TextEdit", "Script Editor", "Calculator"):
        if subprocess.run(["pgrep", "-x", app], capture_output=True).returncode == 0:
            raise SystemExit(f"{app} is already running; cleanup the previous fixture first")
    for index in (4, 5, 13):
        if (live.q(f"--spaces --space {index}") or {}).get("windows", [1]):
            raise SystemExit(f"space {index} must be empty")
    live.build_helpers()
    live.require_mouse_access()
    configure_fixture()
    for index in (4, 13):
        checked(f"space {index} --layout tree")
    live.setup()
elif args.action in ("run", "extra"):
    live.build_helpers()
    configure_fixture()
    (live.run if args.action == "run" else live.extra)(args.label)
    unlocked()
    failed = [result for result in live.results if not result[1]]
    print(f"{len(live.results) - len(failed)}/{len(live.results)} passed")
    sys.exit(bool(failed))
elif args.action == "cleanup":
    # Quiesce the test service before app termination can generate late AX destruction callbacks.
    # The next documented step restores the original binary and restarts its service.
    live.sh("yabai --stop-service", check=True)
    live.osa('tell application "TextEdit" to quit saving no')
    live.osa('tell application "Script Editor" to quit saving no')
    live.osa('tell application "Calculator" to quit')
    focus_file = pathlib.Path(live.STATE)
    if focus_file.exists():
        focus_file.unlink()
    print("Test service stopped and disposable apps closed; run deploy.sh restore immediately.")
elif args.action == "restore":
    for key, value in state["config"].items():
        if key == "focus_follows_mouse" and value == "disabled":
            value = "off"
        checked(f"config {key} {value}")
    for index, layout in state["layouts"].items():
        checked(f"space {index} --layout {layout}")
    for index in state["visible"]:
        space = live.q(f"--spaces --space {index}")
        if space and not space["is-visible"]:
            checked(f"space --focus {index}")
    if state["focus"]:
        checked(f"window --focus {state['focus']}")
    print("Restored config, visible spaces and focused window. Snapshot retained for inspection.")
