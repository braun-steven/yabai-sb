# Phase 11: Rendering and UX

**Goal:** smoother, cheaper rendering, and fixes for the input edge cases. Reduce Motion is respected for window
animations too.

**Prerequisites:** phase 7 (P7.5 tab bar backend). **Phase gate:** `make ci`, plus `swift test --sanitize=thread`.

Read `doc/swift-port-performance.md`, `doc/performance/`, and the user memory notes on border memory and WindowServer
activation stalls. Most subphases need a live check, because these paths can't be fully tested headless.

| ID | Title | Depends on |
|---|---|---|
| P11.1 | Respect Reduce Motion for window animations | — |
| P11.2 | One AX frame-setting path | — |
| P11.3 | Skip identical tab bar and selection renders | — |
| P11.4 | Move border edges in one update | — |
| P11.5 | Animation: alpha once per proxy, display link on the right screen | — |
| P11.6 | Cheaper tab bar hover | — |
| P11.7 | Focus-follows-mouse fixes | — |

---

## P11.1 Respect Reduce Motion for window animations

**Where:**

- `WindowAnimation.animationDuration` (`WindowAnimation.swift`) returns `0` only while animations are suppressed.
- `TabBarGlass` already reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and observes
  `accessibilityDisplayOptionsDidChangeNotification`.

**Steps**

1. Add a cached `reduceMotion` flag (updated on the main thread from the notification, read on `@WM` through an
   `Atomic<Bool>`). Reuse the existing observer if it can serve both.
2. `animationDuration` returns 0 when the flag is set.
3. Document this in the README near the existing "Reduce Motion disables transitions" sentence: it now covers window
   animations too. Add a CHANGELOG entry.
4. Test: with the flag injected true, `animationDuration` is 0. Expose the flag as an internal static for tests.

**Live check:** System Settings → Accessibility → Display → Reduce Motion on: window moves are instant. Off: animated
(with `window_animation_duration` > 0).

**Gate:** quick. **Commit:** `P11.1 Skip window animations when Reduce Motion is on`.

---

## P11.2 One AX frame-setting path

**Where:**

- The animation and layout path sets frames as size → position → size (`setFrame` in `WindowAnimation.swift`), with
  `AXEnhancedUserInterface` turned off once per application for a batch.
- `Window.resizeRelative` (`Window.swift`), used by mouse-drag resizing (`EventHandler+Mouse.swift`, throttled by a fixed
  `67.67` ms), does move → resize, toggling EUI per call.
- `Window.setFrame` toggles EUI per window.

**Steps**

1. Make one `@WM` function own the AX frame write: `applyFrame(_ window:, frame:, euiScope:)`, doing size → position →
   size and EUI handling.
2. Use it from `resizeRelative` and `Window.setFrame`. During a drag, keep EUI disabled for the application for the
   whole drag: disable on drag start, restore on drag end. Restore it on every exit path, including cancellation.
3. Name the throttle constant (`dragResizeInterval`) and document why 67.67 ms (≈ 15 Hz), or derive it from the measured
   AX write latency of the last write (an exponential moving average, clamped to 16–100 ms). Choose the simpler one
   unless you can justify the adaptive version; record the choice.
4. Tests: a pure helper that decides the order of operations and EUI toggles for (drag start, drag frames, drag end)
   returns the expected sequence.

**Live check:** drag-resize windows of Safari, Terminal, an Electron app (VS Code) and Finder, both edges. There is less
jitter than before, and after the drag the EUI state is restored: VoiceOver or accessibility apps still work.

**Gate:** quick. **Commit:** `P11.2 Set window frames through one AX path with drag-long EUI scope`.

---

## P11.3 Skip identical tab bar and selection renders

**Where:**

- `TreeView.flushTree` calls `root.renderBars()` and `selected.showSelection()` on every flush.
- `TabBar.render` always draws, orders and publishes hits.
- `showFeedback` (`TreeView.swift`) has no dedupe, unlike the drop feedback in `MouseHandler`.

**Steps**

1. Give each tab bar a `RenderKey: Equatable`, made of:
   - frame;
   - card;
   - entries, with titles and the icon identity (pid or bundle id, not the image pointer, unless it is stable);
   - states (focused, urgent, …);
   - style;
   - a `Config` generation counter that increments on every config change. Add it to `ConfigObserver` if no such
     counter exists.
2. Skip drawing when the key equals the last rendered key. Ordering is still updated if the z-order may have changed;
   be conservative and order every time unless proven redundant.
3. Dedupe selection feedback by `(container id, direction, frame)`.
4. Tests: rendering twice with the same key records one draw (headless recorder or a draw counter); a config change
   forces a redraw.

