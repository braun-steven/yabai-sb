# Open issues

Carried over from the Swift refactor's **Open issues** section when `doc/swift-refactor.md` was removed on 2026-10-20.
The full text is in git: `git show edf74650:doc/swift-refactor.md`.

## 2. Live checks never run: Mission Control, cross-display, SA unloaded

- **Status:** open. Not covered by any live check so far.
- **Not checked:**
  - Mission Control enter and exit. An agent shell cannot open Mission Control (see `doc/live-testing.md`).
  - Cross-display moves. The test machine has one display.
  - Space moves with the scripting addition unloaded. Checks so far ran with it loaded.
- **Next step:** run these on the user's machine with a second display, and with the scripting addition unloaded, before relying on the refactored display and space paths.

## 4. Latency regressions accepted but not explained

- **Status:** accepted by the user on 2026-10-20 without investigation. Cause not located.
- **Numbers** (same fixture, both builds benchmarked two or three times):
  - Same-application focus over the socket: 4.5 ms vs 3.8 ms.
  - `perf.py` `focus-same-app-observed`: 63.5 / 63.6 ms vs 45.6–48.1 ms.
  - `perf.py` `floating-resize-command-pair`: 70.3 / 72.7 ms vs 53.5 / 64.3 / 68.9 ms (about +15% on average, noisy).
  - `query --tree` on a flat five-window space: 0.121 ms vs 0.107 ms (accepted as sub-millisecond).
- **Candidates:** the `AsyncStream` hop in the event loop (the consumer runs at `.medium` priority), and the IPC response queue.
- **Next step:** only if the user wants it. Measure with `scripts/live-tests/perf.py` on both builds, then test each candidate separately.
