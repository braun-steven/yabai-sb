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
| P7 | `@WM` actor, event loop, signals | [ ] | | |
| P8 | Event handlers + Mission Control | [ ] | | |
| P9 | Display + space model | [ ] | | |
| P10 | Process, application, workspace | [ ] | | |
| P11 | Window + window_manager* | [ ] | | |
| P12 | Tree + tree_view | [ ] | | |
| P13 | Border, tab bars, animation, mouse, SA client | [ ] | | |
| P14 | Remove C, docs, final verification | [ ] | | |

**Rule for `[L]`:** the next phase may start while a phase waits for the user. Never have more than two phases in `[L]`: stop and ask the user to do the pending steps first.

## Context
- The Swift pilot moved the AppKit side of the glass tab bars to Swift: branch `swift-pilot-tab-bar-glass`, commit `69b9085`, files `src/tab_bar_glass.{swift,c,h}`. The user liked it and wants all of yabai in Swift.
- Today's codebase: ~16k lines of C, 4k of headers, 1.6k ObjC, 2k OSAX, and 82 unit tests in `tests/src/`.
- **Decisions made by the user (do not re-open):**
  - Minimum **macOS 27**. Drop older code paths. Assume arm64-only: P1 asks the user once before deleting x86_64.
  - **SwiftPM** builds the binary. A **thin `makefile`** keeps the existing entry points.
  - Long-lived branch **`swift-port`**. It merges into `master` only when the user says so after P14.
- What stays non-Swift:
  - the scripting addition (`src/osax/`, ObjC injected into Dock)
  - the C module `CPrivate`, which only declares private framework functions

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
### Package layout (repo root)
As built in P0 (it deviates from the first plan; see the P0 Handoff log entry for why):
```
Package.swift            // swift-tools-version 6.2, Swift 6 language mode. platforms [.macOS("27.0")] (since P1).
src/                     // TEMPORARY C target YabaiC (path "src"): sources manifest.m + osax/payload_bin.c + osax/loader_bin.c.
  include/yabai_c.h      //   every header of the unity build; module.modulemap makes it the module YabaiC for Swift.
                         //   Shrinks every phase, deleted in P14 (except src/osax, which moves to osax/).
  osax/                  // ObjC payload/loader (macOS 27 only since P1), built by the makefile only (arm64e); its _bin.c are YabaiC sources
Sources/
  CPrivate/              // (P2) C target: include/CPrivate.h (from src/misc/extern.h, with CF_RETURNS_RETAINED, CF_ASSUME_NONNULL,
                         // CF_IMPLICIT_BRIDGING and _Nullable), include/module.modulemap, CPrivate.c (the two function pointers
                         // yabai.c resolves with macho_find_symbol). Links SkyLight.
  YabaiCore/             // (P3) Swift library without window server access: pure, unit-tested logic
  Yabai/                 // Swift executable: main.swift (runs the client for -m, otherwise calls yabai_main of yabai.c),
                         // TabBarGlass.swift, Platform/ (P2: SkyLight, AX, CoreDock wrappers; MachO.swift = macho_find_symbol
                         // via @_cdecl), Shims/ (@_cdecl entry points for C), IPC/ (P5: client, socket, dispatch, config domain)
tests/YabaiCoreTests/    // Swift Testing (import Testing) and Golden/. Not Tests/: the file system is case-insensitive, and
                         // Tests/ would be the C harness tests/.
tests/YabaiTests/        // (P5) Swift Testing of the Yabai executable (@testable import Yabai): the IPC handlers on the C managers,
                         // and (P6) the golden replay (Golden/); tests that touch the managers nest in the serialized suite DaemonState
tests/src, tests/makefile // the C harness (deleted in P14); it links all of Sources/Yabai but main.swift
```
- **Build system:** SwiftPM 6.4 uses Swift Build. Products land in `.build/out/Products/<Debug|Release>`; the makefile copies them to `bin/`. Since P1 the makefile builds `--arch arm64` only (`ARCHS`).
- **Linker settings** (unsafeFlags is fine in a root package): `-F/System/Library/PrivateFrameworks -framework SkyLight` on YabaiC; `-sectcreate __TEXT __info_plist assets/Info.plist` and `-isysroot $SDKROOT` (see pitfalls) on `Yabai`.
- **YabaiC** compiles with `-fno-objc-arc`, C11 and the warnings of today's makefile, without `-fvisibility=hidden` (see pitfalls).

