# Refactor status

This is the single source of truth for progress. The protocol is in [overview.md](overview.md), sections "State and
handoff" and "Resume protocol".

Status values: `todo`, `in-progress`, `done`, `blocked`, `skipped`. Find a subphase's commit with
`git log --oneline --grep '^P<ID> '`.

## Run settings

- live_tests: deferred
- plan written at: f5a3bc4b (2026-10-22)

## Phase 1: Gates and tooling

phase: done · mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| P1.1 | `scripts/ci.sh`, `make ci-quick` and `make ci` | done | `scripts/ci.sh quick\|full` with per-step logs in `.build/ci/`. Tree has 0 compiler warnings, so the allowlist is empty. Gates: `make ci` passed (build 4s, test 6s, install 32s, osax-test 9s, check-build 97s). Broken-file check failed as expected and was reverted. No live checks. Fix (phase agent): the test step now prints every `Test run with` line (XCTest-hosted and Swift Testing runs), not only the last. |
| P1.2 | OSAXEmbed enumerates its inputs | done | Inputs are the 10 `osax/` native files plus the 2 scripts, enumerated from `osax/` (same set as the old list, no new files). Gates: `make ci` passed (build 5s, test 14s, install 32s, osax-test 7s, check-build 92s). Touching `Core.swift` rebuilds the payload; a no-op build keeps its mtime; a new file in `osax/` triggers a rebuild. Default `make` output shows only `[n / m] OSAX`; the "Build and embed" step name appears with `swift build -v`. No live checks. |
| P1.3 | Baseline measurements | done | Numbers in "Baseline (P1.3)" at the end of this file, measured at `e3047f40`. No source changes. Gates: `make ci` passed. No live checks. |
| P1.4 | Fix documentation drift and add the refactor plan to AGENTS.md | done | `doc/architecture.md` names the Swift symbols that replaced the C ones (`WindowManager.treeView(for:)`, `treeFocus(direction:for:)`, `setWindowLayout(_:_:)`, `treeSplit(_:for:)`, `Con.visibleWindowCount()`, `Con.raiseTabs(force:)`, `WindowManager.cardDidOrder(_:)`). `doc/testing-refactor.md` open ends: ISSUES.md 5 to 7 are fixed, no `withKnownIssue` remains. Stale "C" comments reworded in `YabaiCore` `ViewArea`, `Area`, `SpaceList`, `MessageParse`, `Message.swift:186` and `CPrivate.h:57`. `AGENTS.md` row added. Diff checked: only comments and docs changed. Gates: `make ci-quick` passed (0 warnings), `make install` passed (CPrivate header touched). No live checks. |

## Phase 2: Crash and robustness fixes

