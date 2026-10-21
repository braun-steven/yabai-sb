# Open issues

Carried over from the Swift refactor's **Open issues** section when `doc/swift-refactor.md` was removed on 2026-10-20.
The full text is in git: `git show edf74650:doc/swift-refactor.md`.

## 1. Crash: force unwrap of a terminated application's window

- **Status:** open. Not reproduced since the refactor; not re-tested after the cleanup.
- **Where:** `Sources/Yabai/WindowAnimation.swift:454`, `WindowFrameGroup.groups(for:)`, `let owner = placement.window.application!`.
- **Symptom:** quitting several applications quickly traps. The original report named `capture.window.application!` in `window_manager_group_window_frames`; related reports trap in `window_unobserve`.
- **Cause (suspected):** a window of an already terminated application is still laid out, so its `application` is nil when the frame group is built. The path is `windowDestroyed` → `space_manager_untile_window` → `tree_flush`.
- **Pre-existing:** seen in the C build since 2026-10-14; not introduced by the refactor.
- **Reproduce:** quit several applications at once, e.g. `scripts/live-tests/live.py cleanup`, then check `scripts/live-tests/crashes.py`.
- **Next step:** find where a destroyed window keeps its tree slot, and skip or untile a window whose application is gone instead of force-unwrapping. This needs its own fix commit, not a refactor change.

## 2. Live checks never run: Mission Control, cross-display, SA unloaded

- **Status:** open. Not covered by any live check so far.
- **Not checked:**
  - Mission Control enter and exit. An agent shell cannot open Mission Control (see `doc/live-testing.md`).
  - Cross-display moves. The test machine has one display.
  - Space moves with the scripting addition unloaded. Checks so far ran with it loaded.
- **Next step:** run these on the user's machine with a second display, and with the scripting addition unloaded, before relying on the refactored display and space paths.

## 3. User-visible behavior change missing from the CHANGELOG

- **Status:** resolved. Entry added under `[Unreleased]` / Changed in `CHANGELOG.md`.
- **Change:** a window on no space now reports `is-visible` false from `query --windows` (it was true, through `space_is_visible(0)`).
- **Also:** `query --tree` and `query --displays --space` without an active space now fail. `space --display` and `window --display` were not re-checked, so the entry leaves them out.
- **Next step:** none. `doc/yabai.asciidoc` has no prose for `is-visible`, only the JSON examples.

## 4. Latency regressions accepted but not explained

- **Status:** accepted by the user on 2026-10-20 without investigation. Cause not located.
- **Numbers** (same fixture, both builds benchmarked two or three times):
  - Same-application focus over the socket: 4.5 ms vs 3.8 ms.
  - `perf.py` `focus-same-app-observed`: 63.5 / 63.6 ms vs 45.6–48.1 ms.
  - `perf.py` `floating-resize-command-pair`: 70.3 / 72.7 ms vs 53.5 / 64.3 / 68.9 ms (about +15% on average, noisy).
  - `query --tree` on a flat five-window space: 0.121 ms vs 0.107 ms (accepted as sub-millisecond).
- **Candidates:** the `AsyncStream` hop in the event loop (the consumer runs at `.medium` priority), and the IPC response queue.
- **Next step:** only if the user wants it. Measure with `scripts/live-tests/perf.py` on both builds, then test each candidate separately.
