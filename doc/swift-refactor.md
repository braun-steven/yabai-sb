# Idiomatic Swift refactor — phased plan

The daemon is Swift, but it is still written like the C it came from: free `snake_case` functions that thread manager
pointers (`window_manager_foo(sm, wm, …)`), `nonisolated(unsafe)` global managers, pseudo-enums made of
`RawRepresentable` structs and global constants, `Int32` everywhere, malloc'ed C strings and a C-shaped `rule`
struct next to YabaiCore's Swift `Rule`. This plan turns it into idiomatic Swift without changing what yabai does.

## How to use this file

Work runs in two roles. A **phase agent** is the agent the user starts with "continue with the next phase"; it runs
one phase by spawning one **subphase agent** per subphase (2.1, 2.2, …), one after another. Each subphase agent works
with a fresh context on a single subphase, so no agent carries a whole phase. If your prompt says you are a subphase
agent, follow **Subphase agent**; otherwise you are the phase agent.

### Phase agent

1. Read `AGENTS.md`, this file's **Rules**, the **Status board**, the section of the phase you take and the latest
   **Reports**. Skim the **Target conventions**. Do not read source code or change it yourself: that is the subphase
   agents' job, and your context must last for the whole phase.
2. Take the first phase in the Status board that is not `[x]`. Work only on that phase.
3. For each of its subphases that is not `[x]`, in board order:
   - Spawn one subphase agent with the Agent tool: `subagent_type: "general-purpose"`, `model: "opus"` (Opus 5.5),
     `effort: "medium"`, and the prompt template below. Spawn exactly one at a time and wait for its completion
     notification before doing anything else: subphase agents share the working tree, the build directory and git.
   - Before a subphase with live work (deploys, harness, bench, perf; usually the verification subphase), tell the
     user in your reply that a live test is about to start, that yabai will restart and layouts reset, and that they
     must not touch keyboard or touchpad until the terminal window is focused again.
   - When it returns, check `git status` (clean), `git log --oneline` (its commits), its board row and its report.
     Do not trust the summary alone: if the report does not state that `make` and `make test` passed at its last
     commit, run both through `output-summarizer`.
   - Row `[x]`: go on with the next subphase. Row `[~]` (context ran out or the work was larger than expected):
     spawn a fresh subphase agent for the same subphase; it continues from the report. Stop and report to the user
     if two agents in a row made no progress on a subphase, or if the build or tests fail at HEAD.
   - The agent returned `BLOCKED: <question>` (a decision only the user can make): ask the user with
     AskUserQuestion, then continue that agent with SendMessage and the answer, or spawn a fresh one with the answer
     in its prompt. Record the decision in **Open issues**.
4. When every subphase is `[x]`, check the phase's **Done when** list (send a subphase agent to fix gaps rather than
   fixing them yourself), set the phase row to `[x]` with the last commit, and commit this file. Then tell the user
   the phase is done, summarize the subphase reports in a few lines, and say that the next phase can start from a
   cleared context.

Without a subagent tool (e.g. Codex), do the subphases yourself, in order, following **Subphase agent** for each.

Prompt template for a subphase agent (fill in the angle brackets, drop the optional lines):

```
You are a subphase agent for the yabai Swift refactor. Do subphase <n.m> (<title>) of phase <n> in
doc/swift-refactor.md and nothing else. Follow that file's "Subphase agent" section.
<Optional: An earlier agent left this subphase [~]; continue from its report.>
<Optional: The user decided: <answer to the BLOCKED question>.>
End your final message with exactly one of:
  DONE <first>..<last commit> — <one-line summary>
  PARTIAL <last commit> — <what remains>
  BLOCKED: <question for the user, with the options you see>
```

### Subphase agent

1. Read `AGENTS.md`, this file's **Rules**, **Target conventions**, your phase's section (its common steps, your
   subphase and **Done when**) and the reports of this phase's earlier subphases. Read `doc/live-testing.md` before
   anything live.
2. Do only your subphase. Work that belongs to a later subphase goes into your report's "Next"; a bug goes into
   **Open issues** (or its own fix commit, see **Rules**).
