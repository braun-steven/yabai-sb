# Port yabai (this fork) to Swift — phased handoff plan

> **How to use this file (every agent, every session)**
> 1. This plan lives in the repo as `doc/swift-port.md` on branch `swift-port` (P0 copies it there). Always work from that copy, never from `master`.
> 2. Read **Context**, **Parity contract**, **Target architecture**, **Agent rules**, **Swift conventions and pitfalls** (the skill `.claude/skills/swift-port-conventions/SKILL.md`) and **Verification checklist** once.
>    **Very important:** run every build, test, analyzer, live-check and other long-output command through the `output-summarizer` subagent, never directly. This keeps the main agent's context window small. Details in **Agent rules**.
> 3. In the **Status board**, find the first phase that is not `[x]`. If it is `[~]`, resume from its last **Handoff log** entry.
> 4. Do only that phase. Its steps, "Done when" and handoff duties are in **Phases**.
> 5. Before you stop, even mid-phase:
>    - update its row in the Status board
>    - append a **Handoff log** entry (template at the end)
>    - commit this file together with the code
>
>    A new agent with no other context must be able to continue from here.

## Status board
Legend: `[ ]` not started · `[~]` in progress · `[L]` code done and live-checked, waiting only for a user step (a `sudo` scripting-addition reload) · `[x]` done.

| Phase | Title | Status | Last commit | Notes |
|---|---|---|---|---|
| P0 | Branch, SwiftPM skeleton, baselines | [x] | 1c5bee6 | layout deviates from the plan, see Target architecture |
| P1 | macOS 27 / arm64 cleanup (still C) | [x] | 174b5b8 | OSAX 2.1.34, reloaded by the user and live-checked |
| P2 | CPrivate module + Platform wrappers | [x] | 872fe3b | no live run (no behavior change); conventions moved to a skill |
| P3 | YabaiCore: geometry, labels, space_layout math, JSON writer | [x] | 2a646a8 | label lists live in Swift behind an opaque C reference |
| P4 | YabaiCore: message tokens/selectors/values, rule parsing | [x] | 348c156 | C handlers keep get_token/token_equals/daemon_fail until P5/P6 |
| P5 | IPC server, CLI client, config domain | [x] | 91aa5b0 | other domains write into a FILE that the Response captures; new test target YabaiTests |
| P6 | IPC display/space/window/query/rule/signal domains + golden tests | [x] | c1854e6 | `rule --list`/`signal --list` json stays C until P11/P7; golden replay is a Swift test |
| P7 | `@WM` actor, event loop, signals | [x] | b36d9e2 | handlers stay C, called from `handle` in EventLoop.swift; signal commands use posix_spawn (no fork in Swift) |
| P8 | Event handlers + Mission Control | [x] | f8b995a | `mouse_drop_action_regions` moves to P13 with `mouse_handler.c` |
| P9 | Display + space model | [x] | 91b5393 | review fixes and the display checks in the second 2026-10-15 entry; `struct view`, `space_manager`, `display_manager` and the view table stay C until their last C users (P11–P13) |
| P10 | Process, application, workspace | [x] | 5f6e386 | `struct process`, `process_manager` and `application` stay C until P11 (window*.c reads them); `g_workspace_context` is gone |
| P11 | Window + window_manager* | [x] | e5f4110 | `struct window` and `window_manager` stay C until their last C users (P12, P13); `window_frame_*` tests belong to `window_animation.c` (P13) |
| P12 | Tree + tree_view | [x] | acc7b04 | `struct con` stays C until P13 (mouse_handler.c, border.c, tab_bar.c use it); the `final class Con` conversion moves there |
| P13 | Border, tab bars, animation, mouse, SA client | [x] | 88f84a5 | all 82 original tests ported; shared-model/bridge cleanup remains for P14 |
| P14 | Remove C, docs, final verification | [x] | 012edf9 | models and docs complete; full release/ASan/TSan verification passes; 103 tests and byte-identical golden; original binary restored; final report in the last handoff entry |

**Rule for `[L]`:** the next phase may start while a phase waits for the user. Never have more than two phases in `[L]`: stop and ask the user to do the pending steps first.

## Context
- The Swift pilot moved the AppKit side of the glass tab bars to Swift: branch `swift-pilot-tab-bar-glass`, commit `69b9085`, files `src/tab_bar_glass.{swift,c,h}`. The user liked it and wants all of yabai in Swift.
- Pre-port codebase: ~16k lines of C, 4k of headers, 1.6k ObjC, 2k OSAX, and 82 unit tests in `tests/src/`.
- **Decisions made by the user (do not re-open):**
  - Minimum **macOS 27**. Drop older code paths. Assume arm64-only: P1 asks the user once before deleting x86_64.
  - **SwiftPM** builds the binary. A **thin `makefile`** keeps the existing entry points.
  - Long-lived branch **`swift-port`**. It merges into `master` only when the user says so after P14.
- What stays non-Swift:
  - the scripting addition (`osax/`, ObjC injected into Dock)
  - the C module `CPrivate`: private declarations, wrappers for APIs Swift cannot call, and MRR notifications

## Parity contract (must hold after every phase)
1. **CLI and socket protocol:**
   - `yabai -m …` encoding (`client_encode_message`, `src/yabai.c:58`)
   - socket `/tmp/yabai_$USER.socket`
   - response handling, including the `FAILURE_MESSAGE` first byte and exit codes (`src/yabai.c:91-130`)
   - every `daemon_fail(...)` text, byte for byte
2. **Query JSON is byte-identical:** key order, number formats (`%.4f`, `JSON_FRAME_FORMAT`), escaping (`json_string` in `src/misc/helpers.h`), separators. Write an ordered writer; never use `JSONEncoder`.
3. **Config, rules and signals:** option names, value syntax, defaults, rule semantics, signal events and their environment variables (`src/event_signal.c`). `doc/yabai.asciidoc` stays correct.
4. **Service and SA:** `--start/--restart/--stop-service`, `--load-sa`, `--version` (`src/misc/service.h`); the SA opcodes and payload layout (`src/osax/common.h`). Bump `OSAX_VERSION` whenever the payload changes.
5. **Build entry points:** `make`, `make install`, `make asan`, `make tsan`, `make test`, `make man` → `bin/yabai`. `scripts/live-tests/deploy.sh` and the external `~/.local/bin/update-yabai-fork` (runs `make install`, copies `bin/yabai`) depend on this.
6. **Performance:** `scripts/live-tests/bench.py` medians stay within 10% of the P0 baseline (Handoff log, P0 entry). Measure the way the baseline was measured (V5 step 2): the numbers depend on the layout state far more than on the build.

## Target architecture
### Package layout (repo root, after P14)
```
Package.swift            // Swift 6; macOS 27, arm64 executable
Sources/
  CPrivate/              // private declarations, resolved function pointers, unavailable-API wrappers, Notify.m (MRR)
  YabaiCore/             // pure Swift logic without window server access
  Yabai/                 // Swift daemon/client, models, IPC/, Platform/, and Swift conversions in Shims/
                         // Definitions.swift = constants/value types; Helpers.swift = shared helpers
osax/                    // arm64e payload/loader built by make; generated byte arrays compiled by the OSAX C target
tests/YabaiCoreTests/    // Swift Testing of pure logic
tests/YabaiTests/        // @testable import Yabai; serialized DaemonState and Golden/ IPC capture
```
- **Build system:** the makefile generates OSAX arrays, then drives SwiftPM. Products land in `.build/out/Products/<Debug|Release>` and are copied to `bin/`. Every variant replaces `bin/`.
- **Linker settings:** CPrivate links Cocoa and private SkyLight. Yabai links Carbon/Cocoa/CoreServices, embeds `assets/Info.plist` and passes `-isysroot $SDKROOT` to stamp the SDK correctly.
- **Remaining C/ObjC:** CPrivate uses C11 and `-fno-objc-arc`; `osax/` retains the injected payload/loader. No YabaiC, unity build, C harness or `@_cdecl` model bridge remains. Earlier handoff entries describe their historical state.
- **Models:** final classes use identity equality, ARC-owned CF resources and weak tree parents. Arrays replace sbuffers/temporary storage. `Table.swift` preserves the C hash-table iteration order for query parity. Rules remain Swift value structs behind explicit heap pointers.

### Concurrency model (replaces `event_loop.c`, `memory_pool.h`, `ts.h`)
- **Global actor `@WM`** with a custom executor on a `DispatchSerialQueue` named `"yabai.wm"`. It owns managers, models and config.
- **`EventLoop.post(_ event: Event)`** is `nonisolated` and callable from any thread. It does `queue.async { WM.assumeIsolated { handle(event); signals.flush() } }`.
  - The serial queue keeps events in FIFO order. **Never** use `Task {}` for events.
  - `Event` is a `Sendable` enum with associated values. Add its dispatch case and handler together.
- **Producers only post**, on their own threads:
  - AX observers (`Application.swift`, `MissionControl.swift`; main run loop)
  - SkyLight notify procs (`SLSRegisterConnectionNotifyProc`, `Yabai.swift`)
  - NSWorkspace, distributed and KVO notifications (`Workspace.swift`)
  - the mouse event tap (`MouseHandler.swift`; main run loop)
  - the IPC accept thread (`IPC/MessageLoop.swift`)
- **`@MainActor`** owns AppKit (the glass tab bars). `dispatch_after(main)` calls become `DispatchQueue.main.asyncAfter`, which posts back to `@WM`.
- **Cross-thread state** uses Synchronization `Mutex`/`Atomic`, with today's lock scopes:
  - borders (`Border.swift`)
  - tab-bar hit snapshots (`TabBar.swift`)
  - animation proxies/takeover (`WindowAnimation.swift`)
  - the mouse state read by the event tap
- **Animations:** `NSScreen.displayLink(target:selector:)` / `CADisplayLink` and concurrent dispatch workers; workers own AX references and copied application names.
- **Blocking AX and SkyLight calls stay synchronous on `@WM`.** They can block about 1 s on frozen apps (`doc/live-testing.md`). Making them `async` would reorder events.

### Platform layer (`Sources/Yabai/Platform/`)
- `SkyLight.swift`, `AX.swift` and `CoreDock.swift` wrap `CPrivate` and return Swift types, e.g. `SLS.spaces(forWindows: [UInt32]) -> [UInt64]` or `AXElement.title: String?`.
- CF ownership follows imported API annotations. Callback contexts and retained event handoffs also use `Unmanaged` with explicit ownership notes.
- C callbacks are `@convention(c)` functions with an `Unmanaged` context or a global. Each one gets a NOTE on who owns the context and for how long.

### Model conventions
- Containers:
  - `struct table` → `Table<Key, Value>` (same bucket/insertion/rehash order for query parity)
  - `sbuffer.h` lists → arrays
  - `*_str[]` tables → `enum X: String, CaseIterable`
  - `ts_*` temporary strings → plain `String`
- **Tree:** `final class Con { weak var parent: Con?; var children: [Con]; var focus: [Con]; … }`. Port the `tree.c` primitives one-to-one: `con_insert`, `con_unlink`, `con_replace`, `con_wrap`, `con_wrap_children`, `con_reparent_children`, `tree_reap_empty`, `tree_flatten`.
- **Command errors:** `throw CommandError.fail(text)`. One top-level `catch` writes exactly what `daemon_fail` writes.
- **Naming:** a C file `foo_bar.c` becomes `FooBar.swift`, a C function `foo_bar_baz` becomes `FooBar.baz` or a method `baz`.

## Agent rules
- **Read first:**
  - `AGENTS.md`
  - `doc/live-testing.md`: spaces 1–3, 9–11 and 15 belong to the user; deploys reset layouts
  - for SA work, `doc/payload-updates.md`
- **Edit files only with the `Edit` tool. Always.** Never change a file through `Bash`: no `python`, `perl` or `sed -i` script, no heredoc or redirect into a file, no `git apply`. Read the file, then make the change with `Edit`. `Bash` is for building, testing, running and inspecting.
- **Port one-to-one first. Simplify in a separate commit** after the phase's tests pass. No behavior or feature changes.
- **Port every `// NOTE:` comment with its code.** They record hard-won macOS behavior. Keep the repo style: `// NOTE:` blocks, sparse comments, function braces on their own line (as in `Sources/Yabai/TabBarGlass.swift`).
- **Warnings and concurrency escapes:**
  - no warnings; `make install` uses `-warnings-as-errors`
  - `@unchecked Sendable` and `nonisolated(unsafe)` only with a NOTE explaining why
- **No new package dependencies.**
- **Live checks are done by the agent, without the user:**
  - Deploy with exactly `bash scripts/live-tests/deploy.sh <install|asan|tsan>`, run from the repository root with nothing chained in front. The user allowed only that command; the auto-mode classifier blocks any other way of replacing `~/.local/bin/yabai`, so don't work around it.
  - The first deploy backs up the installed binary. At the end of every session run `bash scripts/live-tests/deploy.sh restore`, unless the user said to keep the port build installed.
  - Each deploy restarts yabai and resets all layouts, and `live.py` moves windows on spaces 4, 5 and 12. Tell the user before you start a live run and after each deploy.
  - **Still needs the user:** reloading the scripting addition (`sudo ~/.local/bin/yabai --load-sa`, twice, in a real terminal; see `doc/live-testing.md`). It is only needed when `OSAX_VERSION` changes. Before asking, test the new daemon against the old payload, then set the phase to `[L]` until the user reports the reload.
- **Sync with master at the start of every phase:**
  - Use `git log <last-synced>..master -- src tests doc` and port or merge each fix. While a file is still C, `git merge master` is fine.
  - Write the new SHA in the Handoff log.
- **Commits:** small, on `swift-port`, with concise imperative subjects (repo style). No README "Fork changes" entries until P14.
- **Long output: always delegate to the `output-summarizer` subagent (very important).**
  - Why: builds, test runs and logs fill the main agent's context window. A phase needs many of them, so the main agent must stay small and focused.
  - Delegate every command whose output is expected to be long, for example: `make`, `make install`, `make asan`, `make tsan`, `make test`, `make analyze`, `make -C tests`, `swift build`, `swift test`, the golden replay, `scripts/live-tests/` scripts (`live.py`, `bench.py`, `crashes.py`, `ipc_compare.sh`), `git log` and `git diff` over `master`, and wide greps over `src/` or `Sources/`.
  - Give the subagent the goal, the exact command with its working directory, the question to answer (e.g. "do all four builds finish with no warnings? list each warning line"), and the answer format. Ask for the exact failing lines when you need them, not the whole log.
  - Run a command yourself only when its output is short, when you need the full raw output, or when it changes state (`deploy.sh`, `codesign`, `git commit`, editing files).
- **Pitfalls:** when something costs you real time, add it to the skill `.claude/skills/swift-port-conventions/SKILL.md` in the same commit. Note it in the Handoff log too.

## Swift conventions and pitfalls
Moved in P2 to the project skill `.claude/skills/swift-port-conventions/SKILL.md` (it outgrew a page). Read it before writing Swift; add new pitfalls there.

## Verification checklist (referenced by the phases)
Run these through the `output-summarizer` subagent (see **Agent rules**, "Long output"). Record its answers in the Handoff log, not the raw output.
- **V1 Build:** `make`, `make install`, `make asan` and `make tsan` succeed with no warnings, and `bin/yabai --version` runs.
- **V2 Unit tests:**
  - `make test` passes: it generates OSAX arrays if needed, then runs `swift test`, including golden IPC replay (145 responses captured in P0).
  - Keep the test ledger in the Handoff log: C tests left + Swift tests added. It must reach "82 ported" by P14. The golden replay and `goldenCaptureCoversEveryCommand` are not part of the 82.
  - A response of the golden capture changes only when the phase changes behavior on purpose (it should not). Re-record with `GOLDEN_RECORD=1 swift test --filter Golden`, and explain each changed record in the Handoff log.
- **V3 Analyzer:** historical unity-build check; P14 removed `make analyze` with YabaiC. V3 is no longer applicable.
- **V4 Golden IPC (from P6):** `swift test --filter Golden` passes, with byte-identical responses.
- **V5 Live (the agent runs it):**
  1. `deploy.sh install`, then from `scripts/live-tests`: `live.py setup` → `run <phase>` → `extra <phase>` → `cleanup` → `launch <phase>`
  2. `bench.py`, within 10% of the P0 baseline. The medians depend on the layout state (rotate ran 55 to 150 ms on one build), so compare like for like: after `live.py setup`, `deploy.sh install` then `bench.py <phase>-A` and `<phase>-B`; then `deploy.sh restore` (also a restart) and `bench.py base-A` and `base-B` on the installed build, with the same windows.
  3. `crashes.py`, with no new reports
  4. Once per phase with `deploy.sh asan` and `deploy.sh tsan`: a short `live.py run`
  5. At the end of the session: `deploy.sh restore` (see Agent rules)
- **V6 Manual spot checks** for what the phase touched: glass tab bars (backdrop glass and blur), borders, scratchpads, rules, signals (`yabai -m signal --add event=window_focused action='echo $YABAI_WINDOW_ID >> /tmp/x'`), `--load-sa` after `killall Dock`.

A phase is `[x]` only when V1–V3 (and V4 from P6 on) and V5 pass, and any scripting-addition reload it needed was done by the user.

## Phases

### P0 — Branch, SwiftPM skeleton, baselines (done; the package layout deviates, see Target architecture)
1. `git switch swift-pilot-tab-bar-glass && git switch -c swift-port`. Copy this file to `doc/swift-port.md` and commit.
2. Add `Package.swift` with the targets above:
   - `YabaiC` = the unity build. Move `src/` into `Sources/YabaiC/` with `git mv`; `manifest.m` is the only source, and the OSAX `_bin.c` files go to `OSAXBlob`.
   - `Yabai` holds `main.swift` and the moved `tab_bar_glass.swift`.
   - `YabaiCoreTests` is empty for now.
3. Rename `main` in `yabai.c` to `int yabai_main(int argc, char **argv)`. `main.swift` calls it and exits with its result.
4. Turn the `tab_bar_glass.h` bridging header into part of `yabai_c.h`. Remove the swiftc/lipo rules from the makefiles.
5. Rewrite the `makefile` as a thin wrapper:
   - `make` → `swift build` + copy to `bin/yabai`
   - `install` → `swift build -c release -Xswiftc -warnings-as-errors`
   - `asan`/`tsan` → `--sanitize=address` / `--sanitize=thread`
   - `test` → `swift test && $(MAKE) -C tests`; point `tests/makefile` at the new paths
   - keep the `payload_bin.c`/`loader_bin.c` rules (as prerequisites of every build), `man`, `sign`, `analyze`
6. Update the paths in `AGENTS.md`, `doc/live-testing.md` and `scripts/live-tests/deploy.sh` if they changed.
7. Record baselines in the Handoff log:
   - `wc -l` per language
   - release binary size
   - `make install` time
   - `bench.py` medians of the installed `master` build (run them before the first deploy; record `~/.local/bin/yabai --version`)
