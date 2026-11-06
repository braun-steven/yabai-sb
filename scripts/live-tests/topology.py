#!/usr/bin/env python3
# Display change checks: every space holds the same windows in the same tree, on the same display, before and after.
# usage: topology.py snap <name>             saves the state of every display, space, window, tree and rule
#        topology.py show <name>             prints a saved state
#        topology.py diff <a> <b>            compares two saved states slot by slot; fails when they differ
#        topology.py fixture                 opens 12 TextEdit windows: a tab pair and a split on spaces 1, 11, 14 and 16
#        topology.py cleanup                 quits TextEdit, leaving the desktop to `restore`
#        topology.py restore <name>          puts the spaces, windows and focus back into a saved state, from any state
#        topology.py record <name> <seconds> records a change made by hand (a real cable): toporec and saved states
#        topology.py run <scenario> [hold]   runs a scenario, compares and restores; `scenarios` lists them
# The states and recordings are in ~/.local/state/yabai/topology-tests. Read doc/live-testing.md first.
import json, os, subprocess, sys, time
from sa_move import sa_move

TOOLS = os.path.dirname(os.path.abspath(__file__))
STATES = os.path.expanduser("~/.local/state/yabai/topology-tests")
FIXTURE_SPACES = (1, 11, 14, 16)
SETTLE = 12  # the seconds after the last display change before a state is read; macOS still moves windows after that

def y(*args, timeout=20):
    return subprocess.run(["yabai", "-m", *args], capture_output=True, text=True, timeout=timeout)

def q(*args):
    r = y("query", *args)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None

def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)

def build(name):
    # Compiles a Swift helper when it is missing or older than its source.
    src, out = os.path.join(TOOLS, name + ".swift"), os.path.join(TOOLS, name)
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        subprocess.run(["swiftc", "-O", "-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight",
                        src, "-o", out], check=True, timeout=300)
    return out

def shape(node):
    if node is None: return "?"
    if node.get("type") == "window": return str(node["window"])
    return (node.get("layout") or "?") + "[" + " ".join(shape(c) for c in node["nodes"]) + "]"

def tree_windows(node, out):
    if node is None: return out
    if node.get("type") == "window": out.append(node["window"])
    for child in node.get("nodes") or []: tree_windows(child, out)
    return out

def state():
    spaces = q("--spaces") or []
    trees = {s["index"]: q("--tree", "--space", str(s["index"])) for s in spaces}
    rules = json.loads(y("rule", "--list").stdout or "[]")
    focused = q("--windows", "--window")
    return {"time": time.time(), "displays": q("--displays") or [], "spaces": spaces, "windows": q("--windows") or [],
            "trees": {str(k): shape(v) for k, v in trees.items()}, "rules": rules,
            "focused": focused["id"] if focused else None}

def path(name):
    os.makedirs(STATES, exist_ok=True)
    return os.path.join(STATES, name + ".json")

def save(name, value):
    with open(path(name), "w") as f: json.dump(value, f, indent=1)

def load(name):
    with open(path(name)) as f: return json.load(f)

def show(s):
    for d in sorted(s["displays"], key=lambda d: d["index"]):
        print(f"display {d['index']} id {d['id']} {d['uuid'][:8]} spaces {d['spaces']}")
    by_space = {}
    for w in s["windows"]: by_space.setdefault(w["space"], []).append(w["id"])
    for p in s["spaces"]:
        shown = "V" if p["is-visible"] else " "
        print(f"  {p['index']:>2} id {p['id']:>4} {p['uuid'][:8]} d{p['display']} {shown} "
              f"{sorted(by_space.get(p['index'], []))} {s['trees'].get(str(p['index']))}")

def differences(a, b):
    # The slot oracle: everything the user sees, by space index. The ids and uuids of the spaces may change.
    found = []
    if len(a["spaces"]) != len(b["spaces"]):
        found.append(f"{len(a['spaces'])} spaces became {len(b['spaces'])}")
    display_of = lambda s: {p["index"]: next(d["uuid"] for d in s["displays"] if d["index"] == p["display"])
                            for p in s["spaces"]}
    da, db = display_of(a), display_of(b)
    moved = [(i, u[:8], db[i][:8]) for i, u in da.items() if i in db and db[i] != u]
    if moved and {d["uuid"] for d in a["displays"]} == {d["uuid"] for d in b["displays"]}:
        found.append(f"spaces on another display: {moved}")
    now = {w["id"]: w for w in b["windows"]}
    for w in a["windows"]:
        n = now.get(w["id"])
        if n is None:
            found.append(f"window {w['id']} {w['app']} is gone")
        elif n["space"] != w["space"]:
            found.append(f"window {w['id']} {w['app']} on space {n['space']}, was {w['space']}")
        elif w["is-floating"] and w["frame"] != n["frame"] and not w["is-minimized"]:
            found.append(f"floating window {w['id']} {w['app']} moved: {w['frame']} became {n['frame']}")
    for i, tree in a["trees"].items():
        if b["trees"].get(i) != tree:
            found.append(f"tree of space {i}: {tree} became {b['trees'].get(i)}")
    visible = lambda s: sorted(p["index"] for p in s["spaces"] if p["is-visible"])
    if visible(a) != visible(b) and len(a["displays"]) == len(b["displays"]):
        found.append(f"visible spaces {visible(a)} became {visible(b)}")
    if a["focused"] != b["focused"]:
        found.append(f"focus {a['focused']} became {b['focused']}")
    rule_spaces = lambda s: [r.get("space") for r in s["rules"]]
    if rule_spaces(a) != rule_spaces(b):
        found.append(f"rule spaces {rule_spaces(a)} became {rule_spaces(b)}")
    return found

