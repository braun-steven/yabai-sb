#!/usr/bin/env python3
# Live checks of the yabai daemon for window moving, layout flushing and focus.
# usage: live.py setup | run <label> | extra <label> | launch <label> | cleanup
import json, os, subprocess, sys, time

TOOLS = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(TOOLS, ".focused-window")  # the user's focused window, recorded by setup
SPACE = 4          # empty space on display 1
OTHER_SPACE = 12   # empty space on display 2
RESTORE_OTHER = 11 # space shown on display 2 before the tests
results = []

def sh(cmd, check=False, timeout=60):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd}: {r.stderr.strip()}")
    return r

def y(args, timeout=60):
    return sh(f"yabai -m {args}", timeout=timeout)

def q(args):
    r = y(f"query {args}")
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None

def timed(args, timeout=60):
    t = time.perf_counter()
    r = y(args, timeout=timeout)
    return (time.perf_counter() - t) * 1000.0, r

def osa(script):
    return sh(f"osascript -e '{script}'")

def space_windows(sid=SPACE):
    ws = q(f"--windows --space {sid}") or []
    return [w for w in ws if w["app"] in ("TextEdit", "Script Editor", "Calculator")]

def real_bounds(wids):
    out = sh(f"{TOOLS}/bounds " + " ".join(map(str, wids))).stdout.split("\n")
    res = {}
    for line in out:
        p = line.split()
        if len(p) == 5: res[int(p[0])] = tuple(float(v) for v in p[1:])
    return res

def display_frame(index):
    for d in q("--displays"):
        if d["index"] == index: return d["frame"]

def overlap(a, b):
    ax, ay, aw, ah = a; bx, by, bw, bh = b
    return min(ax + aw, bx + bw) - max(ax, bx) > 2 and min(ay + ah, by + bh) - max(ay, by) > 2

def record(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)

def tree_leaves(node, out):
    if node.get("window"): out[node["window"]] = node
    for n in node.get("nodes") or []: tree_leaves(n, out)
    return out

def check_layout(name, tabbed=False, settle=0.4, sid=SPACE):
    # Every tiled window must be where the tree says it should be. A window that is larger than its
    # frame at the right position is accepted: the application enforces a minimum size.
    time.sleep(settle)
    leaves = tree_leaves(q(f"--tree --space {sid}"), {})
    real = real_bounds(list(leaves))
    ws = {w["id"]: w for w in space_windows(sid)}
    problems = []
    clamped = 0
    for wid, leaf in leaves.items():
        f = leaf["frame"]
        exp = (f["x"], f["y"], f["w"], f["h"])
        rb = real.get(wid)
        if rb is None: problems.append(f"{wid} no bounds"); continue
        pos_ok = abs(exp[0] - rb[0]) <= 1.5 and abs(exp[1] - rb[1]) <= 1.5
        size_ok = abs(exp[2] - rb[2]) <= 1.5 and abs(exp[3] - rb[3]) <= 1.5
        if pos_ok and not size_ok and rb[2] >= exp[2] - 1.5 and rb[3] >= exp[3] - 1.5:
            clamped += 1
        elif not (pos_ok and size_ok):
            problems.append(f"{wid} expected {exp} real {rb}")
        w = ws.get(wid)
        if w:
            c = w["frame"]
            if any(abs(a - b) > 1.5 for a, b in zip((c["x"], c["y"], c["w"], c["h"]), rb)):
                problems.append(f"{wid} cached {c} != real {rb}")
    record(name, not problems, "; ".join(problems[:3]) + (f" ({clamped} at min size)" if clamped else ""))
    return not problems

def flatten_row():
    # Put every tiled window directly on the space, next to a window that already is.
    tree = q(f"--tree --space {SPACE}")
    anchors = [n["window"] for n in tree.get("nodes") or [] if n.get("window")]
    leaves = list(tree_leaves(tree, {}))
    if not anchors or not leaves: return
    for wid in leaves:
        if wid not in anchors: y(f"window {wid} --warp {anchors[0]}"); time.sleep(0.15)
    y(f"space {SPACE} --balance"); time.sleep(0.3)

def find_tabbed(node):
    if node.get("layout") == "tabbed": return node
    for n in node.get("nodes") or []:
        r = find_tabbed(n)
        if r: return r

