# Phase 5: Platform responsiveness

**Goal:** a hung application can no longer freeze tiling, fewer synchronous WindowServer round trips run on hot paths,
and no deprecated CoreGraphics calls remain.

**Prerequisites:** phase 4 (P4.5 keyed delayed events), and phase 2 (P2.1 `pid_t?`, P2.2 notification enum).
**Phase gate:** `make ci`.

Read the user memory note on WindowServer activation stalls, also in `doc/architecture.md` / `doc/live-testing.md` if
recorded there: synchronous SkyLight queries about a just-focused window can block for about 500 ms. AX and SkyLight
calls stay synchronous on `@WM` (conventions: "Blocking calls").

| ID | Title | Depends on |
|---|---|---|
| P5.1 | Hung-app AX breaker | — |
| P5.2 | Mission Control exit without the 100 ms window-list poll | — |
| P5.3 | Cache the space list and display arrangement | — |
| P5.4 | Batch space lookups while waiting for windows | — |
| P5.5 | No synchronous ordered-in query on the border order path | — |
| P5.6 | Replace deprecated CG event calls | — |
| P5.7 | Typed message send for the bridged move operation (optional) | — |

---

## P5.1 Hung-app AX breaker

**Where:**

- Only the system-wide element gets a messaging timeout (`systemElement.setMessagingTimeout(1.0)` in
  `WindowManager+Startup.swift`).
- Every AX call on a frozen app blocks `@WM` for up to 1 s, serially.
- `Application.swift` already treats `.cannotComplete` as a retry signal while observing (`axRetry`).

**Steps**

1. Add a pure, testable `struct AXBreaker` (in `YabaiCore` if it needs only pids and instants):
   - `mutating func recordTimeout(pid:now:)` opens the breaker for a pid for `cooldown` (2 s).
   - `func isOpen(pid:now:) -> Bool`.
   - `mutating func recordSuccess(pid:)` closes it.
2. Hold one breaker instance `@WM`; `WindowManager` is fine.
3. In the AX wrappers (`Platform/AX.swift`), the attribute getters and setters, after a call returns `.cannotComplete`,
   record a timeout for the element's pid (`AXUIElementGetPid`, from P2.1). Before a call from a **non-essential** path,
   skip it if the breaker is open for that pid. Non-essential means:
   - title refreshes;
   - property refreshes for rules;
   - animation frame writes.

   Essential calls (an explicit user command acting on that window, destroy handling) still go through. Implement this
   with a parameter or a separate wrapper method (`ifResponsive`), not a global switch.
4. Set a per-application timeout on each `Application.ref` when the application is created (`setMessagingTimeout(0.5)`),
   so a single call to a hung app waits 0.5 s instead of the default. Record the value next to the existing NOTE.
5. Log breaker transitions once per transition (open, close) through `Logger.windows` at notice level.
6. Tests: the `AXBreaker` state machine, covering open, cooldown expiry and success closing it.

**Acceptance:** the breaker is unit-tested, every non-essential call path names its choice explicitly, and builds are
clean.

**Live check:** freeze an app (`kill -STOP <pid>` of a test app such as TextEdit), then switch spaces, focus other
windows and open new windows. yabai stays responsive after at most one ~0.5 s stall. `kill -CONT` restores normal
handling.

**Gate:** quick. **Commit:** `P5.1 Skip non-essential AX calls to unresponsive applications`.

---

## P5.2 Mission Control exit without the 100 ms window-list poll

**Where:**

- `EventHandler.missionControlCheckForExit()` (`EventHandler+System.swift`) calls `CGWindowListCopyWindowInfo` every
  100 ms while Mission Control is active, looking for Dock windows at layer 18.
- The AX notification `AXExposeExit` is already observed (`MissionControl.swift`).

**Steps**

1. Trace how `AXExposeExit` is handled today and why the poll exists. Read the NOTEs; there may be exit paths that AX
   misses, such as switching spaces from within Mission Control. Record the findings in the notes.
2. Make the AX notification the primary exit signal. Keep the poll only as a fallback:
   - first check after 500 ms, then every 500 ms;
   - posted with the P4.5 key `.missionControlCheck`, so only one is pending;
   - cancelled (replaced with nothing) when the AX exit arrives. Add `EventLoop.cancel(key:)` if P4.5 didn't.