8. **Golden capture:** while the C IPC is still in place, write `tests/YabaiCoreTests/Golden/commands.txt` (~60 commands covering every domain) and record the expected responses from the C implementation. The capture method is your choice, e.g. a `-DGOLDEN` test entry in `tests/src/tests.m` that runs the message handlers on fixture managers. P6 replays these. (Done: `tests/src/golden.c`, 145 commands.)
- **Done when:** V1, V2, V3, V5 (the binary behaves like the pilot). Status `[x]`.

### P1 — macOS 27 / arm64 cleanup (still C)
1. Ask the user: "Drop the x86_64 slice and `x64_payload.m`?" Proceed as answered.
2. Delete:
   - the `workspace_is_macos_*` / `@available` / `majorVersion` branches (about 38 sites outside `src/osax`), keeping the newest behavior
   - unused `SUPPORTED_MACOS_VERSION_LIST` entries
   - `#if __x86_64__` paths (`manifest.m`, `sa.m`, `display_manager.c`, `helpers.h`, `timer.h`)
3. In `src/osax/`:
   - keep only the macOS 27 pattern/offset branches in `arm64_payload.m`, after checking them with `bash scripts/payload-history.sh`
   - delete `x64_payload.m` if approved, and the x86 paths in `loader.m`/`payload.m`
   - bump `OSAX_VERSION`; this phase needs the user's scripting-addition reload (see Agent rules)
4. Set `MACOS_MIN = 27.0` everywhere: `platforms: [.macOS("27.0")]` in `Package.swift`, `makefile` (OSAX), `tests/makefile` (C and Swift `-target`). If x86_64 goes, set `ARCHS = arm64` in the makefile.
   - P0 tried 27.0 in `Package.swift`: it adds 5 `-Wdeprecated-declarations` warnings for the `CVDisplayLink*` calls in `window_animation.c` (deprecated since macOS 15; P13 replaces them with `NSScreen.displayLink`), and Swift Build warns that x86_64 is deprecated for 27.0. Until P13, wrap those calls in `#pragma clang diagnostic ignored "-Wdeprecated-declarations"` with a NOTE.
   - With the deployment target at 27, `@available(macOS 26.0, *)` / `#available` checks in Swift become redundant; remove them (`TabBarGlass.swift`).
- **Done when:** V1–V3, V5 (especially `live.py extra`: the SA space switches).

### P2 — CPrivate + Platform wrappers
1. Create `Sources/CPrivate` from `src/misc/extern.h` plus the private declarations in `sa.h`/`log.h` that Swift needs. Add nullability. `YabaiC` includes `CPrivate.h` instead of `extern.h` (one source of truth).
2. Create `Sources/Yabai/Platform/{SkyLight,AX,CoreDock,MachO}.swift`. Write wrappers only for the calls the next phases need, each with a doc comment that names the C call it wraps.
3. Port `macho_find_symbol` (`src/misc/macho_dlsym.h`) and keep it callable from C with `@_cdecl`.
- **Done when:** V1–V3. No live run needed (no behavior change), so `[x]` without V5.

### P3 — YabaiCore: geometry, labels, space_layout math, JSON writer
- **Port:**
  - the area helpers (tests `tests/src/area.c`)
  - `src/misc/label.h` (test `label_list`)
  - the pure functions of `space_layout.c`: `space_layout_parse`, `space_layout_targets`, `space_layout_move_candidate`, `space_move_replacement` (`tests/src/space_layout.c`)
  - `json_string` + a `JSONWriter` that reproduces `JSON_PROPERTY` / `JSON_FRAME_FORMAT` (test `json_string_escaping`)
- C callers get `@_cdecl` shims.
- Delete each ported C test from `TEST_LIST` in `tests/src/tests.m` in the same commit that adds its Swift twin.
- **Done when:** V1–V3, V5.

### P4 — YabaiCore: message tokens, selectors, values, rule parsing
- **Port** `message_parse.c`: tokens, `token_to_value`, `parse_label`, selector parsing, value parsers (bool/choice/spacing/opacity/…), `daemon_fail*` formatting. Also rule parsing (`rule.c`) and signal parsing.
- Port the tests: `message_config_bool/choice/options/values`, `message_window_toggle_lookup`, `message_label_reserved`, `message_rule_parse`, `message_signal_parse`, `message_selectors`, `message_query_target`, `rule_effects_combine`.
- **Done when:** V1–V3, V5.

### P5 — IPC server, CLI client, config domain
1. **Client:** port `client_encode_message` and the response handling in `yabai.c` to Swift. `main.swift` handles `-m` itself.
2. **Server:** a socket thread (`accept`/`read`) that posts `.daemonMessage` (still into the C event loop through `event_loop_post` until P7). A `ResponseWriter` replaces `FILE *rsp`.
3. **Config domain:** port `handle_domain_config` (`message_config.c`), calling the C managers through `yabai_c.h`.
- Port the tests `message_client_encoding` and the remaining `message_config_*`.
- **Done when:** V1–V3, V5, V6 (set and read several config options and compare with `master`).

### P6 — Remaining IPC domains + golden tests
- **Port:**
  - `handle_domain_display`/`space` (`message_space.c`)
  - `handle_domain_window` (`message_window.c`)
  - query, rule and signal (`message.c`)
  - the serializers they call (`window_info_serialize`, the space/display/tree serializers), on top of `JSONWriter`
- Add `Golden` tests that replay the P0 capture with byte comparison:
  - The records are read by `Golden.records()` in `tests/YabaiCoreTests/GoldenTests.swift` (format in `tests/src/golden.c`).
  - The fixture is `golden_fixture` in `tests/src/golden.c`: `window_manager_init`, `space_manager_init` and the signal storage, nothing else. The commands run in order on one state (later commands read what earlier ones set).
  - The test target needs the daemon's code: either test the `Yabai` executable target (`@testable import Yabai` works for executables on macOS) or move the IPC code into a library target first.
  - Keep the C replay (`golden_replay` in `tests/src/tests.m`) until the C tests are gone, or delete it in the same commit that makes the Swift replay pass.
- Port the tests `message_window_command_groups`, `message_window_layout_values`, `message_space_command_groups`, `window_info_serialize_selected`, `window_info_tree_fields`, `tree_view_serialize_tree`.
- **Done when:** V1–V6.

### P7 — `@WM` actor, event loop, signals
1. Add the `@WM` global actor, the `Event` enum and `EventLoop.post` as described in the architecture. `event_loop_post` becomes a `@_cdecl` shim that maps `(type, context, param1)` to `Event`.
2. Keep calling the C handlers (`EVENT_HANDLER_*`) from Swift until P8.
3. Delete `event_loop.c` and `memory_pool.h`. Keep `ts_reset()` per event while C still uses `ts_*`.
4. Port `event_signal.c` (`flush` after each event).
- Port the tests `event_signal_filter_properties`, `event_signal_args`, `event_signal_describe_spaces`.
- **Done when:** V1–V6. Run `tsan` live this phase.

### P8 — Event handlers + Mission Control
- **Port** `event_handlers.c`, `event_handlers_window.c`, `event_handlers_space.c`, `event_handlers_mouse.c`, `event_handlers_system.c` and `mission_control.c`. Each `EVENT_HANDLER(X)` becomes a `@WM` function in a `switch`.
- Port the tests `mouse_event_coalescing`, `application_launch_retry_backoff`, `mouse_resize_handle`, `mouse_drop_action_regions`.
- **Done when:** V1–V6. `live.py launch` matters most here.

### P9 — Display + space model
- **Port** `display.c`, `display_manager.c`, `space.c`, `view.c`, `space_layout.c` (the rest) and `space_manager.c`. Convert `struct view` and the display/space manager state into Swift classes, and remove their C structs when no C code uses them.
- Port the tests `display_area_is_in_direction`, `closest_display_in_direction`, `space_list_navigation`, `auto_padding_*`, `space_known_focus`, `space_window_user_predicates`.
- **Done when:** V1–V6. Check cross-display moves and the `space_layout` reconcile.

### P10 — Process, application, workspace
- **Port** `process_manager.c`, `application.c` and `workspace.m`: NSWorkspace/KVO observers become Swift observers that post events. The AX observer context ownership needs a NOTE.
- **Done when:** V1–V6, including the frozen-app and launch-retry checks.

### P11 — Window + window_manager*
- **Port** `window.c`, `window_manager.c`, `window_manager_discovery.c`, `window_manager_lookup.c`, `window_manager_focus.c`, `window_manager_rules.c`, `window_manager_scratchpad.c` and `window_manager_tree.c`. Convert `struct window` and `struct window_manager`; config fields become typed properties.
- Port the tests `window_frame_*`, `window_pending_focus`, `window_unresolved_list`, `window_validity`, `window_one_shot_rules`, `window_rules_*`, `window_child_windows_collect`.
- **Done when:** V1–V6. Scratchpads, rules and focus-follows-mouse are spot-checked.

### P12 — Tree + tree_view
- **Port** `tree.c` and `tree_view.c` one-to-one onto `final class Con`.
- Port all `tree_*` and `tree_view_*` tests. These are the biggest test group; keep their fixtures (`tree_test_leaf`, `tree_test_split` → Swift helpers).
- **Done when:** V1–V6. `bench.py` matters most here: tab focus, rotate and split focus.

### P13 — Border, tab bars, animation, mouse, SA client
- **Port:**
  - `border.c`: keep today's approach; memory measurements are in the user's notes
  - `tab_bar.c` + `tab_bar_glass.c` (merge them with `Sources/Yabai/TabBarGlass.swift`)
  - `window_animation.c` (DisplayLink, as described above)
  - `mouse_handler.c` (event tap)
  - `sa.m` (`[UInt8]` payload builder with `SA_OPCODE_*`; keep `OSAX_VERSION` checks)
- Port the tests `border_*`, `tab_bar_*`, `window_child_windows_collect` (if not done) and the remaining mouse tests.
- **Done when:** V1–V6, all variants, and a full `live.py extra`.

### P14 — Remove C, docs, final verification
1. Finish the deferred shared-model conversion (`final class Con`, view/managers, window/application/process, mouse/tab-bar state), `rule.c` and the startup/service/helper residue. Then delete the actual `YabaiC` target (`src/` except OSAX), the **C harness only** (`tests/src/`, `tests/makefile`; preserve `tests/YabaiCoreTests/` and `tests/YabaiTests/`) and `make analyze`. Remove leftover `@_cdecl` shims. Move `src/osax` to `osax/` and update the makefile payload rules.
2. Rewrite the Architecture, Build and Testing sections of `AGENTS.md`. Update `doc/live-testing.md` (unit tests section), `doc/payload-updates.md` (paths) and README (build instructions; ask the user about a "Fork changes" line).
3. Run the full V1–V6 with all three variants.
4. Final report in the Handoff log: lines, size and build time against the P0 baselines, `bench.py` comparison, known deviations.
5. Ask the user whether to merge `swift-port` into `master`.

## Handoff log
Append one entry per session, newest last. Template:
```
### <YYYY-MM-DD> P<n> <status after session>
- Commits: <first>..<last> on swift-port
- Master synced to: <sha>
- Done: <what was finished>
- Resume at: <exact next step, file and function>, or "next phase"
- Open @_cdecl shims / C structs still shared: <list>
- Tests: C remaining <n>, Swift added <n> (total ported <n>/82)
- Measurements: <lines, size, build time, bench medians if run>
- Deviations from plan / surprises: <…>
- Pitfalls added to "Swift conventions and pitfalls": <titles, or none>
- Waiting on user: <scripting-addition reload, questions>
```

### 2026-10-14 P0 [~]
- Commits: the commit that adds this file, on swift-port (branched from swift-pilot-tab-bar-glass at 69b9085)
- Master synced to: 827f5b7 (master is an ancestor of the pilot; nothing to sync)
- Done: P0 step 1 (branch created, plan committed as doc/swift-port.md)
- Resume at: P0 step 2 (Package.swift)
- Open @_cdecl shims / C structs still shared: the pilot's tab_bar_glass_* entry points (src/tab_bar_glass.h)
- Tests: C remaining 82, Swift added 0 (total ported 0/82)
- Measurements (pilot, before P0): release bin/yabai 1,952,344 B (master 1,836,856 B); make install 6.8 s (master 5.6 s);
  make analyze 37 known false positives
- Deviations from plan / surprises: none yet
- Waiting on user: nothing (agents deploy and run the live checks themselves since 4754520)

### 2026-10-14 P0 [x]
- Commits: 1c5bee6 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (merged as 826e456; nothing newer on master)
- Done: steps 2–8.
  - `Package.swift` with the C target YabaiC (the unity build) and the executable Yabai (`main.swift` → `yabai_main`, `TabBarGlass.swift`). The makefile wraps `swift build`; `tests/makefile` builds the Swift sources against the module map.
  - `space_manager_init` was split out of `space_manager_begin` (defaults only) for the golden fixture.
  - Golden capture: 145 commands (every config option, rule, signal, query errors, window/space/display commands that fail before acting) in `tests/YabaiCoreTests/Golden/`, replayed at the end of `make -C tests`. Swift test `goldenCaptureCoversEveryCommand` parses the records.
