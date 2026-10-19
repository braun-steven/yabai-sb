# Idiomatic Swift refactor — phased plan

The daemon is Swift, but it is still written like the C it came from: free `snake_case` functions that thread manager
pointers (`window_manager_foo(sm, wm, …)`), `nonisolated(unsafe)` global managers, pseudo-enums made of
`RawRepresentable` structs and global constants, `Int32` everywhere, malloc'ed C strings and a C-shaped `rule`
struct next to YabaiCore's Swift `Rule`. This plan turns it into idiomatic Swift without changing what yabai does.

## How to use this file

Work runs in two roles. A **phase agent** is the agent the user starts with "continue with the next phase"; it runs
one phase by spawning one **subphase agent** per subphase (2.1, 2.2, …), one after another. Each subphase agent works
with a fresh context on a single subphase, so no agent carries a whole phase. If your prompt says you are a subphase
agent, follow **Subphase agent**; otherwise you are the phase agent. A subphase agent plans its subphase and implements
the plan through **Haiku subagents** of its own (**Subphase agent**, step 3), so the chain is phase agent → subphase
agent → Haiku subagents.

### Phase agent

1. Read `AGENTS.md`, this file's **Rules**, the **Status board**, the section of the phase you take and the latest
   **Reports**. Skim the **Target conventions**. Do not read source code or change it yourself: that is the subphase
   agents' job, and your context must last for the whole phase.
2. Take the first phase in the Status board that is not `[x]`. Work only on that phase. Track it with the Claude
   Code Task tools (see **Progress tracking**): check `TaskList`, then create one task per subphase that is not
   `[x]` and does not have a task yet.
3. For each of its subphases that is not `[x]`, in board order:
   - Spawn one subphase agent with the Agent tool: `subagent_type: "general-purpose"`, `model: "opus"` (Opus 5.5),
     `effort: "medium"`, and the prompt template below. Spawn exactly one at a time and wait for its completion
     notification before doing anything else: subphase agents share the working tree, the build directory and git.
     Set its task `in_progress` (owner: the agent id) when you spawn it, and give the task id in the prompt.
   - Before a subphase with live work (deploys, harness, bench, perf; usually the verification subphase), tell the
     user in your reply that a live test is about to start, that yabai will restart and layouts reset, and that they
     must not touch keyboard or touchpad until the terminal window is focused again.
   - When it returns, check `git status` (clean), `git log --oneline` (its commits), its board row and its report. If anything is
     uncommitted, send the agent back with SendMessage to commit it before you go on.
     Do not trust the summary alone: if the report does not state that `make` and `make test` passed at its last
     commit, run both through `output-summarizer`.
   - Row `[x]`: set its task `completed` and go on with the next subphase. Row `[~]` (context ran out or the work was larger than expected):
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
Your subphase task is #<task id>; report progress to the phase agent as "Progress tracking" says.
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
3. **Plan, then implement through Haiku subagents.** Before you edit anything, read what the subphase touches and write
   a plan in your own context: the files, symbols and call sites that change (search for every reference to a
   renamed symbol), and the order of the changes. Decide
   every open question in the plan yourself (design, API and model choices, comment wording, anything that changes
   behavior). Split the plan into pieces, one subagent per piece: when the subphase names several independent changes
   (say foo, bar and baz), spawn one subagent for each; when it is a single change, spawn one. Spawn them with the
   Agent tool: `subagent_type: "general-purpose"`, `model: "haiku"` (Haiku 5.5), `effort: "high"`. Spawn them one at a
   time, never in parallel: they share the working tree. Each prompt stands alone: the files and symbols the plan
   names, the exact change (old and new text, the rename, or the rule in precise words), the **Rules** and **Target
   conventions** that apply, and these instructions: edit with `Edit`; do not commit. You may build and test to check your piece; the subphase agent runs the full build and tests after all pieces. The file
   list is a starting point, not a limit: when the change renames or alters a symbol that other files use, search the
   tree for the old name (`grep` across `Sources/`, `tests/` and `doc/`) and update every reference the change breaks,
   in any file, and list each extra file in the report. If the change needs a decision the plan does not cover, stop
   and report it instead of guessing; finish with the files changed and anything you were unsure about. When a
   subagent returns, check its `git diff` yourself: each hunk must be the change its piece asked for, or a reference
   the change broke. Send a wrong or incomplete hunk back to a new Haiku subagent with the fix (a one-line fix you
   may make yourself). For a large diff, have `output-summarizer` run `git diff` and list every hunk that
   goes beyond its piece. If you cannot spawn subagents, implement the plan yourself, piece by piece.
4. Commit in small steps; every commit builds and passes the tests. After each piece's diff check, build and test it
   through `output-summarizer` if you can spawn it; otherwise run them yourself and filter the output
   (`2>&1 | grep -E 'error:|warning:'`, the test summary lines). Commit each piece once both pass; the subagents never
   commit.
5. You cannot ask the user. If a decision is genuinely theirs (an output change the plan does not cover, dropping a
   behavior, a trade-off the plan leaves open), commit what is done, record the question in **Open issues** and
   return `BLOCKED: …`. Decide everything else yourself and note the decision in your report.
6. Before you return, even unfinished: set your subphase row to `[~]` or `[x]` (with the last commit), set the phase
   row to `[~]`, append a report (template below) and commit everything you changed, this file included. You always
   commit before you return, on `DONE`, `PARTIAL` and `BLOCKED` alike, so `git status` is clean. A fresh agent with no
   other context must be able to continue from it. When your context runs low, stop at a clean commit and return
   `PARTIAL` rather than starting another step.

### Progress tracking

Progress is visible in the Claude Code Task list (`TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`; load them with
`ToolSearch` if they are deferred). Only the phase agent has these tools: subagents do not get them, so the phase
agent keeps the whole list and the subagents report to it. Without them (e.g. Codex), skip this section.

