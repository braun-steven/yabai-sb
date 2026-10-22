# Phase 4: Core lifecycle and event loop

**Goal:**

- one code path for removing and untiling windows;
- per-window state cleaned up in one place;
- AX callbacks free of raw object pointers;
- delayed events handled by a single timer with keyed replacement;
- focus state in one struct;
- startup steps that are explicit.

**Prerequisites:** phase 2 (P2.2 added the `SLSNotification` enum). **Phase gate:** `make ci`, plus `swift test
--sanitize=thread` and `--sanitize=address`.

Read `doc/architecture.md` fully before any subphase. Behavior must stay identical: these are refactors. Every
subphase adds `DaemonState` tests for the code it restructures, written **before** the refactor, so they pin the
current behavior; they must pass before and after.

| ID | Title | Depends on |
|---|---|---|
| P4.1 | One window teardown path | — |
| P4.2 | One untile/unmanage path | P4.1 |
| P4.3 | `forget(_:)` for per-window tables | P4.1 |
| P4.4 | AX window callbacks carry a `WindowID` | P4.1 |
| P4.5 | Single timer and keyed delayed events in `EventLoop` | — |
| P4.6 | `FocusState` | — |
| P4.7 | Explicit startup sequence | P4.5 |

---

## P4.1 One window teardown path

**Where:**

- `EventHandler.windowDestroyed(_:)` (`EventHandler+Window.swift`) and `EventHandler.removeTerminatedWindows(_:)`
  (`EventHandler.swift`) repeat the same teardown tail:
  - clear `MouseState.shared.window` and `ffmWindowID`;
  - push `.windowDestroyed` when `isEligible`;
  - `removeScratchpad(from:unfloat:false)`, `removeWindow`, `unobserve()`, `destroy()`.
- They differ in two ways. The first untiles immediately with focus handoff (`treeFocusCandidate`, `untile`,
  `removeManagedWindow`, `treeFocusAfterClose`, then a border refresh). The second batches (`untileWindowBatched`,
  returning the views to flush) and calls `invalidate()` first.

**Steps**

1. Write the tests first (`DaemonState` suite, `Workspace` fixture, fake ids): destroy a tiled window through each path
   and check that the following are equal for an equivalent setup:
   - the `treeDump`;
   - `managedWindows`;
   - the window table;
   - the scratchpad state;
   - the pushed signals. Inspect `EventSignals.shared` the way existing tests do.
2. Add `@WM func teardown(_ window: Window, untile: TeardownUntile)` on `EventHandler`, or on `WindowManager` if that
   fits the architecture doc better. Make `enum TeardownUntile { case immediate, batched(into: inout [View]) }`, or
   pass a closure, whichever reads better without protocols. It holds the shared tail exactly once.
3. Make both call sites use it. Keep the order of operations exactly as today in each path. Where they differ, the
   differences are the parameter.
4. Keep `invalidate()` semantics: `removeTerminatedWindows` calls it, while `windowDestroyed` relies on the caller.

**Acceptance:** the shared tail exists once (`grep -n "removeScratchpad(from:" Sources/Yabai/EventHandler*.swift` shows
one call), and the new tests pass.

**Gate:** quick. **Commit:** `P4.1 Tear down destroyed and terminated windows through one path`.

---

## P4.2 One untile/unmanage path

**Where:** the sequence "untile from view, `adjustLayer(to: .normal)` if needed, `removeManagedWindow`, `purifyWindow`"
recurs with small variations at:

- `WindowManager+Reconciliation.swift` (two sites);
- `WindowManager+Management.swift` (two sites);
- `WindowManager+Tree.swift`;
- `EventHandler.swift` (around `purifyWindow` in the space/app handling);
- `WindowManager+Discovery.swift`.

Find all of them with `grep -rn "purifyWindow(\|removeManagedWindow(" Sources/Yabai`.

**Steps**

1. Tabulate every site in the P4.2 notes in `status.md`: which steps it does, in which order, and why it differs.
2. Add `@WM func unmanage(_ window: Window, from view: View?, options: UnmanageOptions)` on `WindowManager`, with an
   `OptionSet` for the variable parts (`resetLayer`, `purify`, `flush`).
3. Replace each site whose behavior the option set reproduces exactly. Leave a site alone, with a `// NOTE:` explaining
   why, if its order can't be expressed without changing behavior.
4. Tests: for two representative sites (reconciliation, and a float toggle in Management), pin the tree and window
   state before and after.

**Acceptance:** at least 5 of the 7 sites use `unmanage`, the tests pass, and the golden replay is unchanged.

**Gate:** quick. **Commit:** `P4.2 Unmanage windows through one helper`.

---

## P4.3 `forget(_:)` for per-window tables

**Where:** `WindowManager.removeWindow(_:)` (`WindowManager+Registry.swift`) clears `Border` only. Other global
per-window state:

