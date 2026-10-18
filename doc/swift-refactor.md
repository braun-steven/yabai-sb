# Idiomatic Swift refactor — phased plan

The daemon is Swift, but it is still written like the C it came from: free `snake_case` functions that thread manager
pointers (`window_manager_foo(sm, wm, …)`), `nonisolated(unsafe)` global managers, pseudo-enums made of
`RawRepresentable` structs and global constants, `Int32` everywhere, malloc'ed C strings and a C-shaped `rule`
struct next to YabaiCore's Swift `Rule`. This plan turns it into idiomatic Swift without changing what yabai does.

## How to use this file (every agent)

1. Read `AGENTS.md`, this file's **Rules**, **Target conventions** and the latest **Reports**. Read
   `doc/live-testing.md` before anything live.
2. Take the first phase in the **Status board** that is not `[x]`. If it is `[~]`, continue from its last report.
   Do only that phase (or sub-phase).
3. Before you stop, even mid-phase: update the Status board row, append a report (template below), and commit this
   file with the code. A new agent with no other context must be able to continue.

## Status board

Legend: `[ ]` not started · `[~]` in progress · `[x]` done.

| Phase | Title | Status | Last commit | Note |
|---|---|---|---|---|
| 1 | Cleanup, one type per concept, Swift strings | [ ] | | |
| 2 | Swift types: enums, OptionSets, typed IDs, containers | [ ] | | |
| 3a | Methods: tree and views | [ ] | | |
| 3b | Methods: windows, applications, rules | [ ] | | |
| 3c | Methods: spaces, displays, processes | [ ] | | |
| 3d | Methods: events, signals, rendering, input, SA, startup | [ ] | | |
| 3e | Platform boundary | [ ] | | |
| 4 | Compiler-checked isolation | [ ] | | |
| 5 | Commands, errors, config, Codable queries | [ ] | | |
| 6 | Async event loop and Observation | [ ] | | |

Phases run in order: 2 builds on 1's types, 4 is cheap once functions are methods on `@WM` classes (3), 5 rewrites
the IPC handlers against the final model, and 6 needs the compiler-checked isolation of 4 and the config of 5.

## Rules

- **Behavior stays.** No features or fixes mixed in. A bug you find goes into **Open issues** (or its own commit,
  named as a fix, when it is small and clear).
- **Output may change** (query JSON, failure texts, ordering), but only on purpose: list every changed golden record
  in the report, re-record with `GOLDEN_RECORD=1 swift test --filter Golden`, and add a CHANGELOG entry for changes a
  user or script can see. Update `doc/yabai.asciidoc` (`make man`) where it documents the output.
- **Every commit builds and passes** `make` and `make test` (warnings are errors). Commit to `main`, in small steps;
  a sub-phase may take several commits. Update tests in the same commit as the code they test.
- Run builds, tests and other long-output commands through the `output-summarizer` subagent (exact command, working
  directory, question, answer format).
- **Live checks** (phases 2–6): follow `doc/live-testing.md`. Deploys restart yabai and reset layouts; tell the
  user first, use `bash scripts/live-tests/deploy.sh install`, and restore the installed binary afterwards.
- **Return to the terminal after live work.** The user must not touch keyboard or touchpad during live tests and
  watches the window that runs the agent (usually iTerm2) to see when they end. Before any live step, record its id
  (`yabai -m query --windows --window`, while it has focus); after the last live step of a block (harness, bench,
  perf, deploy/restore, mirror), focus it again with `yabai -m window --focus <id>` (this also shows its space) and
  check that `query --windows --window` returns it. Do this on failures too. `live.py cleanup` does it for the window
  `setup` recorded, but bench, perf and deploys run outside that pair.
- **Performance** (end of phases 2, 3e, 4, 5, 6): `scripts/live-tests/bench.py` medians stay within 10% of the
  baseline recorded in phase 1, measured the same way; phases 5 and 6 also compare `perf.py` query/command latency.
- **Out of scope:** `osax/` (payload, loader) and the SA protocol. CPrivate only shrinks (wrappers Swift no longer
  needs).