- **Phase agent:** check `TaskList` first and reuse open tasks. One task per subphase, subject `<n.m> <title>`:
  `in_progress` with the subphase agent as owner while it runs, `completed` once its row is `[x]`; a `[~]` row keeps
  its task `in_progress` for the next agent. When a subphase agent sends its plan, create one task per piece, subject
  `<n.m> piece: <change>`, blocked by the previous piece where order matters. Mirror each progress message into the
  tasks (`in_progress` when a piece's Haiku agent starts, `completed` once the subphase agent committed it, a one-line
  status in the subphase task's description after each commit). Pieces left on `PARTIAL` or `BLOCKED` stay open,
  with what remains in their description.
- **Subphase agent:** report to the phase agent with `SendMessage` to `main` (load it with `ToolSearch`; skip this if
  it is unavailable). Send the list of pieces once the plan is written, a line when you spawn a piece's Haiku agent,
  and a line after each commit (`<n.m>: piece <k> committed at <hash>`, or what went wrong). Keep the messages to a
  few lines; they do not replace the report or the final `DONE`/`PARTIAL`/`BLOCKED` line.
- **Haiku subagent:** no tracking of its own; its final message (files changed, what is unfinished or unclear) is
  its status, and the subphase agent passes the gist on.
- Tasks are a live view only; the Status board and Reports stay the record.

## Status board

Legend: `[ ]` not started · `[~]` in progress · `[x]` done. A phase is `[x]` once all its subphases are and its
**Done when** holds.

| Phase | Title | Status | Last commit | Note |
|---|---|---|---|---|
| 1 | Cleanup, one type per concept, Swift strings | [x] | c05a4dd6 | baseline in `doc/performance/2026-10-18-refactor-baseline/` |
| **2** | **Swift types** | [x] | 15a53089 | live check without mouse checks; bench within 10% |
| 2.1 | Pseudo-enums → enums and OptionSets | [x] | 51ef4736 | flags left to 2.2 |
| 2.2 | Bit fields → OptionSets and Bools | [x] | 78fcf65e | `Definitions.swift` deleted |
| 2.3 | Typed IDs | [x] | c97529ef | own border/proxy windows stay raw |
| 2.4 | `Int32` → `Int`, sentinels → optionals | [x] | 4153f4ae | ids no longer integer literals |
| 2.5 | Explicit orders, `Table` → `Dictionary` | [x] | e3b71ba1 | queries already in window server order |
| 2.6 | Verification: live check, benchmark | [x] | c50e63e3 | mouse checks skipped (posting denied) |
| **3** | **Models and managers as types with methods** | [x] | 21da3d9e | live check 28/28 incl. mouse; bench within 10% (same-session baseline) |
| 3.1 | Tree and views | [x] | 7f4762fc | methods converted; make + 112 tests pass |
| 3.2 | Windows, applications, rules | [x] | 4e0c6d6b | `WindowManager.shared`; split into 15 extension files |
| 3.3 | Spaces, displays, processes | [x] | bd28acbe | ID members; `SpaceManager/DisplayManager/ProcessManager/MissionControl.shared` |
| 3.4 | Events, signals, rendering, input, SA, startup | [x] | e12b2e71 | `EventHandler`, `EventSignals`, `Border`/`TabBar` statics, `MouseState/ScriptingAddition.shared`, `SLS.connection` |
| 3.5 | Platform boundary | [x] | 2a055797 | no raw SLS/AX calls outside `Platform/`; `SkyLight+Windows.swift`, `MachOSymbol` |
| 3.6 | Verification: done-when sweep, live check, benchmark | [x] | 21da3d9e | sweep clean; capture image ownership fix |
| **4** | **Compiler-checked isolation** | [~] | 4bd853c4 | |
| 4.1 | Mouse event tap state | [x] | 4bd853c4 | `MouseTapState`; tap no longer reads `MouseState` |
| 4.2 | Process table | [x] | d21e375e | Carbon posts `ProcessKey`s; table and startup enumeration on yabai.wm |
| 4.3 | Remaining globals | [x] | 4f34f728 | `Log.verbose` Atomic, SA socket paths immutable, Mission Control Mutex, tab bars on `WindowManager` |
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
- **Edit single files with the Claude Code tools, not scripts.** Read a file with `Read`, then change it with `Edit`
  (or `Write` for a new file or a full rewrite); use `Edit`'s `replace_all` for a rename within that file. Do not
  change one file with a Python script, `sed`, `perl`, `awk` or shell redirection (`>`, `tee`, heredocs). Scripts are
  fine for mass edits across many files, where making one `Edit` per file would be impractical.
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

The goal is to mark managers and models `@WM` and remove all `nonisolated(unsafe)` globals (the `nonisolated(unsafe) static let shared` of
`WindowManager`, `SpaceManager`, `DisplayManager`, `ProcessManager` and `MissionControl`, `g_mouse_state`, `g_verbose`,
`g_sa_socket_file`, `tabBarList`). Fix each compiler error by giving the state one owner,
not by adding `nonisolated(unsafe)`. 4.1–4.3 give the state touched from other threads its owner first, so 4.4 can
flip the annotations.

- **4.1 Mouse event tap:** the tap (main run loop) reads `MouseState`: split the tap's part into `Atomic`/`Mutex`
  state with a NOTE naming its threads.
- **4.2 Process table:** the Carbon process handler mutates the table on the main thread while `@WM` handlers read
  it: make the handler only post events and keep the table `@WM`, or give it a `Mutex`.
- **4.3 Remaining globals:** `g_verbose` → `Atomic`; the SA socket path → immutable after startup or `@WM`;
  `MissionControl.shared` (mode and Dock observer), `tabBarList` get an owner.
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
- ~~Phase 1 had no live check; rules and scratchpads (storage changed) need one.~~ Checked live in 2.6 (rules,
  `rule --apply`, one-shot rules, scratchpad toggles across spaces): no regression.
- Sentinel ids (2.4) changed a few paths that only the window server's "no id" reaches: the daemon no longer passes
  id 0 on (no view for space 0, no gesture/warp for display 0, no layout of a view whose space has no display, no
  `display_manager_focus_display` window search without a space). `query --windows` `is-visible` of a window on no
  space is now false (was true through `space_is_visible(0)`); `query --displays --window/--space` without a display,
  `space`/`window --display` without a current space and `query --tree` without an active space now fail. 2.6 found
  no regression in the reachable neighbours (hidden and minimized windows, the same queries and commands with ids,
  one display), but could not produce a real nil id; later live checks keep watching.
- Pre-existing crash (not from the refactor; seen in the C build since 2026-10-14 and again in 2.6 with the
  installed pre-phase-2 build): quitting several applications quickly (`live.py cleanup`) traps in
  `window_manager_group_window_frames` on `capture.window.application!` (`WindowAnimation.swift`), from
  `windowDestroyed` → `space_manager_untile_window` → `tree_flush`; related reports trap in `window_unobserve`. A
  window of an already terminated application is still laid out. Needs its own fix commit (not a refactor change).
- Live checks run in an environment where synthetic mouse posting is denied (`mouse trusted` prints false even outside
  the sandbox, 2026-10-19), so `live.py run` cannot run as is; 2.6 ran a temporary copy without the
  focus-follows-mouse and alt-drag checks (T6, T7). Those two need the user's terminal or a granted posting
  permission. Posting worked in 3.6's session, where `live.py run` passed 28/28 including T6/T7; check
  `mouse trusted` before each live check, since it depends on the session.
- `Grid` (YabaiCore `Rule.swift`) keeps `UInt32` fields: sscanf "%d" writes into them and the grid math relies on
  unsigned wrap for negative input. Making it `Int` changes behavior for negative grids; decide in phase 5.4.
- 3.6's live check did not cover a session with the scripting addition unloaded (space moves without SA); a later
  live check should.

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

### 2026-10-18 Subphase 2.1 [x]
- Commits: 40c21c73..51ef4736 (plus this report)
- Done: every RawRepresentable pseudo-enum and global enum constant except the 2.2 flags became a Swift enum next
  to its user: tree/view (`ConLayout`, `ConOrientation`, `ConZoom`, `TreeResult`, `TreePosition`, `TreeOrientation`,
  `FocusWrapping`, `ViewType`), tab bar (`TabBarStyle`, `TabBarBackdrop`, `TabBarState`), window manager
  (`WindowOperationResult`, `WindowLayout`, `FocusFollowsMouse`, `PurifyMode`, `WindowOrigin`, `FrontProcessMode`),
  spaces/displays (`SpaceOperationResult`, `SpaceLayoutResult`, `DisplayArrangementOrder`, `ExternalBarMode`,
  `DockOrientation`), mouse (`MouseAction`, `MouseDropAction`, `MouseModifierKey`, `MouseModifiers` OptionSet,
  `DockSwipe` field namespace), `AnimationEasing` (curves as `value(at:)`), `MissionControlMode`. Merged with
  YabaiCore: `window_split`→`WindowSplit`, `layerValue`/`LAYER_AUTO`→`WindowLayer.level` (`Window.layer` is a
  `WindowLayer`), `TYPE_*`→`ValueType?`, `HANDLE_*`→`ResizeHandle`. Config names come from String raw values through
  YabaiCore's generic `parseConfigChoice`; the `*Names` index tables and `tab_bar_parse_style/backdrop` are gone.
  `Definitions.swift` holds only `view_flag`, `window_flag`, `window_rule_flag`.
- Output changes: golden `config mouse_modifier` before `mouse_state_init` prints `fn` instead of `(null)` (the
  property now defaults to fn; the daemon always initialized it to fn, so no user-visible change, no CHANGELOG).
- Verification: `make`, `make test` (112 tests: 70 Yabai + 42 YabaiCore; the two tab bar parse tests became one
  names test), golden re-recorded for the one record above.
- Decisions: the op-error types are named `WindowOperationResult`/`SpaceOperationResult` (they include `.success`;
  5.1 turns them into `Error`s). `window --split` parses into `SplitOrientation` (`.fixed`/`.toggle`) instead of -1.
  An unknown `abs`/`rel` type stays a nil `ValueType?` with the old behavior (no change for gap/padding, absolute for
  move/ratio). `MouseState.modifier` stores the config key; the tap compares `MouseModifiers`.
- Next: 2.2 (`view_flag`, `window_flag`, `window_rule_flag` in `Definitions.swift`, then delete the file).
- Notes for the next agent: `Edit` works on files read with `sed`/`grep`, so large files need no full `Read`.
  Converting a switch to an exhaustive enum turns `default:` into a "will never be executed" error. New pitfall about
  `.none` cases is in `AGENTS.md`.

### 2026-10-18 Subphase 2.2 [x]
- Commits: ccdfef12..78fcf65e (plus this report)
- Done: `View.flags` → `ViewOverrides` OptionSet (`overrides`: layout, the paddings, gap, auto padding a space set
  itself) and Bools `isPaddingEnabled`, `isGapEnabled`, `isValid`, `isDirty`, `isUnpadded`; the spacing selector is
  `enum ViewSpacing` with `.view`/`.spaceManager` key paths and `.override`. `Window.flags` → Bools `hasShadow`,
  `isFullscreen`, `isMinimized`, `isFloating`, `isSticky`, `isWindowed`, `isMovable`, `isResizable`;
  `Window.rule_flags` → `isManagedByRule`, `isFullscreenByRule`, `mouseFollowsFocusByRule: Bool?` (MFF + MFF_VALUE).
  `RuleProp` → `Bool?` in `RuleEffects` (`mff` renamed `mouseFollowsFocus`). AX notification masks →
  `WindowNotifications` / `ApplicationNotifications` OptionSets (`.all`, `.required`). `Definitions.swift` deleted.
- Output changes: none (golden unchanged).
- Verification: `make`, `make test` (112 tests: 70 Yabai + 42 YabaiCore, golden included) at 78fcf65e.
- Decisions: Bools rather than OptionSets for window and view state (only set/check/clear was used). `View()` keeps
  padding and gap disabled by default (tests build bare views); `view_create` enables them as before. The query
  property masks (`WindowProperty` etc., `UInt64` constants in YabaiCore `Query.swift`) stay for phase 5.5 (Codable
  queries).
- Next: 2.3 (typed IDs).
- Notes for the next agent: free functions like `view_is_dirty`, `window_can_move` now just read the Bools; phase 3
  folds them into the models.

### 2026-10-18 Subphase 2.3 [x]
- Commits: b9d85070..c97529ef (plus this report)
- Done: `WindowID`/`SpaceID`/`DisplayID` in YabaiCore `Identifiers.swift` (RawRepresentable structs of the C width;
  Hashable, Comparable, Sendable, printed as the number, integer literals allowed). They replace the raw ids in
  models (`Window.id`, `Con.window_id`, `View.sid`/`insertion_point`, tab bars, borders, scratchpads), managers
  (current/last/focused ids, `Table` keys, `LabelList<ID>` now generic), events, selectors (`SelectorContext`,
  `DisplayQuery`, `SpaceQuery`, `WindowQuery.id`, `QueryTarget`), `Rule.did/sid`, `WindowInfo.id`, `SpaceWindow`,
  `SpaceList`/`SpaceLayout` math and the `SLS`/`AXElement` wrappers, which now take and return typed ids.
- Output changes: none (golden unchanged).
- Verification: `make`, `make test` (112 tests: 70 Yabai + 42 YabaiCore, golden included) at c97529ef.
- Decisions: `.rawValue` only at C calls (CPrivate, SkyLight, CoreGraphics), JSON/env output (`Int32(bitPattern:)` as
  before) and the SA payload (`SAPayload.pack(_: WindowID/SpaceID)`; `sa_window_order` holds `WindowID`s). yabai's
  own windows that are ordered against managed ones (`TabBar.id`, glass panel id, feedback window) are `WindowID`;
  border edge windows (`Border.ids`) and animation proxies (`proxy.id`) stay raw `UInt32` handles that only reach
  SkyLight. Signal contexts still carry ids as raw pointers (3.4 types the signal payload). C-shaped
  pointer+count window lists (`UnsafeMutablePointer<WindowID>`) stay for now.
- Next: 2.4. Sentinel ids (`0`) remain; `ExpressibleByIntegerLiteral` keeps `== 0`/`= 0` compiling, so 2.4 can drop
  that conformance to find every sentinel once ids are optionals.
- Notes for the next agent: compile-error-driven mass edits worked well (a script reading `swift build` errors and
  appending `.rawValue`/wrapping), but review its output: it also "fixes" Swift declarations that should change type.
  New pitfall (ambiguous `.map(ID.init)`, C out-parameters) is in `AGENTS.md`.

### 2026-10-19 Subphase 2.4 [x]
- Commits: 2c675624..4153f4ae (2c675624 from an earlier session; plus this report)
- Done: 2c675624 made `Int32` `Int` outside C and wire formats. cca8ca95: `WindowID`/`SpaceID`/`DisplayID` lost
  `ExpressibleByIntegerLiteral` (tests keep it in `tests/*/IdentifierLiterals.swift`) and gained `init?(nonzero:)`;
  every 0 id is now nil: model fields (focused/last window, current/last space and display, `Con.window_id`, insertion
  points, tab bar/border/feedback/glass ids, mouse ids), id-returning lookups (`window_space`, `display_space_id`,
  `display_manager_*_display_id`, `space_manager_*_space`, `ax_window_id`, …), selectors (`SelectorContext`,
  `Selection<DisplayID?>`), `RuleEffects.did/sid`, `SpaceList`/`SpaceLayout` results. `Window(id:)`, `View(sid:)`,
  `WindowInfo(id:)` replace the zero defaults; `Window.isDestroyed` replaces the zeroed id of `window_destroy`.
  4153f4ae: -1 sentinels (`saPayloadCurrent: Bool?`, reconcile surplus/deficit `Int?`, `backdropRadius: CGFloat?`,
  child-window walk), Dock pid `pid_t?`, test `Int32` helpers.
- Output changes: none in the golden (unchanged). JSON, signal env and SA bytes print 0 for nil via `?.rawValue ?? 0`.
  Degenerate window-server cases listed in **Open issues**.
- Verification: `make`, `make test` (112 tests: 70 Yabai + 42 YabaiCore, golden included) at 4153f4ae.
- Decisions: remaining fixed-width integers are C/ABI or wire (connection ids, fds, pids, window levels, exit codes,
  SA payload, sscanf buffers, `Token.positiveInteger`'s C int wrap, JSON `Int32(bitPattern:)`), plus `Grid` (Open
  issues). Int results that print 0 (`space_manager_mission_control_index`, arrangement index) stay for 5.5.
  `tab_bar_hit_test` keeps its out-pointer (`WindowID?`); phase 3 can return an optional.
- Next: 2.5.
- Notes for the next agent: `swift build` stops after the first failing batch; to see every type error of the Yabai
  target at once, run `swiftc -typecheck -wmo -continue-building-after-errors` over `Sources/Yabai` with
  `-I .build/out/Products/Debug` and the CPrivate/OSAX module maps (see AGENTS.md pitfall).

### 2026-10-19 Subphase 2.5 [x]
- Commits: 176f52db..e3b71ba1 (plus this report)
- Done: 176f52db sorts the table loops whose order can show: `rule_apply`/`rule_reapply_all` and
  `window_manager_find_application_windows` (app hide/show/terminate tiling) by window id, `window_manager_begin` by
  pid, the `*_for_all_spaces` config loops, `space_manager_handle_display_add` and `tab_bar_refresh_all` by space id.
  e3b71ba1: manager tables are `[pid_t: Application]`, `[WindowID: Window]`, `[WindowID: View]`, `[SpaceID: View]`,
  `[ProcessKey: Process]` (new `ProcessKey`, both PSN longs) and `Set`s for the lost-focus/front-switch events;
  `Table.swift` deleted; AGENTS.md updated.
- Output changes: none (golden unchanged). Queries never read the tables: windows, spaces and displays come from
  window server lists (space window order, Mission Control order, arrangement), so the old Table NOTE was stale.
- Verification: `make`, `make test` (112 tests: 70 Yabai + 42 YabaiCore, golden included), `swift build -c release`.
- Decisions: `add` keeps the existing value like `table_add` (`if dict[k] == nil`), except after an explicit remove
  (space swap). Unsorted loops left as they are where order has no visible effect: opacity/purify updates, border
  refreshes (each border orders against its own window), the SkyLight notification id list.
- Next: 2.6 (verification; the live check could include `rule --apply` and app hide/show with several windows).
- Notes for the next agent: Dictionary iteration order differs between runs; any new loop over `wm.window`,
  `sm.view` or `pm.process` whose order can show must sort.

### 2026-10-19 Subphase 2.6 [x]
- Commits: none in code; verified c50e63e3 (plus this report).
- Done: **Done when** sweep: no RawRepresentable pseudo-enums or global enum constants (only typed ids, OptionSets
  and plain constants remain), `Table` gone, golden changes explained in 2.1–2.5. Live check of a release build of
  HEAD (`deploy.sh install`, restored afterwards; one display, laptop only, like the baseline): `live.py run` without
  T6/T7 23/23, `extra` 5/5 (cross-display and ctrl+arrow skipped); own checks 30/34 with the 4 misses being errors
  in the check script, rerun by hand and passing: `rule --add … manage=off` + `rule --apply <label>`, `rule --apply
  <args>` (no rule stored), one-shot rule (first new window floats, rule removed, second tiles), scratchpad assign /
  toggle hide-show / toggle from space 5 and back / clear (also while hidden), hiding and showing TextEdit with 3
  windows (leaves and rejoins the tree, `is-hidden`, focus moves off), minimize/deminimize, `query --displays
  --window/--space`, `query --tree`, `space`/`window --display 1`, `display --focus` current. Probes compared with the
  installed build gave identical results. No new crash report from HEAD.
- Output changes: none.
- Verification: `make`, `make test` (112 tests) at c50e63e3. Bench, standard fixture on space 4: matched flat tree
  (autotiling off, float → tree, balance; two runs each, same session) HEAD tab/rotate/split medians 33.7/147.2/31.8 ms
  vs installed 47.9/141.8/41.5 ms (rotate +3.8%, focus faster). Setup's nested tree as in phase 1: HEAD
  31.9/129.5/32.5 ms vs phase-1 baseline 29.2/124.9/30.0 ms (+9%, +4%, +8%; within 10%). A first installed run on
  the nested tree before the deploy gave 24.0/111.9/22.7 ms, but the restart rebuilt a different tree, so it is not
  a matched pair.
- Decisions: a stale `~/.local/state/yabai/yabai.before-deploy` (2026-10-18 09:29, older than the binary
  `update-yabai-fork` installed at 21:59) would have made `deploy.sh restore` install an old build; it was moved to
  `yabai.stale-before-deploy-20261018` before the deploy, and restore put back the current binary (sha256 eabeafba…).
- Next: phase 2 done-when holds; phase 3. The crash and mouse-posting items are in **Open issues**.
- Notes for the next agent: the restored installed build crashed once in `live.py cleanup` (pre-existing, Open
  issues); launchd restarts it, which resets layouts again. Check `crashes.py` and which binary's UUID a report names
  (`dwarfdump --uuid`) before blaming the build under test.

### 2026-10-19 Subphase 3.1 [x]
- Commits: 0e5fc200..7f4762fc (written afterwards by the 3.2 agent from git history; the 3.1 agent left no report).
- Done: `Tree.swift` became `Con.swift`; `Con` has the tree primitives and i3 operations as methods, `View` owns
  layout/flush (`TreeView.swift`), tree navigation and cross-display moves are `WindowManager` methods
  (`WindowManagerTree.swift`); C-origin comments in the tree tests removed.
- Output changes: none (golden untouched).
- Verification: `make`, `make test` (112 tests) per the board note.
- Decisions: unknown (no report).
- Next: none for 3.1.
- Notes for the next agent: none recorded.

### 2026-10-19 Subphase 3.2 [x]
- Commits: d2c252a8..4e0c6d6b (d2c252a8..09932c6f by an earlier agent, paused without report; ffdf0670..4e0c6d6b
  by this one).
- Done: window, application and rule operations are methods (`Window`, `WindowID`, `Application`, `Rule`,
  `WindowManager`); `WindowManager.swift` split into `WindowManager+{Appearance, Discovery, Focus, Geometry, Layout,
  Lookup, Management, Placement, Reconciliation, Registry, Rules, Scratchpad, Startup, Toggles, Tree}.swift`
  (`WindowManagerRules/Tree.swift` renamed); all `WindowManager` state has Swift names (tab bar: `tabBarHeight`, …,
  `tabBarFocusedColorIsCustom`; scratchpads: `scratchpads`, `scratchpadGrid`, …); `g_window_manager` and
  `window_manager_global()` replaced by `nonisolated(unsafe) static let shared` (phase 4 removes the
  `nonisolated(unsafe)`); C-name comments in the scope files reworded; stale `window_manager_global()` pitfall removed
  from `AGENTS.md`, file names there updated.
- Output changes: none (golden untouched; config keys keep their snake_case CLI names).
- Verification: `make` (no warnings), `make test` 112 tests incl. golden, at each of ffdf0670, 9eb0a863, 4e0c6d6b.
- Decisions: piece 1 (property renames) was run as a script by this agent before the user's "Haiku pieces strictly"
  reminder arrived; a revert was denied, so it was reviewed and committed as is. Pieces 2–3 ran through Haiku agents.
- Next: belongs to later subphases: `space_manager_can_use_known_focus`, `windowDidReceiveFocus`, `mouse_drop*` still
  take `wm`/`sm` parameters (3.3/3.4); `WindowAnimation.swift`'s `window_manager_*`/`window_frame_*` free functions
  (3.4); `connection_global()`, `process_manager_global()`, `space_manager_*`/`display_manager_*` calls inside the
  3.2 files and raw `SLS*`/AX calls in `Window.swift`, `WindowManager+Lookup/Appearance.swift` (3.3–3.5);
  `Application.observe()` still logs `application_observe:` in its debug text.
- Notes for the next agent: config keys (`"tab_bar_height"`, `runConfig("scratchpad_grid…")`) and golden records
  share spellings with old property names; restrict mass renames to member uses, not string literals.

### 2026-10-19 Subphase 3.3 [x]
- Commits: f8df0e16..bd28acbe (6 pieces, each through a Haiku agent, plus this report).
- Done: `Process.swift` split out (`isTerminated`, `attachRunningApplication()`, KVO observation as `Process` methods in
  `Workspace.swift`); `ProcessManager.shared` (`process(for:)`, `activeSpace(forConnection:)`, `begin()`);
  `Workspace` (was `WorkspaceContext`, `begin()`, `dockPID`); `MissionControl.shared` (`mode`, `isActive`,
  `observe()`/`unobserve()`), `connectionNotificationHandler`; `DisplayID.swift` (`uuid`, `init?(uuid:)`,
  `init?(arrangement:)`, `init?(containing:)`, `currentSpace`, `spaces`, `arrangement`, `previous`/`next`, statics
  `main/active/dock/underCursor/first/last/all/count`, `constrainedBounds`, `focus(space:)`, `focusSpace(_:)`) and
  `DisplayManager.shared` (dock/menu bar, arrangement, `focusWindow(at:)`); `SpaceID.swift` (`display`, `windows`,
  `isUser/isFullscreen/isVisible`, `SpaceID.all` in Mission Control order, `missionControlIndex`, `active`,
  `underCursor`, `moveWindow(s)`, `waitForWindow(s)`, `isLastUserSpace`); `SpaceManager.shared` with Swift property
  names (`views`, `currentSpaceID`, …) split into `SpaceManager.swift` (views), `+Layout` (layout/padding/tiling),
  `+Operations` (focus/switch/swap/move/create/destroy), `+SpaceLayout` (reconcile, was `SpaceLayout.swift`).
  `space_manager_can_use_known_focus` is `WindowManager.canUseKnownFocus(front:pendingFocus:)`.
- Output changes: none (golden untouched; debug texts and config keys keep their old spellings).
- Verification: `make` (no warnings), `make test` 112 tests incl. golden, at every piece's commit.
- Decisions: IDs got the stateless queries (statics for whole-set ones), managers the state-dependent ones;
  `DisplayID.center` is non-optional (the comparator uses `?.center ?? .zero`, as CGDisplayBounds gives for an invalid
  id); `Process.isObservable()` stays a method since it stores the policy; phase 4 text now names the `shared`
  instances instead of the removed globals.
- Next: for 3.4: `connection_global()`/`g_connection` (Yabai.swift), `scripting_addition_*` calls in the space files,
  `pending_window_focus()`, `psn_equals`, `string_equals`, `mouse_drop(SpaceManager.shared, wm, …)` parameters,
  debug texts with C names. For 3.5: raw `SLS*`/AX calls in `SpaceID.swift`, `DisplayManager.swift`
  (`element(at:)`), `SpaceManager.swift`. Phase 5: C names in `Serialize.swift` doc comments
  (`space_manager_query_*`, `display_manager_query_displays`) and YabaiCore doc comments (`space_layout_*`,
  `space_manager_move_space_replacement`).
- Notes for the next agent: Haiku agents did call-site rewrites with a balanced-paren Python script
  (/tmp/displays/rewrite.py, /tmp/spaceids/rewrite.py, outside the repo); it skips string interpolations, so grep for
  leftovers. A stored property and a method with the same base name (`view` vs `view(for:)`) were avoided by renaming
  the dictionary to `views`.

### 2026-10-19 Subphase 3.4 [x]
- Commits: 3cf826e3..e12b2e71 (11 pieces, each through a Haiku agent, plus this report).
- Done: `SLS.connection` replaces `connection_global()`/`g_connection`; Helpers/Log: `OSTimer`, `RGBAColor(hex:)` (`argb`),
  `UnixSocket`, `String.bytesEqual`, `SLS.disableShadow`, `AXUIElement.windowID/pid`, `ProcessSerialNumber.isSame(as:)`,
  CGRect/CGPoint/Float helpers, `Log.verbose`, `debugMessage`; `Daemon.run`/`Daemon.isRoot` and `Service.install()` etc.;
  `ScriptingAddition.shared` (`focusSpace(_:)`, `moveSpace(_:after:focus:)`, `setLayer(_:of:)`, `orderWindows(_:)` with
  `WindowOrder`, `socketPath`, …); `@WM final class EventSignals` with typed `SignalSubject` (no raw pointer contexts),
  describe functions as `PendingSignal` methods; `Border` statics (`refresh(_:)`, `refreshSpace(of:)`, `windowMoved(_:)`, …)
  with a `BorderUpdate` OptionSet; `TabBar` members (`render(frame:card:above:entries:count:)`, `TabBar.refreshAll()`, …),
  `weak var owner: Con?` instead of the C callback, `TabBarGlass` statics; `WindowPlacement` (was `window_capture`),
  `WindowManager.animateWindows/animateWindow/setWindowFrames`, `Window.setFrame`, `WindowFrameGroup.groups(for:)`;
  `MouseState.shared` with camelCase fields, `resolveDrop(onto:at:)`, `drop(_:from:onto:in:at:)`, `beginEventTap(mask:)`;
  `@WM final class EventHandler` with the handlers as methods in `EventHandler{,+Window,+Space,+Mouse,+System}.swift`,
  `pending_*` accessors replaced by atomic ops at the call sites, `Process.nameAndPID`/`launchRetryDelay`,
  `ResizeHandle(at:in:)`, `WindowManager.updateWindowNotifications()`; debug prefixes name Swift methods
  (`WindowManager.addExistingApplicationWindows:`, …).
- Output changes: none (golden untouched); only verbose debug texts changed their prefixes.
- Verification: `make` (no warnings), `make test` 112 tests incl. golden, at every piece's commit.
- Decisions: per-window `Border` class became internal so its statics form the API; `EventHandler`/`EventSignals` are
  `@WM` classes with `static let shared` (compiles in Swift 6.4); atomics stay global `let`s; `MouseState.setDefaults()`
  kept (tests and golden depend on `.none` defaults before startup); `ScriptingAddition` reaches its `@WM` cache through
  `.shared` inside `WM.assumeIsolated` closures (capturing `self` is rejected as a data race).
- Next: for 3.5: `macho_find_symbol` (Platform/MachO.swift) and the raw SkyLight/AX calls. Phase 5 / 6.4: IPC
  `message_loop_begin`, `daemon_message_handle`, the `var connection` alias in `Serialize.swift`. Optional: some
  `@Test` display names still carry C names.
- Notes for the next agent: the event handler files were re-indented into extensions, so git shows them as new files;
  compare with a whitespace-normalized diff. Methods named like Darwin functions (`UnixSocket.connect/close`) must
  call `Darwin.` explicitly, and a method `notify(_:)` would shadow the global `notify(_:_:)` (hence
  `ScriptingAddition.report(_:)`).

### 2026-10-19 Subphase 3.5 [x]
- Commits: 157cd2c7..2a055797 (7 pieces, each through a Haiku agent, plus this report).
- Done: AX calls go through `AXUIElement`/`AXObserver`/`AXError` extensions in `Platform/AX.swift` (`attribute`,
  `attributeValue`, typed getters, `setAttribute(_:to:)`, `perform`, `element(at:)`, `withEnhancedUserInterfaceDisabled`,
  `AXError.name`); `AXElement`, `axErrorName` and `axEnhancedUIWorkaround` are gone. SkyLight calls for the daemon's own
  windows are in the new `Platform/SkyLight+Windows.swift` (`SLS.region/newWindow/order(_:_:_:relativeTo:)` with
  `SLS.Order`, setters, `moveWindow(s)`, `context`, `cornerRadius`, `SLS.Transaction`, connections, `captureImage`); the
  rest in `SkyLight.swift` (`SLS.FrontProcessMode`, `setFrontProcess`, `postEventRecord`, `setMenuBarAlpha`,
  `registerNotification`, `moveWindows(_:_:toSpaceByCompatID:)`, `associatedWindows`, `findWindow`, …). Focus helpers
  take `ProcessSerialNumber` by value. `macho_find_symbol` is `MachOSymbol.address(of:inImage:)`. CPrivate lost five
  unused declarations and `CONNECTION_CALLBACK`; C-era comments in CPrivate.h and Platform reworded.
- Output changes: none (golden untouched).
- Verification: `make` (no warnings), `make test` 112 tests incl. golden at every commit; `swift build -c release`
  after the CPrivate change. No live check (3.6).
- Decisions: wrappers keep the connection as first parameter like the existing ones; border edge and animation proxy ids
  stay raw `UInt32` (2.3) and are wrapped with `WindowID(_)` at the calls. Failure-only differences: `SLS.windowAlpha`
  and `windowBounds` return nil on a non-success result (callers keep their old defaults); proxy and feedback windows
  skip their setters when creation fails (old code called them with id 0); `SLS.newWindow(_:shape:options:tags:)`
  returns nil without an empty region; `orderIn` no longer reuses a stale ordered-in flag after a failed query.
- Next: 3.6 should exercise focus (with/without raise), scratchpad hide, space moves without SA, borders, tab bars,
  insertion feedback and animations live, since these call paths changed shape. CGWindowListCreateC and other public
  CoreGraphics calls stay outside `Platform/` (not SkyLight/AX).
- Notes for the next agent: a C function typedef (`connection_callback`) does not work as a Swift parameter type; the
  wrapper spells `@convention(c)` (pitfall added to AGENTS.md).

### 2026-10-19 Subphase 3.6 [~] (handover, stopped by user)
- Commits: none. Last commit 8816cfb1. Nothing live was run (no deploy; installed binary untouched).
- Sweep done (by the stopped agent): no raw SLS/AX calls outside `Platform/`, no manager `*_global()` accessors;
  `stdout_global`/`environ_global` are CPrivate accessors for libc globals and stay. Two code leftovers remain:
  1. `IPC/MessageLoop.swift`: `message_loop_begin`/`daemon_message_handle` → `enum MessageLoop { static func
     begin(socketPath:); static func handle(_:) }`, call sites in `Yabai.swift` and `EventLoop.swift`, C-origin
     comments in that file reworded.
  2. `IPC/Serialize.swift`: drop the global `var connection` alias; uses → `SLS.connection`.
- State: piece 1's Haiku agent was stopped mid-run. Its edits are **uncommitted and unreviewed** in
  `EventLoop.swift`, `IPC/MessageLoop.swift`, `Yabai.swift` (not built or tested). Review that diff against piece 1
  above; finish it (or `git checkout` those three files and redo it), build, test, commit.
- Next: piece 2, then the live check (deploy, `live.py run` without T6/T7 as in 2.6, plus focus with/without raise,
  scratchpad hide, space moves without SA, borders, tab bars, insertion feedback, animations), bench against the
  baseline as in 2.6, restore the installed binary, return focus to the terminal. Then the phase agent marks phase 3
  `[x]` and starts phase 4.

### 2026-10-19 Subphase 3.6 [x]
- Commits: 4db7c651..21da3d9e (made outside the workflow, partly by another agent; reviewed here), plus this report.
- Done: reviewed 4db7c651 against handover piece 1 (`enum MessageLoop` with `begin(socketPath:)`, `handle(_:)`,
  private `run`/`read`; call sites in `Yabai.swift` and `EventLoop.swift`; C-origin comments reworded; `Darwin.read`
  where the method shadows it) and 45c4e297 against piece 2 (global `connection` alias gone, uses are
  `SLS.connection`): both complete, no gaps, no Haiku pieces needed. Done-when sweep at HEAD (dc446a3b): no top-level
  `snake_case` functions in `Sources/Yabai`, no raw `SLS*(`/`AXUIElement*`/`AXObserver*`/`_AX*` calls outside
  `Platform/`; the only `*_global()` left are CPrivate libc accessors (`stdout_global`, `stderr_global`,
  `environ_global`).
- Output changes: none.
- Verification: at HEAD dc446a3b (includes phase 4 commits 88c374ac..dc446a3b made outside the workflow): `make`
  without warnings, `make test` 112 tests pass incl. golden. Live check and bench were run by another agent (Codex)
  before the 4.x commits, one display, synthetic mouse posting available:
  - First `live.py run` 27/28 with a yabai restart; crash reports showed the known app-quit crash and an animation
    failure from capture image ownership, fixed in its own commit 21da3d9e (the SLS capture wrapper retains the
    image before releasing the array; make + 112 tests pass).
  - After the fix: `live.py run` 28/28 incl. mouse (T6/T7), animation and fullscreen checks, stable daemon PID;
    extra 5/5 (frozen-app focus included; cross-display skipped, one display). Targeted checks passed: border
    geometry, scratchpad hide/show, space moves, focus with and without raise, tab bar and insertion commands;
    screenshots showed the glass tab strip and the insertion preview.
  - Bench: against the historical baseline numbers rotate was +10.05%; a same-session run of the phase 1 baseline
    build (isolated temp copy, bench scripts unchanged) against HEAD: baseline run 1 17.3/119.7/30.0 ms
    (tab/rotate/split), HEAD run 1 16.2/109.9/19.0 ms; both HEAD runs within 10% of the baseline's two-run averages
    on all three workloads.
  - Installed binary restored, terminal focus verified. The known rapid-app-quit crash still occurred during cleanup
    (Open issues). A session with the SA unloaded was not tested (Open issues).
- Decisions: none.
- Next: phase 4. Its rows 4.1–4.3 are not recorded here; their commits exist (88c374ac..dc446a3b).
- Notes for the next agent: compare bench against a same-session run of the baseline build; the historical numbers
  alone drift around the 10% limit.

### 2026-10-19 Subphase 4.1 [x]
- Commits: 88c374ac (Codex, outside the workflow; reviewed here), 4bd853c4 (one Haiku piece), plus this report.
- Done: 88c374ac splits the tap's state into `MouseTapState` (`MouseHandler.swift`): the modifier and the +1
  `CFMachPort` sit behind `Mutex`es, `tracksFocus` is an `Atomic`, and the click/drag/replay fields are touched only by
  the tap on the main run loop. The callback gets `MouseTapState` as its unretained context and no longer reads
  `MouseState`. `MouseState.modifier` forwards to it, and window and drag decisions stay on yabai.wm. The review found
  no `nonisolated(unsafe)` added and the same behavior. On lifetime, the re-enable on timeout retains the port under
  the lock, and teardown clears it under the lock, then disables, invalidates, removes the source and releases (old
  order). An enable racing teardown hits an invalidated port, which is harmless. The one gap was comments:
  4bd853c4 restores the dropped NOTE (moves reach the tap for glass hover with focus-follows-mouse off) and rewraps
  the overlong NOTE so it names the threads and the +1 port.
- Output changes: none.
- Verification: `make` (no warnings), `make test` 112 tests incl. golden at 4bd853c4. No live check (4.6).
- Decisions: the bit-pattern `UInt` storage of the port stays; a non-Sendable `CFMachPort` cannot go in a `Mutex`
  directly. The failed-`tapIsEnabled` path now also calls `tapEnable(false)` before invalidating, which has no
  effect on a disabled tap.
- Next: 4.2 (its commit 13237fa9 also exists outside the workflow). `MouseState.shared` keeps
  `nonisolated(unsafe)` until 4.4.
- Notes for the next agent: none.

### 2026-10-19 Subphase 4.2 [x]
- Commits: 13237fa9 (Codex, outside the workflow; reviewed here), d21e375e (one Haiku piece), plus this report.
- Done: 13237fa9 makes Carbon's process handler (main thread) post only `ProcessKey` events
  (`carbonProcessLaunched/Terminated/FrontSwitched`). The duplicate-launch, debugger and creation checks, the table
  updates and `isTerminated` now run on yabai.wm. `ProcessManager.begin` enumerates the running processes inside
  `WM.shared.queue.sync`, then installs the handler (with no context pointer). `Daemon.run` runs window manager
  init/begin and space begin in a `WM.shared.queue.sync` too, so earlier Workspace/display events cannot race them.
  Carbon events arrive only once `NSApp.run` starts. No `nonisolated(unsafe)` was added. Review gap: the Carbon handlers
  and the launch-retry event re-posted `applicationLaunched/Terminated/FrontSwitched`, an extra queue hop that let
  later events overtake them. d21e375e calls the application handler in the same event, so the order and the retry
  delay match the old single hop. `process(for:)` takes a `ProcessKey`, and the stale NOTEs (Process `terminated`,
  `processTerminated`, `begin` doc) name the threads.
- Output changes: none.
- Verification: `make` (no warnings), `make test` 112 tests incl. golden at d21e375e. No live check (4.6); startup
  with `queue.sync` from the main thread is first exercised live there.
- Decisions: kept the table `@WM` (plan option 1), not a `Mutex`. The table and `isTerminated` now change when the
  event is handled, not when Carbon posts it: handlers of events queued before the termination see the process
  as alive, as they would if the events had arrived in that order. The KVO observer in `Workspace.swift` still
  writes `process.policy` on the main thread (a model field, left to 4.4/4.5).
- Next: 4.3.
- Notes for the next agent: `ProcessManager.shared` keeps `nonisolated(unsafe)` until 4.4.

### 2026-10-19 Subphase 4.3 [x]
- Commits: c8ff6c81, af4d0152, 8f40c508, dc446a3b (Codex, outside the workflow; reviewed here), 7c842668, 4f34f728
  (one Haiku piece each), plus this report.
- Done: `Log.verbose` is an `Atomic<Bool>` (relaxed). `debug_output` parses into a local and stores it only when parsing
  succeeds, as before. The SA socket paths (`socketPath` for $USER, `sudoSocketPath` for SUDO_UID as root) are `let`s
  resolved in `ScriptingAddition.init`. `--load-sa` keeps its root check and SUDO_UID diagnostic. `MissionControl`
  keeps the mode and AX references in a `Mutex`. The observer, AX and CFRunLoop calls run outside the lock, and
  unobserve takes the references out before it releases them (old order). The tab bar registry is
  `WindowManager.tabBars` (yabai.wm only), and the tap still reads only `tabBarHits`. Review gaps: af4d0152 put
  the daemon's `$USER` on the SA (`daemonUser`) for the lock file and message socket. 7c842668 makes `Daemon` read
  it itself again and adds a NOTE naming the threads that read the paths. 4f34f728 rewrites the Mission Control NOTE
  so it names the threads (main thread at startup, yabai.wm afterwards) and justifies the `@unchecked Sendable`.
- Output changes: none.
- Verification: `make` (no warnings), `make test` 112 tests incl. golden at 4f34f728. No live check (4.6).
- Decisions: Mission Control keeps the `Mutex` instead of waiting for `@WM`, since startup `observe()` runs on the
  main thread while yabai.wm may already handle events. A trial build showed that both `@unchecked Sendable`s are
  needed: `withLock` cannot hand the non-Sendable AX references out of a plain `Sendable` state (region isolation
  error). They stay for 4.5's audit, each with a NOTE.
- Next: 4.4. The `nonisolated(unsafe)` that remain are the `static let shared` of `WindowManager`, `SpaceManager`,
  `DisplayManager`, `ProcessManager`, `MouseState` and `ScriptingAddition`.
- Notes for the next agent: none.
