# Refactor baseline (2026-10-18)

Baseline of `doc/swift-refactor.md` phase 1: the installed binary built from `a797d9aa` (same sources as `631a660d`),
macOS 27, laptop display only (one display, spaces 1–15), standard six-window fixture on space 4 (`live.py setup`).

`bench.py` (two runs, milliseconds):

| Run | tab focus median | rotate median | split focus median |
|---|---:|---:|---:|
| base1 | 29.7 | 120.1 | 27.4 |
| base2 | 28.7 | 129.7 | 32.7 |

`perf.py base --samples 50` raw results: `perf_base.json`. Medians (ms): CLI query 23.01, socket query 4.31,
same-app focus 18.19, cross-app focus 28.75, tab focus 39.81, split focus 29.07, rotate 115.13, send to space 12 and
back 192.81, floating move pair 39.17, floating resize pair 75.70, space 4↔5 27.12, space 4↔12 20.44.

Compare later phases on the same setup (one display) or record a new baseline on the installed build first.