- Resume at: next phase (P1). Its first step asks the user about x86_64.
- Open @_cdecl shims / C structs still shared: the tab_bar_glass_* entry points (src/tab_bar_glass.h); `yabai_main` (C, called by main.swift)
- Tests: C remaining 82, Swift added 0 (total ported 0/82); plus golden replay 145/145 and 1 Swift test (`goldenCaptureCoversEveryCommand`)
- Measurements:
  - Lines: C 16,061 · headers 4,301 (incl. yabai_c.h) · ObjC 1,056 · OSAX 2,076 · Swift 446 · C tests 2,918
  - Release `bin/yabai` (universal): 1,954,568 B (pilot 1,952,344 B)
  - `make install`: 8.5 s from an empty `.build` (pilot makefile: 6.8 s), 1.6 s with nothing changed
  - Bench baseline. Installed pilot build (yabai-v7.1.25, the pilot's code), measured as in V5 step 2: tab focus 30.8 / 31.5, rotate 150.5 / 147.2, split focus 30.3 / 28.7 ms. P0 build in the same state: 31.1 / 32.9, 145.2 / 148.5, 28.2 / 30.9 ms.
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled), `launch` 3/3; asan `run` 28/28 with no reports; tsan `run` 28/28 with only the 2 known `APPLICATION_LAUNCHED` reports; no new crash reports (28 before and after). `deploy.sh restore` done.
- Deviations from plan / surprises:
  - The C sources stay in `src/` (target path "src") instead of moving to `Sources/YabaiC`. That keeps master merges, `payload-history.sh` and the docs' paths working; the files go away when they are ported anyway. The OSAX `_bin.c` files are sources of YabaiC, not a separate `OSAXBlob` target.
  - Swift tests live in `tests/YabaiCoreTests` (case-insensitive file system). `YabaiCore` is not created yet; P3 adds it with its first code.
  - The deployment target is 12.0 (the lowest Swift Build accepts), not 11.0 or 27.0; 27.0 belongs to P1 (warnings listed there).
  - The binary keeps `-rdynamic` (Swift Build's default) and gets rpaths into the toolchain and `.build` (unused at runtime; the Swift runtime comes from `/usr/lib/swift`).
  - Golden capture finding: `config mouse_modifier` answers `(null)` on a fresh daemon (no modifier set; `printf("%s", NULL)`). A getter takes the next option as its value (`config window_gap top_padding` fails). Both are recorded as they are.
  - Bench medians depend on the layout state: right after `live.py run` the P0 build measured rotate 55 ms, right after a restart 150 ms. V5 step 2 now prescribes the like-for-like procedure.
- Pitfalls added to "Swift conventions and pitfalls": Swift Build prelinks C targets (no `-fvisibility=hidden`); Swift Build's extra warnings; SDK version of the binary; Swift imports C headers with ARC; case-insensitive `Tests/`. The section is close to a page; P1 may move it into a skill.
- Waiting on user: nothing

### 2026-10-14 P1 [L]
- Commits: 174b5b8 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: steps 1–4. The user chose to drop x86_64.
  - Every `workspace_is_macos_*`, `@available`, `__builtin_available` and `majorVersion` branch is gone, keeping the newest path; so are `SUPPORTED_MACOS_VERSION_LIST`, `workspace_use_macos_space_workaround` and every `__x86_64__` path. Code that only the old paths used went with them: `tab_bar_window_list`, `border_window_list`, the 1204 Mission Control notification, the `SLSMoveWindowsToManagedSpace` space move, `SLSGetWindowLevel`.
  - `display_manager_display_is_animating` always returned false since Sonoma, so it is deleted with its 13 callers, `SPACE_OP_ERROR_DISPLAY_IS_ANIMATING` and its `daemon_fail` text ("…the display is in the middle of an animation."), which macOS 27 could never print. The golden capture did not contain it (145/145 unchanged).
  - `SLSWindowIteratorGetCornerRadii` (macOS 26+) is now declared in `extern.h` (`CF_RETURNS_RETAINED`) and called directly instead of through `dlsym`.
  - OSAX: `arm64_payload.m` keeps only the macOS 27 values (checked against 3b463fc "macOS 27 offsets"; the getters take no arguments now), `x64_payload.m` and the x86 paths of `loader.m`/`payload.m` are deleted, `verify_os_version` accepts only macOS 27, the `macOSSequoia` flag is gone, `OSAX_VERSION` is 2.1.34.
  - `MACOS_MIN = 27.0` / `ARCHS = arm64` (makefile, OSAX `-arch arm64e` only), `.macOS("27.0")` in `Package.swift`, 27.0 in `tests/makefile`. The `CVDisplayLink*` calls and payload's `getsegbyname` (deprecated since 13) are wrapped in `-Wdeprecated-declarations` pragmas with a NOTE. `TabBarGlass.swift` has no availability checks left.
  - `AGENTS.md` (build, OSAX, version gating) and `doc/payload-updates.md` describe the macOS 27 / arm64 layout.
- Resume at: the user's scripting-addition reload, then next phase (P2). For the reload, the P1 build (with payload 2.1.34) must be installed: `bash scripts/live-tests/deploy.sh install`, the user runs `sudo ~/.local/bin/yabai --load-sa` twice in a real terminal, then `python3 scripts/live-tests/sa_version.py` must print `payload 2.1.34 attrib 0x5f`, then `live.py setup` → `extra P1-sa` → `cleanup`, then `deploy.sh restore` and check `sa_version.py` again (the restored master binary ships payload 2.1.33). Then set P1 to `[x]`.
- Open @_cdecl shims / C structs still shared: unchanged (tab_bar_glass_* entry points; `yabai_main`)
- Tests: C remaining 82, Swift added 0 (total ported 0/82); golden replay 145/145, `goldenCaptureCoversEveryCommand` passes
- Measurements:
  - Lines (git ls-files; ObjC includes `manifest.m`, OSAX all of `src/osax`, Swift includes the tests): C 15,897 · headers 4,193 · ObjC 1,027 · OSAX 1,435 · Swift 498 · C tests 2,918
  - Release `bin/yabai` (arm64 only): 849,384 B (P0 universal: 1,954,568 B)
  - `make install`: 7.2 s from an empty `.build` (P0: 8.5 s, two architectures)
  - V1 all four variants warning-free; V3 37 warnings, the known count
  - V5 with Dock still on payload 2.1.33 (new daemon against the old payload): `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 11 ms), `launch` 3/3; asan `run` 28/28 with no reports; tsan `run` 28/28 with no reports; crash reports 28 before and after. Signal spot check (`window_focused`) passes. `deploy.sh restore` done.
  - Bench (V5 step 2, same windows): P1 tab focus 36.9 / 34.5, rotate 154.0 / 154.2, split focus 33.2 / 31.1 ms; installed build 33.3 / 35.9, 156.3 / 151.9, 33.5 / 32.7 ms.
- Deviations from plan / surprises:
  - `space_manager_swap_space_with_space_on_display` and `window_manager_wait_for_native_fullscreen_transition` lost the parameters that only the deleted checks used.
  - The README still lists the old supported versions; that is P14's README update.
  - The Bash tool keeps the working directory between calls: after `cd scripts/live-tests && python3 live.py …`, the next `bash scripts/live-tests/deploy.sh` fails. Run the harness in a subshell, `(cd scripts/live-tests && python3 live.py …)`. Added to `doc/live-testing.md`.
- Pitfalls added to "Swift conventions and pitfalls": none (the working-directory note is in `doc/live-testing.md`)
- Waiting on user: the scripting-addition reload (see Resume at)

### 2026-10-14 P1 [x]
- Commits: the commit that adds this entry, on swift-port (code unchanged since 174b5b8)
- Master synced to: 4754520 (nothing newer on master)
- Done: the scripting-addition reload. With the P1 build installed the user ran `sudo ~/.local/bin/yabai --load-sa` twice; `sa_version.py` printed `payload 2.1.34 attrib 0x5f`. `live.py setup` → `extra P1-sa` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 12 ms, Dock pid unchanged) → `cleanup`. No new crash reports (28). `deploy.sh restore` done.
- Resume at: next phase (P2)
- Open @_cdecl shims / C structs still shared: unchanged (tab_bar_glass_* entry points; `yabai_main`)
- Tests: C remaining 82, Swift added 0 (total ported 0/82)
- Measurements: see the P1 [L] entry
- Deviations from plan / surprises: after `deploy.sh restore` Dock was back on payload 2.1.33 without a user step: the restored master binary matches the `--load-sa` sudoers rule, so its yabairc reinstalls its own payload when yabai starts. Added to `doc/live-testing.md`. A port build's payload therefore only stays loaded while a port build is installed.
- Pitfalls added to "Swift conventions and pitfalls": none
- Waiting on user: nothing

### 2026-10-14 P2 [x]
- Commits: 872fe3b (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: steps 1–3.
  - `Sources/CPrivate`: `include/CPrivate.h` is `src/misc/extern.h` (moved with `git mv`) inside `CF_IMPLICIT_BRIDGING_ENABLED` + `CF_ASSUME_NONNULL`; every returned object is `_Nullable`, as are the parameters the C code passes NULL to (notify-proc context, `opaque_shape`, `SLWindowContextCreate` options). `CPrivate.c` defines `CGSGetConnectionPortById` and `SLSPerformAsynchronousBridgedWindowManagementOperation` (they were `static` in extern.h). CPrivate links SkyLight; YabaiC and Yabai depend on it, and `yabai_c.h` does `#include <CPrivate.h>`. `tests/makefile` and `make analyze` pass `-I Sources/CPrivate/include`; the tests compile `CPrivate.c` and the Swift files of `Sources/Yabai/*/`.
  - `macho_find_symbol` is Swift (`Platform/MachO.swift`, `@_cdecl`); `src/misc/macho_dlsym.h` keeps only the prototype. Checked against the C original in a scratch program: same addresses for `_CGSGetConnectionPortById`, the bridged-operation symbol and `_SLSMainConnectionID`, NULL for a missing symbol or image.
  - `Platform/SkyLight.swift` (`enum SLS`), `AX.swift` (`struct AXElement`), `CoreDock.swift` (`enum CoreDock`): the calls that `window.c`, `space.c` and `display.c` make for the serializers P6 ports (bounds, alpha, sub-level, title, owner/pid, ordered-in, spaces for windows, the window query iterator as `[SLS.QueriedWindow]`, managed displays, current space, space type/name, display spaces), plus the AX title/role/subrole/window id and the Dock state. They take the connection as the C calls do. A scratch program run against the window server matched `yabai -m query --windows --window` field by field.
  - `CF_CONSUMED` on the `window_ref` parameter of `window_create` and `window_manager_create_and_add_window` (see surprises).
  - The "Swift conventions and pitfalls" section moved to `.claude/skills/swift-port-conventions/SKILL.md` (it outgrew a page); the plan points there.
- Resume at: next phase (P3)
- Open @_cdecl shims / C structs still shared: tab_bar_glass_* entry points (src/tab_bar_glass.h); `yabai_main` (C, called by main.swift); `macho_find_symbol` (Swift, called by yabai.c)
- Tests: C remaining 82, Swift added 0 (total ported 0/82); golden replay 145/145, `goldenCaptureCoversEveryCommand` passes
- Measurements:
  - Lines (git ls-files, as in P1 but Swift counts every `.swift` file): C 15,901 · headers 4,153 · ObjC 1,027 · Swift 989
  - Release `bin/yabai`: 850,648 B (P1: 849,384 B); `make install` 5.0 s incremental after the other variants
  - V1 all four variants warning-free; V2 passes; V3 37 warnings, identical to HEAD before the phase (diffed)
  - V5 not run: P2 changes no behavior ("Done when" is V1–V3)
- Deviations from plan / surprises:
  - The plan put `macho_dlsym.c` into CPrivate; step 3 ports it to Swift instead, and CPrivate only declares private functions (plus the two resolved pointers, which give it the source file Swift Build needs).
  - Nothing from `sa.h`/`log.h` went into CPrivate: they hold yabai's own declarations (the OSAX byte arrays, `g_verbose`), not private framework ones, and no Swift code needs them yet.
  - With `CF_IMPLICIT_BRIDGING_ENABLED` the analyzer trusts the Create rule for `_AXUIElementCreateWithRemoteToken` and reported a new leak in `window_manager_add_windows_by_element_id`, where the element is handed to `window_manager_create_and_add_window`. That function always takes the reference (the other callers pass `CFRetain(window_ref)`, `window_destroy` releases it), so the parameter is now `CF_CONSUMED`, and the count is back to 37.
- Pitfalls added to "Swift conventions and pitfalls": a C target without sources does not link; nullability is per file (macros, multi-level pointers); imported C types (`Boolean`, `CGError`, CF out-parameters)
- Waiting on user: nothing

### 2026-10-14 P3 [x]
- Commits: 2a646a8 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: the whole phase.
  - New library target `YabaiCore` (`Sources/YabaiCore/`, does not import YabaiC): `Area.swift` (`Area`, `Direction`; `area_from_cgrect`, `area_max_point`, `area_is_in_direction`, `area_distance_in_direction`), `Label.swift` (`LabelList`), `SpaceLayout.swift` (`space_layout_parse`, `space_layout_targets`, `space_layout_move_candidate`), `SpaceList.swift` (`space_manager_move_space_replacement`), `JSON.swift` (`ts_string_escape`/`json_string`, `json_bool`, `%.4f` through `vsnprintf`, `JSON_FRAME_FORMAT`, and `JSONWriter`, which reproduces `JSON_PROPERTY`: separator, tab, lazily evaluated values, `finish()` closes the object). Yabai and YabaiCoreTests depend on it; `tests/makefile` builds it as its own module before the Yabai sources.
  - C callers go through `@_cdecl` shims in `Sources/Yabai/Shims/` (`AreaShims`, `LabelShims`, `SpaceLayoutShims`, `JSONShims`); the C prototypes stay in `view.h`, `label.h`, `space_layout.h`, `space_manager.h` and `helpers.h`, each with a pointer to its shim.
  - Label lists: `struct label *` sbuffers became an opaque `struct label_list *` (a `LabelListBox` retained by the first `label_set`, never released, like the C lists were never freed). `label_find_id` returns the name in temporary storage, `label_find_name` returns the id through an out parameter, `label_remove_id` takes the list instead of its address. The two loops in `space_manager.c` that poked into the label array became `label_swap_ids` (swap of spaces across displays) and `label_replace_id` (`space_manager_handle_display_add`).
  - `ts_string_from_bytes` (`src/misc/ts.h`): the one way for Swift to allocate temporary storage (see pitfalls).
  - Ported tests (Swift display names = the C names): `display_area_is_in_direction`, `closest_display_in_direction`, `space_layout_parse`, `space_layout_targets`, `space_move_replacement`, `space_layout_move_candidate`, `label_list`, `json_string_escaping`. Extra Swift tests: `labelListMovesIDs`, `jsonEscapesEveryControlCharacter`, `jsonNumbersMatchPrintf`, `jsonWriterMatchesJSONProperty`. `tests/src/area.c` and `label.c` are deleted; `tests/src/space_layout.c` keeps only `space_list_navigation` (a P9 test) and is renamed `space_list.c`.
- Resume at: next phase (P4)
- Open @_cdecl shims / C structs still shared: tab_bar_glass_* entry points (src/tab_bar_glass.h); `yabai_main` (C, called by main.swift); `macho_find_symbol`; the P3 shims `area_max_point`, `area_is_in_direction`, `area_distance_in_direction`, `label_find_id`, `label_find_name`, `label_remove_id`, `label_set`, `label_replace_id`, `label_swap_ids`, `space_layout_parse`, `space_layout_targets`, `space_layout_move_candidate`, `space_manager_move_space_replacement`, `json_string`. C structs still shared: `struct area` (view/tree code, P9/P12), `struct space_layout` (in `struct space_manager`, P9); `struct label_list` is opaque to C.
- Tests: C remaining 74, Swift added 8 (total ported 8/82); plus 4 extra Swift tests, golden replay 145/145, `goldenCaptureCoversEveryCommand` passes
- Measurements:
  - Lines (as in P2): C 15,808 · headers 4,032 · ObjC 1,027 · Swift 1,864 · C tests 2,649
  - Release `bin/yabai`: 926,616 B (P2: 850,648 B; the YabaiCore module and the shims)
  - V1 all four variants warning-free (`make -C tests` too); V2 passes; V3 35 warnings: the 37 known minus two false positives that went with the ported C (`label.h` null dereference, `space_layout.c` garbage value), no new ones (diffed)
  - V5: `run` 28/28, `extra` 14/14, `launch` 3/3; asan `run` 28/28 and tsan `run` 28/28, both with no reports (labels, direction queries and `space_layout` errors exercised under both); crash reports 29 before and after (the 29th, 18:12 today, is from an unknown build that is neither the installed binary nor this session's). `deploy.sh restore` done; `sa_version.py` back at 2.1.33.
  - V6 (what P3 touched): space and display labels set, moved to another id, queried by name, removed (and the "not associated with a label" error); a label with `"` and `\` comes back escaped; `query --displays --display east/west/north/south` from display 1 gives 2 and the three "could not locate" errors; the yabairc's `space_layout 15 10:5 10:5:1b` parses and reads back, `10::5`, `0` and `1b:2b` fail with the C texts. `rule --list` (48 rules), `signal --list` and `query --displays` are byte-identical to the installed build's.
  - Bench (V5 step 2, same windows): P3 tab focus 31.7 / 27.3 / 31.8, rotate 158.9 / 153.6 / 145.3, split focus 27.7 / 27.5 / 30.9 ms (the third sample after the sanitizer runs); installed build 28.2 / 26.8, 145.1 / 154.2, 26.0 / 26.3 ms. Within 10% of the P0 baseline; the timed commands (`window --focus`, `space --rotate`) run none of the ported code, so the spread is noise.
- Deviations from plan / surprises:
  - The plan lists `display_area_is_in_direction` and `closest_display_in_direction` under P9 too; they test only the area helpers, so they moved with them in P3.
  - Label names are Swift `String`s: a label with invalid UTF-8 (only possible through a crafted argv) is stored with U+FFFD replacements, where C kept the raw bytes.
  - `area_from_cgrect` and `struct area` stay C (the struct's constructor; view and tree code use it on hot paths); YabaiCore has `Area.init(CGRect)` for later phases.
- Pitfalls added to "Swift conventions and pitfalls": header functions that touch `static` globals; `String ==` is not `strcmp`; YabaiCore does not import YabaiC (shims, tuples, the test makefile)
- Waiting on user: nothing

### 2026-10-14 P4 [x]
- Commits: 348c156 (code), then the commit that adds this entry and `scripts/live-tests/ipc_compare.sh`, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: the whole phase.
  - `Sources/YabaiCore/Message.swift`: `Token` (bytes; `token_equals`/`token_prefix` byte for byte, `token_is_positive_integer`/`token_is_hexadecimal` wrapping like C, `token_is_float` through strtof, `token_to_value`, sscanf through `Token.scan`), `TokenValue` (`token_value_float`), `TokenSource`, `Message` (`get_token`'s twin, with `peek`), `ResponseText` (string interpolation that writes tokens as their bytes) and `Response` (`daemon_fail`, `daemon_fail_unknown_*`).
  - `MessageParse.swift`: `parse_config_bool`, `parse_config_choice`, `parse_key_value_pair`, `parse_layer`, `parse_value_type`, `parse_resize_handle`, `WindowToggle` (the lookup of `window_toggle_for_value`), `LabelKind` + `parse_label`, `parse_properties`, `parse_direction`/`direction_str`, the display/space/window selectors (with the stack selectors), the optional selectors, `parse_insert_selector`, `peek_tree_direction` (`parseTreeFocus`) and `parse_query_target`. The selectors look things up through a `SelectorContext` protocol (`DisplayQuery`/`SpaceQuery`/`WindowQuery` enums plus label lookups and the active display/space/window).
  - `Rule.swift`: `POSIXRegex`, `RulePattern`, `RuleEffects` with `combine` (`rule_combine_effects`), `Rule`, `parse_rule`, `EventSignal`, `parse_signal` (the event names come in as a closure, `signal_type_from_string`, until the signals are Swift in P7).
  - `src/message_parse.h` (new, in `yabai_c.h`): `struct token`, `token_value`, `properties`, `selector`, `query_target`, `enum label_type`, the `*_global()` accessors of the manager singletons, and the prototypes of the shims in `Sources/Yabai/Shims/MessageShims.swift`. The shims keep the C signatures: `CMessage` reads the next tokens of the C cursor with `get_token`, so a parser consumes exactly what C did; a parser writes into a `Response`, which the shim writes to `rsp` before it returns; `CSelectorContext` calls the C managers. `parse_rule`/`parse_signal` fill `struct rule`/`struct signal` with malloc'ed strings and compile the patterns into their `regex_t` again, so `rule_destroy`/`event_signal_destroy` are unchanged. `window_toggle_list` (`message_window.c`) is now a table of functions in `WindowToggle` order, indexed by `window_toggle_index`.
  - Left in C on purpose: `get_token`, `token_equals`, `token_is_valid`, `daemon_fail` (variadic) and `daemon_fail_space_op`/`daemon_fail_unmanaged_window` (they format the results of C manager calls), and the `COMMAND_*`/`ARGUMENT_*` strings. The C handlers use them ~300 times; they go with the handlers in P5/P6. `parse_window_layout`/`parse_split_orientation` (`message_window.c`) are P6's, with their test.
- Resume at: next phase (P5)
- Open @_cdecl shims / C structs still shared: the P3 list, plus `token_to_value`, `token_value_float`, `daemon_fail_unknown_command/option/value`, `parse_config_bool`, `parse_config_choice`, `parse_layer`, `parse_value_type`, `parse_resize_handle`, `window_toggle_index`, `parse_label`, `parse_properties`, `parse_display_selector`, `parse_space_selector`, `parse_window_selector`, `parse_optional_{display,space,window}_selector`, `parse_insert_selector`, `peek_tree_direction`, `parse_query_target`, `parse_rule`, `parse_signal`, `rule_combine_effects`. C structs still shared: those of P3, plus `struct token`, `token_value`, `properties`, `selector`, `query_target` (until the handlers are Swift), `struct rule`/`rule_effects` (P11) and `struct signal` (P7).
- Tests: C remaining 65, Swift added 9 (total ported 17/82): `message_config_bool`, `message_config_choice`, `message_window_toggle_lookup`, `message_label_reserved`, `message_rule_parse`, `message_selectors`, `message_query_target`, `message_signal_parse`, `rule_effects_combine`. Extra Swift tests: `messageTokens`, `tokenValues`, `responseEchoesTokenBytes`, `messageProperties`, `messageKeyValuePairs`, `messageValueParsers`, `messageSelectorLookups`, `messageRuleValues`. Golden replay 145/145 (through the shims), `goldenCaptureCoversEveryCommand` passes. `message_config_options` and `message_config_values` stay C: they run `handle_domain_config`, P5's.
- Measurements:
  - Lines (as in P3): C 14,735 · headers 4,162 · ObjC 1,027 · Swift 4,350 · C tests 2,313
  - Release `bin/yabai`: 1,195,768 B (P3 build of today: 929,192 B). `__TEXT` +64 KB (the new Swift), `__LINKEDIT` +180 KB: the binary exports ~700 public YabaiCore symbols because of `-rdynamic` (P0), and imports more of the Swift runtime. A candidate for P14 (dead-strip the exports).
  - V1 all four variants warning-free (`make -C tests` too); V2 passes; V3 38 warnings, diffed against HEAD: the 35 known minus two NullDereference reports through the old C selector (`window_manager_find_prev/next_managed_window`), plus a view leak in `event_handlers.c` and `window_manager_lookup.c` (views owned by tables) and three `a->id` NullDereference in `window_manager_{stack,warp,swap}_window` reached from `handle_domain_window`, where the analyzer assumes the command equals both `--focus` and `--stack`. All are the known false-positive classes.
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 11 ms, Dock pid unchanged), `launch` 3/3; asan `run` 28/28 and tsan `run` 28/28, both without reports. `deploy.sh restore` done. Crash reports 29 → 30, see surprises.
  - V6 (what P4 touched): 70 IPC commands (`scripts/live-tests/ipc_compare.sh`, added after 348c156: display/space/window selectors with every keyword, label and index, invalid values, property lists with empty and trailing entries, labeled rules with every key and `--one-shot`, `rule --list`, failing rules and signals with several errors each, `signal --list`, config getters, window/space/display commands that fail while parsing) are byte-identical to the installed build's after a fresh start, on the release, asan and tsan builds; only `--display mouse` follows the cursor. A `window_focused` signal runs.
  - Bench (V5 step 2, same windows): P4 tab focus 33.3 / 35.7, rotate 151.4 / 147.2, split focus 28.9 / 30.2 ms; installed build 35.7 / 33.5, 156.0 / 155.3, 32.7 / 30.4 ms.
- Deviations from plan / surprises:
  - Rule and signal strings (labels, patterns, actions, scratchpads) are Swift `String`s, so like the labels of P3 a value with invalid UTF-8 is stored with U+FFFD. Failure responses echo the raw bytes.
  - TOKEN_TYPE_UNKNOWN stays in the C enum, but nothing returns it (C could not for a valid token either). `TIME_FUNCTION` of the ported parsers is gone (profiling builds only).
  - `rule --list` on a daemon that ran for hours showed `"space":0` for the yabairc's `space=11` rules, while a fresh daemon (either build) shows 11: the stored space id went stale. Not a P4 change; compare IPC output only after a restart.
  - Crash (pre-existing, not P4): the P4 release daemon crashed 13 s after a deploy while `live.py cleanup` quit the test apps: SIGSEGV in `window_manager_apply_window_frame_group` (`group->application` NULL) < `window_manager_set_window_frames` < `tree_flush` < `space_manager_untile_window` < `EVENT_HANDLER_WINDOW_DESTROYED`. The 18:12 report of today (an unknown build) has the same stack. Likely cause: `APPLICATION_TERMINATED` (`src/event_handlers.c:318`) sets `window->application = NULL` for a window that a pending `WINDOW_DESTROYED` already invalidated, but leaves it in its tree; the pending event of a sibling then untiles and flushes the tree with that window in it. It did not reproduce in two tries (installed build and P4 build). It belongs on master, reported to the user.
- Pitfalls added to "Swift conventions and pitfalls": mutable C globals; macros that name another constant; `&x` in a `CVarArg...` list; parameter names that are C type names
- Waiting on user: nothing (the crash above is reported for a decision on master)

### 2026-10-14 P5 [x]
- Commits: 094259e (code), 91aa5b0 (dead config shims removed), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: the whole phase.
  - Client: `ClientMessage.encode` (`Sources/YabaiCore/Client.swift`, `client_encode_message`) and `Client.send` (`Sources/Yabai/IPC/Client.swift`, `client_send_message`). `main.swift` runs it for `-m`/`--message` before `yabai_main`; the client code and `CLIENT_OPT_*` are gone from `yabai.c`. Output goes through write(2) (C: fprintf + fflush of each read), with the same quirks: the failure byte is checked at the start of every read of up to `BUFSIZ - 1` bytes, and each read is printed up to its first null byte.
  - Server: `message_loop_begin` (`@_cdecl`, `IPC/MessageLoop.swift`) binds the socket and runs the accept loop on a `Thread`, which posts `DAEMON_MESSAGE` through `event_loop_post` (`event_loop_global()`). The handler in `event_handlers_system.c` calls `daemon_message_handle` (Swift): it reads the message, calls `debug_message` with the same prefix as before (`EVENT_HANDLER_DAEMON_MESSAGE`), runs `handleMessage` into a `Response`, and `ResponseWriter.send` writes it to the socket and closes it (replaces fdopen/fflush/fclose).
  - `handleMessage` dispatches by domain (`Domain` in `Message.swift`). The config domain is Swift (`handleDomainConfig`, `IPC/MessageConfig.swift`, generic over `TokenSource`); the C domains are called with a `FILE *` from `open_memstream` (`Response.appendWritten`), and their output is appended to the Response. `handle_domain_{display,space,window,query,rule,signal}` are no longer `static` (prototypes in `message.h`, which now comes after `message_parse.h` in `yabai_c.h`). `handle_message` keeps its C signature as a shim for the golden replay of the C tests.
  - `message_config.c` and the config `COMMAND_*`/`ARGUMENT_*` strings of `message_parse.c` are deleted (`enum Config` in `MessageConfig.swift`). The `*_str` tables of the C headers it printed are Swift arrays there, until their headers are Swift (static C arrays cannot be read from Swift). `TokenSource` has `peek()` now (config `space_layout` stops before the first token that is not a layout); `cFormat` formats numbers like printf (`%f`, `%.4f`).
  - `scripting_addition_is_sip_friendly` (`sa.m`) is no longer `static`; `message_parse.h` has `event_loop_global()`, `mouse_state_global()` and `verbose_global()`.
  - `scripts/live-tests/ipc_compare.sh` gained the P5 cases (every config getter, `--space` getters and errors, ~45 failing setters, setting the yabairc's own values again, messages with several commands and a failure between them, the client's "no arguments" and "USER not set" errors). `live.py` checks the daemon pid with `pgrep -ox yabai` (see surprises).
- Resume at: next phase (P6). The test target `YabaiTests` already imports the executable, so the Swift golden replay can live there (move `Golden/` or point it at `tests/YabaiCoreTests/Golden`).
- Open @_cdecl shims / C structs still shared: the P4 list minus `parse_config_bool`/`parse_config_choice` (removed), plus `message_loop_begin`, `daemon_message_handle`, `handle_message` (C prototype for golden.c) and `client_encode_message` (only for golden.c; delete both with the C replay in P6). `space_layout_parse` and `parse_optional_display_selector` have no C caller left (the first is called from `MessageConfig.swift`). C structs: unchanged from P4.
- Tests: C remaining 62, Swift added 3 (total ported 20/82): `message_client_encoding` (YabaiCoreTests), `message_config_options`, `message_config_values` (YabaiTests, serialized suite). Extra Swift test: `cFormatMatchesPrintf`. Golden replay 145/145 (now through the Swift dispatch and config domain), `goldenCaptureCoversEveryCommand` passes.
- Measurements:
  - Lines (git ls-files, `src/` without `src/osax`; Swift = every tracked `.swift` file): C 13,919 · headers 4,106 (`src/**/*.h`; all tracked `.h` 4,235) · ObjC 1,026 · Swift 5,567 · C tests 2,208
  - Release `bin/yabai`: 1,241,272 B (P4: 1,195,768 B)
  - V1 all four variants warning-free (`make -C tests` too); V2 passes; V3 34 warnings, diffed against HEAD before the phase (38): gone are the leak in `message_config.c` and four reports in `tree.c`, `tree_view.c` and `window_manager.c` whose paths started in the C config handler; new is one view leak in `border.c` (views owned by tables, the known class).
  - V5: `run` 28/28 (first try 27/28, see surprises), `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 13 ms, Dock pid unchanged), `launch` 3/3; asan `run` 28/28 and tsan `run` 28/28, both without reports. Crash reports 30 before and after. `deploy.sh restore` done; `sa_version.py` back at 2.1.33.
  - V6: `ipc_compare.sh` (now ~1,760 lines of output) is byte-identical between the P5 release build and the installed build, each right after a restart; the asan and tsan builds differ only in `--display mouse` (cursor) and the windows of space 4 (the test apps were closed). A `window_focused` signal runs; `debug_output on` logs `EVENT_HANDLER_DAEMON_MESSAGE: query --spaces --space 4`.
  - Bench (V5 step 2, same windows): P5 tab focus 28.3 / 27.1, rotate 153.3 / 155.1, split focus 27.3 / 28.7 ms; installed build 25.0 / 27.0, 153.9 / 146.8, 28.1 / 27.5 ms. Within 10% of the P0 baseline.
- Deviations from plan / surprises:
  - The plan says the socket thread does "accept/read". The message is still read on the event loop, as in C (with the 1 s socket timeouts and their NOTE): reading on the accept thread would let one stalled client hold up every other client instead of the event loop, a behavior change. P7 can decide with `.daemonMessage`.
  - `handle_message` moved to Swift in this phase (the plan does not name it), because the Swift dispatch is what lets the config domain write into a `Response` while the other domains are C.
  - Two null bytes are appended to every received message, so a message without its empty last token cannot make get_token read past the buffer (C read past it, into the temporary storage). A negative length closes the connection.
  - The tab_bar_offset check `float == (int) float` converts like arm64's `fcvtzs` (saturating, NaN → 0, `cInt` in `MessageConfig.swift`), since Swift's `Int32(Float)` traps where C was undefined.
  - The test target `YabaiTests` was added now (plan: P6) for the config tests, which need the C managers.
  - `live.py run` failed "daemon still running (same pid)" once: right after a deploy `pgrep -x yabai` listed the daemon and a `yabai -m config layout tree` client of the yabairc, which takes seconds while every space is laid out again; at the end only the daemon was left. The installed build's restart showed the same two pids. `live.py` now compares `pgrep -ox yabai` (oldest), noted in `doc/live-testing.md`.
- Pitfalls added to "Swift conventions and pitfalls": testing code of the executable (`@testable import Yabai`, serialized suites); C fields that hold an enum as `int`
- Waiting on user: nothing

### 2026-10-14 P6 [x]
- Commits: c1854e6 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: the whole phase.
  - Handlers in Swift: `handleDomainDisplay`/`handleDomainSpace` (`Sources/Yabai/IPC/MessageSpace.swift`, with `spaceCommandArrange`/`spaceCommandLayout`, `failSpaceOp`, `CommandResult`), `handleDomainWindow` (`MessageWindow.swift`: the five command groups, `parseWindowLayout`, `parseSplitOrientation`, the toggles as a switch over `WindowToggle`, `failUnmanagedWindow`), `handleDomainQuery`/`handleDomainRule`/`handleDomainSignal` (`MessageQuery.swift`). Command strings are private enums per file, as `enum Config` in P5. `handleMessage` reads a Swift `Message` built from the received bytes; `get_token`, `CMessage` and the C cursor are gone.
  - Query json in Swift: `Serialize.swift` (`displaySerialize`, `viewSerialize`, the space/window query lists, `windowInfo(for:)`/`windowInfo(forID:)`/`windowInfoSetTree`, `treeSerialize`) and `Sources/YabaiCore/Query.swift` (`DisplayProperty`/`SpaceProperty`/`WindowProperty` with their lists, `WindowSplit`, `WindowInfo.serialize`). `window_serialize` stays a `@_cdecl` entry point for the debug output of `window_manager_discovery.c`.
  - Deleted C: `message_parse.c`, `message_space.c`, `message_window.c`, `message.c`; the serializers of `display.c`, `display_manager.c`, `view.c`, `space_manager.c`, `window.c` (all of `window_info_*`, `window_property_title_ts`), `window_manager.c` and `tree_view.c`; the `*_PROPERTY_LIST` tables, `struct window_info`, `view_type_str`, `window_split_str`, `con_layout_str`; every parser shim of P4 that only the C handlers called, `handle_message` and `client_encode_message`. `src/message_parse.h` is now `src/globals.h` (only the accessors of the singletons, plus `connection_global()`).
  - `event_signal_storage_init` (`event_signal.c`) replaces the `memory_pool_init` call in `yabai.c`, so the golden fixture can set up the signal storage (see pitfalls).
  - Golden: `tests/YabaiCoreTests/Golden` moved to `tests/YabaiTests/Golden`; `goldenReplay` and `goldenCaptureCoversEveryCommand` are in `tests/YabaiTests/GoldenTests.swift` (record with `GOLDEN_RECORD=1 swift test --filter Golden`). The C replay `tests/src/golden.c` is deleted. The tests that touch the C managers nest in `@Suite(.serialized) struct DaemonState` (`tests/YabaiTests/DaemonState.swift`), since `.serialized` only orders the tests within one suite tree. `tests/YabaiTests/TreeFixtures.swift` has `treeTestLeaf`/`treeTestSplit` for P12.
  - `scripts/live-tests/ipc_compare.sh` gained ~70 P6 cases: the full json of every query and target (`--displays`/`--spaces`/`--windows` with every target, property subsets, `--tree`) and display/space/window/rule/signal commands that fail before they act.
- Resume at: next phase (P7)
- Open @_cdecl shims / C structs still shared: the P3 shims (`area_*`, `label_*`, `space_layout_*`, `space_manager_move_space_replacement`, `json_string`, used by `rule.c`/`event_signal.c`), `rule_combine_effects`, `message_loop_begin`, `daemon_message_handle`, `window_serialize`. `space_layout_parse` still has no C caller. C structs: `struct area`, `struct space_layout`, `struct rule`/`rule_effects` (P11, filled by `parseCRule` in `MessageShims.swift`), `struct signal` (P7, `parseCSignal`), and the manager/window/view/con structs the handlers and serializers read.
- Tests: C remaining 56, Swift added 6 (total ported 26/82): `message_window_layout_values`, `message_window_command_groups`, `message_space_command_groups`, `window_info_tree_fields`, `tree_view_serialize_tree` (YabaiTests), `window_info_serialize_selected` (YabaiCoreTests). Extra Swift test: `windowInfoWritesEveryPropertyInListOrder`. Golden replay 145/145 in Swift (through the Swift handlers), `goldenCaptureCoversEveryCommand` passes; 42 Swift tests in all.
- Measurements:
  - Lines (as in P5): C 12,246 · headers 3,743 · ObjC 1,022 · Swift 7,279 · C tests 1,850
  - Release `bin/yabai`: 1,308,744 B (P5: 1,241,272 B); `make install` 6.8 s incremental
  - V1 all four variants warning-free (`make -C tests` too); V2 passes; V3 36 warnings (HEAD before the phase: 34), diffed and triaged: gone are the three `a->id` NullDereference of `window_manager_{stack,warp,swap}_window` and a `dview` leak, whose paths started in the C window handler; new are a use-after-free (`window_manager.c:143`) and a NullDereference (`tree.c:112`) on paths through `window_manager_tree_move_direction` → `tree_move` → `tree_flatten(root)` that assume the root container has a parent (it never has, and `tree_flatten` never frees a parentless container), and four view leaks (views owned by tables). The functions became top-level entry points of the analyzer when their C caller went away; all are the known false-positive classes.
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 13 ms, Dock pid unchanged), `launch` 3/3; asan `run` 28/28 and tsan `run` 28/28, both without reports. Crash reports 30 before and after. `deploy.sh restore` done.
  - V6: `ipc_compare.sh` (196 commands, ~2,800 lines) is byte-identical between the P6 release build and the installed build, each right after a restart, except `query --windows` (all): the same 7 windows with identical fields, in another order (the z-order changed as the live run moved focus), and the spinner character of a terminal title. A `window_focused` signal runs for `window --focus <id>` and back.
  - Bench (V5 step 2, same windows): P6 tab focus 28.7 / 34.6, rotate 160.5 / 152.4, split focus 32.3 / 31.3 ms; installed build 32.5 / 30.5, 153.2 / 151.7, 33.4 / 33.7 ms.
