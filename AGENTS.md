# Repository Guidelines

yabai is a tiling window manager for macOS, written in C11 + Objective-C (manual retain/release, `-fno-objc-arc`) and Swift (`Sources/Yabai/`). It talks to private macOS frameworks (SkyLight, etc.). On branch `swift-port` the C code is being ported to Swift in phases: read `doc/swift-port.md` before working on that branch.

This is a personal fork. Whenever a new feature is added, update the "Fork changes" list at the top of `README.md` in the same commit. Only features go there: fixes to features of this fork do not get an entry.

## Project Structure
- `Package.swift`: the SwiftPM package that builds the binary; the makefile drives it.
- `src/`: yabai implementation (C/Objective-C). Only `src/manifest.m` is compiled; see Architecture.
- `src/include/`: `yabai_c.h`, every header of the unity build, which Swift imports as the module `YabaiC`.
- `Sources/Yabai/`: the Swift code (`main.swift` runs the client for `-m`, otherwise calls `yabai_main` in `yabai.c`; `EventLoop.swift` is the `@WM` actor and the event loop, `EventSignal.swift` the signals, `Log.swift` the debug output).
- `Sources/Yabai/IPC/`: the client (`Client.swift`), the socket of the daemon and the dispatch of a message to its domain (`MessageLoop.swift`), the handlers of the domains (`MessageConfig.swift`, `MessageSpace.swift` for display and space, `MessageWindow.swift`, `MessageQuery.swift` for query, rule and signal) and the json of the queries (`Serialize.swift`).
- `Sources/Yabai/Platform/`: Swift wrappers of the private SkyLight, AX and CoreDock calls, and `macho_find_symbol` (`MachO.swift`, called by C through `@_cdecl`).
- `Sources/Yabai/Shims/`: the `@_cdecl` entry points through which the C code calls ported `YabaiCore` code (the C prototypes stay in the headers, with a pointer to the shim).
- `Sources/YabaiCore/`: the Swift library of pure logic without window server access (geometry, labels, `space_layout` math, the JSON writer, the message tokens, value parsers, selectors and rule/signal parsing), unit-tested by `tests/YabaiCoreTests/`.
- `Sources/CPrivate/`: the C module that declares the private framework functions (`include/CPrivate.h`, with nullability); the unity build includes it through `yabai_c.h`, and Swift imports it as `CPrivate`.
- `src/misc/`: shared helpers (macros, logging, timers, etc.).
- `src/osax/`: scripting-addition payload/loader sources used for elevated features.
- `tests/`: small C test harness (no external framework), the golden IPC capture (`tests/YabaiTests/Golden/`) and the Swift tests (`tests/YabaiCoreTests/` for `YabaiCore`, `tests/YabaiTests/` for the code of `Sources/Yabai` through `@testable import Yabai`; not `Tests/`: the file system is case-insensitive).
- `doc/`: Asciidoc source and generated manpage, plus `payload-updates.md` and `live-testing.md`.
- `examples/`: sample config files (e.g. `examples/yabairc`).
- `assets/`: icons, banner, plist.
- `scripts/`: maintenance tooling (codesigning helper, `install.sh`, `payload-history.sh`, and the live test harness in `scripts/live-tests/`).

## Build, Test, and Development Commands
- `make`: debug build, an arm64 binary at `bin/yabai` (macOS 27 or later; the scripting addition is arm64e). It runs `swift build` (Package.swift), which builds incrementally in `.build/`, and copies the product to `bin/`. Every build target replaces `bin/`.
- `make install`: optimized release build (`-c release`: `-O3 -DNDEBUG` for C, Swift warnings are errors) at the same path.
- `make asan` / `make tsan`: builds with Address/Thread sanitizers (plus UBSan).
- `make clean`: removes `bin/`, `.build/` and the generated `src/osax/payload_bin.c` / `loader_bin.c`. These are rebuilt on the next `make`, and also whenever `payload.m`, `loader.m` or a file they include (`common.h`, `*_payload.m`) changes.
- `make man`: regenerates `doc/yabai.1` from `doc/yabai.asciidoc` (needs `asciidoctor`). Edit the asciidoc, not the manpage.
- `make test`: runs `swift test`, then the C tests (`make -C tests`, `tests/bin/tests`) under ASan/UBSan; undefined behavior aborts the run. The Swift tests include the golden IPC replay (`goldenReplay` in `tests/YabaiTests/GoldenTests.swift`), which compares the responses to the commands of `tests/YabaiTests/Golden/commands.txt` byte for byte; after an intended change of a response, re-record with `GOLDEN_RECORD=1 swift test --filter Golden` and review the diff. One Swift test runs with `swift test --filter <name>`. There is no single-test runner for the C tests. To run one test, temporarily trim `TEST_LIST` in `tests/src/tests.m`.
- `make analyze`: runs the clang static analyzer over the unity build. The remaining warnings are known false positives (views owned by tables, `buf_push`, atomic stores, `objc_msgSend` initializers); check new ones. Private functions that return a +1 CF object without `Copy`/`Create` in their name need `CF_RETURNS_RETAINED` (see `Sources/CPrivate/include/CPrivate.h`).
- `./scripts/codesign ./bin/yabai`: re-sign after rebuilding, otherwise macOS drops the Accessibility permission.
- `update-yabai-fork` (in `~/.local/bin`, outside the repo): deploys the local build. It runs `make install`, signs the binary with the `yabai-cert` identity, installs it to `~/.local/bin/yabai`, updates the `--load-sa` sudoers rule, and restarts the service. It refuses to build when tracked files have uncommitted changes, so commit first. It also prompts for sudo, so the user runs it themselves, in a real terminal (the `!` prefix has no TTY for the password). Agents deploy test builds with `scripts/live-tests/deploy.sh` instead (see `doc/live-testing.md`). With a full commit SHA it checks out that commit from `origin/master` first.
- `bash scripts/payload-history.sh [--grep <re>] [--show <rev>]`: lists or inspects past scripting-addition pattern/offset updates.