**Live check:** tabbed containers update titles and icons when they change, focus changes update the active tab, and
config changes to tab bar colors apply immediately.

**Gate:** quick. **Commit:** `P11.3 Skip tab bar and selection renders that would not change`.

---

## P11.4 Move border edges in one update

**Where:** `Border.updateFrameLocked` and `Border.windowMoved` (`Border.swift`) move the four edge windows with four
`SLS.moveWindow` calls. Only the reshape path is wrapped in `disableUpdate`/`reenableUpdate`.

**Steps**

1. Wrap the four moves in `SLS.disableUpdate`/`reenableUpdate`, the same wrapper the reshape path uses. If
   `Transaction` (`SkyLight+Windows.swift`) can carry moves, prefer one transaction; check what it supports first.
2. Make sure `reenableUpdate` runs on every path, using `defer`.

**Live check:** borders on; drag a window quickly. The border edges no longer separate visibly mid-drag. Compare a
screen recording before and after if possible.

**Gate:** quick + sanitizers (border lock). **Commit:** `P11.4 Move all border edges in one window server update`.

---

## P11.5 Animation: alpha once per proxy, display link on the right screen

**Where:**

- The animation tick (`WindowAnimation.swift`) calls `SLS.windowAlpha` per window per frame, although the alpha is
  already read when the proxy is built.
- The display link comes from `NSScreen.main`, with no `preferredFrameRateRange`.

**Steps**

1. Store the alpha in the animation entry when the proxy is created, and use it in the tick.
2. Pick the screen that contains the union of the animated target frames (fall back to `NSScreen.main`), and set
   `preferredFrameRateRange` to `.init(minimum: 60, maximum: Float(screen.maximumFramesPerSecond), preferred: Float(screen.maximumFramesPerSecond))`,
   or the equivalent API for `CADisplayLink` from `NSScreen.displayLink`; check the SDK.
3. Test the screen choice through a pure helper (frames plus screen rects in, index out).

**Live check:** on a ProMotion display, animations look smoother. Optional measurement: log the tick interval at debug
level and check about 8 ms on the built-in display at 120 Hz. Animations on an external display don't stutter.

**Gate:** quick. **Commit:** `P11.5 Reuse proxy alpha and drive animations from the target screen`.

---

## P11.6 Cheaper tab bar hover

**Where:** `TabBar.updatePointer` (`TabBar.swift`), called on every mouse move from the event tap (`MouseHandler`),
runs `isCovered` (`SLSFindWindowAndOwner` + `CGWindowListCreate`) before checking whether the hover target changed.
It only happens while the pointer is over a glass tab bar.

**Steps**

1. Compute the candidate `(glass, windowID)` from the hit table first. If it equals the current pointer state (same bar,
   same entry, same pressed state), return without calling `isCovered`.
2. Cache the `isCovered` result per `(aboveWid, bar)` until the next `windowOrdered` notification invalidates it (an
   atomic generation bumped in the notification handler).
3. Keep the tap callback fast: the tap is disabled if callbacks are slow (see the timeout handling in
   `MouseHandler.swift`).

**Live check:** hovering glass tabs highlights correctly, including when another window partly covers the bar, and moving
a window over the bar updates the hover.

**Gate:** quick + sanitizers. **Commit:** `P11.6 Check tab bar coverage only when the hover target changes`.

---

## P11.7 Focus-follows-mouse fixes

**Where:**

- `EventHandler+Mouse.swift` (the FFM handler around the `ffmWindowID` gate) runs `window(at:)` on every non-stale
  move. It has a magic 1250 ms gesture delay. `ffmWindowID` is cleared only by a focus event, so a refused focus could
  block FFM until the next focus change (inferred, not reproduced).
- `MouseState.ffmWindowID` is in `MouseHandler.swift`.

**Steps**

1. Name the 1250 ms constant, with a comment on why it exists.
2. Skip the hit test while the pointer stays inside the frame of the last hit window, with the frame cached at the hit.
3. Clear `ffmWindowID` when no focus event arrives within 500 ms of the FFM focus request: store the request time and
   check it on the next move. That makes a refused focus retryable.
4. Tests: a pure decision helper `(pointer, lastHitFrame, ffmWindowID, requestTime, now) → (hitTest: Bool, clearPending:
   Bool)`, with rows as `@Test(arguments:)`.

**Live check:** with `focus_follows_mouse autofocus` and `autoraise`:
- moving across windows focuses each;
- moving within a window doesn't trigger repeated work (debug log);
- over a window whose app refuses focus (a modal dialog's parent), FFM resumes on the next window.

**Gate:** quick. **Commit:** `P11.7 Make focus follows mouse cheaper and self-healing`.