def report(title, a, b):
    found = differences(a, b)
    print(f"{'PASS' if not found else 'FAIL'}  {title}  {len(found)} difference(s)")
    for line in found: print("   ", line)
    return not found

def fixture():
    spaces = q("--spaces")
    busy = {w["space"] for w in q("--windows")}
    if len(spaces) < max(FIXTURE_SPACES):
        raise SystemExit(f"the fixture needs {max(FIXTURE_SPACES)} spaces")
    start = next((s["index"] for s in spaces if s["index"] not in busy and not s["is-native-fullscreen"]
                  and s["index"] not in FIXTURE_SPACES), None)
    if start is None: raise SystemExit("the fixture needs an empty space")
    before = state()
    y("space", "--focus", str(start)); time.sleep(0.7)
    subprocess.run(["open", "-a", "TextEdit"]); time.sleep(1.5)
    osa('tell application "TextEdit" to close (every window whose name is not "Untitled")')
    for _ in range(12):
        osa('tell application "TextEdit" to make new document'); time.sleep(0.35)
    time.sleep(1)
    ids = sorted(w["id"] for w in q("--windows") if w["app"] == "TextEdit" and w["has-ax-reference"])[:12]
    for n, chunk in zip(FIXTURE_SPACES, (ids[i:i + 3] for i in range(0, 12, 3))):
        for w in chunk:
            r = y("window", str(w), "--space", str(n)); time.sleep(0.3)
            if r.returncode: print("move", w, r.stderr.strip())
        r = y("window", str(chunk[1]), "--stack", str(chunk[2])); time.sleep(0.3)
        if r.returncode: print("stack", r.stderr.strip())
    refocus(before)

def cleanup():
    osa('tell application "TextEdit" to quit saving no'); time.sleep(1.5)

def refocus(s):
    for p in s["spaces"]:
        if p["is-visible"]:
            y("space", "--focus", str(p["index"])); time.sleep(0.5)
    if s["focused"]:
        w = next((w for w in s["windows"] if w["id"] == s["focused"]), None)
        if w: y("space", "--focus", str(w["space"])); time.sleep(0.5)
        y("window", "--focus", str(s["focused"]))

def restore(target):
    # NOTE: `space_layout` must be off here: its reconcile would undo these steps and shift the indices.
    layout = y("config", "space_layout").stdout.strip()
    y("config", "space_layout", "off")
    try:
        restore_spaces(target)
        restore_windows(target)
        refocus(target)
    finally:
        if layout: y("config", "space_layout", *layout.split())
        y("config", "--reload")

def restore_spaces(target):
    slots = [s["uuid"] for s in target["spaces"]]
    display = {s["uuid"]: s["display"] for s in target["spaces"]}
    # A slot whose uuid is gone takes an extra space, or a new one; the empty extras that are left over are destroyed.
    spaces, windows = q("--spaces"), q("--windows")
    live = {s["uuid"] for s in spaces}
    missing = [i for i, u in enumerate(slots) if u not in live]
    extras = [s for s in spaces if s["uuid"] not in slots]
    extras.sort(key=lambda s: any(w["space"] == s["index"] for w in windows), reverse=True)
    for i in missing:
        if extras:
            slots[i] = extras.pop(0)["uuid"]
        else:
            before = {s["uuid"] for s in q("--spaces")}
            y("space", "--create"); time.sleep(0.4)
            slots[i] = next(s["uuid"] for s in q("--spaces") if s["uuid"] not in before)
        display[slots[i]] = target["spaces"][i]["display"]
    for s in sorted(extras, key=lambda s: -s["index"]):
        if any(w["space"] == s["index"] for w in windows):
            print("keeping extra space with windows:", s["index"])
        else:
            y("space", str(s["index"]), "--destroy"); time.sleep(0.4)
    for u in slots:
        s = next(s for s in q("--spaces") if s["uuid"] == u)
        if s["display"] != display[u]:
            y("space", str(s["index"]), "--display", str(display[u])); time.sleep(0.6)
    for i, u in enumerate(slots):
        at = {s["uuid"]: s["index"] for s in q("--spaces")}
        if at[u] != i + 1:
            y("space", str(at[u]), "--swap", str(i + 1)); time.sleep(0.4)
    spaces = q("--spaces")
    print("space order restored:", [s["uuid"] for s in spaces] == slots, len(spaces), "spaces")

