# Swift port performance comparison

This report compares the installed pre-port daemon (C/ObjC plus the pre-existing glass pilot) with the Swift port on macOS 27.0.1 arm64. The pre-port universal binary at `~/.local/bin/yabai` had SHA-256 `a6ebdf54b33f36fe8e139953f587e6b1984f3836de3daa68e9f468c85ed4192c` and arm64 UUID `5C558C4E-6AB1-363C-9FBF-9FA783D76BC7`. The installed Swift binary was from `swift-port` commit `d9199b3`, SHA-256 `3da5dda14fb52dc3c65e05a82e5b88c94e41a3855e1605ef33c949c640c88a30`, UUID `80FFA1C6-4C67-30D9-A66F-BE2B274CA46F`. Both reported `yabai-v7.1.25`.

The matched harness used the same disposable TextEdit, Script Editor and Calculator fixture, with the same five tiled window IDs on space 4, a flat horizontal tree, borders enabled at 3 px, glass tabs, animation duration 0, focus-follows-mouse disabled, and mouse-follows-focus off. Tree autotiling was disabled and orientation fixed to horizontal during measurements. No user windows were used. Pre-port blocks A/B each took 50 samples per measure (100 total); Swift A took 100 and Swift B 50 (150 total), following the instruction to retain every valid Swift sample. All 18 measures in every block had zero failures, stable daemon PIDs within each pair, and the expected tree shape was restored. Quantiles below use nearest rank. Values are milliseconds; command round trips include CLI process startup.

| Measure | Pre-port n | Median / p90 / p95 / max | Swift n | Median / p90 / p95 / max |
|---|---:|---:|---:|---:|
| CLI window query round trip | 100 | 8.82 / 11.61 / 13.84 / 16.09 | 150 | 9.42 / 13.47 / 14.94 / 20.85 |
| Raw socket window query round trip | 100 | 4.19 / 7.46 / 8.14 / 10.97 | 150 | 4.41 / 7.52 / 8.67 / 12.41 |
| Same-app focus command | 100 | 9.22 / 11.77 / 13.26 / 29.91 | 150 | 9.93 / 11.12 / 11.55 / 44.20 |
| Cross-app focus command | 100 | 21.08 / 27.49 / 29.05 / 47.85 | 150 | 19.74 / 27.03 / 28.81 / 56.01 |
| Tab focus command | 100 | 27.87 / 41.36 / 52.19 / 112.37 | 150 | 28.59 / 40.83 / 55.85 / 131.69 |
| Split focus command | 100 | 21.16 / 27.62 / 30.03 / 60.29 | 150 | 20.12 / 26.71 / 29.69 / 44.13 |
| Rotation command, alternating 90°/270° | 100 | 119.16 / 140.03 / 148.48 / 171.44 | 150 | 118.51 / 144.13 / 149.01 / 163.70 |
| Send a window to space 12 and back, with membership polling | 100 | 404.86 / 879.40 / 895.81 / 917.38 | 150 | 405.76 / 868.36 / 897.08 / 946.64 |
| Floating move command pair | 100 | 17.34 / 20.38 / 21.22 / 22.21 | 150 | 16.11 / 20.18 / 21.49 / 23.45 |
| Floating move plus WindowServer bounds polling | 100 | 78.21 / 81.94 / 82.91 / 85.30 | 150 | 75.92 / 81.60 / 82.51 / 109.60 |
| Floating resize command pair | 100 | 42.15 / 46.38 / 48.05 / 51.37 | 150 | 41.68 / 47.04 / 48.80 / 53.95 |
| Floating resize plus WindowServer bounds polling | 100 | 111.78 / 134.03 / 137.05 / 164.77 | 150 | 111.11 / 133.69 / 137.23 / 168.46 |
| Same-app focus plus focused-ID polling | 100 | 18.46 / 27.21 / 29.04 / 35.22 | 150 | 19.01 / 26.50 / 27.71 / 30.62 |
| Cross-app focus plus focused-ID polling | 100 | 38.24 / 51.17 / 55.81 / 63.00 | 150 | 43.25 / 50.95 / 57.30 / 75.74 |
| Space 4↔5 command round trip | 100 | 11.93 / 47.61 / 58.09 / 517.41 | 150 | 9.51 / 54.97 / 489.49 / 513.92 |
| Space 4↔5 plus active-space polling | 100 | 53.16 / 114.13 / 117.41 / 569.11 | 150 | 59.93 / 114.66 / 554.67 / 572.57 |
| Space 4↔12 command round trip | 100 | 29.14 / 38.93 / 40.31 / 94.60 | 150 | 28.62 / 40.17 / 41.45 / 58.94 |
| Space 4↔12 plus active-space polling | 100 | 43.26 / 58.95 / 70.32 / 83.05 | 150 | 40.30 / 57.17 / 61.30 / 75.96 |

The common command medians and most p95 values are close. CLI and direct-socket query medians were 8.82→9.42 ms and 4.19→4.41 ms. Same-app focus command median was 9.22→9.93 ms; cross-app focus was 21.08→19.74 ms. Rotation, move, resize, tab-focus and split-focus command medians were also close. Cross-app observed completion (command plus focused-ID polling) was 38.24→43.25 ms at the median, with p95 55.81→57.30 ms.