There is no linter. The build uses `-Wall -Wextra` plus a few extra warnings (`warnings` in `Package.swift`, mirrored in `WARN_FLAGS` of `makefile` and `tests/makefile`), so keep it warning-free. The OSAX payload/loader are built without these warnings.

## Coding Style & Naming
- Language: C11 + Objective-C (`.c`, `.h`, `.m`); compile with `clang` via `xcrun`.
- Formatting: follow surrounding file style (4-space indentation, K&R braces, minimal vertical noise).
- Naming: `snake_case` for functions/files, `SCREAMING_SNAKE_CASE` for constants/macros, `struct foo_bar` for types.
- Adding modules: create `src/<name>.{c,h}`; include the header in `src/include/yabai_c.h` and the implementation in `src/manifest.m`.

## Testing Guidelines
- Tests live in `tests/src/tests.m` and include targeted test code (e.g. `tests/src/tree.c`). The Swift tests of `YabaiCore` live in `tests/YabaiCoreTests/` (Swift Testing); a test ported from C has the C `TEST_FUNC` name as its display name (`@Test("label_list")`).
- Add a new test by implementing `TEST_FUNC(name, { ... })` and registering it in `TEST_LIST`.
- Before testing a change live on this machine (deploying a test build, reloading the scripting addition, running the live harness, sanitizer builds, reading crash reports), read `doc/live-testing.md`. It also covers pitfalls of the unit tests, e.g. that `TEST_FUNC` breaks on commas in brace initializers.

## Architecture

**Unity build.** The C target `YabaiC` of `Package.swift` compiles only `src/manifest.m` (plus the generated OSAX byte arrays). It `#include`s `src/include/yabai_c.h`, which includes every header in dependency order, and then every `.c`/`.m` file. A new module needs its header added to `yabai_c.h` and its implementation to `manifest.m`. The Swift target `Yabai` imports the same headers as the module `YabaiC` and exports its entry points to C with `@_cdecl`. The Swift library `YabaiCore` does not import `YabaiC`: the shims in `Sources/Yabai/Shims/` convert between its types and the C structs. Swift's importer compiles the headers with ARC, so a header must not contain manual retain/release code outside an `#ifndef __swift__` block (see `misc/notify.h`). Everything shares one translation unit, so `static` helpers can collide across files, and clangd diagnostics for a single file are noise. The tests compile the same `manifest.m` with `-DTESTS`, which removes `main` in `yabai.c` and stubs the OSAX arrays. Test files are `#include`d into `tests/src/tests.m`.

**Global singletons.** `yabai.c` defines the global state: `g_window_manager`, `g_space_manager`, `g_display_manager`, `g_process_manager`, `g_mouse_state`, and the socket paths. The `*_manager.c` files hold the logic; `window_animation.c` holds the frame requests and animations of `window_manager.c`, `window_manager_discovery.c` creates the windows of applications, `window_manager_lookup.c` finds the windows for the window selectors, `window_manager_focus.c` focuses windows, `window_manager_rules.c` applies rules to windows, and `window_manager_scratchpad.c` toggles scratchpads. `space_layout.c` keeps the number of spaces per display that the `space_layout` option asks for. `window.c`, `space.c`, `display.c` and `application.c` are thin wrappers over AX/SkyLight for a single object.

**Tree layout.** Each space has a `struct view` (`view.c`: layout type, area, padding). Tiled spaces use an i3-style container tree: `tree.c` holds the container operations (splith, splitv and tabbed containers, focus, move, resize), `tree_view.c` applies a tree to the windows of a space (frames, tab bars, stacking order of tabs), `window_manager_tree.c` holds the i3 navigation commands (focus and move in a direction, across displays), and `tab_bar.c` draws the tab bars. The Liquid Glass style is split in two: `tab_bar_glass.c` takes a snapshot of a bar on the event loop, and `Sources/Yabai/TabBarGlass.swift` shows it with AppKit on the main queue. `tab_bar_glass.h` is the interface between them.