### Two bridges while C and Swift coexist
- **Swift → C:** `src/include/yabai_c.h` includes the system headers and every header of the unity build, in order; `src/manifest.m` includes it and then the `.c`/`.m` files. Swift (`import YabaiC`) sees all C structs and functions. Only non-`static` C functions can be called from Swift.
- **C → Swift:**
  1. Move a C function's body to Swift as `@_cdecl("same_name") func …` with the identical C signature.
  2. Keep the prototype in its `.h` file and delete the C body.
  3. C callers stay unchanged.
- When every user of a C struct is Swift, convert the struct into a Swift class and delete the C struct and its `@_cdecl` shims. Record the open shims in the Handoff log.

### Concurrency model (replaces `event_loop.c`, `memory_pool.h`, `ts.h`)
- **Global actor `@WM`** with a custom executor on a `DispatchSerialQueue` named `"yabai.wm"`. It owns managers, models and config.
- **`EventLoop.post(_ event: Event)`** is `nonisolated` and callable from any thread. It does `queue.async { WM.assumeIsolated { handle(event); signals.flush() } }`.
  - The serial queue keeps events in FIFO order. **Never** use `Task {}` for events.
  - `Event` is a `Sendable` enum: one case per entry of `EVENT_TYPE_LIST` (`src/event_loop.h`, 42 entries), with associated values instead of `context`/`param1`.
- **Producers only post**, on their own threads:
  - AX observers (`application.c`, `mission_control.c`; main run loop)
  - SkyLight notify procs (`SLSRegisterConnectionNotifyProc`, `src/yabai.c`)
  - NSWorkspace, distributed and KVO notifications (`workspace.m`)
  - the mouse event tap (`mouse_handler.c`; main run loop)
  - the IPC accept thread (`message.c`)
- **`@MainActor`** owns AppKit (the glass tab bars). `dispatch_after(main)` calls become `DispatchQueue.main.asyncAfter`, which posts back to `@WM`.
- **Cross-thread state** uses Synchronization `Mutex`/`Atomic`, with today's lock scopes:
  - `border_lock` (`border.c`)
  - `tab_bar_hit_lock` (`tab_bar.c`)
  - `window_animations_lock` (`window_animation.c`)
  - the mouse state read by the event tap
- **Animations:** `CVDisplayLink` becomes `NSScreen.displayLink(target:selector:)` / `CADisplayLink`. The proxy-building pthreads become a concurrent `DispatchQueue`.
- **Blocking AX and SkyLight calls stay synchronous on `@WM`.** They can block about 1 s on frozen apps (`doc/live-testing.md`). Making them `async` would reorder events.

### Platform layer (`Sources/Yabai/Platform/`)
- `SkyLight.swift`, `AX.swift` and `CoreDock.swift` wrap `CPrivate` and return Swift types, e.g. `SLS.spaces(forWindows: [UInt32]) -> [UInt64]` or `AXElement.title: String?`.
- **`Unmanaged` appears only in this layer.** `cfarray_of_cfnumbers` becomes `ids as CFArray`.
- C callbacks are `@convention(c)` functions with an `Unmanaged` context or a global. Each one gets a NOTE on who owns the context and for how long.

### Model conventions
- Containers:
  - `struct table` → `[Key: Value]`
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
  - `make test` passes: it runs `swift test`, then the C tests and the golden IPC replay (`Golden IPC: 145 of 145 responses match` in P0).
  - Keep the test ledger in the Handoff log: C tests left + Swift tests added. It must reach "82 ported" by P14. The golden replay and `goldenCaptureCoversEveryCommand` are not part of the 82.
  - A response of the golden capture changes only when the phase changes behavior on purpose (it should not). Re-record with `GOLDEN_RECORD=1 make -C tests`, and explain each changed record in the Handoff log.
- **V3 Analyzer:** `make analyze` keeps its known 37 false positives while C exists. Triage new ones.
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
1. Delete `Sources/YabaiC`, `tests/` and `make analyze`. Remove leftover `@_cdecl` shims. Move `src/osax` to `osax/` and update the makefile payload rules.
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