phase: done · mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| P2.1 | Public `AXUIElementGetPid` and checked CF casts | done | `AXUIElement.pid` is `pid_t?` through `AXUIElementGetPid`; its one caller (`EventHandler+Window.swift`, window created) unwraps it. The typed AX getters and the two array reads (`WindowManager+Discovery.swift`, `SkyLight+Windows.swift` corner radius) go through the new `castAttribute<T>(_:typeID:)` in `AX.swift`, which checks the CF type ID before the cast and logs a debug line on a mismatch. `pointAttribute`/`sizeAttribute` return nil where they returned `.zero` on a failed AXValue read; the callers use `?? .zero`, so they are unchanged. New `tests/YabaiTests/AXAttributeTests.swift` (CFNumber refused as a string, pid of the application element). Gates: `make ci-quick` passed, 240 tests in 29 suites (was 236), 0 warnings. No live checks. |
| P2.2 | Typed, length-checked SLS notification payloads | done | `SLSNotification` enum (`Sources/Yabai/Platform/SLSNotification.swift`, declaration order = old registration order) with `payload(_:_:as:)`, nil for a nil buffer or a short length. The handler switches on the enum, decodes each case with the same offsets and widths, and logs and drops a short payload; no `data!` left. `Daemon.run` registers `allCases`. Deviation: `WindowID(_:)` kept (not `init?(nonzero:)`), so decoded values are unchanged. Tests: `tests/YabaiTests/SLSNotificationTests.swift` (7). Gates: `make ci-quick` passed, 247 tests in 30 suites (was 240), 0 warnings. Live check added (P2.2, SLS space and window notifications). |
| P2.3 | CPrivate hardening: KVC guard, timer, Mach-O bounds, region ownership | done | `Notify.m` wraps the two private `setValue:forKey:` calls in `@try`. `OSTimer.now` is `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (same clock and ns units as the removed `ReadOSTimerC`, which only `OSTimer.now` used); `ReadOSTimerC` is deleted. `MachOSymbol.address` skips a symbol whose name offset is past the string table or has no NUL before its end. Region ownership: Swift imports the `CGSNewRegionWithRect` out-param as `UnsafeMutablePointer<CFTypeRef?>` (managed), so the local owns the +1 region; no code change, one NOTE added. Gates: `make ci-quick` passed (247 tests in 30 suites, 0 warnings), `make install` passed (0 warnings). Live checks added (P2.3, bridged window move; notification icon path). |
| P2.4 | Log private-symbol availability at startup | done | `Daemon.configureSettingsAndAcquireLock` keeps its two `skyLightSymbol` lookups (same order, each once) in locals, passes them to `CPrivateSetResolvedFunctions`, then `logSymbolAvailability` logs one `Logger.daemon.notice` line naming the unresolved symbols with their features, or one `debug` line. Deviation: the table covers the two symbols the startup path resolves. The `dlsym(objc_msgSend)` in `SkyLight.swift` (`bridgedMoveWindows`) is a public libobjc symbol looked up per call, not a private one, so it is not in the table. `doc/live-testing.md` has a "Startup diagnostics" section. Gates: `make ci-quick` passed (247 tests in 30 suites, 0 warnings), `make install` passed (0 warnings). Live check added (P2.4, startup log). |
| P2.5 | IPC hardening: length cap, malformed-message reply, client timeout | done | `MessageLoop.readMessage` throws `MessageReadError` (`invalidLength` above `maxMessageLength` = 1 MiB, before any body byte is read; `incomplete` for a short or closed message). Every rejected message gets `invalid message` (`MessageLoop.rejection()`, written through the responses queue) and a `Logger.ipc` warning. `Client.send` sets `SO_RCVTIMEO` from `YABAI_CLIENT_TIMEOUT` (`Client.responseTimeout`, default 30 s, invalid values ignored) and fails with `yabai-msg: timed out waiting for a response..` on expiry. Tests: `tests/YabaiTests/MessageLoopTests.swift` (socket pairs, no deadline). Documented in `doc/yabai.asciidoc` (`make man`) and CHANGELOG. Deviation: no README "Fork changes" entry (a hardening fix; P2.1 to P2.4 added none). Gates: `make ci-quick` passed (256 tests in 30 suites, 0 warnings), Golden unchanged, `--sanitize=thread` and `--sanitize=address` passed with 0 reports. Live check added (P2.5, IPC limits on the running daemon). |
| P2.6 | No traps in JSON encoding and signal parsing | done | `JSON.encode` and `Response.write(json:)` are `throws(CommandError)` and throw `could not encode query json`; the `Query.swift` encode helper is typed too (`encode(to:)` stays untyped, as Encodable requires). `SignalCommand` throws `missing required key-value pair 'event=..'` instead of trapping; the golden case `signal --add label=x` already covers that text, so no new test. Callers: the query and rule handlers already throw `CommandError`; `debugWindowInfo` logs `try?`. Deviation: the encode failure is unreachable in practice (non-finite floats are strings), so no test. Gates: `make ci-quick` passed (256 tests in 30 suites, 0 warnings), `swift test --filter Golden` passed without re-recording, acceptance grep empty. No live checks. |

## Phase 3: Scripting addition hardening

phase: done · mode: nested · osax_bumped: 2.1.37

| ID | Title | Status | Notes |
|---|---|---|---|
| P3.1 | Fade timer runs only while fades are active | done | `OSAX_VERSION` bumped to 2.1.37 (`osax_bumped`; docs and `scripts/osax/runtime.py` expected version updated). `sa_swift_tick` returns Bool (true while fades remain) and `sa_swift_has_fades` is new (`Core.swift`, `OSAXCore.h`, `sa_core_has_fades` macro). `payload.m`: the timer is created suspended; `ensure_fade_timer` resumes it after an accepted fade with duration > 0 (opcode 8 only); the handler suspends it when the core reports no fades. Deviation: `fade_queue` is kept in a static (it was released after creating the source) so `ensure_fade_timer` can dispatch to it. Tests: `fadeTimerStateFollowsActiveFades` in `osax/testing/tests/PayloadTests.swift`; `doc/payload-updates.md` "Fade timer". Gates: `make ci-quick` passed (256 + 83 tests, 0 warnings), `make osax-test` passed (10 tests), `swift test --package-path osax` under `--sanitize=thread` and `--sanitize=address` passed with 0 reports, `make osax-payload` 0 warnings. Live check added (P3.1, fades and idle Dock). |
| P3.2 | Gate the Dock animation patch on known Dock UUIDs | done | `payload.m`: `read_image_uuid` reads `LC_UUID` from the load commands (ncmds and cmdsize checked against sizeofcmds, magic checked) and `known_dock_uuids` lists `3BDF6A3B-866B-3C07-920C-E9E7FB57B56B`; the animation write runs only for a known build, otherwise it logs `unknown Dock build <uuid>; animation patch skipped` and the lookup stays pattern-gated. `ScriptingAddition.attributeVerdict` (new, internal): every bit but `OSAX_ATTRIB_ANIM_TIME` is required; a missing animation bit gives the warning "space animation patch unavailable for this Dock build" and exit 0. Tests: three `scriptingAdditionAttributeVerdict*` tests in `tests/YabaiTests/SAConnectionTests.swift` (no ScriptingAddition test file existed). `OSAX_VERSION` not bumped again (2.1.37 from P3.1). `doc/payload-updates.md` "Adding a Dock build". Checked the reader outside Dock with a scratch harness on the thin arm64e Dock slice (ASan/UBSan): the UUID matches, and a small sizeofcmds, huge ncmds and bad magic return without reading past the header. Gates: `make ci-quick` passed (259 + 83 tests, 0 warnings), `make osax-test` passed (10 tests), `make osax-payload` 0 warnings (`-Wall -Wextra -Werror`). Live check added (P3.2, Dock patch still applied). |
| P3.3 | Guarded reads in the payload core | done | `osax/core/swift/Core.swift`: every force unwrap removed (`swiftValidate` opcode and flag reads, the 7/8 and 13 float reads, `swiftTick` fade lookup, `transfer` base address); the flag bytes of opcodes 5, 10 and 11 are read through `Cursor` instead of raw subscripts. `import Foundation` removed: the core builds without it. Remaining `!` in the file are logical not only. Deviation: step 5 was done as a table test, `fixedLengthOpcodesRejectEveryTruncation` in `osax/testing/tests/PayloadTests.swift` (15 cases: every fixed-size opcode, lengths 0 to expected-1 rejected, one extra byte rejected); the existing truncation and bounded fuzz tests are unchanged. `OSAX_VERSION` not bumped (2.1.37 from P3.1). RawSpan step skipped: optional, no scratch build attempted. Gates: `make ci-quick` passed (259 + 83 tests, 0 warnings), `make osax-test` passed (11 tests), `swift test --package-path osax` under `--sanitize=thread` and `--sanitize=address` passed with 0 reports, `make osax-payload` 0 warnings. No live check (the plan lists none for P3.3). |
| P3.4 | Daemon checks the payload socket's owner | done | `SAConnection.connect(_:)` first runs `isTrustedSocketPath` (`lstat`, `S_IFSOCK`, owner): the user's uid, or as root the `SUDO_UID` user (no `SUDO_UID`: any non-root owner). Pure helper `SAConnection.isTrustedSocket(mode:owner:uid:sudoUID:)`; `parseSUDOUID` rejects empty, non-decimal, out-of-range and 0 values, and `resolveSudoSocketPath` uses it. A mismatch logs a warning through `Logger.daemon` (no SA logger exists; its doc covers the SA) and returns false. Tests: 13-row truth table and 10-row parser table in `tests/YabaiTests/SAConnectionTests.swift`; existing socketpair tests unaffected (no path connect). No payload change, no `OSAX_VERSION` bump. Gates: `make ci-quick` passed (261 + 83 tests, 0 warnings), Golden unchanged, TSan and ASan passed with 0 reports. Live check added (P3.4, space create/focus and `--load-sa`). |

## Phase 4: Core lifecycle and event loop

phase: in-progress · mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| P4.1 | One window teardown path | done | `EventHandler.teardown(_:untile:)` (`EventHandler.swift`) holds the shared tail once: mouse state, the `.windowDestroyed` signal, scratchpad, window table, AX notifications, `destroy()`. `windowDestroyed` calls it with `.immediate` (untile with focus hand-over, as before); `removeTerminatedWindows` calls it with `.batched` and flushes the views it returns. Deviation: `.batched` returns the view instead of taking `inout [View]`, since Swift does not allow inout in enum payloads. Tests: `WindowTeardownTests` in `tests/YabaiTests/EventHandlerTests.swift` (3 rows of both paths compared, a layout pin, an ineligible row), written first and passing before and after the refactor. Test seams: `EventSignals.pending` is `private(set)` with `discardPending()` (reset by `DaemonFixture`), and `updateWindowNotifications` is a no-op in headless mode (`doc/live-testing.md`). Not observable headless: the focus hand-over (`focusWindow` needs a visible space), so the tests pin the untile, not the focus. Gates: `make ci-quick` passed (264 + 83 tests, 0 warnings). No live check (the plan lists none). |
| P4.2 | One untile/unmanage path | done | `WindowManager.unmanage(_:from:options:)` (`WindowManager+Management.swift`, `UnmanageOptions` `.flush`/`.purify`). Six sites use it: M1 `unmanageWindow` (`[.flush, .purify]`), L1 `warpWindow` (`.flush`), E1 `teardown(.immediate)` (`.flush`), D1 `applicationHidden` (`.purify`), R1 `validateWindows` and R2 `checkForWindows` (`.purify`, :AXBatching comments and dirty flags kept). Not applicable (no untile step): T1 `treeSetView`, X1 `Discovery`, M2 `addManagedWindow`, `TreeView.unmanageWindows`, `Appearance`. `SpaceManager.untile` is deleted (no callers). `teardown(.batched)` keeps `untileWindowBatched`, with a NOTE that it does no adjustLayer. Deviations: (a) R1/R2 call adjustLayer before `View.remove` (remove only changes the tree and recomputes frames, adjustLayer only sends the layer message, so neither reads the other); (b) the float guard is vacuous in R1 (a float view has no tree, so `windowIDs` is empty), in R2 (already under `layout != .float`) and in D1 (a float view has no managed windows). Tests: `UnmanageTests` (`tests/YabaiTests/UnmanageTests.swift`): reconciliation through `validateWindows` (now internal) and the float toggle through `makeWindowFloating`, with the shadow per PurifyMode; written first, passing before and after. Not headless-testable: R2 (`shouldBeManaged` reads SkyLight via `id.isSticky`) and D1 (ends in `Border.refreshSpace`). Gates: `make ci-quick` passed (267 + 83 tests, 0 warnings), Golden unchanged. No live check (the plan lists none). |
| P4.3 | `forget(_:)` for per-window tables | done | `WindowManager.forget(_:)` (`WindowManager+Registry.swift`) clears the state keyed by a removed id: `Border` (`Border.remove`, as before), `windowLostFocusedEvents`, `managedWindows`, and `MouseState` `window`, `ffmWindowID` and `feedbackWindowID` (with its direction). `removeWindow` calls it, then drops the window. Left alone, each with a comment: `windowAnimations` (its display link owns the entry and proxy), `tabBarHits` (rebuilt per bar update), `tabBarPointer` (change cache), the focus scalars `focusedWindowID`, `lastWindowID`, `pendingFocusWindowID` (P4.6), `Application.focusedWindowID`, and `Border.show`/`hide` (batch lists). Deviations: step 4 (atomics namespace) skipped, because `doc/swift-conventions.md` (Atomics) keeps Swift-owned flags as global `let` Atomics. The lost-focus entry of a removed id is now dropped; only a later window with the same id would notice. Tests: `WindowForgetTests` (`tests/YabaiTests/EventHandlerTests.swift`), red before the change. Seams: `Border.isTracked`, `Border.trackForTest`. Gates: `make ci-quick` passed (268 + 83 tests, 0 warnings), Golden unchanged; `swift test --sanitize=thread` and `--sanitize=address` passed, 0 sanitizer reports. No live check (the plan lists none). |
| P4.4 | AX window callbacks carry a `WindowID` | done | `WindowID` is the AX context of each window's notifications (`Window.notificationContext`, read back with `WindowID(notificationContext:)`); the minimized, deminimized and destroyed callbacks post `.windowMinimized(windowID:)`, `.windowDeminimized(windowID:)` and `.windowDestroyed(windowID:)` and never touch a window. The `@WM` handlers look the window up (`EventHandler+Window.swift`): destroyed invalidates it and calls the `Window` body once (`windowDestroyed(windowID:)`, also used by the SkyLight destroyed handler); a missing window returns (a deminimized one also drops its lost focus event, as an invalid one did). The application notifications keep the Application context, which they never read. `Unmanaged<Window>` is gone from `Sources/Yabai`. The early signal is restored (fix commit `P4.4 Fix ignoring the queued events of a window destroyed on the main thread`): the AX destroyed callback marks the window id in `axDestroyedWindowIDs` (`markAXDestroyed`, a `Mutex<Set<WindowID>>`) and posts `.windowDestroyed` only for a new mark, and `Window.isValid` is false for a marked id, so the events queued for the window before its destroyed event are ignored at once, as before the P4.4 commit. The callback touches no window. The `@WM` handler still invalidates `valid` and tears the window down once; `forget` and the not-found branch of `windowDestroyed(windowID:)` drop the mark. Tests (`EventHandlerTests.swift`): the terminate race and double destroy pinned first on the `Window` API (passing before the change), then through `handle(_:)` with ids, plus an unknown id and the context round trip. Gates: `make ci-quick` passed (272 + 83 tests, 0 warnings); TSan and ASan passed, 0 sanitizer reports. Live check added to `live-checks.md`. |
| P4.5 | Single timer and keyed delayed events in `EventLoop` | done | `DelayedQueue` (`Sources/Yabai/DelayedQueue.swift`, pure and generic, deadline order, FIFO for equal deadlines, keyed insert supersedes) holds the delayed events. `EventLoop` arms one `DispatchSourceTimer` on a private serial queue for the earliest deadline, under the Mutex of the queue, and re-arms after each delivery. `post(_:after:key:)` takes a `DelayedEventKey` (`.spaceLayoutReconcile`, `.missionControlCheck`); `spaceLayoutGeneration` and the generation payload are gone, and the Mission Control check is keyed, so repeated enters keep one check chain. Deviations: (a) the timer runs on the uptime clock (DispatchTime), so a delay pending during a system sleep ends later than with `Task.sleep(until:clock: .continuous)`; (b) a reconcile already delivered to the event stream is handled even when a later schedule supersedes it (the generation check used to drop it), so in that race one extra pass runs early. (c) The acceptance grep `Task {` now matches only a comment; the one Task left is the consumer, `Task(priority: .medium) { @WM in`. Tests: `DelayedQueueTests` (10 tests, `tests/YabaiTests/DelayedQueueTests.swift`), written first and passing against the extracted ordering before EventLoop changed. Gates: `make ci-quick` passed (284 + 83 tests, 0 warnings); TSan and ASan passed, 0 sanitizer reports. Live check added (P4.5). The timer and keyed replacement in EventLoop have no unit test: the live check covers them. |
| P4.6 | `FocusState` | todo | |
| P4.7 | Explicit startup sequence | todo | |

## Phase 5: Platform responsiveness

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P5.1 | Hung-app AX breaker | todo | |
| P5.2 | Mission Control exit without the 100 ms window-list poll | todo | |
| P5.3 | Cache the space list and display arrangement | todo | |
| P5.4 | Batch space lookups while waiting for windows | todo | |
| P5.5 | No synchronous ordered-in query on the border order path | todo | |
| P5.6 | Replace deprecated CG event calls | todo | |
| P5.7 | Typed message send for the bridged move operation (optional) | todo | |

## Phase 6: YabaiCore simplification

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P6.1 | Generic token lookup and dead-code sweep | todo | |
| P6.2 | Shared key-value scanner for rules and signals | todo | |
| P6.3 | Swift number and pattern parsing, verified against libc | todo | |
| P6.4 | Layout math in YabaiCore | todo | |

## Phase 7: Daemon model cleanup

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P7.1 | No force unwraps in tree mutation | todo | |
| P7.2 | No raw-pointer or sentinel state | todo | |
| P7.3 | Split the `Window` model | todo | |
| P7.4 | Typed service errors and tested builders | todo | |
| P7.5 | One tab bar code path per operation | todo | |

## Phase 8: Swift strictness and diagnostics

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P8.1 | `MemberImportVisibility` and `ExistentialAny` | todo | |
| P8.2 | Strict memory safety in YabaiCore | todo | |
| P8.3 | Measured trials: strict memory safety in Yabai, nonisolated(nonsending) by default | todo | |
| P8.4 | OSSignposter intervals | todo | |
| P8.5 | Optional lint target | todo | |

## Phase 9: Configuration management

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P9.1 | Failure messages name the valid values | todo | |
| P9.2 | Warn when several config files exist | todo | |
| P9.3 | Dry-run parsing for config, rule and signal commands | todo | |
| P9.4 | yabairc command extractor | todo | |
| P9.5 | `yabai -m config --check [file]` | todo | |
| P9.6 | `yabai -m config --reload [file]` | todo | |

## Phase 10: IPC features

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P10.1 | Batch message encoding | todo | |
| P10.2 | `yabai -m batch` | todo | |
| P10.3 | Subscriber registry and event encoding | todo | |
| P10.4 | `yabai -m subscribe` | todo | |

## Phase 11: Rendering and UX

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P11.1 | Respect Reduce Motion for window animations | todo | |
| P11.2 | One AX frame-setting path | todo | |
| P11.3 | Skip identical tab bar and selection renders | todo | |
| P11.4 | Move border edges in one update | todo | |
| P11.5 | Animation: alpha once per proxy, display link on the right screen | todo | |
| P11.6 | Cheaper tab bar hover | todo | |
| P11.7 | Focus-follows-mouse fixes | todo | |

## Phase 12: Tree and window features

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P12.1 | Rule effect `insert=` | todo | |
| P12.2 | Window labels and `LABEL` in `WINDOW_SEL` | todo | |
| P12.3 | Restore the floating frame (verify first) | todo | |
| P12.4 | Tree snapshots and `space --undo` | todo | |
| P12.5 | skhd binding-mode recipes | todo | |
| P12.6 | Pin labelled spaces to displays | todo | |

## Phase 13: Mouse and layout features

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P13.1 | Split-gap hit testing | todo | |
| P13.2 | Drag the gap between splits to resize | todo | |
| P13.3 | Drop ghost preview while dragging | todo | |
| P13.4 | `space --save-layout` | todo | |
| P13.5 | `space --restore-layout` | todo | |

## Handoff log

Append only. Format: `YYYY-MM-DD HH:MM · role · ID · event · next step`.

- 2026-10-22 · planner · — · plan written · orchestrator starts phase 1
- 2026-10-22 13:23 · phase agent · P1 · start (nested) · start P1.1 subphase agent
- 2026-10-22 13:23 · subphase agent · P1.1 · start · add scripts/ci.sh, makefile targets, docs; run gates
- 2026-10-22 13:40 · subphase agent · P1.1 · done · P1.2 (OSAXEmbed inputs) is next; it depends on P1.1 and can start now
- 2026-10-22 13:30 · subphase agent · P1.2 · start · enumerate osax/ in OSAXEmbed; verify rebuild and no-op; run gates
- 2026-10-22 13:45 · subphase agent · P1.2 · done · P1.3 (baseline measurements) is next; it depends on P1.1 and can start now
- 2026-10-22 13:38 · subphase agent · P1.3 · start · measure baseline (make ci, sanitizers, coverage, binary size, grep counts); no source changes
- 2026-10-22 13:44 · subphase agent · P1.3 · done · P1.4 (documentation drift) is next; it has no dependencies and can start now
- 2026-10-22 13:50 · subphase agent · P1.4 · start · fix doc drift (architecture.md, testing-refactor.md, C comments), AGENTS.md row; gates
- 2026-10-22 13:50 · subphase agent · P1.4 · done · make ci-quick and make install passed; the phase agent runs the phase close (make ci) for P1
- 2026-10-22 13:29 · phase agent · P1 · resume (nested) · P1.1 done at e197af95; start P1.2
- 2026-10-22 13:55 · phase agent · P1 · close · Phase 1 done. `make ci`/`make ci-quick` (scripts/ci.sh, logs in .build/ci/) are the gates; OSAXEmbed enumerates osax/ (same 10 files as before); baseline in "Baseline (P1.3)"; doc drift fixed and AGENTS.md links the plan. Deviation: P1.2's "Build and embed" step name only shows with `swift build -v`. Phase agent fixed ci.sh to print both test-run summaries. Next phase: run `make ci-quick` per subphase and `make ci` at close; remaining C-style doc comments are listed under Discovered. No live checks added in phase 1. · orchestrator starts phase 2
- 2026-10-22 13:57 · phase agent · P2 · start (nested) · start P2.1 subphase agent
- 2026-10-22 14:05 · subphase agent · P2.1 · start · AX pid through AXUIElementGetPid (pid_t?), type-checked attribute casts, two unsafeBitCast array reads replaced; gates
- 2026-10-22 14:12 · subphase agent · P2.1 · done · `make ci-quick` passed (240 tests, 0 warnings); no live checks in P2.1. P2.2 (SLS notification payloads) is next.
- 2026-10-22 14:02 · subphase agent · P2.2 · start · SLSNotification enum and length-checked payload helper; registration iterates the enum; handler and tests; gates
- 2026-10-22 14:20 · subphase agent · P2.2 · done · `make ci-quick` passed (247 tests, 0 warnings). One live check added (P2.2, SLS notifications). P2.3 (CPrivate hardening) is next.
- 2026-10-22 14:05 · subphase agent · P2.3 · start · KVC guard in Notify.m, OSTimer on CLOCK_UPTIME_RAW (drop ReadOSTimerC), Mach-O string bounds, region ownership check; gates quick + release
- 2026-10-22 14:08 · subphase agent · P2.3 · done · `make ci-quick` (247 tests, 0 warnings) and `make install` passed. Two live checks added (P2.3). P2.4 (symbol availability log) is next; it depends on P2.3 and can start now.
- 2026-10-22 14:11 · subphase agent · P2.4 · start · log unresolved private symbols once after Daemon.configureSettingsAndAcquireLock resolves them (logging only); docs; gates quick + release
- 2026-10-22 14:25 · subphase agent · P2.4 · done · `make ci-quick` (247 tests, 0 warnings) and `make install` (0 warnings) passed. One live check added (P2.4). P2.5 (IPC hardening) is next; it has no dependency on P2.4 and can start now.
- 2026-10-22 14:16 · subphase agent · P2.5 · start · length cap (1 MiB) and malformed-message reply in MessageLoop.readMessage; client receive timeout (YABAI_CLIENT_TIMEOUT, 30 s) in Client.send; socketpair tests; asciidoc and CHANGELOG; gates quick + sanitizers
- 2026-10-22 14:20 · subphase agent · P2.5 · done · `make ci-quick` (256 tests, 0 warnings), Golden unchanged, TSan and ASan clean. One live check added (P2.5). The live check needs a deployed daemon: the client timeout expiry is only unit-tested for the value parsing. P2.6 (traps in JSON and signal parsing) is next; it has no dependency on P2.5 and can start now.
- 2026-10-22 14:22 · subphase agent · P2.6 · start · JSON.encode and Response.write(json:) throw CommandError; SignalCommand throws instead of trapping; the Query.swift encode helper typed; gates quick
- 2026-10-22 14:24 · subphase agent · P2.6 · done · `make ci-quick` (256 tests, 0 warnings), Golden unchanged, acceptance grep empty. No live checks. Phase 2 has no subphase left: the phase agent runs the phase close (`make ci`).
- 2026-10-22 14:27 · phase agent · P2 · close · Phase 2 done; each subphase reviewed and its gate re-run by the phase agent, no fix commits needed; `make ci` passed (256 + 83 tests, osax-test 9, install and check-build PASS). Changes: AX pid through `AXUIElementGetPid` (`pid_t?`) and `castAttribute` checks CF type ids; `SLSNotification` enum with length-checked `payload`; `@try` around private KVC in Notify.m, `OSTimer.now` on `CLOCK_UPTIME_RAW` (`ReadOSTimerC` removed), Mach-O string-table bounds; one startup notice for unresolved private symbols; IPC 1 MiB cap, `invalid message` reply, client `SO_RCVTIMEO` (`YABAI_CLIENT_TIMEOUT`, 30 s); `JSON.encode`/`Response.write(json:)` are `throws(CommandError)` and YabaiCore has no traps. Deviations: raw SLS ids still enter through `WindowID(_:)` (Discovered); no README entry for `YABAI_CLIENT_TIMEOUT` (hardening, CHANGELOG + man page only). For the next phase: `Response.write(json:)` now needs `try`; 5 phase-2 live checks are pending in live-checks.md; `bin/yabai` holds an unsigned release build. · orchestrator starts phase 3
- 2026-10-22 14:30 · phase agent · P3 · start (nested) · start P3.1 subphase agent
- 2026-10-22 14:34 · subphase agent · P3.1 · start · fade timer armed only while fades run (Core tick returns Bool, has_fades export, ensure_fade_timer in payload.m); OSAX_VERSION 2.1.37; gates quick + payload + sanitizers
- 2026-10-22 14:40 · subphase agent · P3.1 · done · `make ci-quick` (256 + 83 tests, 0 warnings), `make osax-test` (10 tests), TSan and ASan clean, `make osax-payload` 0 warnings. One live check added (P3.1). P3.2 (Dock UUID gate) is next; it has no dependency and can start now.
- 2026-10-22 14:36 · subphase agent · P3.2 · start · read Dock LC_UUID in payload.m init_instances and gate the animation write on known UUIDs; daemon warning for a missing ANIM_TIME bit (ScriptingAddition.swift) with a unit test; payload-updates.md; gates quick + payload
- 2026-10-22 14:39 · subphase agent · P3.2 · done · `make ci-quick` (259 + 83 tests, 0 warnings), `make osax-test` (10 tests), `make osax-payload` 0 warnings. One live check added (P3.2). P3.3 (guarded reads in the payload core) is next; it has no dependency and can start now.
- 2026-10-22 14:41 · subphase agent · P3.3 · start · replace force unwraps in osax/core/swift/Core.swift with guarded reads; try dropping import Foundation; add an explicit per-opcode truncation test; run osax gates
- 2026-10-22 15:05 · subphase agent · P3.3 · done · force unwraps gone from Core.swift, Foundation import dropped, table test for fixed-length truncations added. Gates passed (ci-quick, osax-test, TSan, ASan, osax-payload 0 warnings). RawSpan skipped (optional). P3.4 (payload socket owner check) is next; it has no dependencies and can start now.
- 2026-10-22 14:46 · subphase agent · P3.4 · start · lstat-based owner check before SAConnection.connect (pure isTrustedSocket helper, SUDO_UID parser); truth-table tests; gates quick + Golden + sanitizers
- 2026-10-22 14:48 · subphase agent · P3.4 · done · `make ci-quick` (261 + 83 tests, 0 warnings), Golden unchanged, TSan and ASan 0 reports. One live check added (P3.4). Phase 3 has no subphase left: the phase agent runs the phase close (`make ci`).
- 2026-10-22 15:00 · phase agent · P3 · close · Phase 3 done; each subphase reviewed and its gate re-run by the phase agent, no fix commits needed; `make ci` passed (261 + 83 tests, osax-test 11, install and check-build PASS), Golden unchanged, `swift test` and `swift test --package-path osax` under `--sanitize=thread` and `--sanitize=address` clean. Changes: `OSAX_VERSION` 2.1.37; the payload fade timer starts suspended and runs only while fades remain (`sa_swift_tick` returns Bool, `sa_swift_has_fades`); the Dock animation code write is gated on `known_dock_uuids` (LC_UUID, bounds-checked), and the daemon treats a missing `OSAX_ATTRIB_ANIM_TIME` as a warning (`ScriptingAddition.attributeVerdict`); the Swift payload core has no force unwraps and no Foundation import; `SAConnection.connect` lstat()s the payload socket and requires a socket owned by the user (`isTrustedSocket`, `parseSUDOUID`). Deviations: optional RawSpan rewrite skipped; SA warnings log through `Logger.daemon` (no `Logger.sa`); SUDO_UID=0 counts as unset. For the next phase: 4 phase-3 live checks plus the combined phase check are pending in live-checks.md and need a payload reload (sudo, user); `sscanfUIntC` is unused (Discovered); `bin/yabai` holds an unsigned release build. · orchestrator starts phase 4
- 2026-10-22 14:56 · phase agent · P4 · start (nested) · start P4.1 subphase agent
- 2026-10-22 15:00 · subphase agent · P4.1 · start · DaemonState tests for windowDestroyed and removeTerminatedWindows first (against the unchanged code); then one `teardown` helper for the shared tail; gate quick
- 2026-10-22 15:01 · subphase agent · P4.1 · done · `make ci-quick` (264 + 83 tests, 0 warnings). Tests written first and run against the unchanged code, then again after the refactor. No live check. P4.2 (unmanage path) is next; it depends on P4.1 and can start now.
- 2026-10-22 15:04 · subphase agent · P4.2 · start · site survey of the untile/removeManaged/purify sequence before writing any tests; gate quick
- 2026-10-22 15:10 · subphase agent · P4.2 · blocked · acceptance (5 of 7 sites via `unmanage`, exact order) not reachable: only M1, L1 and E1 match one untile-shaped helper; R1/R2 and D1 differ in call order, flush and float guard; T1 and M2 have no untile step (see the P4.2 row). No code changed. Decision needed: either accept a second helper shape for R1/R2 and D1 (a call-order change the phase rule forbids), or amend the acceptance to the sites that match. P4.3 depends only on P4.1 and can start now.
- 2026-10-22 15:08 · subphase agent · P4.2 · start (retry with the phase's design: `unmanage(_:from:options:)` with flush and purify options; R1/R2 and D1 use the documented deviations) · tests first against unchanged code (reconciliation via `validateWindows`, float toggle via `makeWindowFloating`); gate quick + Golden
- 2026-10-22 15:11 · subphase agent · P4.2 · done · `make ci-quick` (267 + 83 tests, 0 warnings), Golden unchanged, UnmanageTests passing before and after the refactor. Six sites on `unmanage`; `SpaceManager.untile` deleted. Deviations (a) order of remove and adjustLayer in R1/R2 and (b) vacuous float guards are in the P4.2 row. No live check. Next: P4.3 (`forget(_:)`, depends on P4.1, done) and P4.4 (depends on P4.1, done); P4.5 and P4.6 have no dependencies.
- 2026-10-22 16:00 · subphase agent · P4.3 · start · survey of WindowID-keyed state done; tests first (forget clears Border, lost-focus, managed mapping, MouseState feedback and ids), then `forget` in WindowManager+Registry; step 4 (atomics namespace) skipped: conflicts with swift-conventions "Atomics"; gate quick + TSan + ASan
- 2026-10-22 16:30 · subphase agent · P4.3 · done · `make ci-quick` (268 + 83 tests, 0 warnings), TSan and ASan clean (0 reports). `WindowForgetTests` written first (red), then `forget`. Deviations: step 4 skipped (swift-conventions Atomics); focus scalars and `windowAnimations` left with comments. No live check. Next: P4.4 (AX callbacks carry a `WindowID`, depends on P4.1, done).
- 2026-10-22 15:22 · subphase agent · P4.4 · start · pinned the terminate race and double-destroy behavior first (tests on the Window API); then window ids as AX contexts, id-carrying events, `@WM` invalidation in the handler; gate quick + TSan + ASan
- 2026-10-22 15:40 · subphase agent · P4.4 · done · `make ci-quick` (272 + 83 tests, 0 warnings), TSan and ASan clean (0 reports). Concern for review: invalidation moved to `@WM`, so an event queued before the destroyed event of the same window (focus, move) now sees it valid; before, the AX callback invalidated on the main thread. Next: P4.5 (single timer and keyed delayed events; no dependency on P4.4).
- 2026-10-22 15:30 · subphase agent · P4.4 · fix · restored the early invalidation: the AX destroyed callback marks the id (`markAXDestroyed`, `axDestroyedWindowIDs`) and posts once, `Window.isValid` reads the mark, `forget` and the not-found branch drop it; `invalidate()` and the `@WM` handler are unchanged. Tests: mark ignores queued moved and minimized events, destroyed tears down once and drops the mark; a second mark returns false. `make ci-quick` (274 + 83 tests, 0 warnings), TSan and ASan clean (0 reports). No live check added (the P4.4 live check still applies). Next: P4.5 (single timer and keyed delayed events; no dependency on P4.4).


## Discovered

Out-of-scope findings, as `- P<ID>: <finding> (<file:line>)`.

- P3.1: `doc/payload-updates.md` "Hardened core prototypes" still says normal builds select the Objective-C core (2.1.35), which the removed-prototype notes in `doc/osax-prototypes.md` contradict. Left as is; only the version number changed there.
- P2.2: `WindowID(_:)` for the raw window server ids in `connectionNotificationHandler` contradicts the convention that raw ids enter through `init?(nonzero:)`. Kept as is so decoded values do not change; a 0 id would now reach `Border`/`EventLoop` as before.
- P1.4: C-style names remain in doc comments outside the four files P1.4 named: `YabaiCore/Query.swift`, `Client.swift`, `Message.swift` (e.g. `:56`, `:238`), `EventSignal.swift`, `SpaceLayout.swift`, `SpaceWindow.swift`, `Rule.swift` (e.g. `Rule.swift:360`, `:373`, `:505`, `:518`). Plus "Ported from src/..." provenance lines (`Rule.swift:6`, `SpaceWindow.swift:7`, `Sources/Yabai/IPC/Client.swift:8`, `Sources/YabaiCore/Client.swift:4`).
- P3.4: `sscanfUIntC` in `Sources/CPrivate/include/CPrivate.h:148` has no caller after the SUDO_UID parser moved to `SAConnection.parseSUDOUID`; remove it in a CPrivate change (needs `make install`). Left as is.


## Baseline (P1.3)

Measured on the tree at `e3047f40` (P1.2 done), before any Phase 1 source change. The commit that records these numbers
is the P1.3 commit itself. Full logs are in `.build/ci/` (`p1.3-*.log` for the commands run by hand).

- `make ci` (`scripts/ci.sh full`, all steps PASS, about 2 min 28 s wall; log `.build/ci/p1.3-make-ci.log`): build 8 s,
  test 14 s, install 32 s, osax-test 2 s, check-build 92 s.
- Tests from `make ci` (`grep 'Test run with' .build/ci/test.log`): 236 tests in 28 suites passed in 1.195 s, then
  83 tests in 2 suites passed in 0.556 s. osax-test (`.build/ci/osax-test.log`): 9 tests in 1 suite passed in 1.450 s.
- `xcrun swift test --sanitize=thread` (`.build/ci/p1.3-tsan.log`): pass, 44 s wall. 236 tests passed in 5.501 s and
  83 tests in 1.746 s. 0 ThreadSanitizer reports.
- `xcrun swift test --sanitize=address` (`.build/ci/p1.3-asan.log`): pass, 32 s wall. 236 tests passed in 3.353 s and
  83 tests in 5.033 s. 0 AddressSanitizer reports.
- `make coverage` (`.build/ci/p1.3-coverage.log`, 44 s): TOTAL 15535 lines, 8926 missed, 42.54% line coverage. 17 of the
  94 `Sources/` files are at 0.00%. The 10 with the most missed lines (all 0.00%): `Yabai/SpaceManager+Operations.swift`
  (352 missed), `Yabai/Workspace.swift` (240), `Yabai/Yabai.swift` (229), `Yabai/Service.swift` (227),
  `Yabai/ProcessManager.swift` (177), `Yabai/EventHandler+Space.swift` (150),
  `Yabai/WindowManager+Reconciliation.swift` (149), `Yabai/Platform/SkyLight+Windows.swift` (109),
  `Yabai/MissionControl.swift` (106), `Yabai/Platform/MachO.swift` (94). The other 7 at 0.00% are `IPC/Client.swift`
  (67), `CPrivate/include/CPrivate.h` (61), `Yabai/Log.swift` (49), `CPrivate/CPrivate.c` (30), `CPrivate/Notify.m`
  (20), `Yabai/main.swift` (19) and `Yabai/Platform/CoreDock.swift` (12).
- Release binary (`stat -f %z bin/yabai`, after `make install` in `make ci`): 8889912 bytes.
- Counts over `grep -rn ... --include=*.swift Sources`:
  - `grep -rn '!' --include=*.swift Sources | grep -v '!=' | wc -l` (rough force-unwrap count): 443
  - `grep -rn 'unsafeBitCast' --include=*.swift Sources | wc -l`: 7
  - `grep -rn 'Unmanaged' --include=*.swift Sources | wc -l`: 33
  - `grep -rnE 'preconditionFailure|fatalError|fatal\(' --include=*.swift Sources | wc -l`: 25
- 2026-10-22 16:45 · subphase agent · P4.5 · start · `DelayedQueue` (pure, `Sources/Yabai/DelayedQueue.swift`) with its tests first against the current ordering; then one `DispatchSourceTimer` on a private serial queue in `EventLoop` with keyed replacement (`DelayedEventKey`), `spaceLayoutGeneration` removed, Mission Control check keyed; docs and live check; gates quick + TSan + ASan
- 2026-10-22 15:39 · subphase agent · P4.5 · done · `make ci-quick` (284 + 83 tests, 0 warnings), TSan and ASan clean (0 reports). DelayedQueue tests first, then the timer and keyed events; spaceLayoutGeneration removed; Mission Control check keyed. One live check added (P4.5). Deviations and the in-flight reconcile race are in the P4.5 row for review. Next: P4.6 (FocusState; no dependencies, can start now).