3. Commit in small steps; every commit builds and passes the tests. Run builds and tests through `output-summarizer`
   if you can spawn it; otherwise run them yourself and filter the output (`2>&1 | grep -E 'error:|warning:'`, the
   test summary lines).
4. You cannot ask the user. If a decision is genuinely theirs (an output change the plan does not cover, dropping a
   behavior, a trade-off the plan leaves open), commit what is done, record the question in **Open issues** and
   return `BLOCKED: …`. Decide everything else yourself and note the decision in your report.
5. Before you return, even unfinished: set your subphase row to `[~]` or `[x]` (with the last commit), set the phase
   row to `[~]`, append a report (template below) and commit this file with the code. A fresh agent with no other
   context must be able to continue from it. When your context runs low, stop at a clean commit and return
   `PARTIAL` rather than starting another step.

## Status board

Legend: `[ ]` not started · `[~]` in progress · `[x]` done. A phase is `[x]` once all its subphases are and its
**Done when** holds.

| Phase | Title | Status | Last commit | Note |
|---|---|---|---|---|
| 1 | Cleanup, one type per concept, Swift strings | [x] | c05a4dd6 | baseline in `doc/performance/2026-10-18-refactor-baseline/` |
| **2** | **Swift types** | [ ] | | |
| 2.1 | Pseudo-enums → enums and OptionSets | [ ] | | |
| 2.2 | Bit fields → OptionSets and Bools | [ ] | | |
| 2.3 | Typed IDs | [ ] | | |
| 2.4 | `Int32` → `Int`, sentinels → optionals | [ ] | | |
| 2.5 | Explicit orders, `Table` → `Dictionary` | [ ] | | |
| 2.6 | Verification: live check, benchmark | [ ] | | |
| **3** | **Models and managers as types with methods** | [ ] | | |
| 3.1 | Tree and views | [ ] | | |
| 3.2 | Windows, applications, rules | [ ] | | |
| 3.3 | Spaces, displays, processes | [ ] | | |
| 3.4 | Events, signals, rendering, input, SA, startup | [ ] | | |
| 3.5 | Platform boundary | [ ] | | |
| 3.6 | Verification: done-when sweep, live check, benchmark | [ ] | | |
| **4** | **Compiler-checked isolation** | [ ] | | |
| 4.1 | Mouse event tap state | [ ] | | |
| 4.2 | Process table | [ ] | | |
| 4.3 | Remaining globals | [ ] | | |
| 4.4 | Managers and models `@WM` | [ ] | | |
| 4.5 | `Sendable`, `Handoff` and `WM.assumeIsolated` audit | [ ] | | |
| 4.6 | Verification: tsan live run, live check, benchmark | [ ] | | |
| **5** | **Commands, errors, config, Codable queries** | [ ] | | |
| 5.1 | `CommandError` and throwing handlers | [ ] | | |
| 5.2 | Typed commands: window | [ ] | | |
| 5.3 | Typed commands: other domains | [ ] | | |
| 5.4 | `Config` values and option table | [ ] | | |
| 5.5 | Queries with `JSONEncoder` | [ ] | | |
| 5.6 | Verification: docs, live check, benchmark, perf | [ ] | | |
| **6** | **Async event loop and Observation** | [ ] | | |
| 6.1 | `AsyncStream` event loop | [ ] | | |
| 6.2 | Async handlers where they wait | [ ] | | |
| 6.3 | Timers | [ ] | | |
| 6.4 | IPC | [ ] | | |
| 6.5 | Observation | [ ] | | |
| 6.6 | Animation completion | [ ] | | |
| 6.7 | Verification: tsan, freeze check, live check, benchmark, perf | [ ] | | |

Phases run in order: 2 builds on 1's types, 4 is cheap once functions are methods on `@WM` classes (3), 5 rewrites
the IPC handlers against the final model, and 6 needs the compiler-checked isolation of 4 and the config of 5.
Subphases run in order too; a later one may rely on an earlier one's types.

## Rules

- **Behavior stays.** No features or fixes mixed in. A bug you find goes into **Open issues** (or its own commit,
  named as a fix, when it is small and clear).