**Single-threaded event loop.** `Sources/Yabai/EventLoop.swift` runs the handlers one at a time on the serial dispatch queue `yabai.wm`, the executor of the global actor `@WM`. `EventLoop.post(Event)` (or `event_loop_post(type, context, param1)` from C, which maps to the `Event` enum) can be called from any thread; never use `Task {}` for events, which would reorder them. Event types are an X-macro list (`EVENT_TYPE_LIST` in `event_loop.h`), and handlers are written as `EVENT_HANDLER(NAME)` in `event_handlers.c` (applications) and `event_handlers_{window,space,mouse,system}.c`; `handle` in `EventLoop.swift` calls them. After each handler the loop runs the pushed signals and resets the temporary storage. Producers on other threads only post events: AX observers, SkyLight connection callbacks, the NSWorkspace notifications in `workspace.m`, the mouse event tap in `mouse_handler.c`, and the IPC thread. State changes should happen inside handlers, not in callbacks. To add an event, add an entry to the list, a case to `Event` (with both switches in `EventLoop.swift`) and write its handler.

**IPC / CLI.** The same binary is both the daemon and the client. `yabai -m ...` (`Sources/Yabai/IPC/Client.swift`, run by `main.swift`) sends its arguments over the Unix socket `/tmp/yabai_$USER.socket`. In the daemon, the message thread in `Sources/Yabai/IPC/MessageLoop.swift` accepts the connection and posts a `DAEMON_MESSAGE` event. On the event loop, `daemon_message_handle` reads the message, `handleMessage` dispatches it by domain, and the response is sent when the handler returns. The handlers of the domains are Swift (`Sources/Yabai/IPC/Message*.swift`): they read tokens from a `Message`, write into a `Response` (`fail` writes the failure byte and text), and call the C managers through `YabaiC` (the singletons through the accessors of `src/globals.h`). The value parsers, selectors, labels, properties and rule/signal parsing are in `Sources/YabaiCore/Message*.swift` and `Rule.swift`; the selectors look things up in the C managers through `CSelectorContext` (`Sources/Yabai/Shims/MessageShims.swift`). The query json is written by `Sources/Yabai/IPC/Serialize.swift` and `WindowInfo` (`Sources/YabaiCore/Query.swift`, also the property lists), except `rule --list`, which is still C (`rule_serialize`). A new command needs:
- its command and argument strings in the private enum of its handler (e.g. `enum Config` of `MessageConfig.swift`, `WindowCommand` of `MessageWindow.swift`), and its parsing in the handler of its domain
- documentation in `doc/yabai.asciidoc` (then `make man`)
- usually a `CHANGELOG.md` entry under `[Unreleased]`, with an issue link

**Rules and signals.** `rule.c` matches windows when they are created or when a rule is applied. The signals are Swift: `Sources/YabaiCore/EventSignal.swift` holds the table, the filters and the `signal --list` json, and `Sources/Yabai/EventSignal.swift` the `@WM` state, `event_signal_push` (called by the C handlers) and the flush, which starts the user's shell commands with `posix_spawn` (through `env`, which sets the environment variables).

**Scripting addition (OSAX).** This is optional and needs SIP to be partially disabled. `src/osax/loader.m` injects `payload.m` into Dock.app. The payload then serves the socket `/tmp/yabai-sa_$USER.socket`. The client side is `src/sa.m`: it sends a length-prefixed byte payload (`sa_payload_init` / `sa_payload_send`) with an `SA_OPCODE_*` from `src/osax/common.h`. Some features depend on finding private Dock functions by byte pattern. The patterns and search offsets of macOS 27 are in `src/osax/arm64_payload.m`. New macOS releases usually break these. See `doc/payload-updates.md` for that workflow. If the payload protocol or behavior changes, bump `OSAX_VERSION` in `common.h`: a running Dock only gets the new payload when the version differs.

**macOS version gating.** On branch `swift-port` the minimum is macOS 27 on arm64, and the code has no macOS version or architecture branches; `verify_os_version` in `src/osax/payload.m` accepts only macOS 27. Add a branch only when a newer release needs different behavior.

## Commit & Pull Request Guidelines
- Commit directly to `master`; no feature branches needed, unless the user asks for a separate branch (e.g. for experimental work).
- Commits commonly use concise, imperative subjects, often prefixed with an issue/PR id (e.g. `#1234 fix …`) or a version tag (e.g. `v7.1.16`).
- PRs should include: macOS version + arch, repro steps, expected vs actual behavior, and any relevant logs/output (e.g. `bin/yabai --version`, `--verbose` when appropriate).