- **Never:**
  - `Task {}` per event or any other path that lets events overtake each other: events are handled one at a time,
    in the order they were posted (phase 6 keeps this with one consumer of an `AsyncStream`).
  - Blocking AX/SkyLight calls on the Swift concurrency thread pool in bulk (they can block about 1 s on frozen
    apps). They stay synchronous on `@WM` or on the dedicated dispatch workers of the animations.
  - Combine (Observation and `AsyncStream` cover its uses).
  - Protocols/`any P` for dependency injection, or existentials and capturing closures on hot paths (mouse drag,
    animation, tree layout, border updates). Concrete `final class`es and structs; generics if abstraction is needed.
- New pitfalls go to the pitfalls list in `AGENTS.md` (brief, with an example file) in the same commit.

## Target conventions

What every phase converges on. Apply them to the code a phase touches; do not leave a file half-converted.

- **Naming:** Swift API Design Guidelines. Types `UpperCamelCase`, members `lowerCamelCase`, no C names, no
  `/// \`c_function_name\`` doc comments, no "Ported from src/…" headers. C function order is no longer preserved;
  order code by responsibility.
- **Comments:** keep every `// NOTE:` that records macOS/WindowServer/AX behavior, reworded to name Swift symbols.
  Drop comments that only explain the C origin.
- **Models** (`Window`, `Application`, `Process`, `View`, `Con`, `TabBar`, …): `final class` with methods and
  computed properties (`window.isFloating`, `view.add(window)`, `con.insert(child, at:)`). Strings are `String`, flags
  are `OptionSet`s or `Bool`s, "none" is an optional, not `0`/`-1`/`NULL`.
- **Managers:** `final class` singletons reached as `WindowManager.shared`, `SpaceManager.shared`, etc. No
  `*_global()` accessors, no manager parameters. Large managers split into `Type+Area.swift` extension files
  (e.g. `WindowManager+Focus.swift`).
- **IDs:** `WindowID`, `SpaceID`, `DisplayID` (in YabaiCore; `Hashable`, `Sendable`, raw value of the C width). Raw
  integers only at the Platform/CPrivate boundary and in the SA payload.
- **Integers:** `Int` for counts, indices and arithmetic; fixed-width types only for C/ABI and wire formats.
- **Enums:** Swift `enum`s; `String` raw values where the value is a CLI token or JSON text, so parsing and printing
  share one table.
- **Errors:** command code `throws(CommandError)`; one `catch` writes the failure response. Platform wrappers return
  optionals/`Bool` (no invented AX/SkyLight error types).
- **Config:** value structs (`BorderConfig`, `TabBarConfig`, …) separate from runtime state; renderers take snapshots.
- **Isolation:** window manager state is `@WM`, AppKit is `@MainActor`, anything another thread touches has an
  explicit owner (`Mutex`/`Atomic`) and a NOTE saying which threads use it.
- **Events and async:** producers `yield` into one `AsyncStream<Event>`; a single `@WM` loop handles them in order.
  Handlers may `await`; after every `await` they re-check the state they rely on (other `@WM` tasks may have run).
  Delays use `Task.sleep`, not `DispatchQueue.asyncAfter`.
- **Observation:** config and the model state renderers show are `@Observable`; renderers update from observation
  where order relative to other window server calls does not matter.
- **Queries:** `Codable` response types encoded with `JSONEncoder`; the JSON shape is documented in
  `doc/yabai.asciidoc`.
- **Platform:** SkyLight, AX and CoreDock calls go through `Sources/Yabai/Platform/` wrappers that take and return
  Swift types.
- **Tests:** Swift Testing, descriptive names (C `TEST_FUNC` display names are no longer required). Pure decisions
  move to YabaiCore or pure helpers so they can be tested without the window server.

## Phases

### 1 — Cleanup, one type per concept, Swift strings