- Deviations from plan / surprises:
  - `rule --list` and `signal --list` are still written by C (`window_manager_query_window_rules` → `rule_serialize`, `event_signal_list`) through `Response.appendWritten`: they serialize `struct rule`/`struct signal`, which P11/P7 port.
  - The plan names only the serializers; the collection of a window's values (`window_info_for_window`, `window_info_for_window_id`, `window_info_set_tree`, …) moved too, because `window_info_tree_fields` tests it and nothing else used it.
  - A non-AX window whose `proc_name` fails gets app "" (C kept the name of the previous such window in its static buffer). App names, titles and roles are Swift `String`s, so invalid UTF-8 (only a truncated `proc_name`) would come out as U+FFFD, like the labels since P3.
  - The `window --toggle` handler checks the toggle before it needs an acting window (C ran the same checks in another order); the results are the same.
- Pitfalls added to "Swift conventions and pitfalls": header functions with a body that are not `static` (duplicate symbol in the test target, `memory_pool_init`)
- Waiting on user: nothing

### 2026-10-14 P7 [x]
- Commits: b36d9e2 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: the whole phase.
  - `Sources/Yabai/EventLoop.swift`: the global actor `WM` (executor: `DispatchSerialQueue` "yabai.wm", default QoS like the C pthread, an autorelease pool per work item), `WM.assumeIsolated` (see pitfalls), the `Event` enum (one case per `EVENT_TYPE_LIST` entry; ids as associated values, C objects and retained CF objects in a `Handoff` wrapper), `EventLoop.post` (`queue.async { WM.assumeIsolated { handle; eventSignalFlush; ts_reset_storage } }`), the `@_cdecl` shim `event_loop_post(type, context, param1)` (the `struct event_loop *` parameter is gone; every C caller drops `&g_event_loop`), and `handle`, which calls the C handlers. The handlers lost `static`; `event_loop.h` declares them through the X-macro.
  - `event_loop.c`, `memory_pool.h`, `event_signal.c`, `g_event_loop`, `g_signal_event`, `g_signal_storage`, `event_signal_storage_init` and `tests/src/event_signal.c` are deleted. `event_signal.h` keeps `enum signal_type` and the prototype of the `event_signal_push` shim (the C handlers push signals). `ts_reset_storage` (`ts.h`) resets the temporary storage after each event.
  - Signals: `Sources/YabaiCore/EventSignal.swift` (`SignalType` with the names of `signal_type_str`, `PendingSignal` = `struct event_signal` with `filters` = `event_signal_filter`, `SignalTable` = `g_signal_event` with add/remove/`list`, the `signal --list` json), `Sources/Yabai/EventSignal.swift` (the `@WM` state `eventSignals`/`pendingSignals`, the describe functions on the C structs, `eventSignalPush`, `eventSignalFlush`, `eventSignalSpawn`). The signal domain uses them directly (`parseCSignal` is gone); `handleMessage` and `handleDomainSignal` are `@WM`, and `daemon_message_handle` enters `@WM` with `WM.assumeIsolated`.
  - `Sources/Yabai/Log.swift`: `debug(_:)` for Swift, written to C's stdout (`stdout_global()`), so the lines keep their order with the C debug output. `globals.h` gained `process_manager_global`, `stdout_global`, `environ_global`.
  - `AGENTS.md` (event loop, signals, file list), `doc/live-testing.md` (signals no longer fork) updated.