def front_order(wids):
    # The on-screen windows among wids, front to back.
    out = sh(f"{TOOLS}/bounds order " + " ".join(map(str, wids))).stdout.split()
    return [int(v) for v in out]

def focused_id():
    w = q("--windows --window")
    return w["id"] if w else None

def build_helpers():
    # Compile the Swift helpers when they are missing or older than their source.
    for name in ("bounds", "mouse", "freeze"):
        src, out = os.path.join(TOOLS, name + ".swift"), os.path.join(TOOLS, name)
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
            sh(f"swiftc -O '{src}' -o '{out}'", check=True, timeout=300)

def require_mouse_access():
    if sh(f"{TOOLS}/mouse trusted", check=True).stdout.strip() != "true":
        raise RuntimeError("synthetic mouse event posting denied; run outside the command sandbox with Accessibility permission")

def setup():
    if not os.path.exists(STATE):
        w = q("--windows --window")
        if w:
            with open(STATE, "w") as f: f.write(str(w["id"]))
    y(f"space --focus {SPACE}")
    time.sleep(0.6)
    sh("open -a TextEdit"); time.sleep(1.5)
    # TextEdit may show an open panel on launch; close it and make documents.
    osa('tell application "TextEdit" to close (every window whose name is not "Untitled")')
    for _ in range(3):
        osa('tell application "TextEdit" to make new document'); time.sleep(0.5)
    sh("open -a 'Script Editor'"); time.sleep(1.5)
    osa('tell application "Script Editor" to close (every window whose name is not "Untitled")')
    for _ in range(2):
        osa('tell application "Script Editor" to make new document'); time.sleep(0.5)
    sh("open -a Calculator"); time.sleep(1.5)
    for _ in range(20):
        if len(space_windows()) >= 6: break
        time.sleep(0.5)
    print("windows:", [(w["app"], w["id"], w["is-floating"]) for w in space_windows()])

def row_order():
    ws = [w for w in space_windows() if not w["is-floating"]]
    return [w["id"] for w in sorted(ws, key=lambda w: (w["frame"]["x"], w["frame"]["y"]))]