3. Replace `CGWindowListCopyWindowInfo` in the fallback with a SkyLight query for windows owned by Dock at that layer, if
   one exists in `Platform/SkyLight*.swift`. Otherwise keep the CG call and note that `kCGWindowName` is redacted
   without Screen Recording permission (the current `name != nil` check relies on that).

**Acceptance:** no CG window-list copy at 10 Hz anymore (read the code), and builds are clean.

**Live check:** enter and leave Mission Control in each way: the gesture; the key; clicking a window; clicking a space;
Escape; switching spaces from inside. After each exit, the layout is restored, and `yabai -m query --spaces` shows the
right visible space.

**Gate:** quick. **Commit:** `P5.2 Leave Mission Control on its AX notification with a slow fallback poll`.

---

## P5.3 Cache the space list and display arrangement

**Where:**

- `SpaceID.all` and its users (`missionControlIndex`, `previous`, `next`, `init?(missionControlIndex:)`) in
  `SpaceID.swift` recompute through `DisplayManager.shared.managedDisplaySpaces`, which calls
  `SLSCopyManagedDisplaySpaces` on every access.
- `DisplayManager.arrangedDisplays` queries and sorts on every read. Its comparator builds display ids and calls
  `CGDisplayBounds` for both operands of every comparison.

**Steps**

1. **Arrangement.** Snapshot each display once as `(uuid, center)` and sort with a pure function in `YabaiCore`. Next to
   it, the existing `orderedBuiltinLast` logic keeps its semantics. Test the pure sort.
2. **Space list.** Add `@WM` caches on `DisplayManager` (or `SpaceManager`, whichever owns the data) for
   `managedDisplaySpaces` and `arrangedDisplays`. Invalidate them on:
   - `SLSNotification.spaceCreated` and `.spaceDestroyed`;
   - the display reconfiguration callback(s) (`DisplayManager`);
   - space-change events (`spaceChanged`, `displayChanged`);
   - Mission Control exit.
3. Add `invalidateSpaceCaches()` and call it from each of these handlers. Add a debug log on a miss.
4. Safety net: the cache also expires after 2 s, so a missed invalidation self-heals.
5. Tests: the pure sort, and that the cache returns the stored value until invalidated. Put the cache logic in a small
   generic `struct Cached<Value>` with an injectable clock, so tests need no window server.

**Acceptance:** repeated reads within an event don't call SkyLight (read the code and check the debug log), and the
tests pass.

**Live check:**
- create and destroy spaces (with the payload);
- move spaces between displays;
- plug and unplug a display;
- `space --focus next/prev/<index>`.

Indices and focus must stay correct.

**Gate:** quick. **Commit:** `P5.3 Cache space lists and display arrangement until they change`.

---

## P5.4 Batch space lookups while waiting for windows

**Where:** `SpaceID.waitForWindows(_:timeoutMS:)` and `waitForWindow` (`SpaceID.swift`) poll `wid.space` per window
every 10 ms. Also, the `Window` getters `space`, `spaces`, `parent` and `level` each issue their own SkyLight query.

**Steps**

1. In `waitForWindows`, query all still-pending windows with one call per poll (`SLS.spaces(_:forWindows:)` or the
   equivalent wrapper; grep `forWindows` in `Platform/SkyLight.swift`). Keep the arrival logic monotonic: a window that
   arrived stays arrived.
2. Leave the `Window` getters alone unless a caller reads several of them in a row on a hot path. If so, add one
   combined snapshot query used by that caller only, and list it in the notes.
3. Test the arrival bookkeeping with a pure helper that takes a closure for the query.

**Acceptance:** one SkyLight call per poll iteration, and the tests pass.

**Live check:** move several windows to another space at once (`window --space` on a tabbed container, and a scratchpad
toggle); the operation completes without visible extra delay.

**Gate:** quick. **Commit:** `P5.4 Query the spaces of all pending windows in one call`.

---

## P5.5 No synchronous ordered-in query on the border order path

**Where:**

