import json, subprocess, time, statistics, sys
def y(a): return subprocess.run(f"yabai -m {a}", shell=True, capture_output=True, text=True)
def t(a):
    s = time.perf_counter(); y(a); return (time.perf_counter() - s) * 1000
y("space --focus 4"); time.sleep(0.5)
ws = [w["id"] for w in json.loads(y("query --windows --space 4").stdout) if not w["is-floating"]]
y(f"window --focus {ws[0]}"); time.sleep(0.3)
y("window --layout tabbed"); time.sleep(0.5)
tab = []
for i in range(40):
    tab.append(t(f"window --focus {ws[i % len(ws)]}")); time.sleep(0.12)
y(f"window {ws[0]} --layout splith"); time.sleep(0.5)
rot = []
for i in range(20):
    rot.append(t("space 4 --rotate 90")); time.sleep(0.3)
foc = []
for i in range(40):
    foc.append(t(f"window --focus {ws[i % len(ws)]}")); time.sleep(0.12)
def st(n, v): print(f"{sys.argv[1]:8} {n:14} median {statistics.median(v):6.1f}  mean {statistics.mean(v):6.1f}  p90 {sorted(v)[int(len(v)*0.9)]:6.1f} ms")
st("tab focus", tab); st("rotate", rot); st("split focus", foc)