def run(label):
    print(f"== {label} ==")
    require_mouse_access()
    pid = sh("pgrep -ox yabai").stdout.strip()
    y(f"space --focus {SPACE}"); time.sleep(0.5)
    ws = space_windows()
    if len(ws) < 6: record("setup", False, f"only {len(ws)} windows"); return
    first = [w for w in ws if w["app"] != "Calculator"][0]["id"]
    y(f"window --focus {first}"); time.sleep(0.3)

    # Keep the floating Calculator away from the centers of the tiled windows.
    frame = display_frame(1)
    for w in ws:
        if w["app"] == "Calculator":
            y(f"window {w['id']} --move abs:{frame['x'] + frame['w'] - 260}:{frame['y'] + frame['h'] - 290}")

    # Flat row: every window in one splith container at the root.
    y(f"window {first} --layout splith"); time.sleep(0.3)
    flatten_row()
    for w in ws:
        if w["is-floating"] and w["app"] != "Calculator": y(f"window {w['id']} --toggle float")
    time.sleep(0.3)
    check_layout("initial layout")

    # T1: full relayouts.
    times = []
    for i in range(4):
        ms, r = timed(f"space {SPACE} --rotate 90"); times.append(ms)
        check_layout(f"rotate #{i+1}")
    ms, r = timed(f"space {SPACE} --balance"); times.append(ms)
    check_layout("balance")
    record("relayout latency", True, f"mean {sum(times)/len(times):.1f} ms, max {max(times):.1f} ms")

    # Commands that change focus or tabs but not most frames.
    y(f"window --focus {first}"); time.sleep(0.3)
    ms_tab, r = timed("window --layout tabbed")
    check_layout("tabbed layout", tabbed=True)
    tabbed = find_tabbed(q(f"--tree --space {SPACE}")) or {}
    tabs = [n["window"] for n in tabbed.get("nodes") or [] if n.get("window")]
    tab_times = []
    order_bad = []
    for wid in tabs[1:] + tabs[:1]:
        ms, r = timed(f"window --focus {wid}"); tab_times.append(ms); time.sleep(0.15)
        fo = front_order(tabs)
        if not fo or fo[0] != wid: order_bad.append(f"{wid}: front {fo[:2]}")
    check_layout("tabbed after tab switches", tabbed=True)
    record("active tab is in front of the other tabs", not order_bad, "; ".join(order_bad[:3]))
    record("tab switch latency", True, f"mean {sum(tab_times)/len(tab_times):.1f} ms")
    r = y(f"window {first} --layout splith"); time.sleep(0.3)
    y(f"space {SPACE} --balance")
    check_layout("back to splith")
    tree = q(f"--tree --space {SPACE}")
    record("tree is a flat row again", len(tree["nodes"]) == 5 and tree["layout"] == "splith", f"{tree['layout']} with {len(tree['nodes'])} children")

    # T3: rapid repeated focus moves.
    order = row_order()
    y(f"window --focus {order[0]}"); time.sleep(0.5)
    for _ in range(3):
        sh("yabai -m window --focus east")
    time.sleep(0.6)
    got = focused_id()
    expected = order[3] if len(order) > 3 else order[-1]
    record("rapid focus east x3", got == expected, f"focused {got}, expected {expected} (row {order})")

    # T4: send a window to a visible space on the other display and focus it.
    y(f"space --focus {OTHER_SPACE}"); time.sleep(0.6)
    y(f"space --focus {SPACE}"); time.sleep(0.6)
    mover = [w for w in space_windows() if w["app"] == "TextEdit"][0]["id"]
    ms, r = timed(f"window {mover} --space {OTHER_SPACE}")
    y(f"window --focus {mover}")
    time.sleep(0.8)
    w = q(f"--windows --window {mover}")
    sp = q("--spaces --space")
    rb = real_bounds([mover]).get(mover)
    d2 = display_frame(2) or display_frame(1)
    on_d2 = rb is not None and rb[0] >= d2["x"] - 1
    record("send to space and focus" if len(q("--displays")) == 1 else "send to visible space on other display", w and w["space"] == OTHER_SPACE and on_d2 and sp["index"] == OTHER_SPACE,
           f"window space {w and w['space']}, focused space {sp['index']}, bounds {rb}, send {ms:.0f} ms")
    y(f"window {mover} --space {SPACE}"); time.sleep(0.5)
    y(f"space --focus {RESTORE_OTHER}"); time.sleep(0.5)
    y(f"space --focus {SPACE}"); time.sleep(0.5)
    check_layout("layout after window came back")

    # T6: focus follows mouse between windows of the same application.
    y("config focus_follows_mouse autofocus"); time.sleep(0.3)
    te = [w for w in space_windows() if w["app"] == "TextEdit"]
    def center(w):
        f = w["frame"]; return f["x"] + f["w"] / 2, f["y"] + f["h"] / 2
    ffm_ok = True; ffm_detail = []
    for target in [te[0], te[1], te[0], te[1]]:
        x, yy = center(target)
        sh(f"{TOOLS}/mouse move {x} {yy}", check=True); time.sleep(0.4)
        got = focused_id()
        ffm_ok &= got == target["id"]; ffm_detail.append(f"{target['id']}->{got}")
    record("autofocus between same-app windows", ffm_ok, ", ".join(ffm_detail))
    # Sweep across the whole space while timing a query.
    disp = display_frame(1)
    sweep = subprocess.Popen([f"{TOOLS}/mouse", "sweep", str(disp['x']+20), str(disp['y']+500),
                              str(disp['x']+disp['w']-20), str(disp['y']+500), "400"],
                             stderr=subprocess.PIPE, text=True)
    qt = []
    while sweep.poll() is None:
        ms, r = timed("query --spaces --space"); qt.append(ms)
    _, sweep_error = sweep.communicate()
    if sweep.returncode != 0:
        raise RuntimeError(f"mouse sweep failed: {sweep_error.strip()}")
    time.sleep(0.6)
    under = None
    for w in space_windows():
        f = w["frame"]
        if f["x"] <= disp["x"] + disp["w"] - 20 <= f["x"] + f["w"] and f["y"] <= disp["y"] + 500 <= f["y"] + f["h"]: under = w["id"]
    got = focused_id()
    record("autofocus sweep ends on window under cursor", got == under, f"focused {got}, under cursor {under}")
    record("query latency during sweep", True, f"max {max(qt):.1f} ms over {len(qt)} queries")
    y("config focus_follows_mouse off"); time.sleep(0.2)

    # T7: alt-drag a floating window.
    calc = [w for w in space_windows() if w["app"] == "Calculator"][0]
    if not calc["is-floating"]: y(f"window {calc['id']} --toggle float"); time.sleep(0.4)
    y(f"window {calc['id']} --move abs:600:400"); time.sleep(0.4)
    before = real_bounds([calc["id"]])[calc["id"]]
    x0, y0 = before[0] + before[2] / 2, before[1] + 40
    sh(f"{TOOLS}/mouse altdrag {x0} {y0} {x0+300} {y0+150} 200", check=True); time.sleep(0.5)
    after = real_bounds([calc["id"]])[calc["id"]]
    dx, dy = after[0] - before[0], after[1] - before[1]
    record("alt-drag moves floating window", abs(dx - 300) < 6 and abs(dy - 150) < 6, f"moved by ({dx:.0f}, {dy:.0f})")
    check_layout("layout after drag")

    # T8: a stalled client must not block the daemon for long.
    stall = subprocess.Popen(f"sleep 4 | nc -U /tmp/yabai_{os.environ['USER']}.socket", shell=True)
    time.sleep(0.2)
    ms, r = timed("query --spaces --space", timeout=30)
    stall.wait()
    record("query while another client stalls", ms < 2000, f"{ms:.0f} ms")

    # T9: an application that does not respond.
    se_pid = sh("pgrep -x 'Script Editor'").stdout.strip()
    sh(f"kill -STOP {se_pid}")
    try:
        ms, r = timed(f"space {SPACE} --rotate 90", timeout=120)
        ms2, r = timed("query --spaces --space", timeout=120)
    finally:
        sh(f"kill -CONT {se_pid}")
    record("relayout with a frozen app", True, f"rotate {ms:.0f} ms, next query {ms2:.0f} ms")
    time.sleep(0.5)
    y(f"space {SPACE} --balance")
    check_layout("layout after app resumed", settle=1.0)

    # T10: overlapping animations.
    y("config window_animation_duration 0.15")
    for i in range(3):
        y(f"space {SPACE} --rotate 90"); time.sleep(0.05)
    time.sleep(0.8)
    y("config window_animation_duration 0.0")
    check_layout("layout after overlapping animations")

    # T5: native fullscreen round trip.
    fs = [w for w in space_windows() if w["app"] == "TextEdit"][0]["id"]
    ms, r = timed(f"window {fs} --toggle native-fullscreen", timeout=30)
    time.sleep(1.5)
    ms2, r = timed(f"window {fs} --toggle native-fullscreen", timeout=30)
    time.sleep(1.5)
    w = q(f"--windows --window {fs}")
    record("native fullscreen round trip", w and not w["is-native-fullscreen"] and w["space"] == SPACE,
           f"enter {ms:.0f} ms, exit {ms2:.0f} ms, space {w and w['space']}")
    y(f"space --focus {SPACE}"); time.sleep(0.5)
    check_layout("layout after native fullscreen")

    alive = sh("pgrep -ox yabai").stdout.strip()
    record("daemon still running (same pid)", alive == pid, f"{pid} -> {alive}")