Space 4↔5 had rare long round trips in both builds. Values above 250 ms (also above 450 ms) occurred 1/50 and 3/50 times in pre-port A/B, and 8/100 and 3/50 times in Swift A/B; maxima were 517.41 and 513.92 ms. The pooled p95 is sensitive to this frequency: 4/100 pre-port samples leave its p95 below the tail (58.09 ms), while 11/150 Swift samples put its p95 in the tail (489.49 ms). Both builds had roughly 500 ms maxima, so this percentile difference should be read together with per-block counts and raw samples. A separate Swift-only probe completed before the desktop locked: after 10 warmups it alternated real space 4/5 switches for 200 samples with a 60 ms pause and 100 with a 250 ms pause, querying the active space after every command outside the timed interval. It had zero command-duration stalls above 250 ms and no failures. This checked-between-switches probe is a different workload from the command-only primary measure and has no valid pre-port counterpart yet; it does not establish a cause for the mixed-workload tails.

## Visible border and frame observations

The border helper measured command-to-composited-pixel-change on the main display, using a persistent ScreenCaptureKit stream requested at 120 Hz over 2560×1440 logical pixels. It detected the configured 6 px probe border changing in captured pixels, with 40 same-app and 40 cross-app focus samples per build and no failures. The command portion is reported separately from the displayed metric. The pre-port focus probe used window IDs [25231, 25225, 25262], while Swift used [25225, 25218, 25262]. Both were the same blank-app fixture, but the exact focused windows differed, so this is a matched app/state comparison rather than a window-for-window pair.

| Operation | Pre-port command median | Swift command median | Pre-port displayed median / p95 | Swift displayed median / p95 |
|---|---:|---:|---:|---:|
| Same-app focus | 9.54 ms | 10.02 ms | 37.09 / 62.09 ms | 28.90 / 57.53 ms |
| Cross-app focus | 19.23 ms | 19.28 ms | 55.31 / 83.77 ms | 45.15 / 78.38 ms |
| Floating move, old edge gone and new edge visible | 5.94 ms | 6.22 ms | 26.86 / 31.35 ms | 25.64 / 31.78 ms |

The focus probe’s command round trips were effectively unchanged while its median displayed changes were earlier in the Swift capture. Treat this as a captured presentation difference, not an internal border-drawing duration. At 120 Hz, frame sampling is quantized at about 8.3 ms; callback scheduling and operating-system capture timing add uncertainty. These values are not photon latency. The move measurement includes the move command, window-server geometry update, old-edge removal, new-edge arrival and capture; it does not isolate border-rendering cost.

## Memory snapshots

Values are MiB (bytes divided by 1,048,576). Physical footprint is the daemon’s primary footprint measure; RSS is included for process context. WindowServer RSS is a system-wide, noisy metric. Do not sum the processes because shared pages and backing stores can overlap.

| Build and state | Daemon RSS / physical | Dock RSS / physical | WindowServer RSS |
|---|---:|---:|---:|
| Pre-port, flat, border off, glass | 84.11 / 53.40 | 33.86 / 50.60 | 275.78 |
| Pre-port, flat, border on, glass | 84.16 / 53.40 | 33.86 / 50.60 | 277.28 |
| Pre-port, five tabs, glass | 84.02 / 61.10 | 37.17 / 51.70 | 287.00 |
| Pre-port, five tabs, i3 | 88.08 / 65.60 | 37.17 / 51.70 | 287.08 |
| Swift, flat, border off, glass | 83.16 / 45.10 | 36.31 / 51.70 | 296.25 |
| Swift, flat, border on, glass (settled) | 83.19 / 45.10 | 36.31 / 51.70 | 296.62 |
| Swift, five tabs, glass | 90.34 / 56.50 | 36.31 / 51.70 | 296.67 |
| Swift, five tabs, i3 | 93.64 / 56.00 | 36.31 / 51.70 | 296.69 |

The five-tab captures include a tree snapshot confirming all five fixture windows were children of one tabbed container. At the start of Swift A, daemon physical footprint was 30.9 MiB and ended at 44.8 MiB; Swift B began at 44.8 MiB and ended at 45.1 MiB. The pre-port process had already received exploratory workload before its normalized blocks, while Swift began after only border probes. This warm-up mismatch makes start values unsuitable as a memory-saving comparison. The end-state captures show process footprints for the tested configurations; the brief workload does not establish a leak or a long-term growth plateau.

## Artifacts and limits

The complete valid per-sample JSON is archived in [doc/performance/2026-10-15](performance/2026-10-15/): [`preport A`](performance/2026-10-15/yabai_perf_preport_A.json), [`preport B`](performance/2026-10-15/yabai_perf_preport_B.json), [`Swift A`](performance/2026-10-15/yabai_perf_swift_A.json), [`Swift B`](performance/2026-10-15/yabai_perf_swift_B.json), the four [pre-port memory captures](performance/2026-10-15/), the four [Swift memory captures](performance/2026-10-15/), the four [border captures](performance/2026-10-15/), and the [Swift checked-between-switches probe](performance/2026-10-15/yabai_space_tail_swift.json). The capture directory README enumerates every filename.

The desktop locked at 2026-10-15 17:08:48 UTC. The original-restored pre-port drift check and matching pre-port tail probe are pending an unlocked desktop, so they are not included in these comparisons. A separate Swift command-only tail file began after the lock timestamp and is excluded as invalid: `/tmp/yabai_space_tail_swift_command_only.json` (start 17:09:56 UTC). The live harness now checks `CGSSessionScreenIsLocked` and exits before querying yabai when the screen is locked; the lock guard was verified in that state. No benchmark UI action should run while the desktop is locked.

The original installed binary was restored and its SHA-256 verified. Saved runtime configuration was restored and all three disposable test applications were closed. Crash reports remained at 18. Display/focus restoration is pending unlock; the restored daemon started while locked and may need another restart to rediscover AX windows. Nothing was merged into master.
