# Port yabai (this fork) to Swift — phased handoff plan

> **How to use this file (every agent, every session)**
> 1. This plan lives in the repo as `doc/swift-port.md` on branch `swift-port` (P0 copies it there). Always work from that copy, never from `master`.
> 2. Read **Context**, **Parity contract**, **Target architecture**, **Agent rules** and **Verification checklist** once.
> 3. In the **Status board**, find the first phase that is not `[x]`. If it is `[~]`, resume from its last **Handoff log** entry.
> 4. Do only that phase. Its steps, "Done when" and handoff duties are in **Phases**.
> 5. Before you stop, even mid-phase:
>    - update its row in the Status board
>    - append a **Handoff log** entry (template at the end)
>    - commit this file together with the code
>
>    A new agent with no other context must be able to continue from here.

## Status board
Legend: `[ ]` not started · `[~]` in progress · `[L]` code done, waiting for the user's live run · `[x]` done.

| Phase | Title | Status | Last commit | Notes |
|---|---|---|---|---|
| P0 | Branch, SwiftPM skeleton, baselines | [~] | see log | step 1 done; resume at step 2 |
| P1 | macOS 27 / arm64 cleanup (still C) | [ ] | | |
| P2 | CPrivate module + Platform wrappers | [ ] | | |
| P3 | YabaiCore: geometry, labels, space_layout math, JSON writer | [ ] | | |
| P4 | YabaiCore: message tokens/selectors/values, rule parsing | [ ] | | |
| P5 | IPC server, CLI client, config domain | [ ] | | |
| P6 | IPC display/space/window/query/rule/signal domains + golden tests | [ ] | | |
| P7 | `@WM` actor, event loop, signals | [ ] | | |
| P8 | Event handlers + Mission Control | [ ] | | |
| P9 | Display + space model | [ ] | | |
| P10 | Process, application, workspace | [ ] | | |
| P11 | Window + window_manager* | [ ] | | |
| P12 | Tree + tree_view | [ ] | | |
| P13 | Border, tab bars, animation, mouse, SA client | [ ] | | |
| P14 | Remove C, docs, final verification | [ ] | | |

**Rule for `[L]`:** the next phase may start while a phase waits for the user's live run. Never have more than two phases in `[L]`: stop and ask the user to run the live checks first.

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
6. **Performance:** `scripts/live-tests/bench.py` medians stay within 10% of the P0 baseline.

## Target architecture
### Package layout (repo root)
```
Package.swift            // swift-tools-version 6.2, platforms [.macOS("27.0")], Swift 6 language mode, complete concurrency checking
Sources/
  CPrivate/              // C target: include/CPrivate.h (from src/misc/extern.h; keep CF_RETURNS_RETAINED, add CF_ASSUME_NONNULL
                         // and _Nullable), include/module.modulemap, macho_dlsym.c (from src/misc/macho_dlsym.h)
  OSAXBlob/              // C target: generated src/osax/payload_bin.c + loader_bin.c (makefile generates them before swift build)
  YabaiC/                // TEMPORARY C target: today's unity build (sources: ["manifest.m"]) + include/yabai_c.h umbrella header.
                         // Shrinks every phase, deleted in P14.
  YabaiCore/             // Swift library without window server access: pure, unit-tested logic
  Yabai/                 // Swift executable: daemon + client (main.swift)
Tests/YabaiCoreTests/    // Swift Testing (import Testing)
src/osax/                // unchanged ObjC payload/loader (moved to osax/ in P14), built by makefile only, arm64e
```
- **Linker settings** (unsafeFlags is fine in a root package): `-F/System/Library/PrivateFrameworks -framework SkyLight`, plus `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker assets/Info.plist` on `Yabai`.
- **YabaiC** compiles with `-fno-objc-arc -std=c11` and the `WARN_FLAGS` of today's makefile.

### Two bridges while C and Swift coexist
- **Swift → C:** `YabaiC/include/yabai_c.h` includes the system headers and every header of `src/manifest.m`, in the same order. Swift sees all C structs and functions.
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
- **Port every `// NOTE:` comment with its code.** They record hard-won macOS behavior. Keep the repo style: `// NOTE:` blocks, sparse comments, function braces on their own line (as in `src/tab_bar_glass.swift`).
- **Warnings and concurrency escapes:**
  - no warnings; `make install` uses `-warnings-as-errors`
  - `@unchecked Sendable` and `nonisolated(unsafe)` only with a NOTE explaining why
- **No new package dependencies.**
- **Live checks:** the user runs every deploy (`scripts/live-tests/deploy.sh <variant>` or `! update-yabai-fork`, from a real terminal because sudo needs a TTY). Ask them, then set the phase to `[L]` until they report back.
- **Sync with master at the start of every phase:**
  - Use `git log <last-synced>..master -- src tests doc` and port or merge each fix. While a file is still C, `git merge master` is fine.
  - Write the new SHA in the Handoff log.
- **Commits:** small, on `swift-port`, with concise imperative subjects (repo style). No README "Fork changes" entries until P14.
- **Long output:** delegate noisy commands (full test runs, builds, logs) to the `output-summarizer` subagent, per the user's global instructions.

## Verification checklist (referenced by the phases)
- **V1 Build:** `make`, `make install`, `make asan` and `make tsan` succeed with no warnings, and `bin/yabai --version` runs.
- **V2 Unit tests:**
  - `swift test` and `make test` (while C tests exist) pass.
  - Keep the test ledger in the Handoff log: C tests left + Swift tests added. It must reach "82 ported" by P14.
- **V3 Analyzer:** `make analyze` keeps its known 37 false positives while C exists. Triage new ones.
- **V4 Golden IPC (from P6):** `swift test --filter Golden` passes, with byte-identical responses.
- **V5 Live (the user runs it):**
  1. `deploy.sh install`, then from `scripts/live-tests`: `live.py setup` → `run <phase>` → `extra <phase>` → `cleanup` → `launch <phase>`
  2. `bench.py <phase>`, within 10% of the P0 baseline
  3. `crashes.py`, with no new reports
  4. Once per phase with `deploy.sh asan` and `deploy.sh tsan`: a short `live.py run`
- **V6 Manual spot checks** for what the phase touched: glass tab bars (backdrop glass and blur), borders, scratchpads, rules, signals (`yabai -m signal --add event=window_focused action='echo $YABAI_WINDOW_ID >> /tmp/x'`), `--load-sa` after `killall Dock`.

A phase is `[x]` only when V1–V3 (and V4 from P6 on) pass and the user reported V5 green.

## Phases

### P0 — Branch, SwiftPM skeleton, baselines
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
   - the user's `bench.py` medians on `master`
8. **Golden capture:** while the C IPC is still in place, write `Tests/YabaiCoreTests/Golden/commands.txt` (~60 commands covering every domain) and record the expected responses from the C implementation. The capture method is your choice, e.g. a `-DGOLDEN` test entry in `tests/src/tests.m` that runs the message handlers on fixture managers. P6 replays these.
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
   - bump `OSAX_VERSION`
4. Set `MACOS_MIN = 27.0` everywhere, including `tests/makefile`.
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
- Add `Golden` tests that replay the P0 capture with byte comparison.
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
  - `tab_bar.c` + `tab_bar_glass.c` (merge them with `tab_bar_glass.swift`)
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
- Waiting on user: <live run variants, questions>
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
- Waiting on user: bench.py baseline on master (P0 step 7)