def extra(label):
    # Checks for the scripting-addition, active-space and container-move changes.
    print(f"== {label} (extra) ==")
    pid = sh("pgrep -ox yabai").stdout.strip()
    y(f"space --focus {SPACE}"); time.sleep(0.5)
    ws = space_windows()
    if len(ws) < 6: record("setup", False, f"only {len(ws)} windows"); return
    first = [w for w in ws if w["app"] != "Calculator"][0]["id"]
    y(f"window --focus {first}"); time.sleep(0.3)
    y(f"window {first} --layout splith"); time.sleep(0.3)
    flatten_row()
    check_layout("flat row before extra checks")

    # Space switching through the scripting addition: the active space is right every time.
    dock = sh("pgrep -x Dock").stdout.strip()
    wrong = []; st = []
    for i in range(50):
        target = 5 if i % 2 == 0 else SPACE
        ms, r = timed(f"space --focus {target}"); st.append(ms); time.sleep(0.15)
        sp = q("--spaces --space")
        if not sp or sp["index"] != target: wrong.append(f"#{i} {target}->{sp and sp['index']}")
    y(f"space --focus {SPACE}"); time.sleep(0.4)
    dock2 = sh("pgrep -x Dock").stdout.strip()
    record("50 space switches", not wrong and dock == dock2,
           f"Dock {dock}->{dock2}, median {sorted(st)[len(st)//2]:.0f} ms" + (f", wrong: {wrong[:3]}" if wrong else ""))
    fp = sh(f"footprint -p {dock2} 2>/dev/null | grep -m1 'Footprint'").stdout.strip()
    record("Dock footprint after switches", True, fp)
    hk = sh("defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A1 '^ *81 =' | grep -c 'enabled = 1'").stdout.strip()
    if hk == "1":
        osa('tell application "System Events" to key code 124 using control down'); time.sleep(1.2)
        sp = q("--spaces --space")
        record("native ctrl+right moves from the right space", sp and sp["index"] == SPACE + 1, f"now on {sp and sp['index']}")
        y(f"space --focus {SPACE}"); time.sleep(0.6)
    else:
        print("SKIP  native ctrl+right: the hotkey is disabled in System Settings")

    # A frozen frontmost application must not slow down space switching.
    se = [w for w in space_windows() if w["app"] == "Script Editor"][0]["id"]
    y(f"window --focus {se}"); time.sleep(0.5)
    se_pid = sh("pgrep -x 'Script Editor'").stdout.strip()
    sh(f"kill -STOP {se_pid}")
    try:
        ms1, r = timed("space --focus 5", timeout=30); time.sleep(0.3)
        ms2, r = timed(f"space --focus {SPACE}", timeout=30)
    finally:
        sh(f"kill -CONT {se_pid}")
    record("space focus with a frozen front app", ms1 < 500 and ms2 < 500, f"to 5: {ms1:.0f} ms, back: {ms2:.0f} ms")
    time.sleep(0.5)

    if len(q("--displays")) < 2:
        print("SKIP  cross-display container warp and swap: only one display is connected")
        alive = sh("pgrep -ox yabai").stdout.strip()
        record("daemon still running (same pid)", alive == pid, f"{pid} -> {alive}")
        return

    # Move a tabbed container of three windows to the other display and back.
    y(f"space --focus {OTHER_SPACE}"); time.sleep(0.6)
    y(f"space --focus {SPACE}"); time.sleep(0.6)
    order = row_order()
    right = order[-1]
    for wid in order[:2]:
        y(f"window {right} --stack {wid}"); time.sleep(0.3)
    tabs = [right] + order[:2]
    y(f"window --focus {right}"); time.sleep(0.3)
    y("window --focus parent"); time.sleep(0.2)
    ms, r = timed("window --warp east")
    time.sleep(0.5)
    spaces = {wid: (q(f"--windows --window {wid}") or {}).get("space") for wid in tabs}
    d2 = display_frame(2)
    rb = real_bounds(tabs)
    on_d2 = all(rb.get(w) and rb[w][0] >= d2["x"] - 1 for w in tabs)
    record("tabbed container warps to the other display", all(v == OTHER_SPACE for v in spaces.values()) and on_d2,
           f"spaces {spaces}, warp {ms:.0f} ms")
    check_layout("layout of the container on the other display", tabbed=True, sid=OTHER_SPACE)
    y(f"window --focus {right}"); time.sleep(0.3)
    y("window --focus parent"); time.sleep(0.2)
    ms, r = timed("window --warp west")
    time.sleep(0.5)
    spaces = {wid: (q(f"--windows --window {wid}") or {}).get("space") for wid in tabs}
    record("tabbed container warps back", all(v == SPACE for v in spaces.values()), f"spaces {spaces}, warp {ms:.0f} ms")
    check_layout("layout after the container came back", tabbed=True)
    y(f"window {right} --layout splith"); time.sleep(0.3)
    flatten_row()
    tree = q(f"--tree --space {SPACE}")
    record("back to a flat row", len(tree["nodes"]) == 5 and all(n.get("window") for n in tree["nodes"]), f"{len(tree['nodes'])} children")

    # Swap a window on this space with one on the other display.
    order = row_order()
    a, b = order[0], order[1]
    y(f"window {b} --space {OTHER_SPACE}"); time.sleep(0.6)
    y(f"space --focus {OTHER_SPACE}"); time.sleep(0.4)
    y(f"space --focus {SPACE}"); time.sleep(0.4)
    ms, r = timed(f"window {a} --swap {b}")
    time.sleep(0.3)
    wa, wb = q(f"--windows --window {a}"), q(f"--windows --window {b}")
    record("swap across displays", wa and wb and wa["space"] == OTHER_SPACE and wb["space"] == SPACE,
           f"{a} on {wa and wa['space']}, {b} on {wb and wb['space']}, swap {ms:.0f} ms")
    check_layout("layout after the swap", settle=0.1)
    check_layout("layout of the other display after the swap", sid=OTHER_SPACE, settle=0.0)
    y(f"window {a} --space {SPACE}"); time.sleep(0.6)
    y(f"space --focus {RESTORE_OTHER}"); time.sleep(0.4)
    y(f"space --focus {SPACE}"); time.sleep(0.4)
    flatten_row()
    check_layout("layout after the window came back")

    alive = sh("pgrep -ox yabai").stdout.strip()
    record("daemon still running (same pid)", alive == pid, f"{pid} -> {alive}")