def restore_windows(target):
    wanted = {w["id"]: w["space"] for w in target["windows"]}
    for _ in range(3):
        sid = {s["index"]: s["id"] for s in q("--spaces")}
        stray = {}
        for w in q("--windows"):
            if w["id"] in wanted and w["space"] != wanted[w["id"]]:
                stray.setdefault(wanted[w["id"]], []).append(w["id"])
        if not stray: break
        for index, ids in stray.items():
            print("windows", ids, "to space", index, "accepted:", sa_move(sid[index], ids))
        time.sleep(0.8)

def display_ids():
    # The roles of the displays by arrangement: main external, second external, builtin.
    displays = sorted(q("--displays"), key=lambda d: d["index"])
    if len(displays) != 3:
        raise SystemExit("the scenarios need three displays: two externals and the open lid")
    return [d["id"] & 0xFFFFFFFF for d in displays]

def scenarios():
    d1, d2, b = display_ids()
    # name: (off stages, on stages, seconds held), the stages as in display_off.swift
    return {"T1": (f"{b}@0", f"{b}@0", 15),
            "T2": (f"{d2}@0", f"{d2}@0", 15),
            "T3": (f"{d1}@0", f"{d1}@0", 15),
            "T4": (f"{d1}@0,{d2}@0.2", f"{d2}@0,{d1}@3", 20),
            "T5": (f"{d1}@0,{d2}@0.2", f"{d1}@0,{d2}@3", 20),
            "T6": (f"{d1}@0,{d2}@0.2", f"{d2}@0,{d1}@0.5", 1),
            "T7": (f"{d1}@0,{d2}@0.2", f"{d2}@0,{d1}@3", 90)}

def run(name, hold=None):
    table = scenarios()
    if name not in table: raise SystemExit(f"unknown scenario, choose from {sorted(table)}")
    off, on, seconds = table[name]
    seconds = float(hold) if hold else seconds
    stamp = f"{name}-{time.strftime('%H%M%S')}"
    stop, recording_stop = path(stamp + ".stop"), path(stamp + ".recording-stop")
    pre = state(); save(stamp + "-pre", pre); show(pre)
    recorder = subprocess.Popen([build("toporec"), path(stamp).replace(".json", ".jsonl"), recording_stop])
    time.sleep(1)
    tool = subprocess.Popen([build("display_off"), stop, str(seconds + 30), off, on],
                            stdout=subprocess.PIPE, text=True)
    passed = False
    try:
        time.sleep(seconds)
        during = state(); save(stamp + "-during", during); show(during)
        open(stop, "w").close()
        for line in tool.stdout:
            print(line.strip())
            if line.startswith(("off", "on")) and not line.rstrip().endswith(": 0"):
                print("FAIL  display change refused")
        tool.wait(timeout=30)
        time.sleep(SETTLE)
        post = state(); save(stamp + "-post", post); show(post)
        report(f"{name} while the displays were away", pre, during)
        passed = report(f"{name} after the displays returned", pre, post)
        time.sleep(30)
        late = state(); save(stamp + "-late", late)
        passed = report(f"{name} 30 s later", pre, late) and passed
    finally:
        open(stop, "w").close()
        tool.wait(timeout=30)
        open(recording_stop, "w").close()
        recorder.wait(timeout=5)
        restore(pre)
        report(f"{name} restored by the harness", pre, state())
    return passed

def record(name, seconds):
    # A change made by hand: saves a state after every change of the displays, and one at the end.
    stop = path(name + ".recording-stop")
    recorder = subprocess.Popen([build("toporec"), path(name).replace(".json", ".jsonl"), stop])
    save(name + "-pre", state())
    last, count, end = None, 0, time.time() + seconds
    try:
        while time.time() < end:
            now = sorted(d["uuid"] for d in q("--displays") or [])
            if last is not None and now and now != last:
                count += 1; print(time.strftime("%H:%M:%S"), "displays changed:", len(now), flush=True)
                time.sleep(SETTLE); save(f"{name}-{count}", state())
                now = sorted(d["uuid"] for d in q("--displays") or [])
            last = now or last
            time.sleep(0.5)
    finally:
        save(name + "-end", state())
        open(stop, "w").close()
        recorder.wait(timeout=5)

def main():
    args = sys.argv[1:]
    command = args[0] if args else ""
    if command == "snap": s = state(); save(args[1], s); show(s)
    elif command == "show": show(load(args[1]))
    elif command == "diff": sys.exit(0 if report(f"{args[1]} to {args[2]}", load(args[1]), load(args[2])) else 1)
    elif command == "fixture": fixture()
    elif command == "cleanup": cleanup()
    elif command == "restore": restore(load(args[1]))
    elif command == "record": record(args[1], float(args[2]))
    elif command == "scenarios": print("\n".join(f"{k}: {v}" for k, v in scenarios().items()))
    elif command == "run": sys.exit(0 if run(args[1], args[2] if len(args) > 2 else None) else 1)
    else: raise SystemExit(__doc__ or "usage: see the top of topology.py")

if __name__ == "__main__":
    main()