- **Output may change** (query JSON, failure texts, ordering), but only on purpose: list every changed golden record
  in the report, re-record with `GOLDEN_RECORD=1 swift test --filter Golden`, and add a CHANGELOG entry for changes a
  user or script can see. Update `doc/yabai.asciidoc` (`make man`) where it documents the output.
- **Every commit builds and passes** `make` and `make test` (warnings are errors). Commit to `main`, in small steps;
  a subphase may take several commits. Update tests in the same commit as the code they test.
- Run builds, tests and other long-output commands through the `output-summarizer` subagent (exact command, working
  directory, question, answer format).
- **Live checks** (phases 2–6, in each phase's verification subphase unless a subphase says otherwise): follow
  `doc/live-testing.md`. Deploys restart yabai and reset layouts; the phase agent tells the user first. Use
  `bash scripts/live-tests/deploy.sh install`, and restore the installed binary afterwards.
- **Return to the terminal after live work.** The user must not touch keyboard or touchpad during live tests and
  watches the window that runs the agent (usually iTerm2) to see when they end. Before any live step, record its id
  (`yabai -m query --windows --window`, while it has focus); after the last live step of a block (harness, bench,
  perf, deploy/restore, mirror), focus it again with `yabai -m window --focus <id>` (this also shows its space) and
  check that `query --windows --window` returns it. Do this on failures too. `live.py cleanup` does it for the window
  `setup` recorded, but bench, perf and deploys run outside that pair.
- **Performance** (verification subphases of phases 2, 3, 4, 5, 6): `scripts/live-tests/bench.py` medians stay
  within 10% of the baseline recorded in phase 1, measured the same way; phases 5 and 6 also compare `perf.py`
  query/command latency.
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

What every phase converges on. Apply them to the code a subphase touches; do not leave a file half-converted.

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

Each phase lists its subphases; one subphase agent works on one subphase (see **How to use this file**). The
verification subphase at the end of a phase runs the live check and benchmark and sweeps the **Done when** list;
earlier subphases only build, test and commit.

### 1 — Cleanup, one type per concept, Swift strings

Done before the subphase workflow existed; kept for reference.

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

- **2.1 Pseudo-enums.** Pseudo-enums (`struct x: RawRepresentable` plus global `let X_Y` constants, mostly in
  `Definitions.swift`, `Helpers.swift`, `MissionControl.swift`) → `enum`s or `OptionSet`s. Merge with YabaiCore
  duplicates (`WindowSplit`, `WindowLayer`, …). `Definitions.swift` should disappear or shrink to a few constants.
- **2.2 Bit fields** → `OptionSet` properties or `Bool`s: `Window.flags`, `Window.rule_flags`, `View.flags`,
  window/AX notification masks. Tri-state rule props (`RuleProp`) → `Bool?` where that reads better.
- **2.3 Typed IDs** (`WindowID`, `SpaceID`, `DisplayID`) through models, managers, selectors and events.
- **2.4 Integers.** `Int32` → `Int` outside C/ABI and wire formats; sentinel values (`0`, `-1`) → optionals.
- **2.5 Containers.** First make every order a user can observe explicit (queries, signal order, focus candidates):
  sort in the query, choose a documented order (e.g. windows by id, spaces by Mission Control index), and record it
  in the report. Then replace `Table` with `Dictionary` (or `Set`) and delete `Table.swift`. Re-record the golden
  with every change explained.
- **2.6 Verification.** Sweep **Done when**. Live check that also exercises rules (`rule --add app=… manage=off`,
  `rule --apply`, one-shot rules) and scratchpads, whose storage changed in phase 1 (see **Open issues**);
  benchmark against the baseline.

**Done when:** no RawRepresentable pseudo-enums or global enum constants remain, `Table` is gone, golden re-recorded
with every change explained, live check and benchmark pass.

### 3 — Models and managers as types with methods

Common steps for 3.1–3.5: free functions → methods/computed properties on the type they act on, or members of their
manager; drop `sm`/`wm`/`dm` parameters and `*_global()` calls (use `.shared`); split files by responsibility into
`Type+Area.swift`; delete C-name doc comments; update call sites everywhere (including `IPC/` and tests, which then
no longer need the `Yabai.` prefix). Golden output should stay unchanged; explain any change. A subphase introduces
the `.shared` singletons it needs; `*_global()` accessors go once their last caller is gone.

- **3.1 Tree and views:** `Tree.swift`, `TreeView.swift`, `View.swift`, `WindowManagerTree.swift`. `Con` gets the
  tree primitives (insert, unlink, replace, wrap, reap, flatten) as methods; `View` owns layout/flush. Keep the i3
  algorithms' structure; `TreeTests` must keep passing unchanged in meaning.
- **3.2 Windows, applications, rules:** `Window.swift`, `Application.swift`, `WindowManager*.swift`, `Rule.swift`,
  `WindowManagerRules.swift`. `WindowManager.swift` (≈1.5k lines) splits into extensions.
- **3.3 Spaces, displays, processes:** `Space.swift`, `SpaceManager.swift`, `SpaceLayout.swift`, `Display.swift`,
  `DisplayManager.swift`, `MissionControl.swift`, `ProcessManager.swift`, `Workspace.swift`. Spaces and displays may
  stay ID-based (WindowServer is the source of truth); give the IDs methods (`spaceID.display`, `displayID.spaces`)
  instead of free functions.
- **3.4 Events, signals, rendering, input, SA, startup:** `EventHandlers*.swift`, `EventLoop.swift`,
  `EventSignal.swift`, `Border.swift`, `TabBar*.swift`, `WindowAnimation.swift`, `MouseHandler.swift`,
  `ScriptingAddition.swift`, `SAConnection.swift`, `Yabai.swift`, `Service.swift`, `Helpers.swift`, `Log.swift`.
  Event handlers can become methods of a handler type or of the manager they change. Signals carry typed values
  instead of `UnsafeMutableRawPointer` contexts. SA calls become `ScriptingAddition.shared.focusSpace(_:)` etc.
- **3.5 Platform boundary:** move the remaining raw `SLS*(` calls (≈116 outside `Platform/`) and
  `AXUIElementCopy*/Set*` calls (≈33) behind `Platform/` wrappers with Swift types. Drop CPrivate wrappers that are
  no longer used.
- **3.6 Verification.** Sweep **Done when** (grep for top-level `snake_case` functions, `_global()`, raw `SLS*(`/AX
  calls outside `Platform/`) and fix leftovers; live check; benchmark.

**Done when (all of 3):** no top-level `snake_case` functions in `Sources/Yabai` (except names CPrivate/C callbacks
require), no `*_global()` accessors, raw SkyLight/AX calls only in `Platform/`, live check and benchmark pass.

### 4 — Compiler-checked isolation

The goal is to mark managers and models `@WM` and remove all `nonisolated(unsafe)` globals (`g_window_manager`,
`g_space_manager`, `g_display_manager`, `g_process_manager`, `g_mouse_state`, `g_mission_control_mode`, `g_verbose`,
`g_sa_socket_file`, `tabBarList`, `missionControlObserver`). Fix each compiler error by giving the state one owner,
not by adding `nonisolated(unsafe)`. 4.1–4.3 give the state touched from other threads its owner first, so 4.4 can
flip the annotations.

- **4.1 Mouse event tap:** the tap (main run loop) reads `MouseState`: split the tap's part into `Atomic`/`Mutex`
  state with a NOTE naming its threads.
- **4.2 Process table:** the Carbon process handler mutates the table on the main thread while `@WM` handlers read
  it: make the handler only post events and keep the table `@WM`, or give it a `Mutex`.
- **4.3 Remaining globals:** `g_verbose` → `Atomic`; the SA socket path → immutable after startup or `@WM`;
  `g_mission_control_mode`, `tabBarList`, `missionControlObserver` get an owner.
- **4.4 `@WM` models and managers:** mark them `@WM`, remove the remaining `nonisolated(unsafe)` globals, fix the
  compiler errors as above.
- **4.5 Audit:** `@WM`-isolated classes are `Sendable`: remove `Handoff` wrappers for them; keep `Handoff` only for
  retained CF objects. Audit every `@unchecked Sendable` (`TabBarGlass`, `WindowAnimation`, `WindowFrameGroup`,
  border and glass snapshots); each keeps a NOTE justifying it or goes. `WM.assumeIsolated` remains only at C
  callback entry points that run on the `yabai.wm` queue.
- **4.6 Verification.** `make tsan` run of the live harness, live check, benchmark.

**Done when:** no `nonisolated(unsafe)` in `Sources/Yabai`, `make tsan` run of the live harness is clean, live check
and benchmark pass.

### 5 — Commands, errors, config, Codable queries

- **5.1 Errors:** add `CommandError` (message text); handlers `throws(CommandError)`, one `catch` in message handling
  writes the failure byte and text. Replace `window_op_error`/`space_op_error` with `Error` enums and the
  `rsp.fail(…); return false` pattern with `throw`. Failure texts may be reworded for clarity (golden + CHANGELOG).
- **5.2–5.3 Parse, then execute:** YabaiCore parses each domain into a typed command (`WindowCommand`,
  `SpaceCommand`, …, extending what `WindowToggle` and `TreeFocus` do); the daemon executes it. Parser tests live in
  `YabaiCoreTests`. 5.2 does the window domain (including tree commands) and sets the pattern; 5.3 applies it to
  space, display, query, rule, signal and the remaining domains.
- **5.4 Config:** move settings out of `WindowManager`/`SpaceManager` into a `Config` value with sub-structs
  (`BorderConfig`, `TabBarConfig`, `MouseConfig`, `AnimationConfig`, `SpaceDefaults`, …). Replace the `if/else`
  chain in `MessageConfig.swift` with a table of option descriptors (name, print, parse, apply). Renderers read
  config snapshots.
- **5.5 Queries with `JSONEncoder`:** `Codable` response types for displays, spaces, windows, the tree and
  `rule --list` (in YabaiCore where they are pure values), encoded with `JSONEncoder`. Decide and document:
  - key order: declaration order is not guaranteed by `JSONEncoder`; use `.sortedKeys` unless the encoder used
    keeps declaration order reliably (check in a scratch test, record the finding in `AGENTS.md`);
  - property selection (`query --windows id,frame`): a custom `encode(to:)` that skips unselected keys, or encode
    the full value and filter the top-level keys;
  - numbers and frames: `JSONEncoder`'s default formatting replaces `%.4f`; set `.withoutEscapingSlashes`.
  Then delete `JSONWriter`, `JSON.escape` and the hand-built JSON in `Serialize.swift`, `Rule.swift` and signals
  if unused.
- **5.6 Verification.** Check docs/man page and CHANGELOG cover every visible change, live check, benchmark, and
  `perf.py` query latency within 10% (status bars query often).

**Done when:** no `window_op_error`/`space_op_error`, no `inout Response` failure plumbing outside the top-level
handler, config options defined in one table, queries encoded by `JSONEncoder`, docs/man page and CHANGELOG updated
for visible changes, golden re-recorded and explained.

### 6 — Async event loop and Observation

- **6.1 Event loop:** replace `EventLoop.post` → `queue.async` with an `AsyncStream<Event>` (unbounded buffer).
  Producers call the continuation's `yield` from any thread; one long-lived `Task { @WM in for await event in … }`
  handles each event and flushes its signals. The `@WM` executor stays on the `yabai.wm` serial queue, so C
  callbacks on that queue can still use `WM.assumeIsolated`. Keep the autorelease pool per event.
- **6.2 Async handlers where they help:** handlers become `async` only when they wait (delays, animation completion,
  SA replies). The single consumer means the next event waits until the handler returns; other `@WM` tasks
  (timers, IPC) can still run at each `await`, so re-check windows/views after it (`Window.isValid`, view lookup).
- **6.3 Timers:** the `DispatchQueue.main.asyncAfter` delays (application launch retry, space layout reconcile,
  Mission Control exit checks, focus deferral, …) become `Task { try await Task.sleep(for:); post(…) }` or `await`
  inside the handler, whichever keeps the event order the code relies on.
- **6.4 IPC:** the accept thread stays; a client message is an event. A command may `await` (e.g. an animation it
  started) without blocking other events only if that is safe for its state; otherwise it stays synchronous.
- **6.5 Observation:** make `Config` (phase 5) and the model state renderers show (focused window, window frames,
  tab bar entries) `@Observable`. Borders, tab bars and opacity update from observation (`Observations` or
  `withObservationTracking`) where the order of window server calls does not matter, replacing explicit refresh
  calls. Keep explicit calls where order matters (tab card ordering after raising tabs, frame flush, border
  hand-over); each kept call gets a NOTE why.
- **6.6 Animations** keep their dispatch workers for the blocking AX/SkyLight calls; their completion may become an
  `async` result the event loop awaits.
- **6.7 Verification.** `make tsan` live run, frozen-application live check (`scripts/live-tests/freeze.swift`),
  live check, benchmark, `perf.py`.

**Done when:** `EventLoop` is the `AsyncStream` loop, no `DispatchQueue.asyncAfter` remains for event timing,
renderers follow config changes through Observation, `make tsan` live run clean, frozen-application live check
shows other events still handled, live check and benchmark pass.

## Open issues

Carried between phases; add, resolve or strike items here.

- ~~Keep or delete the port-era benchmark report?~~ Kept (user, 2026-10-18).
- Phase 1 had no live check (not required); the first live check of the refactor is phase 2's (2.6). It should
  exercise rules (`rule --add app=… manage=off`, `rule --apply`, one-shot rules) and scratchpads, whose storage
  changed.

## Reports

Each subphase agent appends one per session, newest last, at most ~15 lines. Put lasting knowledge in `AGENTS.md`,
not here.

```
### <YYYY-MM-DD> Subphase <n.m> <[~] or [x]>
- Commits: <first>..<last>
- Done: <what changed, briefly>
- Output changes: <golden records / CLI texts changed and why, or "none">
- Verification: <make, make test (count), golden; live check, tsan, bench vs baseline where run>
- Decisions: <choices the plan left open, or "none">
- Next: <exact next step if unfinished, or work left for a later subphase>
- Notes for the next agent: <surprises, new pitfalls (also added to AGENTS.md)>
```

### 2026-10-18 Phase 1 [x]
- Commits: ad53527a..c05a4dd6
- Done: AGENTS.md rewritten for the refactor (skill removed, port references fixed); rules are `[Rule]` with
  `Rule.matches`/`listFlags` in YabaiCore; `area`→`Area`, `DIR_*`/`STACK`→`Direction`/`InsertDirection?`,
  `space_layout` tuple→`[SpaceLayout]`, scratchpad grid→`Grid`; application/process/scratchpad/font names and
  `space_layout_spec` are `String`; `Sources/Yabai/Shims/` and the C-string helpers are gone; stale comments dropped.
- Output changes: none (golden unchanged). Debug output of a terminated process now keeps its name instead of
  "(null)"; `config tab_bar_font` rejects non-UTF-8 values before parsing instead of while creating the font.
- Verification: 113 tests (71 Yabai + 42 YabaiCore; baseline 112, +1 rule matching test), golden, `make`,
  `make install`. Baseline (installed build = HEAD sources, one display): bench tab/rotate/split focus medians
  29.7/120.1/27.4 and 28.7/129.7/32.7 ms; perf.py in `doc/performance/2026-10-18-refactor-baseline/`. No live check.
- Next: phase 2, subphase 2.1 (pseudo-enums in `Definitions.swift`).
- Notes for the next agent: `Token(cString:)` (MessageSpace.swift) remains for sscanf buffers, `debug_message` for the
  socket buffer, argv `strdup`s for posix_spawn. Many daemon files did not import YabaiCore; add the import when a
  YabaiCore type is missing. Shell edits: BSD sed has no `\b` (use perl), and grep build logs for
  `error:` anywhere in the line, not only at its start (`swift build` prints `error: /path:line:col …`).