1. **Instructions.** Rewrite the parts of `AGENTS.md` that describe the port: drop references to
   `doc/swift-port.md`, the one-to-one C naming/order rules, the C `TEST_FUNC` naming rule and the bridge-era
   pitfalls (YabaiC, `@_cdecl` model shims, temporary storage, unity build, C harness, `src/` paths). Keep pitfalls
   that are still true. Point to this file's Target conventions. Remove `.claude/skills/swift-port-conventions/`
   (its content lives in `AGENTS.md`). Fix the references to `doc/swift-port.md` in `doc/live-testing.md`,
   `doc/payload-updates.md`, `tests/YabaiTests/GoldenTests.swift`, `tests/YabaiTests/Golden/commands.txt` and
   `Sources/YabaiCore/JSON.swift` (the golden replay is now a regression snapshot, not a parity contract).
2. **Baseline.** Record test count, `bench.py` medians and `perf.py` results of the starting commit in the report
   (live; tell the user first).
3. **Dead code and stale comments.** `Response.appendWritten(by:)`, `Response.write(to: FILE)`, the empty
   "… itself, for the code that still reads it like the C pointer" doc comments, comments saying "until … Swift",
   "the C managers", "while those are C".
4. **One type per concept.** Use YabaiCore types directly in the daemon and delete the C-shaped copies and their
   converters:
   - `rule`, `rule_effects`, `RULE_*` flags, `regex_t`, `mallocString`, `parseCRule`, `RuleEffects(rule_effects)`
     → `Rule` / `RuleEffects` / `POSIXRegex`, stored as `[Rule]`.
   - `area` → `Area`; `space_layout` and the fixed 8-tuple → `SpaceLayout` / `[SpaceLayout]`; `DIR_*` → `Direction`;
     the scratchpad grid tuple → `Grid`.
5. **Swift strings.** `Application.name`, `Process.name`, `Window.scratchpad`, `Scratchpad.label`,
   `tab_bar_font_name`, `space_layout_spec` and other `UnsafeMutablePointer<CChar>` fields become `String`. Remove
   `strdup`/`free`/`strcmp` and helpers like `cName` / `string(_:)` that become unused.

**Done when:** no `UnsafeMutablePointer<CChar>` in the daemon's models, no `regex_t` outside `POSIXRegex`,
`Sources/Yabai/Shims/` holds only what is still needed (ideally gone), no repo file references `doc/swift-port.md`,
golden unchanged or changes explained.

### 2 — Swift types

1. Pseudo-enums (`struct x: RawRepresentable` plus global `let X_Y` constants, mostly in `Definitions.swift`,
   `Helpers.swift`, `MissionControl.swift`) → `enum`s or `OptionSet`s. Merge with YabaiCore duplicates
   (`WindowSplit`, `WindowLayer`, …). `Definitions.swift` should disappear or shrink to a few constants.
2. Bit fields → `OptionSet` properties or `Bool`s: `Window.flags`, `Window.rule_flags`, `View.flags`, window/AX
   notification masks. Tri-state rule props (`RuleProp`) → `Bool?` where that reads better.
3. Typed IDs (`WindowID`, `SpaceID`, `DisplayID`) through models, managers, selectors and events.
4. `Int32` → `Int` outside C/ABI and wire formats; sentinel values (`0`, `-1`) → optionals.
5. **Containers.** First make every order a user can observe explicit (queries, signal order, focus candidates):
   sort in the query, choose a documented order (e.g. windows by id, spaces by Mission Control index), and record it
   in the report. Then replace `Table` with `Dictionary` (or `Set`) and delete `Table.swift`.

**Done when:** no RawRepresentable pseudo-enums or global enum constants remain, `Table` is gone, golden re-recorded
with every change explained, live check and benchmark pass.

### 3 — Models and managers as types with methods

Common steps for 3a–3e: free functions → methods/computed properties on the type they act on, or members of their
manager; drop `sm`/`wm`/`dm` parameters and `*_global()` calls (use `.shared`); split files by responsibility into
`Type+Area.swift`; delete C-name doc comments; update call sites everywhere (including `IPC/` and tests, which then
no longer need the `Yabai.` prefix). Golden output should stay unchanged; explain any change.

- **3a Tree and views:** `Tree.swift`, `TreeView.swift`, `View.swift`, `WindowManagerTree.swift`. `Con` gets the tree
  primitives (insert, unlink, replace, wrap, reap, flatten) as methods; `View` owns layout/flush. Keep the i3
  algorithms' structure; `TreeTests` must keep passing unchanged in meaning.