- Resume at: next phase (P8)
- Open @_cdecl shims / C structs still shared: the P6 list, plus `event_loop_post` (called by every C producer until P8/P10/P13 port them), `event_signal_push` (called by the C handlers until P8). C structs: unchanged from P6 minus `struct signal`/`struct event_signal`/`struct event_loop` (deleted).
- Tests: C remaining 53, Swift added 3 (total ported 29/82): `event_signal_filter_properties`, `event_signal_args` (YabaiCoreTests), `event_signal_describe_spaces` (YabaiTests). Extra Swift tests: `signalTypeNames`, `signalTableAddsRemovesAndLists`. Golden replay 145/145 (now `@Test @WM`), `goldenCaptureCoversEveryCommand` passes; 47 Swift tests in all.
- Measurements:
  - Lines (as in P6): C 11,670 · headers 3,616 · ObjC 1,019 · Swift 8,148 · C tests 1,783
  - Release `bin/yabai`: 1,360,440 B (P6: 1,308,744 B)
  - V1 all four variants warning-free (`make -C tests` too); V2 passes; V3 39 warnings (HEAD before the phase: 36), diffed: the three new ones are view leaks (views owned by tables, the known class) in `event_handlers_mouse.c` (`MOUSE_DRAGGED`), `event_handlers_space.c` and `window_manager.c:1223`: the handlers are no longer `static`, so the analyzer starts paths in them.
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 15 ms, Dock pid unchanged), `launch` 3/3 (13 attempts, gave up; queries median 19 ms, max 1008 ms); asan `run` 28/28 and tsan `run` 28/28, both without reports (tsan also with two signals firing). Crash reports 26 before and after (older ones aged out). `deploy.sh restore` done; `sa_version.py` back at 2.1.33.
  - V6: `ipc_compare.sh` (246 commands) is byte-identical between the P7 release build and the installed build, each right after a restart, except 10 window queries of space 4, whose windows `bench.py` had rotated between the two captures. A labeled `window_focused` signal gets `$YABAI_WINDOW_ID` for `window --focus <id>` and back, a second one with `app=^NoSuchApp$` is filtered out, `space_changed` gets the four space variables (14 4 23 2, then 23 2 14 4); `debug_output on` logs `event_signal_flush: transmitting window_focused to 2 subscriber(s)`.
  - Bench (V5 step 2, same windows): P7 tab focus 25.1 / 24.6, rotate 158.7 / 152.4, split focus 18.8 / 21.6 ms; installed build 21.7 / 23.2, 150.1 / 153.9, 21.7 / 23.2 ms. Within 10% of the P0 baseline (30.8 / 31.5, 150.5 / 147.2, 30.3 / 28.7 ms).
- Deviations from plan / surprises:
  - Signal commands: Swift cannot call `fork` (unavailable), so the filters run on the event loop and `posix_spawn` starts `/usr/bin/env NAME=VALUE… sh -c <action>` for each matching signal, with the daemon's environment. C forked a copy of the daemon per event, which forked and exec'd each command. Differences: a command's parent is the daemon (`$PPID`), not launchd; the `transmitting … subscriber(s)` debug line is printed by the daemon now (the forked C copy wrote it into its stdout buffer and left with `_exit`, so it never reached the log); a value of more than 127 bytes is no longer cut (the values are ids and mode names); there is no cap of 2,520 pushed signals per event (the C storage was 256 KB).
  - The C handlers stay C and the plan's `signals.flush()` is `eventSignalFlush()`; `handle` calls the handlers with the context and param1 they were posted with, so P8 can replace them case by case.
  - The plan's TSan expectation: the two known `APPLICATION_LAUNCHED` reports did not show up (none since P3 either); dispatch is a happens-before edge that TSan models, the C queue was not.
  - The Event cases keep the C producers' contexts: `Handoff<UnsafeMutablePointer<process>>`, `Handoff<Unmanaged<AXUIElement>>` (`WINDOW_CREATED`), `Handoff<Unmanaged<CGEvent>>` (mouse); the handler still releases the CF objects. `MISSION_CONTROL_ENTER` is never posted (its notification went in P1), the case stays with its handler.
- Pitfalls added to "Swift conventions and pitfalls": `fork`/`environ` unavailable in Swift; a custom global actor has no static `assumeIsolated` (and sending non-Sendable captures into it); locals named like a C type
- Waiting on user: nothing

### 2026-10-14 P8 [~]
- Commits: 0f43b19 (port), f8b995a (dead `event_signal_push` shim removed), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (nothing newer on master)
- Done: the code of the whole phase, V1–V3, part of V5.
  - `event_handlers.c`, `event_handlers_{window,space,mouse,system}.c` and `mission_control.c` are deleted. Their handlers are `@WM` functions in `Sources/Yabai/EventHandlers.swift` (shared helpers, `windowDidReceiveFocus`, the `:AXBatching` helpers, the application handlers), `EventHandlersWindow.swift`, `EventHandlersSpace.swift`, `EventHandlersMouse.swift` and `EventHandlersSystem.swift`, in the order of the C files; `handle` in `EventLoop.swift` calls them and takes the retained CF objects of the events (`takeRetainedValue`). The debug lines keep their C text (`EVENT_HANDLER_<NAME>: …`, `application_launch_retry: …`). `EVENT_HANDLER` and the handler prototypes are gone from `event_loop.h`.
  - `MissionControl.swift`: `connection_handler` (`@_cdecl`, registered by yabai_main), the Dock's AX observer (`mission_control_observe` `@_cdecl`, `missionControlUnobserve`; its state is `nonisolated(unsafe)` with a NOTE). `src/mission_control.h` (new) keeps `enum mission_control_mode`, the C global `g_mission_control_mode` (yabai.c) and `mission_control_is_active`, which `space_manager.c` and `display_manager.c` read; Swift writes it through `mission_control_mode_global()` (`globals.h`).
  - The cross-thread flags `__pending_window_focus`, `__pending_gesture`, `__last_gesture_time`, `__last_cmd_tab_time`, `__pending_mouse_moved/dragged` are `Atomic`s in `EventHandlers.swift`, with the same orderings; `application.c`, `space_manager.c` and `mouse_handler.c` reach them through `@_cdecl` setters/getters declared in `event_loop.h`. `update_window_notifications` is a `@_cdecl` function that is not `@WM` (yabai_main calls it before the event loop runs).
  - C helpers for Swift: `process_is_terminated`/`process_ns_application`/`process_set_ns_application` (`process_manager.h`, atomics on C memory), `window_manager_application_refresh_index`/`window_manager_remove_application_refresh` (`window_manager.h`, sbuffer macros), `workspace_context_global()`. `tableValues(_:as:)` (`EventHandlers.swift`) walks a C hash table like `table_for`.
  - `event_signal_push` (`@_cdecl`) and `src/event_signal.h` are deleted: no C code pushes signals anymore.
  - `AGENTS.md` (event loop, signals), `doc/live-testing.md` (former TSan noise) updated.
- Resume at: V5 of this phase, after the user has unlocked the screen (see surprises). Check first that `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` is not 1 (a scratch Swift script). Then `live.py setup`, `deploy.sh install`, `live.py run P8` → `extra P8` → `cleanup` → `launch P8`; then `deploy.sh asan` and `deploy.sh tsan` with a short `live.py run` each (setup/cleanup around them); bench of the installed build for V5 step 2 if wanted (the P8 numbers below are valid); `crashes.py`; V6 signal spot check; `deploy.sh restore`. Then set P8 to `[x]`.
- Open @_cdecl shims / C structs still shared: the P7 list minus `event_signal_push`, plus `connection_handler`, `mission_control_observe`, `update_window_notifications`, `pending_window_focus(_set)`, `pending_gesture_set`, `last_gesture_time_set`, `pending_mouse_dragged_add`, `pending_mouse_moved_add`. C globals still shared: `g_mission_control_mode`, `g_workspace_context`. C structs: unchanged from P7.
- Tests: C remaining 50, Swift added 3 (total ported 32/82): `mouse_event_coalescing`, `application_launch_retry_backoff`, `mouse_resize_handle` (`tests/YabaiTests/EventHandlerTests.swift`). `mouse_drop_action_regions` stays C: it tests `mouse_determine_drop_action` in `mouse_handler.c`, which is P13's. Golden replay 145/145, `goldenCaptureCoversEveryCommand` passes; 50 Swift tests in all.
- Measurements:
  - Lines (as in P7): C 9,993 · headers 3,628 · ObjC 1,013 · Swift 9,970 · C tests 1,729
  - Release `bin/yabai`: 1,401,816 B (P7: 1,360,440 B)
  - V1 all four variants warning-free (`make install` with `-warnings-as-errors`), `bin/yabai --version` = yabai-v7.1.25; V2 passes (Swift 50/50, C 50/50 under ASan/UBSan, no reports)
  - V3 32 warnings (HEAD before the phase: 39, diffed against a `make analyze` of 6e82559): gone are the five in the deleted handler files (three view leaks, a `dst_view` leak, the `NSRunningApplication` leak of `APPLICATION_LAUNCHED`) and three whose paths started in the C handlers (`tree.c:112` and `tree.c:987:50` NullDereference, `window_manager.c:143` use-after-free); the `space_manager.c` lines moved up by one (an `extern` went). New is one: `tree_view.c:258` use-after-free, on a path from `mouse_drop` (`mouse_handler.c`, a top-level entry now that MOUSE_UP is Swift) through `tree_flatten` → `con_free` that then takes the freed container, which had a parent, for `view->tree` (a root never has a parent): the known class of P6.
  - V5 (partial, P8 release build): bench after `live.py setup` → `deploy.sh install`: tab focus 25.4 / 26.3, rotate 159.5 / 151.2, split focus 26.9 / 24.1 ms (P0 baseline 30.8 / 31.5, 150.5 / 147.2, 30.3 / 28.7 ms; rotate +6%). The installed build's bench afterwards is not usable (the screen locked during it: base-A 27.1 / 150.5 / 17.8, base-B 16.7 / 18.8 / 17.0 ms, moves no longer applied). Crash reports 26 before and after. `deploy.sh restore` done.
  - V6 (partial): `ipc_compare.sh` on the P8 build and on the installed build, each right after a restart: identical except a Calculator tooltip window (`AXHelpTag`, floating) that existed during the P8 capture, `last-window`, and the `--window` queries, which resolved to another focused window because `bench.py` moved focus between the two captures.
- Deviations from plan / surprises:
  - `ffm_window_to_focus` (focus follows mouse, autofocus) called `CFRelease` on the role that `window_role` returns, which is the window's own `window->role` (not a +1 reference): one release too many for every associated window with a role. The Swift port takes the role unretained (NOTE in `ffmWindowToFocus`). Master has the same bug (`src/event_handlers_mouse.c:233`); reported to the user.
  - The AX element of `WINDOW_CREATED` is taken with `takeRetainedValue()` and passed to the `CF_CONSUMED` parameter of `window_manager_create_and_add_window`; Swift retains it for the call (checked in SIL), so the counts match C. The `__fence` value of `AXUIElementCopyAttributeValue` is released by Swift (C leaked it).
  - `CHECK_FOR_EXIT` reads the window list through Foundation bridging instead of CFDictionary calls; a NULL list counts as "Dock window not found" (C would have crashed).
  - Locked screen: after the bench the user's screen locked (23:40). While it is locked, AX reports no windows of any application (System Events too), so the redeployed daemon spent ~40 s in `window_manager_add_existing_application_windows` (AX timeouts) and `live.py run` found 0 windows, then (with freshly launched apps) none of them managed. Check the lock state before a live run.
- Pitfalls added to "Swift conventions and pitfalls": no atomics on C memory (C accessors or Swift-owned `Atomic`; wrapping ops); `#expect` cannot capture a non-copyable value; Swift honors `CF_CONSUMED`
- Waiting on user: unlocking the screen for the rest of V5 (no scripting-addition reload needed: the payload did not change); the `ffm_window_to_focus` over-release on master

