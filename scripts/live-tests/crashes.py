#!/usr/bin/env python3
# Summarizes yabai crash reports, newest first: file, exception, top frames of the crashed thread.
# usage: crashes.py [count]
import json, os, sys
d = os.path.expanduser("~/Library/Logs/DiagnosticReports")
files = sorted((f for f in os.listdir(d) if f.startswith("yabai")), key=lambda f: -os.path.getmtime(os.path.join(d, f)))
print(f"{len(files)} yabai crash reports")
for f in files[:int(sys.argv[1]) if len(sys.argv) > 1 else 10]:
    header, body = open(os.path.join(d, f)).read().split("\n", 1)
    b = json.loads(body)
    t = [t for t in b.get("threads", []) if t.get("triggered")]
    frames = [x.get("symbol", "?") for x in t[0].get("frames", [])[:10]] if t else []
    print(f, b.get("exception", {}).get("type"), "|", " < ".join(frames))
