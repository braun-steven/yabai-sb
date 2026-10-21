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

## 5. Negative window length in a split shorter than its gaps

- **Status:** open, minor. Found by the layout property test in Phase 4 of `doc/testing-refactor.md`.
- **Where:** `Sources/Yabai/Con.swift`, `Con.layOut`: the last child of a split gets `end - offset`, and the other
  children `Int(total * percent + 0.5)` of a `total` that is negative once the gaps exceed the length of the split;
  rounding the other children up can also leave less than nothing for the last one.
- **Symptom:** e.g. a 22 px high `splitv` of three windows with gap 12 lays them out at heights 0, 0 and −2. The
  window server receives a negative size; applications then keep their minimum size and overlap. It needs containers
  only a few gaps long, e.g. nested splits on a small display with a large gap. Such a window is also placed again on
  every flush: `CGRect` standardizes the negative size, so `isClose` never matches the frame request.
- **Test:** `negativeLengthInASplitShorterThanItsGaps` (`tests/YabaiTests/LayoutTests.swift`, `withKnownIssue`). The
  layout property skips such splits, and the flush property skips trees with a negative length.
- **Next step:** decide the wanted layout (clamp lengths at 0, or shrink the gaps), then fix and drop `withKnownIssue`.

## 6. A non-finite ratio or resize value changes every share

- **Status:** open, minor. Found by the window command tests in Phase 5 of `doc/testing-refactor.md`.
- **Where:** `WindowCommand.parse` (`Sources/YabaiCore/WindowCommand.swift`) reads `--ratio` and `--resize` values with
  `%f`, which accepts `nan` and `inf`. `Float.clamped` (`Sources/Yabai/Helpers.swift`) passes NaN through, so
  `WindowManager.ratioDelta` returns NaN, and `Con.resize` (`Sources/Yabai/Con.swift`) turns an infinite delta into
  NaN (`inf - inf`) when it clamps the second share.
- **Symptom:** on `w1 | w2 | w3`, `window --ratio abs:nan`, `--ratio rel:nan` and `--resize right:nan:0` (w2 acting)
  succeed and lay the windows out at 25%, 25% and 50%; `--resize right:inf:0` grows w1 to 58%. `--ratio abs:inf` is
  clamped and works.
- **Test:** `nonFiniteValuesLeaveTheTree` (`tests/YabaiTests/WindowCommandTests.swift`, `withKnownIssue`).
- **Next step:** reject non-finite values in the parser (a failure like other unknown values) and make `Con.resize`
  ignore a non-finite delta; then drop `withKnownIssue`.

## 7. Integer tokens wrap at 32 bits

- **Status:** open, minor. Found by the config tests in Phase 6 of `doc/testing-refactor.md`.
- **Where:** `Token.positiveInteger` (`Sources/YabaiCore/Message.swift`) accumulates the digits in an `Int32` with
  wrapping arithmetic (`&*`, `&+`), so a long run of digits wraps instead of being rejected.
- **Symptom:** `config window_gap 2147483648` sets a gap of −2147483648, `config window_gap 4294967306` a gap of 10,
  and `config tab_bar_height 99999999999` a height of 1215752191. Every argument read as `TokenValue.int` is
  affected, e.g. the integer config options and the `rule`/`signal` indices; a negative result passes the options
  that accept any `.int` (`window_gap`, the paddings, `tab_bar_offset`).
- **Test:** `integerValuesOutOfRangeFail` (`tests/YabaiTests/MessageConfigTests.swift`, `withKnownIssue`). The golden
  replay records `config tab_bar_height 99999999999`; its record changes with the fix.
- **Next step:** return nil on overflow (`multipliedReportingOverflow`), so that the token is a string and the option
  fails with an unknown value; then drop `withKnownIssue` and re-record the golden replay.