### 2026-10-15 P8 [x]
- Commits: the commit that adds this entry, on swift-port (code unchanged since f8b995a)
- Master synced to: 4754520 (nothing newer on master)
- Done: the rest of V5 and V6, with the screen unlocked (checked with `CGSessionCopyCurrentDictionary()` first).
- Resume at: next phase (P9)
- Open @_cdecl shims / C structs still shared: unchanged from the P8 [~] entry
- Tests: C remaining 50, Swift added 0 this session (total ported 32/82)
- Measurements:
  - V5 (P8 release build): `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 17 ms, Dock pid unchanged, footprint 48 MB), `launch` 3/3 (13 attempts, gave up; queries median 13 ms, max 1009 ms); asan `run` 28/28 and tsan `run` 28/28, both without reports. Crash reports 15 before and after (older ones aged out). `deploy.sh restore` done; `sa_version.py` at 2.1.33.
  - Bench (V5 step 2, same windows): P8 tab focus 22.3 / 22.7, rotate 121.5 / 116.2, split focus 21.3 / 21.8 ms; installed build 22.1 / 21.9, 125.9 / 112.7, 21.6 / 21.1 ms. Within 10% of the P0 baseline.
  - V6: a labeled `window_focused` signal gets `$YABAI_WINDOW_ID` for `window --focus <id>` and back, a `space_changed` signal gets `5 4` and `4 5` for `space --focus 5` and back.
- Deviations from plan / surprises: none
- Pitfalls added to "Swift conventions and pitfalls": none
- Waiting on user: nothing (the `ffm_window_to_focus` over-release on master is still reported, not fixed)

### 2026-10-15 P9 [x]
- Commits: 91b5393 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (`git log 4754520..master -- src tests doc` is empty; nothing newer on master)
- Done: the port of the six files and their tests, V1–V6 except the two checks in Waiting on user. The struct conversion is partial, see Deviations.
  - Ported, C names kept as `@_cdecl` with the C signatures (the prototypes stay in the headers, each with an "implemented in" line):
    - `display.c` → `Display.swift`: `display_handler` (`displayReconfigured`), `display_uuid`/`display_id`, `display_bounds_constrained`, `display_center`, `display_space_id`, `display_space_list`.
    - `display_manager.c` → `DisplayManager.swift`: arrangement (the `CFArraySortValues` comparator, so ties sort as before), builtin_display_last, the closest display, focus, `display_manager_begin`.
    - `space.c` → `Space.swift`: `space_window_list_for_connection` (NULL on a failed query, NULL with count 0 on an empty one), `space_window_list`, `space_is_user`/`fullscreen`/`visible`.
    - `view.c` → `View.swift`: the view functions, with `view_root_area` as an internal helper (it was static).
    - `space_layout.c` → `SpaceLayout.swift`: `space_layout_reconcile`, `space_layout_schedule`.
    - `space_manager.c` → `SpaceManager.swift`: everything else, in the C order; `space_manager_can_use_known_focus` is internal (the test uses it).
  - Pure YabaiCore: `SpaceWindow.swift` (the predicates of `space.h`), `SpaceList.indexOf`/`neighbour` (`SpaceList.swift`), `ViewArea.swift` (`autoPaddingApplies`, `rootArea`, `windowGap`).
  - Platform: `SLS` wrappers for the display, cursor, dock and Platform calls (`SkyLight.swift`); `SLS.windows` now returns nil on failure, which `space_window_list_for_connection` needs (NULL with the count untouched, versus an empty list). `SLS.bridgedMoveWindows` runs `[[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:spaceID:]` through objc_msgSend (dlsym).
  - `CPrivate.h`: `SLSHasBridgedWindowOperation`/`SLSPerformBridgedWindowOperation` (Swift 6 rejects the C function pointer), `CGPostMouseEventC` (CGPostMouseEvent is unavailable to Swift).
  - C side: the six `.c` files and `tests/src/{space_list,auto_padding,space_window}.c` are deleted; `window_manager.h` gains `window_manager_application_refresh_count`/`_at` (sbuffer access); `ts.h` gains `ts_list_from_bytes` (aligned temporary lists for C callers).
  - Tests: `space_list_navigation`, `space_window_user_predicates`, `auto_padding_applies`, `auto_padding_root_area` (YabaiCoreTests); `auto_padding_tiled_count`, `auto_padding_gap`, `auto_padding_split_in_tab` (`tests/YabaiTests/ViewTests.swift`, in DaemonState because they build trees); `space_known_focus` (`tests/YabaiTests/SpaceManagerTests.swift`).
  - AGENTS.md (the file list of the display and space logic), `doc/live-testing.md` (the setup/cleanup order and the Swift test pointers), the swift-port-conventions skill (pitfalls below).
- Resume at: next phase (P10). `workspace_display_notch_height` (workspace.m, P10) is still called from `display_bounds_constrained`.
- Open @_cdecl shims / C structs still shared: the P8 list, minus the C files; plus the P9 shims in `display.h`, `display_manager.h`, `space.h`, `view.h`, `space_layout.h` and `space_manager.h`. `space_manager_move_space_replacement` (SpaceLayoutShims) has no caller left: SpaceManager.swift uses `SpaceList.moveReplacement` directly. C structs still shared: `struct view` (tree.c, tree_view.c, window_manager*.c, border.c, tab_bar.c, mouse_handler.c, rule.c), `struct space_manager` (`g_space_manager`: border.c, rule.c, window_manager*.c, tab_bar.c, yabai.c), `struct display_manager` (`g_display_manager`: window_manager*.c, mouse_handler.c, rule.c, yabai.c), `struct space_layout` (inside space_manager), and the view table `struct table view` (walked by tab_bar.c's `table_for`).
- Tests: C remaining 42, Swift added 8 (total ported 40/82). `make test`: Swift YabaiTests 17 tests in 5 suites and YabaiCoreTests 41 tests pass; the C harness 42 succeeded, 0 failed (ASan/UBSan). Golden replay (`goldenReplay`, 145 commands, byte-identical) and `goldenCaptureCoversEveryCommand` pass.
- Measurements:
  - Lines (`git ls-files`; Swift counts the new untracked files too): C 8,077 (P8: 9,993) · headers 3,620 (P8: 3,628) · ObjC 1,007 · OSAX 1,435 · Swift 12,465 in 70 files (P8: 9,970) · C tests 1,364.
  - Release `bin/yabai`: 1,437,432 B (P8: 1,401,816 B). `make install`: 1.4 s incremental (a fresh build time was not measured).
  - V1: `make`, `make install` (warnings as errors), `make asan`, `make tsan` exit 0 with no warnings; `bin/yabai --version` = yabai-v7.1.25.
  - V3: `make analyze` reports 10 warnings, all in files this phase did not touch (`tree.c`, `tree_view.c`, `window_manager.c`, `window_animation.c`, `sa.m`, `notify.h`, `helpers.h`). The P8 list was not kept, so I could not diff it line by line; the drop from 32 comes from the C paths that now end in Swift.
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP: hotkey disabled; 50 space switches, median 17 ms, Dock pid unchanged), `launch` 3/3 (13 attempts, gave up; queries median 11 ms, max 1007 ms). ASan `run` 28/28 after a `cleanup` + `setup` (first try 25/28, see Deviations), TSan `run` 28/28. No sanitizer reports; crash reports 15 before and after.
  - Bench (V5 step 2, the same windows: setup → P9 install → P9-A/B → restore → base-A/B): P9 tab focus 21.1 / 22.6, rotate 150.1 / 156.1, split focus 19.8 / 20.5 ms; master 20.5 / 20.5, 160.9 / 161.0, 20.3 / 20.1 ms. Tab focus is +7% on the two-run medians (+10% in run B); the rest is at or below master. `deploy.sh restore` done (master 1,997,680 B back in place).
  - V6: `ipc_compare.sh` (255 commands) is byte-identical between the P9 release build and the master build on the same state (no change between the two captures). A labeled `space_changed` signal fires once per focus (`13 5` for `space --focus 5`, `14 4` back). The window send "send to visible space on other display" passes in `run`.
- Deviations from plan / surprises:
  - The plan says to convert `struct view` and the display/space manager state into Swift classes. Not done: their C users (P11–P13) read the fields, and the Target architecture rule converts a struct when its last C user is Swift. The Swift code works on the C structs through pointers, as the P8 handlers do.
  - Naming: the functions keep their C names as `@_cdecl` (bridge rule 1), not the `FooBar.baz` naming. Two use Swift names, `spaceManagerFindView` and `viewCreate` (with `@_cdecl`), because a Swift function returning `View` made every Swift caller of the C import (which returns `View!`) ambiguous.
  - `static inline` predicates of `space.h` moved to YabaiCore (`SpaceWindow`); `space_window_is_user_window` remains a C-visible shim for process_manager.c.
  - Small behavior edges (none seen live): `display_manager_set_active_display_id` does nothing for an unknown display (C passed a NULL uuid to SLS); `display_manager_focus_display_with_window_at_point` uses owner connection 0 when SLS does not answer (C read an uninitialized value). `view_destroy` still does not free the struct, as before.
  - The first ASan `run` gave 25/28 (a row of 10 tiled windows where the checks expect 5; focus checks one window off). The cause was the harness: `setup` stacked on the windows that the benches and IPC captures had left on space 4. After `cleanup` and `setup` it was 28/28. Written in `doc/live-testing.md`.
  - The `output-summarizer` subagent refused to run `make` (it writes `bin/` and `.build/`). I ran the builds myself with the output in the scratchpad logs and read only the error lines.
  - Test target: `YabaiC` and `@testable import Yabai` both export `view_auto_padding_applies`, so the test calls `Yabai.view_auto_padding_applies`.
  - Not run (see Waiting on user): `space --display` moves (`space_manager_move_space_to_display`) and `space_layout_reconcile` on a display add or remove. Both change the user's space order on the two displays.
- Pitfalls added to "Swift conventions and pitfalls": a Swift `@_cdecl` function with its C prototype's name (ambiguity, test targets); `@discardableResult` lost on shadowing; anonymous and `CF_ENUM` C types; C calls that are unavailable to Swift (`CGPostMouseEvent`, the `CGEvent` functions) through a CPrivate wrapper; global `let`s of C function-pointer types; `sel_registerName` returns `Selector`; C comparator callbacks receive optional pointers.
- Waiting on user (V6 checks that need your displays, not run):
  - Unplug and replug the external display: `space_layout_reconcile` should bring the spaces back to the count of the layout, if your `space_layout` option is set. The log shows its steps as `space_layout_reconcile:` lines when debug output is on.
  - Move one of your spaces to the other display and back with `yabai -m space <n> --display <d>`. Each move changes the order of the spaces on both displays, so choose a space the harness uses (4–8 or 12–14) or do it yourself.
  - No scripting-addition reload is needed: `sa.m` and `OSAX_VERSION` are unchanged.

### 2026-10-15 P9 [x] (review)
- Commits: the commit that adds this entry, on swift-port (a review of 91b5393, which an earlier session wrote with a smaller model)
- Master synced to: 4754520 (unchanged)
- Done: a line-by-line review of the six ported files and their tests against the deleted C. No behavior errors found. Fixed:
  - CF ownership at the C boundary: Swift returns a CF object from a `@_cdecl` function `@autoreleased` (+0, checked with `-emit-sil` and a C caller), but `display.h` and `display_manager.h` declare `display_uuid`, `display_manager_active_display_uuid`, `display_manager_dock_display_uuid`, `display_manager_point_display_uuid` and `display_manager_arrangement_display_uuid` `CF_RETURNS_RETAINED`. No C code calls them yet; a C caller that released the result would have over-released it when the pool drained. Their `@_cdecl` entry points now return `Unmanaged<CFString>?` at +1 under Swift names (`displayUUIDRetained`, …); Swift code uses `displayUUID`, `displayManagerArrangementDisplayUUID` (Display.swift, DisplayManager.swift, `displayUUIDText` in Serialize.swift).
  - Dead shims removed: `space_layout_targets`, `space_layout_move_candidate` and `space_manager_move_space_replacement` (SpaceLayoutShims.swift, with their prototypes in `space_layout.h` / `space_manager.h`). Their only C caller was `space_layout.c`; the P9 [x] entry named only the last one. `space_layout_parse` stays (MessageConfig.swift calls it).
  - The two V6 checks of the plan's Done-when that the P9 [x] entry left to the user, run with a test build of this tree (see Measurements).
- Resume at: next phase (P10)
- Open @_cdecl shims / C structs still shared: the P9 [x] list, minus the three removed shims.
- Tests: unchanged (C remaining 42, total ported 40/82). `make test`: YabaiTests 17, YabaiCoreTests 41, C 42/42 (ASan/UBSan); `make install` exits 0 without warnings.
- Measurements (`deploy.sh install` of this tree, then `restore`; daemon pid unchanged throughout, crash reports 15 before and after, no new lines in the error log besides the known noise):
  - `space --display`, a hidden space: 14 (sid 19) to display 1 and back; the scripting addition puts it after the focused space (index 4), and back on display 2 at index 13. 10:5 before and after; `space 14 --move prev` put the order of display 2 back.
  - `space --display`, the focused space: 15 (sid 20, focused on display 2) to display 1: display 2 shows the replacement 18 (the previous user space), 20 is focused at index 4 of display 1; back to display 2: 20 focused there, display 1 shows 15 again. `space 11 --display 2` fails with "acting space is already located on the given display.".
  - Display removal, simulated by mirroring display 2 onto display 1 (`CGConfigureDisplayMirrorOfDisplay`, `kCGConfigureForAppOnly`, with `space_layout 15 10:5 10:5:1b`): macOS moved 17–20 to display 1 and merged the visible space 319 of display 2 into space 1 (its two windows), so 14 user spaces; one reconcile pass, `create space on display 1 (14/15)`, gave 15.
  - Display re-added (unmirror): macOS moved 17–20 back and put the two windows on a new space 348 on display 2; one pass, `destroy empty space 347 on display 1 (11/10)`, gave 10:5. Every window was back on its space.
- Deviations from plan / surprises: test coverage that the ports dropped, not fixed: `auto_padding_applies` tests `ViewArea` only, so the `layout == VIEW_TREE` mapping of `view_auto_padding_applies` (C checked `VIEW_DEFAULT`) is untested; `auto_padding_root_area` no longer goes through `view_root_area`, which reads the flags and padding of the view.
- Pitfalls added to "Swift conventions and pitfalls": CF objects returned from `@_cdecl` are autoreleased.
- Waiting on user: nothing. Space 11 has a new id (348) after the simulated replug, as after a real one; the trees of all spaces were reset by the deploys.

### 2026-10-15 P10 [x]
- Commits: 5f6e386 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (`git log 4754520..master -- src tests doc` is empty)
- Done: the whole phase.
  - `process_manager.c` → `Sources/Yabai/ProcessManager.swift`: the Carbon event handler (`processHandler`, context `pm`, NOTE), `process_create`, the debugger check (sysctl), `process_manager_active_space_for_psn` (on `missionControlSpaces`, `SLS.windows`, `SLS.queryWindows`, `SpaceWindow.isUserWindow`), `process_manager_begin` (`@_cdecl`), `process_manager_find_process`, `process_destroy`.
  - `application.c` → `Application.swift`: the AX observer callback (also for the notifications `window_observe` registers; the context NOTE says who owns the application/window), `application_observe`/`unobserve`/`focused_window`/`create`/`destroy` and `application_window_list` (`@_cdecl`; the last one as `applicationWindowListRetained` returning `Unmanaged` at +1, because the prototype is `CF_RETURNS_RETAINED`), `application_is_frontmost`/`is_hidden`. `axErrorName` (`Platform/AX.swift`) replaces `ax_error_str` for Swift; the C table stays for `window.c`.
  - `workspace.m` → `Workspace.swift`: `WorkspaceContext` (`NSObject`, `Sendable`, no state): the eight notifications and the key-value observer; a private global replaces `g_workspace_context`, so the `workspace_*` functions lost their `void *context` parameter (`window_manager.c` and `EventHandlers.swift` updated, `workspace_context_global` deleted). `process->ns_application` holds the `NSRunningApplication` at +1 (`passRetained`).
  - `CPrivate.h`: `ProcessGetNextC`, `ProcessGetPIDC`, `ProcessGetTypeC`, `ProcessCopyNameC`, `ProcessIsVisibleC` (the Process Manager is unavailable to Swift) and `NSObjectRemoveObserverC` (ObjC `@try`, inside `#ifdef __OBJC__`; Swift cannot catch the NSException of removing an unregistered observation). `process_manager.h` gains `process_set_terminated` and `process_is_terminated_acquire` (the KVO callback read with acquire).
  - Deleted: `src/process_manager.c`, `src/application.c`, `src/workspace.m`, the notification tables and `OBSERVER_CALLBACK` of `application.h`, `PROCESS_EVENT_HANDLER`, the `@interface workspace_context`. The headers keep only the prototypes that C still calls, each with an "implemented in" line; Swift-only functions keep their C names without `@_cdecl`.
  - AGENTS.md (global singletons, event loop producers), the swift-port-conventions skill (pitfalls below).
- Resume at: next phase (P11)
- Open @_cdecl shims / C structs still shared: the P9 review list, plus `process_manager_begin`, `workspace_event_handler_begin` (yabai.c), `workspace_application_is_observable`, `workspace_application_observe_activation_policy` (window_manager.c), `application_create`/`destroy`/`observe`/`unobserve` (window_manager.c), `application_focused_window` (window_manager_focus.c), `application_window_list` (window_manager_discovery.c). C structs still shared: `struct process` and `struct process_manager` (`g_process_manager`: `finder_psn` and the process table in window_manager.c and window_manager_scratchpad.c), `struct application` (window*.c, `icon` in tab_bar.c).
- Tests: C remaining 42, Swift added 0 (total ported 40/82); the plan names no tests for P10. `make test`: YabaiTests 17, YabaiCoreTests 41, C 42/42 (ASan/UBSan); golden replay and `goldenCaptureCoversEveryCommand` pass.
- Measurements:
  - Lines (`git ls-files`): C 7,692 (P9: 8,077) · headers 3,622 · ObjC outside osax 700 (P9: 1,007) · Swift 13,064 in 69 files (Sources and tests).
  - Release `bin/yabai`: 1,474,152 B (P9: 1,437,432 B).
  - V1: `make`, `make install` (warnings as errors), `make asan`, `make tsan` exit 0 with no warnings; `bin/yabai --version` = yabai-v7.1.25.
  - V3: `make analyze` reports the same 10 warnings as P9, none in the ported code. For the next diff: `helpers.h:289` CFNumber, `notify.h:31` leak, `sa.m:432` blocking recv, `tree_view.c:219/286/433/476` and `tree.c:987` NullDereference, `window_animation.c:114` garbage value, `window_manager.c:161` NullDereference.
  - V5: `run` 28/28 (the test apps were launched while the daemon ran, through the new Carbon handler), `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 10 ms, Dock pid unchanged, footprint 47 MB), `launch` 3/3 (13 attempts in 120 s, gave up; queries median 12 ms, max 1019 ms; the app gets managed when activated). ASan `run` 28/28 and TSan `run` 28/28, no sanitizer reports. Crash reports 15 before and after. `deploy.sh restore` done; `sa_version.py` 2.1.33.
  - Bench (V5 step 2, same windows: setup → P10 install → P10-A/B → restore → base-A/B): P10 tab focus 33.7 / 33.1, rotate 116.0 / 128.3, split focus 32.7 / 32.8 ms; installed build 32.7 / 32.2, 135.2 / 129.2, 33.0 / 32.8 ms. P10 matches the installed build; both are slower than in P9's session (the layout state; see V5 step 2).
  - V6: `ipc_compare.sh` (255 commands), each capture right after a restart: both builds list the same 11 windows; 12 commands differ, all queries of space 4, the focused window or the tree (focus, frames, split type), which the P10 bench changed between the two captures. Labeled signals `application_hidden`, `application_visible`, `application_terminated`, `application_launched` fired with the right `$YABAI_PROCESS_ID` for hiding, showing, quitting and reopening Calculator (System Events / `open`), and the new Calculator window was managed.
- Deviations from plan / surprises:
  - The plan says the NSWorkspace/KVO observers become Swift observers; done, but the KVO removal goes through the ObjC wrapper `NSObjectRemoveObserverC` in `CPrivate.h`, because the C code depends on catching the exception (the initial-value callback runs inside `addObserver`, before the observation is registered, so removing it there throws). P14 keeps this wrapper (CPrivate stays).
  - The compiler barrier (`__asm__ volatile ("" ::: "memory")`) after `terminated` in the terminate path is gone: `process_set_terminated` is a release store and `EventLoop.post` goes through dispatch (NOTE in `processHandler`).
  - `process_manager_active_space_for_psn` queries every window of the list and takes the first user window, where C stopped iterating at it; same result.
  - The KVO debug lines keep the ObjC method name of `__FUNCTION__` (`-[workspace_context observeValueForKeyPath:ofObject:change:context:]`).
  - Not checked live: the Dock restart, wake, menu bar hiding and Dock preference notifications (a `killall Dock` with a test build installed leaves Dock without the scripting addition until the user reloads it). They only post events, like the checked ones.
  - The `output-summarizer` was not used for the builds (it refused `make` in P9); the logs went to the scratchpad and I read only their error and warning lines.
- Pitfalls added to "Swift conventions and pitfalls": APIs deprecated in 10.9 or earlier are unavailable to Swift (Process Manager); Swift cannot catch an NSException; macros built from other macros do not import.
- Waiting on user: nothing. No scripting-addition reload needed (`sa.m` and `OSAX_VERSION` unchanged). The deploys reset the trees of all spaces.

### 2026-10-15 P11 [x]
- Commits: e5f4110 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (`git log 4754520..master -- src tests doc` is empty)
- Done: the whole phase.
  - Ported, in the C order of each file: `window.c` → `Window.swift`, `window_manager.c` → `WindowManager.swift`, `window_manager_discovery.c` → `WindowManagerDiscovery.swift`, `window_manager_lookup.c` → `WindowManagerLookup.swift`, `window_manager_focus.c` → `WindowManagerFocus.swift`, `window_manager_rules.c` → `WindowManagerRules.swift`, `window_manager_scratchpad.c` → `WindowManagerScratchpad.swift`, `window_manager_tree.c` → `WindowManagerTree.swift` (all in `Sources/Yabai/`). Functions that C still calls keep their C names with `@_cdecl`; the others keep their C names without it, and their prototypes are gone. `static` C helpers are private Swift functions in camelCase (`windowManagerTreeApply`, …), internal where another file or a test uses them.
  - C still calls (prototypes in `window.h` / `window_manager.h`, each block with an "implemented in" line): `window_space`, `window_title_ts`, `window_role_ts`, `window_subrole_ts`, `window_level`, `window_sub_level`, `window_is_sticky`, `window_is_standard`, `window_level_is_standard`; `window_manager_is_window_eligible`, `_find_managed_window`, `_remove_managed_window`, `_unmanage_window`, `_manage_window`, `_resize_window_relative`, `_find_window`, `_stack_window`, `_swap_window`, `_begin`, `_init`, `_rule_matches_window` and the four `_apply_*rule*` functions (rule.c).
  - Swift-only APIs that changed shape: `window_space_list`, `window_manager_find_application_windows` and `window_manager_add_application_windows` return arrays; `window_manager_create_and_add_window` and `window_create` take the `AXUIElement` and retain it themselves (no `CF_CONSUMED`); `window_title`/`window_role`/`window_subrole` return `CFString?` at +0; `application_window_list` returns `CFArray?` (no `Unmanaged`). `window_serialize` (Serialize.swift) is gone; the debug output calls `windowSerialize`.
  - C side: the eight `.c` files and `tests/src/window_rules.c` are deleted. `tree_collect_window_ids` moved to `tree.c` (its C test `tree_window_ids_collect` stays until P12); Swift reads the list with the new `ts_buf_count` (`sbuffer.h`). `window_manager.h` gains inline accessors for the sbuffers `rules`, `scratchpad_window` and `applications_to_refresh` (`buf_del` swaps in the last element, which `window_manager_remove_one_shot_rules` keeps). `g_event_bytes` (the event records are a temporary allocation per call) and `g_layer_*_window_level` (`window_level_is_standard` calls `CGWindowLevelForKey`) are gone from `yabai.c`; `ax_error_str` and the window notification tables are gone from the headers. `application.h` and `workspace.h` lost the prototypes whose last C caller was window_manager.c, and Application.swift / Workspace.swift the matching `@_cdecl`s.
  - `CPrivate`: `SLSGetWindowSubLevelBounded` in `CPrivate.c` (the bounded mach message of `window_sub_level`, see pitfalls).
  - AGENTS.md (window manager files), `doc/live-testing.md` (the SA focus opcode has no caller), the swift-port-conventions skill.
- Resume at: next phase (P12).
- Open @_cdecl shims / C structs still shared: the P10 list minus the application/workspace shims named above, plus the P11 `@_cdecl`s listed under Done. C structs still shared: `struct window` and `struct window_manager` (tree.c, tree_view.c, border.c, tab_bar.c, window_animation.c, mouse_handler.c, rule.c; `rules` is still an sbuffer of the C `struct rule` because rule.c is C), `struct application` (tab_bar.c icon, window_animation.c ref), `struct process`/`process_manager` (read by Swift only now through the table; the struct stays until its table is Swift), and the P9 list (`struct view`, `space_manager`, `display_manager`).
- Tests: C remaining 35, Swift added 7 (total ported 47/82): `window_pending_focus`, `window_unresolved_list`, `window_validity`, `window_one_shot_rules`, `window_child_windows_collect`, `window_rules_combine_matching`, `window_rules_manage_round` (`tests/YabaiTests/WindowManagerTests.swift`, on local window managers, so outside DaemonState). `make test`: YabaiTests 24, YabaiCoreTests 41, C 35/35 (ASan/UBSan); golden replay and `goldenCaptureCoversEveryCommand` pass with no re-record.
- Measurements:
  - Lines (`git ls-files`): C 4,569 (P10: 7,692) · headers 3,517 (P10: 3,622) · ObjC outside osax 692 · Swift 16,364 in 78 files (Sources and tests) · C tests 1,215.
  - Release `bin/yabai`: 1,298,136 B (P10: 1,474,152 B).
  - V1: `make`, `make install` (warnings as errors), `make asan`, `make tsan` exit 0 with no warnings; `bin/yabai --version` = yabai-v7.1.25.
  - V3: `make analyze` 10 warnings, the P10 set moved: `window_manager.c:161` (the `ts_buf_push` false positive) is now `tree.c:442` with `tree_collect_window_ids`, `tree.c:987` is `tree.c:1003` (reported for two columns), `tree_view.c:219` no longer shows; `helpers.h:289`, `notify.h:31`, `sa.m:432`, `tree_view.c:286/433/476`, `window_animation.c:114` unchanged.
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 13 ms, Dock pid unchanged, footprint 46 MB; tabbed container warp there and back 167/163 ms, swap across displays 127 ms), `launch` 3/3 (13 attempts in 120 s, gave up; queries median 28 ms, max 992 ms; activated app managed). ASan `run` 28/28 and TSan `run` 28/28, no sanitizer reports. Daemon pid unchanged in every run; crash reports 15 before and after. `deploy.sh restore` done; `sa_version.py` 2.1.33 attrib 0x5f.
  - Bench (V5 step 2, same windows: setup → P11 install → P11-A/B → restore → base-A/B): P11 tab focus 16.4 / 30.6, rotate 93.8 / 123.9, split focus 16.0 / 31.8 ms; installed build 32.2 / 33.7, 133.7 / 118.6, 32.4 / 33.3 ms. P11 is at or below the installed build (run A was faster than B for both, the layout state again).
  - V6: `ipc_compare.sh` (2,706 lines of output) is byte-identical between the P11 release build and the installed build, each captured right after a restart. On the P11 build: a labeled `manage=off` rule floated a new TextEdit window; `window --scratchpad`, two `window --toggle` (hidden, shown) and `--scratchpad` with no value (unfloated and tiled again) worked; a labeled `window_focused` signal wrote the focused ids. Focus follows mouse passes in `run` (autofocus sweep).
- Deviations from plan / surprises:
  - The plan says to convert `struct window` and `struct window_manager` with config fields as typed properties. Not done, for the reason of P9: their C users (P12, P13) read the fields. The Swift code works on the C structs through pointers.
  - The plan lists the `window_frame_*` tests for P11, but `window_frame_is_close`, `window_frame_needs_update` and `window_manager_group_window_frames` live in `window_animation.c`; the three tests move with it in P13. `window_child_windows_collect` is done here.
  - `TIME_FUNCTION` is not ported (the profiler build only), as in P8–P10. The disabled `#if 0` focus through the scripting addition (`scripting_addition_focus_window`) is not ported; a NOTE in `WindowManagerFocus.swift` names it.
  - `window_manager_tree_focus_*`, `window_manager_set_window_layout`, `window_manager_tree_split` and `window_manager_set_window_insertion` take an optional window, because the focus command runs without a window and `message_window_command_groups` passes nil; C handled NULL in `window_manager_find_tree_view` (for `set_window_insertion` C would have crashed on NULL; Swift fails with INVALID_SRC_VIEW, unreachable from the dispatcher).
  - `window_display_uuid` used an uninitialized frame when `SLSGetWindowBounds` failed; Swift uses `.zero`.
  - The first ASan `run` gave 0/1 (`setup only 0 windows`): `cleanup` focused the user's window on space 3, and `setup` waits only 0.6 s after `space --focus 4`, which the ASan daemon right after a restart did not finish, so the test apps opened on space 3. `cleanup` quit them at once. With `yabai -m space --focus 4` and a 3 s wait before `setup`, ASan and TSan gave 28/28. Not a P11 regression (the release build's setups put the windows on space 4); the harness could wait until space 4 is active.
  - The `output-summarizer` ran `make test` and the live harness; the builds ran in the main session with logs in the scratchpad, as in P9/P10.