- `Border` update (`Border.swift`): `if what.contains(.order) && !SLS.windowIsOrderedIn(SLS.connection, wid) { hide();
  return }`.
- This runs from the `windowOrdered` SLS notification and from tab-bar card ordering (`TabBarGlass.swift`), so it sits
  next to focus changes, which is the activation-stall class.

**Steps**

1. Track ordered-in state per border from the notifications that already arrive:
   - `windowOrdered` (808): ordered in;
   - `windowHidden` (816) and `windowDestroyed` (804): ordered out.

   Confirm these semantics by reading the handlers in `MissionControl.swift`/`Border.swift` and their NOTEs. Record
   your conclusion in a `// NOTE:`.
2. On the `.order` path, use the tracked state, and fall back to the synchronous query only when the state is unknown
   (a new border).
3. Leave every other `windowIsOrderedIn` call alone.

**Acceptance:** the `.order` path makes no SkyLight query when state is known, and builds are clean.

**Live check:**
- borders on; switch focus rapidly between apps with cmd-tab;
- minimize and restore;
- hide (`cmd-h`) and unhide;
- switch spaces.

Borders appear and disappear correctly, with no stuck border on a hidden window.

**Gate:** quick + sanitizers (the border lock). **Commit:** `P5.5 Track border ordering from notifications instead of querying`.

---

## P5.6 Replace deprecated CG event calls

**Where:**

- `CGPostMouseEventC` (`CPrivate.h` wrapper of the deprecated `CGPostMouseEvent`) is used in `DisplayID.swift` to
  click an empty point and focus a display.
- `CGSetLocalEventsSuppressionIntervalC(0.0)` in `Yabai.swift`.
- `CGEnableEventStateCombining` has no replacement; keep it.

**Steps**

1. Replace the click with `CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown/.leftMouseUp, mouseCursorPosition:
   point, mouseButton: .left)` and `.post(tap: .cghidEventTap)`. Check the NOTE in `CPrivate.h` that explains why
   `CGPostMouseEvent` was used (window-server click without an event tap?), and keep the reason in a NOTE. If the NOTE
   says the CGEvent path behaves differently in a way that matters, stop: mark the subphase `blocked` with that reason.
2. Replace the suppression interval with `CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval
   = 0`, applied to the source(s) the daemon posts from. If the daemon posts with `nil` sources, document that the
   setting applied to the default source, and check that the new API covers it.
3. Remove the now-unused CPrivate wrappers, and run `make install`.

**Acceptance:** `grep -rn "CGPostMouseEvent\|CGSetLocalEventsSuppressionInterval" Sources` shows no code use; NOTE text
may remain. Release builds.

**Live check:** `display --focus <n>` on a display with an empty space (no windows) moves focus there; mouse warping
after focus has no lag.

**Gate:** quick + release. **Commit:** `P5.6 Post focus clicks and suppression settings through CGEvent APIs`.

---

## P5.7 Typed message send for the bridged move operation (optional)

**Where:** `SLS.bridgedMoveWindows(_:toSpace:)` (`Platform/SkyLight.swift`) gets `objc_msgSend` through `dlsym` and
`unsafeBitCast`s it to two function types.

**Steps**

1. Try a Swift-only form in a scratch file first: `NSClassFromString` as `NSObject.Type`, `alloc` through
   `perform(NSSelectorFromString("alloc"))`, and `initWithWindows:spaceID:` through a typed `@convention(c)` IMP
   obtained with `class_getMethodImplementation` / `method_getImplementation`. That is still a cast, but of an IMP to its
   exact signature, without `dlsym`.
2. If that is clearly simpler and safer, replace the current code. If not, mark the subphase `skipped` with the reason.
   AGENTS.md allows CPrivate wrappers only when Swift can't make the call, and Swift can, so don't move it to C.

**Acceptance:** either a simpler typed call without `dlsym`, or `skipped` with a reason.

**Live check, if changed:** move windows to another space through the commands that use this path (grep the callers),
for example `window --space <n>` without the payload.

**Gate:** quick. **Commit:** `P5.7 Call the bridged move operation through its typed implementation`, or a status-only
`P5.7 Record skip`.