- `TabBar` hit and pointer state (`tabBarHits`, `tabBarPointer`) in `TabBar.swift`;
- the animation tables in `WindowAnimation.swift` (`windowAnimations`);
- `MouseState` fields;
- the top-level atomics in `EventHandler.swift`;
- anything else keyed by `WindowID`. Grep `\[WindowID` and `WindowID:` in `Sources/Yabai`.

**Steps**

1. List the tables in the notes.
2. Add one `@WM func forget(_ id: WindowID)` that clears every table that can hold the id.
   - Some tables are `nonisolated` behind a `Mutex`: use `withLock`.
   - Some are rebuilt on each render (tab-bar hits): skip those, with a comment.
3. Make `removeWindow` call `forget`, and keep `Border.remove` inside `forget`.
4. Group the loose top-level atomics of `EventHandler.swift` into a caseless `enum` namespace (e.g. `MouseEventState`),
   if that needs no behavior change.
5. Test: after `removeWindow(id)`, each table that `forget` covers lacks the id. This needs test-visible accessors on
   the tables (internal is fine, through `@testable`).

**Acceptance:** the test passes, and no `WindowID`-keyed global table is left that `forget` doesn't handle, unless it
carries a comment saying why.

**Gate:** quick + sanitizers (locks). **Commit:** `P4.3 Forget all per-window state when a window is removed`.

---

## P4.4 AX window callbacks carry a `WindowID`

**Where:**

- `Window.observe()` registers AX notifications with `Unmanaged.passUnretained(self).toOpaque()` as the context.
- The handler (`applicationNotificationHandler` in `Application.swift`, on the main run loop) turns it back into a
  `Window` for minimized, deminiaturized and destroyed notifications, then calls `invalidate()` on the destroyed path.
- `@WM` may already have released the window (`unobserve()` + `removeWindow`) while the main-thread callback is
  running, so the access is a possible use-after-free. Not reproduced, but the pattern is unsafe.

**Steps**

1. Register with the window id as the context: `UnsafeMutableRawPointer(bitPattern: UInt(id.rawValue))`, with id 0
   excluded (ids are non-zero). Read it back as `WindowID(nonzero: UInt32(UInt(bitPattern: context)))`.
2. Change the events to carry ids: `.windowMinimized(windowID:)`, `.windowDeminimized(windowID:)` and
   `.windowDestroyed(windowID:)`. Check the `Event` enum in `EventLoop.swift` and every place that constructs these
   events; `removeTerminatedWindows` and other paths may post `.windowDestroyed` too.
3. Move the "only one caller posts destruction" guarantee to `@WM`. In the handler for `.windowDestroyed(windowID:)`,
   look up the window (`WindowManager.shared.window(for:)`), return if it's missing or `!window.invalidate()`, then
   proceed. All posters now go through `@WM`, so the compare-exchange in `invalidate()` still serializes them.
4. Update the NOTE above `applicationNotificationHandler` to describe the new ownership.
5. Tests: post `.windowDestroyed(windowID:)` twice for one fake window, and check that teardown runs once. Post it for
   an unknown id, and check that nothing happens.

**Acceptance:**

- `grep -n "Unmanaged<Window>" Sources/Yabai` is empty.
- The tests pass under TSan and ASan.

**Live check:** open and close windows of several apps quickly (Terminal `cmd-n`/`cmd-w` bursts); minimize and restore;
quit an app with several windows. No crash, and the tree stays consistent (`yabai -m query --tree`).

**Gate:** quick + sanitizers. **Commit:** `P4.4 Pass window ids, not unretained windows, to AX callbacks`.

---

## P4.5 Single timer and keyed delayed events in `EventLoop`

**Where:**

- `EventLoop.post(_:after:)` (`EventLoop.swift`) inserts into the `delayedEvents` Deque (behind a Mutex, sorted by
  deadline) and starts one `Task { sleep; postDueEvents() }` per call. AGENTS.md forbids a Task per event.
- Superseding is hand-rolled with generation counters: `SpaceManager.spaceLayoutGeneration` with
  `.spaceLayoutReconcile(generation:)`, and the focus deferral `.windowFocusDeferred` with the
  `pendingFocusWindowID`/`pendingFocusTime` checks.

**Steps**

1. Pin the current behavior with tests on a pure helper:
   - delayed events come out in deadline order;
   - equal deadlines keep FIFO order;
   - `postDueEvents` delivers only due events.

   Extract the queue logic into a struct `DelayedQueue` (pure, in `Sources/Yabai`) so that tests don't sleep.