- Pitfalls added to "Swift conventions and pitfalls": global `let`s of CF types; `NDR_record` in a header inline function (duplicate symbol, release link only); `let wm = window_manager_global()` is an Optional; C functions that accept NULL through a helper keep optional parameters; temporary lists become arrays when every caller is Swift.
- Waiting on user: nothing. No scripting-addition reload needed (`sa.m` and `OSAX_VERSION` unchanged). The deploys reset the trees of all spaces, and the ASan run briefly opened the test apps on space 3 before they were quit (see Deviations).

### 2026-10-15 P12 [x]
- Commits: acc7b04 (code), then the commit that adds this entry, on swift-port
- Master synced to: 4754520 (`git log 4754520..master -- src tests doc` is empty)
- Done: the whole phase, one-to-one.
  - `tree.c` → `Sources/Yabai/Tree.swift`, `tree_view.c` → `Sources/Yabai/TreeView.swift`, in the C order, every NOTE kept. The structural primitives (`con_insert`, `con_unlink`, `con_replace`, `con_wrap`, `con_wrap_children`, `con_reparent_children`, `tree_reap_empty`) are private Swift functions in camelCase and still work on the C arrays `children`/`focus` (realloc and memmove, as in C). Containers are allocated with `calloc` and freed with `free`.
  - C still calls (prototypes in `tree.h` under "implemented in"): `con_create`, `con_free`, `tree_attach`, `tree_focus`, `tree_update` (the C test of border.c), `tree_detach`, `tree_flatten`, `tree_find_window`, `tree_insert_relative` (mouse_handler.c), `tree_view_update`, `tree_view_find_window`, `tree_feedback_show`/`hide` (mouse_handler.c), `tree_view_window_list`, `tree_view_tiled_count`, `tree_window_border_area` (border.c), `tree_release_bars`, `tree_refresh_for_window` (tab_bar.c). These keep IUO parameters (`Con!`), so they shadow the C import in the Yabai target. Every other function keeps its C name without `@_cdecl`, and its prototype is gone.
  - Swift-only APIs that changed shape: `tree_collect_window_ids` fills a `[UInt32]` (WindowManager.swift); `tree_copy_title` returns `CFString?`; `tree_next` takes `inout Con?`; `tree_view_window_list` has the array twin `treeViewWindowList`. The tab bar redraw callback is the `@convention(c)` function `treeRenderBarCallback`; the titles of the entries stay alive in a Swift array until `tab_bar_render` returns (passUnretained).
  - C side: `src/tree.c`, `src/tree_view.c`, `tests/src/tree.c`, `tests/src/tree_view.c` deleted; the `ts_buf` lists (`sbuffer.h`, plus `ts_buf_count` of P11) are gone, nothing uses them. The C test `border_tabbed_container_area` keeps C copies of `tree_test_leaf`/`tree_test_split` in `tests/src/border.c`.
  - AGENTS.md (tree layout, test example), `doc/live-testing.md` (tree test fixtures, no `ts_buf`), the comments in `window.h`, `window_manager.h`, `Window.swift`, `View.swift` that named the C tree files.
- Resume at: next phase (P13). Its border, tab bar and mouse code are the last C users of `struct con`, so P13 (or P14) converts it into `final class Con` (Target architecture, Model conventions).
- Open @_cdecl shims / C structs still shared: the P11 list, plus the P12 `@_cdecl`s listed under Done. C structs still shared: `struct con` and `struct con_render` (mouse_handler.c reads and writes `insert_dir`, border.c and tab_bar.c go through the functions above, `struct tab_bar` lives in `con_render`), and the P11 list.
- Tests: C remaining 12, Swift added 23 (total ported 70/82): the 21 `tree_*` tests and `tree_view_window_list_order`, `tree_view_zoom_frames` (`tests/YabaiTests/TreeTests.swift`, in DaemonState). `make test`: YabaiTests 47 tests in 6 suites, YabaiCoreTests 41, C 12/12 (ASan/UBSan); golden replay and `goldenCaptureCoversEveryCommand` pass with no re-record.
- Measurements:
  - Lines (`git ls-files`): C 2,764 (P11: 4,569) · headers 3,432 (P11: 3,517) · Swift 19,373 (Sources and tests) · C tests 391 (P11: 1,215).
  - Release `bin/yabai`: 1,306,344 B (P11: 1,298,136 B).
  - V1: `make`, `make install` (warnings as errors), `make asan`, `make tsan` exit 0 with no warnings; `bin/yabai --version` = yabai-v7.1.25.
  - V3: `make analyze` 4 warnings: `helpers.h:289`, `notify.h:31`, `sa.m:432`, `window_animation.c:114` (the P11 set minus the six in the deleted tree files).
  - V5: `run` 28/28, `extra` 14/14 (+1 SKIP, hotkey disabled; 50 space switches, median 14 ms, Dock pid unchanged, footprint 47 MB; tabbed container warp there and back 188/147 ms, swap across displays 133 ms), `launch` 3/3 (13 attempts in 120 s, gave up; queries median 29 ms, max 1017 ms; activated app managed). ASan `run` 28/28, no reports; TSan `run` 28/28, no new reports (the error log holds 2 old `APPLICATION_LAUNCHED` reports from `event_handlers.c`, a file deleted in P8). Daemon pid unchanged in every run. `deploy.sh restore` done.
  - Bench (V5 step 2, same windows: setup → P12 install → P12-A/B → restore → base-A/B): P12 tab focus 33.1 / 32.9, rotate 119.1 / 126.8, split focus 31.0 / 33.1 ms; installed build 31.6 / 31.7, 128.8 / 116.5, 32.4 / 31.0 ms. Tab focus +4%, the rest at the installed build's level.
  - V6 (P12 release build, space 4): `window --insert east` on a tiled TextEdit window put the next new window to its right (840 px each); `window --focus parent`, `--focus child` and `--layout tabbed` succeed, and the tabbed layout hides one window as a tab; `--layout splith` back. The selection outline and the insert feedback were not inspected by eye.
- Deviations from plan / surprises:
  - The plan ports onto `final class Con`. Not done, for the reason of P9/P11: mouse_handler.c reads and writes `con->insert_dir` and passes containers around, and `struct con_render` holds the C `struct tab_bar` that tab_bar.c draws. The Swift code works on the C struct through pointers; the class conversion belongs to P13 or P14.
  - Five Swift tree tests failed at first: the golden replay, earlier in DaemonState, leaves `tree_workspace_layout tabbed` set, which wraps every container attached to the workspace. `TreeTests.init()` resets it (pitfall below).
  - Crash report 16 (`yabai-2026-10-15-114104.ips`) is from the installed pre-port build (pid 85271, `event_loop_run` in its stack) one minute after the first `restore`: `EXC_BAD_ACCESS` in `window_manager_apply_window_frame_group` < `window_manager_set_window_frames` < `tree_flush` < `EVENT_HANDLER_WINDOW_DESTROYED`, the same stack as the two reports of 2026-10-14. launchd restarted it (pid 85380) before the base bench. Not from the P12 build, but `window_animation.c` is P13's: look at this crash there (a window destroyed while its frame group is applied).
  - The `output-summarizer` ran `make test` and the live harness; the builds and the benches ran in the main session with logs in the scratchpad.
- Pitfalls added to "Swift conventions and pitfalls": the Swift tests have no temporary storage; the golden replay leaves its config behind; test targets need `Yabai.` for functions that also have a C prototype.
- Waiting on user: nothing. No scripting-addition reload needed (`sa.m` and `OSAX_VERSION` unchanged). The deploys reset the trees of all spaces, and the installed build crashed once and was restarted by launchd (see Deviations).

### 2026-10-15 P13 [x]
- Commits: 88f84a5 (code), then the commit that records this SHA, on swift-port
- Master synced to: 4754520 (`git log 4754520..master -- src tests doc` is empty)
- Done:
  - `border.c` → `Border.swift`: native border objects and settings behind a `Mutex`, four SkyLight edge windows, the original batching/handover and callback lock boundaries; edge-frame calculations use a fixed four-frame value to avoid allocating during moves.
  - `tab_bar.c` → `TabBar.swift`, `tab_bar_glass.c` merged into `TabBarGlass.swift`: native immutable hit/snapshot values retain their CF resources, main-queue blocks retain the panel owner, classic RGB drawing and float rounding preserved. `struct tab_bar`/`tab_bar_entry` remain at the tree boundary until P14.
  - `window_animation.c` → `WindowAnimation.swift`: `NSScreen.displayLink` on the main run loop, concurrent dispatch workers for proxy creation and application frame groups, a `Mutex` dictionary for proxy takeover/skip state. Animations hold ids, not window pointers. Frame groups own AX references and copied application names, so workers never read C models or the temporary arena. C animation/frame-group structs, animation table/lock, host-clock global and CoreVideo linkage are gone. Alpha restoration keeps the four-lane SIMD arithmetic and nearest-even rounding, with a bounded scalar tail.
  - `mouse_handler.c` → `MouseHandler.swift`: the event tap posts the same retained events and preserves drag/drop regions and feedback. `sa.m` → `ScriptingAddition.swift`: byte-array payloads preserve native field widths, opcodes, chunking, old-payload fallback, installer/injection behavior and version checks. `OSAX_VERSION` is unchanged.
  - CPrivate wrappers for unavailable Swift APIs (`system`, `popen`, `pclose`, `sscanf`, `CGWindowListCreate`), with retained ownership on the raw window-id array. Removed all six ported source files and the last three C test files; the empty C harness remains for P14. Updated the live/payload docs and P14 instructions to preserve the Swift test directories when deleting the C harness.
- Resume at: next phase (P14), beginning with the remaining shared-model/bridge conversion and C startup/rule/helper residue listed below. P13 validation is complete.
- Open @_cdecl shims / C structs still shared: all earlier model bridges remain for P14. New Swift implementations keep border/tab-bar/glass prototypes still exposed by the headers, `mouse_state_init`/`mouse_handler_begin`/`mouse_handler_end`, and SA `load`/`uninstall`/`payload_changed`. Shared structs still include `con`/`con_render`, `view`, space/display/window/process managers, `window`, `application`, `process`, `mouse_state`, tab bars/entries and rule state. P14 must finish these conversions, `rule.c`, `yabai.c` and remaining C helpers before deleting YabaiC; `final class Con` was explicitly allowed to move to P14 by the P12 handoff.
- Tests: C remaining 0, Swift added 12 (total ported 82/82): 6 `tab_bar_*`, 2 `border_*`, 3 window-frame tests and `mouse_drop_action_regions`. Plus 2 new SA wire-format/overflow tests and 1 SIMD/tail alpha test. `make test`: 62 YabaiTests, 41 YabaiCoreTests, empty C harness ASan/UBSan smoke check; Golden replay/coverage pass without re-record. Targeted alpha test also passes under ASan.
- Measurements:
  - Release binary 1,417,624 B (P12: 1,306,344 B). All V1 builds and version smoke tests pass without warnings. Analyzer: 1 existing warning (`notify.h:31`, NotifyDelegate ownership), down from 4.
  - Lines (source files under `src`, `Sources`, `tests`, excluding generated OSAX arrays): C outside OSAX 446, headers 3,473, ObjC outside OSAX 60 (8 unity-build lines plus the 52-line empty test harness), Swift 21,909 in 91 files.
  - Release live: `run` 28/28, `extra` 14/14 (+1 SKIP, native hotkey disabled), pid unchanged and no new diagnostics. 50 space switches median 9 ms, Dock pid unchanged, footprint 48 MB; frozen-front focus 8/10 ms; tabbed-container warp 141/127 ms, cross-display swap 93 ms.
  - V6: screenshots inspected for glass/glass, glass/blur, glass/off and i3/off, with borders; clicking a nonfocused tab selected the expected window in all four variants. All temporary config restored.
  - Release `launch` 3/3: 13 attempts in 120 s, backed off and gave up; queries median 9 ms/max 998 ms, activated application managed. Daemon pid stayed unchanged, no reports.
  - ASan runtime confirmed in `vmmap`: `run` 28/28 and `extra` 14/14 (+1 SKIP), same pid through cleanup, crash count 18→18, no new stderr or sanitizer reports. Space switches median 23 ms, Dock footprint 48 MB; tabbed warp 109/91 ms, cross-display swap 87 ms.
  - TSan runtime confirmed in `vmmap`: `run` 28/28 and `extra` 14/14 (+1 SKIP), same pid through cleanup, crash count 18→18, no new stderr or sanitizer reports. Space switches median 47 ms, Dock footprint 48 MB; frozen-front focus 43/45 ms, tabbed warp 173/187 ms, cross-display swap 124 ms.
  - Bench (V5 step 2, same windows: setup → P13 restart → P13-A/B → restore → base-A/B): P13 tab focus 31.7/31.4, rotate 125.2/134.4, split focus 31.7/32.9 ms; installed build 31.2/32.4, 120.6/126.3, 33.0/33.9 ms. Ratio of average medians: tab −0.8%, rotate +5.1%, split −3.4%, within 10%.
  - Paired live IPC captures immediately after each restart: 243/255 responses exact (all config getters/errors/rules/signals). The 12 differing responses are five space queries (`last-window`), five window queries (frames/split/focus/title), two tree queries; the same windows remain, but the benchmarks before the restore changed the layout/focus that startup reconstructs. Golden is byte-identical without re-recording.
  - Final `deploy.sh restore` completed and checked the installed binary; test apps are closed. Restored payload is 2.1.33, attributes 0x5f. The P13 binary is arm64, minimum OS/SDK 27.0, version yabai-v7.1.25.
- Deviations from plan / surprises:
  - The deferred shared-model/class cleanup moves to P14 as described above; this phase ports the P13 behavior one-to-one. The P14 step now names the actual `src/` target and the C-only test paths, instead of the obsolete `Sources/YabaiC`/whole `tests/` paths.
  - The Swift SA handshake rejects incomplete/unterminated replies instead of reading beyond them; empty capture arrays and missing drawing contexts fail safely. A nil mouse-drop destination flushes its source rather than dereferencing NULL. Normal inputs preserve C behavior.
  - The installed C binary added report 17 before the first P13 deploy (`yabai-2026-10-15-120138.ips`, pid 88537, `window_unobserve < EVENT_HANDLER_WINDOW_DESTROYED < event_loop_run`) and report 18 during the paired baseline cleanup (`yabai-2026-10-15-122315.ips`, pid 4805, the known `window_manager_apply_window_frame_group < window_manager_set_window_frames < tree_flush < EVENT_HANDLER_WINDOW_DESTROYED < event_loop_run` stack). Both images are the original 393,216 B C binary, UUID `5c558c4e-6ab1-363c-9fbf-9fa783d76bc7`, not P13. The release P13 runs stayed at 17, and ASan began with 18 already present.
  - The first alpha regression fixture inferred `[Any]` from mixed typed/untyped nested integer literals, giving raw bitmap APIs object storage; explicitly typed `[UInt8]` fixed the test. Synthetic clicks must set `event.flags = []`; inherited modifiers hid the test TextEdit application on the first spot check. Repeating with explicit flags passed 4/4.
  - Existing user edits to AGENTS.md (77 added lines of Codex instructions/conventions) are preserved unstaged; only the P13 changes there are included in this phase's commit.
- Pitfalls added to AGENTS.md: unavailable process/scanf/CGWindowList APIs; audited versus unaudited CF imports; frame-worker reference ownership; explicitly typed byte-array fixtures.
- Waiting on user: nothing. No payload reload is needed. The original installed binary is restored; all deploys reset the space layouts.