- **3b Windows, applications, rules:** `Window.swift`, `Application.swift`, `WindowManager*.swift`, `Rule.swift`,
  `WindowManagerRules.swift`. `WindowManager.swift` (≈1.5k lines) splits into extensions.
- **3c Spaces, displays, processes:** `Space.swift`, `SpaceManager.swift`, `SpaceLayout.swift`, `Display.swift`,
  `DisplayManager.swift`, `MissionControl.swift`, `ProcessManager.swift`, `Workspace.swift`. Spaces and displays may
  stay ID-based (WindowServer is the source of truth); give the IDs methods (`spaceID.display`, `displayID.spaces`)
  instead of free functions.
- **3d Events, signals, rendering, input, SA, startup:** `EventHandlers*.swift`, `EventLoop.swift`,
  `EventSignal.swift`, `Border.swift`, `TabBar*.swift`, `WindowAnimation.swift`, `MouseHandler.swift`,
  `ScriptingAddition.swift`, `SAConnection.swift`, `Yabai.swift`, `Service.swift`, `Helpers.swift`, `Log.swift`.
  Event handlers can become methods of a handler type or of the manager they change. Signals carry typed values
  instead of `UnsafeMutableRawPointer` contexts. SA calls become `ScriptingAddition.shared.focusSpace(_:)` etc.
- **3e Platform boundary:** move the remaining raw `SLS*(` calls (≈116 outside `Platform/`) and
  `AXUIElementCopy*/Set*` calls (≈33) behind `Platform/` wrappers with Swift types. Drop CPrivate wrappers that are
  no longer used.

**Done when (all of 3):** no top-level `snake_case` functions in `Sources/Yabai` (except names CPrivate/C callbacks
require), no `*_global()` accessors, raw SkyLight/AX calls only in `Platform/`, live check and benchmark pass.

### 4 — Compiler-checked isolation

1. Mark managers and models `@WM`; remove all `nonisolated(unsafe)` globals (`g_window_manager`, `g_space_manager`,
   `g_display_manager`, `g_process_manager`, `g_mouse_state`, `g_mission_control_mode`, `g_verbose`,
   `g_sa_socket_file`, `tabBarList`, `missionControlObserver`).
2. Fix each compiler error by giving the state one owner, not by adding `nonisolated(unsafe)`. Known spots:
   - the mouse event tap (main run loop) reads `MouseState`: split the tap's part into `Atomic`/`Mutex` state;
   - the Carbon process handler mutates the process table on the main thread while `@WM` handlers read it: make the
     handler only post events and keep the table `@WM`, or give it a `Mutex`;
   - `g_verbose` → `Atomic`; the SA socket path → immutable after startup or `@WM`.
3. `@WM`-isolated classes are `Sendable`: remove `Handoff` wrappers for them; keep `Handoff` only for retained CF
   objects. Audit every `@unchecked Sendable` (`TabBarGlass`, `WindowAnimation`, `WindowFrameGroup`, border and
   glass snapshots); each keeps a NOTE justifying it or goes.
4. `WM.assumeIsolated` remains only at C callback entry points that run on the `yabai.wm` queue.

**Done when:** no `nonisolated(unsafe)` in `Sources/Yabai`, `make tsan` run of the live harness is clean, live check
and benchmark pass.

### 5 — Commands, errors, config, Codable queries

1. **Errors:** add `CommandError` (message text); handlers `throws(CommandError)`, one `catch` in message handling
   writes the failure byte and text. Replace `window_op_error`/`space_op_error` with `Error` enums and the
   `rsp.fail(…); return false` pattern with `throw`. Failure texts may be reworded for clarity (golden + CHANGELOG).
2. **Parse, then execute:** YabaiCore parses each domain into a typed command (`WindowCommand`, `SpaceCommand`, …,
   extending what `WindowToggle` and `TreeFocus` do); the daemon executes it. Parser tests live in `YabaiCoreTests`.
3. **Config:** move settings out of `WindowManager`/`SpaceManager` into a `Config` value with sub-structs
   (`BorderConfig`, `TabBarConfig`, `MouseConfig`, `AnimationConfig`, `SpaceDefaults`, …). Replace the `if/else`
   chain in `MessageConfig.swift` with a table of option descriptors (name, print, parse, apply). Renderers read
   config snapshots.