2. Replace the per-post `Task` with one long-lived timer.
   - Use a `DispatchSourceTimer` on a private serial queue. That queue is not `@WM` and not the Swift pool, so it
     doesn't violate the "AX/SLS not on the pool" rule; the timer only posts.
   - Or use one `Task` that sleeps until the earliest deadline and is re-armed when an earlier event arrives.
   - Re-arm on every insert whose deadline is earlier than the armed one, and after each delivery.
3. Add `post(_:after:key:)` with `key: DelayedEventKey?` (a small enum, e.g. `.spaceLayoutReconcile`,
   `.missionControlCheck`). Inserting with a key removes any pending event with the same key.
4. Migrate `spaceLayoutReconcile` to the key, and remove `spaceLayoutGeneration` and the generation payload. Migrate the
   Mission Control re-check (`.missionControlCheckForExit`) to the key as well. Leave `windowFocusDeferred` as is; P4.6
   handles focus.
5. Update the comment block at the top of `EventLoop.swift` and `doc/architecture.md`.

**Acceptance:**

- `grep -n "Task {" Sources/Yabai/EventLoop.swift` shows only the main consumer.
- `spaceLayoutGeneration` is gone.
- The tests pass under TSan and ASan.

**Live check:** plug or unplug a display, and change `space_layout`, so the reconcile path runs. Open and close Mission
Control several times; space layout and Mission Control exit behave as before.

**Gate:** quick + sanitizers. **Commit:** `P4.5 Deliver delayed events from one timer with keyed replacement`.

---

## P4.6 `FocusState`

**Where:**

- `WindowManager` (`WindowManager.swift`) holds seven focus fields: `windowLostFocusedEvents`,
  `applicationLostFrontSwitchedEvents`, `focusedWindowID`, `focusedWindowPSN`, `pendingFocusWindowID`,
  `pendingFocusTime` and `lastWindowID`.
- Six one-line wrappers live in `WindowManager+Registry.swift`.
- The getter `pendingFocusWindow` in `WindowManager+Focus.swift` clears state as a side effect.

**Steps**

1. Pin the current behavior with tests on the focus helpers that are already pure (`canUseKnownFocus` etc.), plus new
   tests through the wrappers.
2. Introduce `struct FocusState` with:
   - `focused: WindowID?` and its PSN, keeping the PSN only if it can't be derived cheaply. Check every reader; if the
     window is always known, derive it.
   - `pending: (id: WindowID, deadline: ContinuousClock.Instant)?`
   - `last: WindowID?`
   - the two lost-event counters.

   Give it mutating methods named after the domain operations, for example `setPending`, `consumePending(now:)` (which
   replaces the side-effecting getter) and `focusChanged(to:)`.
3. `WindowManager` holds `var focus = FocusState()`. Replace the wrappers, and update the callers (grep each old field
   name).
4. Move `FocusState` into `YabaiCore` if it uses no CPrivate/AppKit types (PSN is a plain struct? check), and test it
   there.

**Acceptance:** none of the old field names remain as stored properties, there is no side effect in a getter, and the
tests pass.

**Live check:** focus follows cmd-tab, clicking, `window --focus` and closing windows (focus returns to the previous
window in the container); `focus_follows_mouse` still works.

**Gate:** quick. **Commit:** `P4.6 Hold focus state in one FocusState value`.

---

## P4.7 Explicit startup sequence

**Where:** `Daemon.run` (`Yabai.swift`) is one long function, and `configureSettingsAndAcquireLock` mixes lock
acquisition, signal setup, SkyLight settings and CPrivate symbol resolution. Managers begin in different styles:

- `Workspace.begin`;
- `ProcessManager.begin` and `DisplayManager.begin` (both `nonisolated`; keep the NOTE in `DisplayManager.swift`);
- `SpaceManager.begin`, which also writes `Config`;
- `WindowManager.begin` (`+Startup`).

**Steps**

1. Split `configureSettingsAndAcquireLock` into named functions: `acquireLock()`, `installSignalHandlers()`,
   `configureEventSystem()` and `resolvePrivateSymbols()`. Keep the order.
2. Turn `Daemon.run` into a list of named steps with one `Logger.daemon.debug` line per step. A plain sequence of
   function calls is fine; no step protocol (conventions: no protocols for DI).
3. `SpaceManager.begin` must not write `Config`. Move that write to the step that owns config initialization, keeping
   the order relative to the other steps. Note it in `doc/architecture.md`.
4. Keep the subscribe-before-tiling order that `doc/architecture.md` documents; re-read that section and preserve it.
5. Update `doc/architecture.md` with the step list.

**Acceptance:** `Daemon.run` reads as an ordered list of steps, and behavior is unchanged (the code review compares
the call order before and after; list both in the commit body).

**Live check:** restart the service (the user: `yabai --restart-service`). Startup log shows the steps; spaces, rules
and the payload work as before.

**Gate:** quick + release. **Commit:** `P4.7 Make the daemon startup an explicit sequence of steps`.