### 2026-10-15 P14 [~]
- Commits: 92b015d..955a4b1 on swift-port (14 code commits), then the commit that adds this entry
- Master synced to: 4754520 (`git log 4754520..master -- src tests doc` is empty)
- Done (P14 step 1, nearly complete):
  - C harness removed (`tests/src`, `tests/makefile`); `make test` is `swift test`. `make analyze` and the C flags of the makefile removed.
  - `rule.c` → `Sources/Yabai/Rule.swift` (`rule --list` json via ResponseText, byte-identical in the golden replay). `yabai.c` → `Sources/Yabai/Yabai.swift` (`yabai_main(arguments)`, options, lock file, startup order kept); `misc/service.h` → `Service.swift`; `misc/notify.h` → `Sources/CPrivate/Notify.m` (MRR ObjC, `NotifyC`; CPrivate builds with `-fno-objc-arc`); log helpers → `Log.swift` (`warn`, `error`, `require`, `notify`, `debug_message`, `g_verbose`).
  - Every shared C struct is a Swift type, converted top-down: `DisplayManager`, `MouseState` (handle is an `Atomic`), `ProcessManager`, `SpaceManager`, `WindowManager` (classes with the C field names; globals `g_*` are `nonisolated(unsafe) let` with a NOTE, accessors `*_global()` return the class), then `Process` (atomics for terminated/ns_application), `Window` (`valid: Atomic<Bool>` replaces `id_ptr`; CF fields owned by ARC; `window_destroy` releases them), `Application`, `View`, `Con` (`children`/`focus` are arrays, `weak var parent`; the memmove primitives are array insert/remove with the same order), `ConRender`/`FeedbackWindow`/`TabBar` (class)/`TabBarEntry`. Classes have identity `==`. `struct table` → `Sources/Yabai/Table.swift`, which keeps the bucket order of hashtable.h so query output order is unchanged. Rules stay the C-shaped Swift struct `rule` behind `UnsafeMutablePointer<rule>` in `wm.rules` (buf_del order kept); labels are a `LabelList` value in the managers.
  - Temporary storage (`ts.h`) is gone: the `*_ts` window functions return String, the list functions return arrays (`space_window_list*` keep an inout count because SpaceLayout.swift distinguishes window server failure from no windows, as C did). All `@_cdecl` shims, `Shims/LabelShims.swift`, `Shims/JSONShims.swift`, the `…Retained` UUID twins and `event_loop_post` are removed.
  - `src/` is deleted (YabaiC target gone). The header constants/enums/small structs are `Sources/Yabai/Definitions.swift` (same names and imported types: int macros Int32, enums RawRepresentable UInt32 structs, anonymous enum Int); helpers.h → `Helpers.swift` (easing in Float, sine curves via Double like C; `read_os_timer` and `psn_equals` through CPrivate wrappers `ReadOSTimerC`/`ProcessSameC` because the APIs are deprecated). New CPrivate wrappers: `NSApplicationLoadC`, `CGSetLocalEventsSuppressionIntervalC`, `CGEnableEventStateCombiningC`, `stdout_global`/`stderr_global`/`environ_global`, `CPrivateSetResolvedFunctions`, `csr_get_active_config`.
  - `src/osax` → `osax/` (git mv) with `src/misc/hashtable.h` (only the payload uses it). New C target `OSAX` (`osax/include/OSAX.h`: common.h, byte arrays now named `__osax_payload`/`__osax_loader`). Makefile and `.gitignore` paths updated; `scripts/payload-history.sh` lists old and new paths. The rebuilt payload differs from the old one only in its install name (the build path, checked by building at the old path: byte-identical), so `OSAX_VERSION` stays 2.1.34 and no reload is needed.
  - Partly done: the classes still have a temporary `var pointee: Self { self }` shim (Window, Application, View, Con, TabBar) so not-yet-cleaned code compiles. 955a4b1 removed `.pointee.` from most files.
- Resume at:
  1. Finish the `.pointee` cleanup: in `Rule.swift`, `WindowManagerRules.swift`, `Shims/MessageShims.swift`, `IPC/MessageQuery.swift`, `TreeView.swift`, `TabBar.swift` (and tests `TreeTests`, `ViewTests`, `BorderTests`, `WindowManagerTests`, `SerializeTests`, `TreeFixtures`) remove `.pointee` only where the base is a class (`target.pointee.`, `window.pointee.`, `node.pointee.` …); keep it on real pointers (`candidate`/`result` = `UnsafeMutablePointer<rule>`, `effects` = `UnsafeMutablePointer<rule_effects>`, `info` = `mouse_window_info`, `layout` = `space_layout`, psn/C strings/out parameters). Then delete the five `var pointee` shims and fix what the compiler reports. Also drop the leftover `Yabai.` prefixes in tests where they are no longer needed (optional).
  2. Optional, if the user wants it: rename the `Shims/` folder (only Area/SpaceLayout/MessageShims conversions are left) and the `*_ts` names; not required by the plan.
  3. P14 step 2: rewrite the Architecture, Build and Testing sections of AGENTS.md (no unity build, no YabaiC, `osax/` target, Definitions.swift/Helpers.swift, CPrivate wrappers, pitfalls below), `doc/live-testing.md` (unit tests section; it still mentions the C harness and `make -C tests`), `doc/payload-updates.md` (`src/osax` → `osax`, symbol names), `.claude/skills/swift-port-conventions/SKILL.md` (mark bridge-era pitfalls as historical), README build instructions; ask the user about a "Fork changes" line. NOTE: AGENTS.md has the user's own unstaged Codex section (77 lines): keep it, and ask the user before committing AGENTS.md whether to include it.
  4. P14 step 3–5: full V1 (make, make install, asan, tsan), V2 (`make test`), V4 golden, V5 live (`run`, `extra`, `launch`, bench A/B against the installed build, crashes, asan + tsan runs, `deploy.sh restore`), V6 spot checks (borders, glass/i3 tab bars, scratchpads, rules, signals, `--load-sa` after `killall Dock` needs the user), `ipc_compare.sh` against the installed build, final report against the P0 baselines, then ask the user whether to merge into master.
- Open @_cdecl shims / C structs still shared: none. Remaining C/ObjC: `Sources/CPrivate` (declarations, CPrivate.c, Notify.m) and `osax/` (payload, loader, generated arrays).
- Tests: C remaining 0; Swift: 62 YabaiTests + 41 YabaiCoreTests pass; golden replay byte-identical, never re-recorded in P14.
- Measurements: lines (git ls-files) C/ObjC/headers 2,008 (osax + CPrivate only), Swift 23,528 (Sources and tests). Release size and build time not yet measured for the final report.
  - Live checks during the session (release builds, deploy.sh install): after the window/application classes `run` 28/28; after the tree/view/tab-bar classes `run` 28/28 and `extra` 14/14 (+1 SKIP, hotkey disabled), daemon pid unchanged, crash reports 18 → 18. Not yet live-checked: commits 609bf63..955a4b1 (arrays instead of temporary storage, labels, Definitions/Helpers, the C target removal). `deploy.sh restore` done at the end of the session: the original binary is installed again.
- Deviations from plan / surprises:
  - The rules stay a C-shaped Swift struct behind heap pointers (one-to-one with the sbuffer of pointers into it), not a class.
  - `exec_config_file` uses `posix_spawn` instead of fork + execvp (Swift cannot fork); an exec failure is now reported like a failed fork. Notifications get the already formatted text (the C `%s` read UTF-8 text as the C string encoding).
  - Weak `parent` and the ARC lifetimes: a window, process or container lives until the last event or reference drops it, instead of being freed in its destroy function; the destroy functions release what C released (CF fields, outline windows, tab bars), and the validity checks are unchanged.
  - The process table is read on the event loop and changed by the Carbon handler on the main thread without a lock, as in C.
- Pitfalls (add to AGENTS.md / the skill in the docs step): a C function and an enum tag with the same name (`con_orientation`) collide in Swift, so the enum type is `ConOrientation`; a class property named like its type needs the module prefix (`Yabai.area()`); C structs imported with an unlabeled `init(_ rawValue:)` lose it as Swift structs (tests use `rawValue:`); C pointer fields map best to IUO properties (`Window!`, `UnsafeMutablePointer<CChar>!`) so call sites keep compiling; a temporary `var pointee: Self { self }` lets pointer-style call sites compile while a struct becomes a class; removing a target's `import YabaiC` also removes the CPrivate/Cocoa re-exports (add `import CPrivate`/`AppKit`); `git add` with one missing pathspec stages nothing.
- Waiting on user: nothing yet; the docs step must ask about committing their AGENTS.md section and about a README "Fork changes" line.

### 2026-10-15 P14 [x] (final verification)
- Commits: `180fa43` removes the temporary model `.pointee` shims; `3deaedc` documents the Swift build/architecture; `012edf9` updates AGENTS.md and live-helper pitfalls; then the commit recording this report and the Package.swift comment correction. All on `swift-port`.
- Master synced to: `4754520`; `git log 4754520..master -- src tests doc` remains empty. No merge into master performed.
- Done:
  - Removed the five identity `.pointee` properties from Window, Application, View, Con and TabBar and converted the remaining class call sites/tests. Real pointer dereferences (rules, effects, out-parameters and C strings) remain. No model `@_cdecl` bridges or `import YabaiC` remain.
  - Rewrote AGENTS.md's structure, build, testing and architecture guidance; updated README requirements/build instructions, payload paths/symbols, live-testing instructions, the Swift conventions skill and this plan's current architecture/checklist. Bridge-era skill entries are explicitly historical.
  - V1: `make`, `make install`, `make asan`, `make tsan` all pass without warnings; each binary runs `--version` (`yabai-v7.1.25`). Release is arm64, minimum OS 27.0, SDK 27.0; verification host macOS 27.0.1 (26A434), Swift 6.4.
  - V2/V4: `make test` passes all 103 tests (62 YabaiTests + 41 YabaiCoreTests); focused Golden passes both tests. Golden responses remain byte-identical, never re-recorded. Ledger: all 82 original C tests ported, C remaining 0.
  - V3: not applicable after deleting YabaiC and `make analyze`.
  - V5 release: `run` 28/28, `extra` 14/14 (+1 SKIP, native Ctrl+Right disabled), `launch` 3/3. Same daemon pid 32958 through release run/extra and spot checks. Relayout mean/max 82.1/135.2 ms; tab switch mean 21.6 ms; sweep query max 39.8 ms. Fifty space switches median 9 ms, Dock pid unchanged, footprint 51 MB; frozen-front space switches 8/10 ms; tabbed-container cross-display warp 133/168 ms, swap 85 ms. Launch: 13 attempts over 120 s, gaps rise from 1.1 to 6.3 s, then give up; queries median/max 9/1030 ms (409 requests); activated application managed.
  - V5 ASan: runtime confirmed in vmmap, `run` 28/28, same pid 35243; no new AddressSanitizer/UBSan diagnostics. V5 TSan: runtime confirmed, `run` 28/28, same pid 36262; no new ThreadSanitizer/UBSan diagnostics. New stderr scanned from byte offsets 16342 (ASan) and 16506 (TSan). Crash reports stayed 18 throughout baseline, release, sanitizers and final restore.
  - V6: 15 spot checks pass, covering signal environment/window id, rule add/list/remove, scratchpad assignment/hide/show, and tab clicks in glass/glass, glass/blur, glass/off and i3/off. Screenshots inspected with borders enabled; temporary config restored. Nested tabbed containers render and focus the expected tab in all four variants.
  - Paired live IPC after restarts: 243/255 response blocks exact; all 255 exit codes match, all 137 errors byte-identical, JSON key order and window-list id order match. Twelve dynamic query responses differ (five space, five window, two tree queries): last-window, selected/focused window, frames, split direction and tree arrangement. These live captures cannot alone establish layout equivalence; the fixed golden replay is byte-identical and live frame checks pass.
  - Final `deploy.sh restore` completed (binary checked with cmp, backup removed), original daemon running, all test applications closed. Active Dock payload remains 2.1.33, attributes 0x5f; the port was tested against it. Embedded OSAX_VERSION stays 2.1.34: P14 changed only the embedded build path, with old-path rebuilding previously proving identical bytes. No scripting-addition reload or Dock restart was needed. All deploys reset the user's space layouts.
- Final measurements against P0:

  | Measure | P0 | P14 |
  |---|---|---|
  | Tracked source lines, excluding generated arrays | C 16,061; headers 4,301; ObjC 1,056; OSAX 2,076; Swift 446; C tests 2,918 | Swift Sources 20,355 + tests 3,168 = 23,523; remaining C/ObjC/headers: CPrivate 395 + OSAX 1,613 = 2,008 |
  | Release binary | 1,954,568 B (universal) | 1,586,024 B (arm64); P1's arm64-only binary was 849,384 B |
  | Clean release build | 8.5 s (empty `.build`) | 17.97 s (`make clean` then `make install`, including OSAX regeneration; Swift build 16.01 s) |
  | Unchanged release build | 1.6 s | 1.44 s |

  Bench uses the prescribed same-window sequence: setup → P14 install → P14-A/B → restore → base-A/B. The table lists individual A/B medians in ms; percentages compare their means. Same-session baseline is the original installed build.

  | Operation | P0 installed baseline (A/B) | P14 (A/B) | Same-session baseline (A/B) | P14 vs P0 / same-session |
  |---|---|---|---|---|
  | Tab focus | 30.8 / 31.5 | 32.6 / 32.7 | 29.5 / 29.9 | +4.82% / +9.93% |
  | Rotate | 150.5 / 147.2 | 124.3 / 135.6 | 133.0 / 139.0 | −12.70% / −4.45% |
  | Split focus | 30.3 / 28.7 | 31.6 / 30.8 | 30.0 / 29.6 | +5.76% / +4.70% |

  Median regressions satisfy the 10% contract against both baselines. P14 rotate-A had a 612.2 ms p90 spike (mean 160.9 ms); rotate-B p90 was 152.9 ms. This tail outlier is recorded rather than hidden by the median comparison. Size/build-time comparisons span the P0 universal-to-arm64 change and are not architecture-normalized.
- Known deviations retained from the port:
  - CPrivate includes fixed-signature unavailable/deprecated-API wrappers and MRR notifications, beyond the initial declarations-only plan. OSAX remains ObjC/C.
  - Swift Table preserves the C bucket/insertion/rehash order instead of using Dictionary. Rules remain Swift value structs behind heap pointers. Some C-derived function/type names and IUO fields remain for one-to-one behavior; optional folder/name cleanup is not required for parity.
  - ARC retains models until the last event/reference drops them; destroy functions still release their platform resources. Con.parent is weak. The process table keeps the original Carbon-main-thread/event-loop access pattern without a new lock; the live TSan run reported no race, which is not proof that all possible interleavings are safe.
  - Config execution uses posix_spawn rather than fork/execvp, because Swift cannot fork; an exec failure is reported like the former fork failure. P13's defensive rejection of incomplete SA replies and safe handling of absent capture/drop resources remain.
- Pitfalls recorded in AGENTS.md, the conventions skill and live-testing notes: Swift enum/function and property/type name collisions, explicit rawValue initializers/imports, pointer-to-class migration, byte fixture types, and live helper assumptions (`focus_follows_mouse` getter `disabled` restores as `off`; current-space focus errors; tabbed containers can be nested).
- User changes: the exact original 77 added Codex/conventions lines in AGENTS.md are still unstaged and preserved. The architecture rewrite was committed using an index snapshot excluding those additions. Asked whether to include them and whether to add a README Fork changes entry; with no answer during verification, kept the additions unstaged and left that list unchanged.
- Resume at: no remaining implementation or verification work for P14. Ask the user whether to merge `swift-port` into `master`; merge only on their explicit instruction. Optional pending preferences: committing the 77 local AGENTS.md lines and adding the proposed README Swift-port entry.

### 2026-10-15 Performance follow-up (merge deferred)
- User requested a Luna subagent to compare pre-port and current latency, memory and visible borders. No merge is authorized; P14 implementation remains complete on `swift-port`.
- Compared the original installed C/ObjC daemon (including its existing Swift glass pilot; arm64 UUID `5C558C4E-6AB1-363C-9FBF-9FA783D76BC7`) with release `d9199b3` (UUID `80FFA1C6-4C67-30D9-A66F-BE2B274CA46F`). Same six disposable windows, controlled flat tree and config; no payload reload.
- Valid primary blocks: pre-port 50 + 50 samples and Swift 100 + 50 per operation, all 18 operations without failures. Retained all valid samples despite unequal counts. Median CLI query 8.82 → 9.42 ms; same-app focus 9.22 → 9.93; cross-app focus 21.08 → 19.74; floating move pair 17.34 → 16.11; resize pair 42.15 → 41.68. Full quantiles and raw data are linked from `doc/swift-port-performance.md`.
- Space 4↔5 command tails above 450 ms occurred 4/100 pre-port and 11/150 Swift, with roughly 500 ms maxima in both. Swift pooled p95 crosses that rare-stall population (58.09 → 489.49 ms); this is unresolved, not proof of a Swift cause. A separate Swift-only checked-between-switches loop had no such stalls in 300 samples, but changes the workload and lacks a valid C counterpart.
- ScreenCaptureKit border captures: 40 samples per operation/build, zero failures. Same-app focus-to-composited-border median 37.09 → 28.90 ms; cross-app 55.31 → 45.15; moving edge 26.86 → 25.64. These include CLI and presentation, not internal draw CPU time or photon latency. Different blank TextEdit documents were selected by query order across restarts; drift/fixed-id rechecks remain outstanding, so do not claim a causal improvement.
- Settled flat daemon physical footprint 53.4 → 45.1 MiB; five-tab glass 61.1 → 56.5; i3 65.6 → 56.0. Warm-up/exposure differ and snapshots are not a leak test. RSS and system-wide WindowServer/Dock observations are in the report.
- Desktop locked at 17:08:48 UTC, after every retained capture. Excluded the later Swift command-only tail probe. Restored-C drift checks and corresponding isolated tail probes were not performed. New helpers reject locked sessions before starting and saving results.
- Cleanup: original installed SHA-256 `a6ebdf54b33f36fe8e139953f587e6b1984f3836de3daa68e9f468c85ed4192c` restored and verified; saved runtime config restored (autotiling on, workspace default, orientation auto, both mouse-focus options off, animation 0). All three disposable test apps closed. Crash reports 18 → 18. Original daemon restarted while locked; after unlock it may need a restart to rediscover AX windows. Display/focus restoration (display 2 space 11, window 504) remains pending unlock; `.focused-window` is preserved.
- Pitfalls added to AGENTS.md, the conventions skill and live-testing notes: autotiling can nest reinsertion fixtures; occlusion invalidates pixel probes; captured presentation time differs from drawing CPU time; match explicit window ids across builds; successful commands during a lock can yield invalid fast timings. User's original 77 AGENTS.md lines remain unstaged.
- Resume at: after an unlocked desktop is available, restore the user's focus/display, restart the original daemon if AX discovery remains empty (warn that layouts reset), and obtain restored-C drift/fixed-id border and matching isolated tail measurements if the user wants to continue. Do not merge without their explicit instruction.

### 2026-10-15 Local guidelines committed
- User explicitly requested committing the remaining local changes. Included the original 77 added Codex/Swift-conventions lines in AGENTS.md without rewriting them.
- Performance results and helpers were already committed as `4e204ba`. Live follow-ups remain as listed above; no merge or deployment performed.