4. **Queries with `JSONEncoder`:** `Codable` response types for displays, spaces, windows, the tree and
   `rule --list` (in YabaiCore where they are pure values), encoded with `JSONEncoder`. Decide and document:
   - key order: declaration order is not guaranteed by `JSONEncoder`; use `.sortedKeys` unless the encoder used
     keeps declaration order reliably (check in a scratch test, record the finding in `AGENTS.md`);
   - property selection (`query --windows id,frame`): a custom `encode(to:)` that skips unselected keys, or encode
     the full value and filter the top-level keys;
   - numbers and frames: `JSONEncoder`'s default formatting replaces `%.4f`; set `.withoutEscapingSlashes`.
   Then delete `JSONWriter`, `JSON.escape` and the hand-built JSON in `Serialize.swift`, `Rule.swift` and signals
   if unused. Check that `perf.py` query latency stays within 10% (status bars query often).

**Done when:** no `window_op_error`/`space_op_error`, no `inout Response` failure plumbing outside the top-level
handler, config options defined in one table, queries encoded by `JSONEncoder`, docs/man page and CHANGELOG updated
for visible changes, golden re-recorded and explained.

### 6 — Async event loop and Observation

1. **Event loop:** replace `EventLoop.post` → `queue.async` with an `AsyncStream<Event>` (unbounded buffer).
   Producers call the continuation's `yield` from any thread; one long-lived `Task { @WM in for await event in … }`
   handles each event and flushes its signals. The `@WM` executor stays on the `yabai.wm` serial queue, so C
   callbacks on that queue can still use `WM.assumeIsolated`. Keep the autorelease pool per event.
2. **Async handlers where they help:** handlers become `async` only when they wait (delays, animation completion,
   SA replies). The single consumer means the next event waits until the handler returns; other `@WM` tasks
   (timers, IPC) can still run at each `await`, so re-check windows/views after it (`Window.isValid`, view lookup).
3. **Timers:** the `DispatchQueue.main.asyncAfter` delays (application launch retry, space layout reconcile,
   Mission Control exit checks, focus deferral, …) become `Task { try await Task.sleep(for:); post(…) }` or `await`
   inside the handler, whichever keeps the event order the code relies on.
4. **IPC:** the accept thread stays; a client message is an event. A command may `await` (e.g. an animation it
   started) without blocking other events only if that is safe for its state; otherwise it stays synchronous.
5. **Observation:** make `Config` (phase 5) and the model state renderers show (focused window, window frames,
   tab bar entries) `@Observable`. Borders, tab bars and opacity update from observation (`Observations` or
   `withObservationTracking`) where the order of window server calls does not matter, replacing explicit refresh
   calls. Keep explicit calls where order matters (tab card ordering after raising tabs, frame flush, border
   hand-over); each kept call gets a NOTE why.
6. Animations keep their dispatch workers for the blocking AX/SkyLight calls; their completion may become an
   `async` result the event loop awaits.

**Done when:** `EventLoop` is the `AsyncStream` loop, no `DispatchQueue.asyncAfter` remains for event timing,
renderers follow config changes through Observation, `make tsan` live run clean, frozen-application live check
(`scripts/live-tests/freeze.swift`) shows other events still handled, live check and benchmark pass.

## Open issues

Carried between phases; add, resolve or strike items here.

- Keep or delete `doc/swift-port-performance.md` and `doc/performance/2026-10-15/` (port-era benchmark report)?
  Ask the user in phase 1.

## Reports

Append one per session, newest last, at most ~15 lines. Put lasting knowledge in `AGENTS.md`, not here.

```
### <YYYY-MM-DD> Phase <n> <[~] or [x]>
- Commits: <first>..<last>
- Done: <what changed, briefly>
- Output changes: <golden records / CLI texts changed and why, or "none">
- Verification: <tests (count), golden, live check, tsan, bench vs baseline>
- Next: <exact next step if unfinished>
- Notes for the next agent: <surprises, decisions, new pitfalls (also added to AGENTS.md)>
```