LAUNCH_WATCH = 120.0

def launch(label):
    # An application that cannot be observed after launch: retries with growing gaps, then gives up,
    # and is managed once it responds and is activated. Run with no test application running.
    print(f"== {label} (launch) ==")
    if sh("pgrep -x TextEdit").returncode == 0: record("TextEdit not running", False); return
    log = f"/tmp/yabai_{os.environ['USER']}.out.log"
    y("config debug_output on")
    offset = os.path.getsize(log)
    # Stopping the application before it finished launching only parks it on the finishedLaunching
    # observation; the retries happen when it is stopped right after, before it can be observed.
    r = sh(f"{TOOLS}/freeze com.apple.TextEdit")
    te_pid = r.stdout.split()[0] if r.returncode == 0 and r.stdout.strip() else None
    print("frozen", r.stdout.strip())
    seen = []; query_ms = []
    try:
        start = time.perf_counter(); pos = offset
        while time.perf_counter() - start < LAUNCH_WATCH:
            time.sleep(0.25)
            ms, r = timed("query --spaces --space"); query_ms.append(ms)
            with open(log) as f:
                f.seek(pos); new = f.read(); pos = f.tell()
            for line in new.splitlines():
                if "TextEdit" in line and ("retrying" in line or "giving up" in line or "could not observe" in line):
                    seen.append((time.perf_counter() - start, line.strip()))
    finally:
        if te_pid: sh(f"kill -CONT {te_pid}")
    retries = [t for t, l in seen if "retrying" in l]
    gave_up = any("giving up" in l for t, l in seen)
    tries = [t for t, l in seen if "could not observe" in l]
    gaps = [round(b - a, 1) for a, b in zip(tries, tries[1:])]
    record("launch retries back off and stop", gave_up and len(retries) <= 12,
           f"{len(tries)} attempts in {LAUNCH_WATCH:.0f}s, gaps between attempts {gaps}, gave up {gave_up}")
    qms = [ms for ms in query_ms]
    record("queries while the frozen app is retried", True, f"max {max(qms):.0f} ms, median {sorted(qms)[len(qms)//2]:.0f} ms over {len(qms)} queries")
    time.sleep(1.0)
    sh("open -a TextEdit"); time.sleep(2.5)
    managed = [w for w in (q("--windows") or []) if w["app"] == "TextEdit"]
    record("activated application gets managed", len(managed) > 0, f"{len(managed)} windows")
    osa('tell application "TextEdit" to quit saving no')
    y("config debug_output off")

def cleanup():
    osa('tell application "TextEdit" to quit saving no')
    osa('tell application "Script Editor" to quit saving no')
    osa('tell application "Calculator" to quit')
    y("config focus_follows_mouse off")
    y("config window_animation_duration 0.0")
    y(f"space --focus {RESTORE_OTHER}"); time.sleep(0.4)
    if os.path.exists(STATE):
        wid = open(STATE).read().strip()
        y(f"window --focus {wid}")
        os.remove(STATE)

if __name__ == "__main__":
    build_helpers()
    cmd = sys.argv[1]
    if cmd == "setup": setup()
    elif cmd == "run":
        run(sys.argv[2])
        fails = [r for r in results if not r[1]]
        print(f"-- {len(results) - len(fails)}/{len(results)} passed")
    elif cmd in ("extra", "launch"):
        (extra if cmd == "extra" else launch)(sys.argv[2])
        fails = [r for r in results if not r[1]]
        print(f"-- {len(results) - len(fails)}/{len(results)} passed")
    elif cmd == "cleanup": cleanup()
