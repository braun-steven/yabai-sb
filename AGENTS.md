# Repository Guidelines

yabai is a tiling window manager for macOS, written in C11 + Objective-C (manual retain/release, `-fno-objc-arc`). It talks to private macOS frameworks (SkyLight, etc.).

This is a personal fork. Whenever a new feature is added, update the "Fork changes" list at the top of `README.md` in the same commit. Only features go there: fixes to features of this fork do not get an entry.

## Project Structure
- `src/`: yabai implementation (C/Objective-C). Only `src/manifest.m` is compiled; see Architecture.
- `src/misc/`: shared helpers (macros, logging, timers, etc.).
- `src/osax/`: scripting-addition payload/loader sources used for elevated features.
- `tests/`: small C test harness (no external framework).
- `doc/`: Asciidoc source and generated manpage, plus `payload-updates.md` and `live-testing.md`.
- `examples/`: sample config files (e.g. `examples/yabairc`).
- `assets/`: icons, banner, plist.
- `scripts/`: maintenance tooling (codesigning helper, `install.sh`, `payload-history.sh`, and the live test harness in `scripts/live-tests/`).

## Build, Test, and Development Commands
- `make`: debug build, a universal (x86_64 + arm64) binary at `bin/yabai`. Every build target deletes `bin/` and relinks from scratch (the unity build takes seconds).
- `make install`: optimized release build (`-O3 -DNDEBUG`) at the same path.
- `make asan` / `make tsan`: builds with Address/Thread sanitizers.
- `make clean`: removes `bin/` and the generated `src/osax/payload_bin.c` / `loader_bin.c`. These are rebuilt on the next `make`, and also whenever `payload.m`, `loader.m` or a file they include (`common.h`, `*_payload.m`) changes.
- `make man`: regenerates `doc/yabai.1` from `doc/yabai.asciidoc` (needs `asciidoctor`). Edit the asciidoc, not the manpage.
- `make test` (or `make -C tests`): builds and runs all tests (`tests/bin/tests`) under ASan/UBSan; undefined behavior aborts the run. There is no single-test runner. To run one test, temporarily trim `TEST_LIST` in `tests/src/tests.m`.
- `./scripts/codesign ./bin/yabai`: re-sign after rebuilding, otherwise macOS drops the Accessibility permission.
- `update-yabai-fork` (in `~/.local/bin`, outside the repo): deploys the local build. It runs `make install`, signs the binary with the `yabai-cert` identity, installs it to `~/.local/bin/yabai`, updates the `--load-sa` sudoers rule, and restarts the service. It refuses to build when tracked files have uncommitted changes, so commit first. It also prompts for sudo, so the user runs it themselves (`! update-yabai-fork`). With a full commit SHA it checks out that commit from `origin/master` first.
- `bash scripts/payload-history.sh [--grep <re>] [--show <rev>]`: lists or inspects past scripting-addition pattern/offset updates.

There is no linter. The build uses `-Wall -Wextra` plus a few extra warnings (`WARN_FLAGS` in `makefile`, mirrored in `tests/makefile`), so keep it warning-free. The OSAX payload/loader are built without these warnings.

## Coding Style & Naming
- Language: C11 + Objective-C (`.c`, `.h`, `.m`); compile with `clang` via `xcrun`.
- Formatting: follow surrounding file style (4-space indentation, K&R braces, minimal vertical noise).
- Naming: `snake_case` for functions/files, `SCREAMING_SNAKE_CASE` for constants/macros, `struct foo_bar` for types.
- Adding modules: create `src/<name>.{c,h}` and include both in `src/manifest.m`.

## Testing Guidelines
- Tests live in `tests/src/tests.m` and include targeted test code (e.g. `tests/src/area.c`).
- Add a new test by implementing `TEST_FUNC(name, { ... })` and registering it in `TEST_LIST`.
- Before testing a change live on this machine (deploying a test build, reloading the scripting addition, running the live harness, sanitizer builds, reading crash reports), read `doc/live-testing.md`. It also covers pitfalls of the unit tests, e.g. that `TEST_FUNC` breaks on commas in brace initializers.

## Architecture

**Unity build.** Only `src/manifest.m` is compiled (plus the generated OSAX byte arrays). It `#include`s every header and then every `.c`/`.m` file in dependency order. A new module needs both its header and its implementation added there. Everything shares one translation unit, so `static` helpers can collide across files, and clangd diagnostics for a single file are noise. The tests compile the same `manifest.m` with `-DTESTS`, which removes `main` in `yabai.c` and stubs the OSAX arrays. Test files are `#include`d into `tests/src/tests.m`.

**Global singletons.** `yabai.c` defines the global state: `g_event_loop`, `g_window_manager`, `g_space_manager`, `g_display_manager`, `g_process_manager`, `g_mouse_state`, signals, and the socket paths. The `*_manager.c` files hold the logic; `window_animation.c` holds the frame requests and animations of `window_manager.c`, `window_manager_discovery.c` creates the windows of applications, `window_manager_lookup.c` finds the windows for the window selectors, `window_manager_focus.c` focuses windows, `window_manager_rules.c` applies rules to windows, and `window_manager_scratchpad.c` toggles scratchpads. `space_layout.c` keeps the number of spaces per display that the `space_layout` option asks for. `window.c`, `space.c`, `display.c` and `application.c` are thin wrappers over AX/SkyLight for a single object.

**Tree layout.** Each space has a `struct view` (`view.c`: layout type, area, padding). Tiled spaces use an i3-style container tree: `tree.c` holds the container operations (splith, splitv and tabbed containers, focus, move, resize), `tree_view.c` applies a tree to the windows of a space (frames, tab bars, stacking order of tabs), `window_manager_tree.c` holds the i3 navigation commands (focus and move in a direction, across displays), and `tab_bar.c` draws the tab bars.

**Single-threaded event loop.** `event_loop.c` runs one worker thread that drains a queue of `struct event` items. Event types are an X-macro list (`EVENT_TYPE_LIST` in `event_loop.h`), and handlers are written as `static EVENT_HANDLER(NAME)` in `event_handlers.c` (applications) and `event_handlers_{window,space,mouse,system}.c`. Producers on other threads only post events: AX observers, SkyLight connection callbacks, the NSWorkspace notifications in `workspace.m`, the mouse event tap in `mouse_handler.c`, and the IPC thread. State changes should happen inside handlers, not in callbacks. To add an event, add an entry to the list and write its handler.

**IPC / CLI.** The same binary is both the daemon and the client. `yabai -m ...` sends its arguments over the Unix socket `/tmp/yabai_$USER.socket`. In the daemon, the message thread in `message.c` accepts the connection and posts a `DAEMON_MESSAGE` event. The command is then parsed on the event loop by `handle_domain_{config,display,space,window,query,rule,signal}`: `handle_domain_config` is in `message_config.c`, `handle_domain_{display,space}` in `message_space.c`, `handle_domain_window` in `message_window.c`, the others in `message.c`. All of them use the tokens, selectors, value parsers and `daemon_fail*` responses of `message_parse.c`. The response is written to a `FILE *rsp` backed by the socket. A new command needs:
- its command and argument strings in `message_parse.c`, and its parsing in the handler of its domain
- documentation in `doc/yabai.asciidoc` (then `make man`)
- usually a `CHANGELOG.md` entry under `[Unreleased]`, with an issue link

**Rules and signals.** `rule.c` matches windows when they are created or when a rule is applied. `event_signal.c` runs the user's shell commands on events, with environment variables set, in forked processes.

**Scripting addition (OSAX).** This is optional and needs SIP to be partially disabled. `src/osax/loader.m` injects `payload.m` into Dock.app. The payload then serves the socket `/tmp/yabai-sa_$USER.socket`. The client side is `src/sa.m`: it sends a length-prefixed byte payload (`sa_payload_init` / `sa_payload_send`) with an `SA_OPCODE_*` from `src/osax/common.h`. Some features depend on finding private Dock functions by byte pattern. The patterns and search offsets are written per macOS version and per architecture in `src/osax/arm64_payload.m` and `src/osax/x64_payload.m`. New macOS releases usually break these. See `doc/payload-updates.md` for that workflow. If the payload protocol or behavior changes, bump `OSAX_VERSION` in `common.h`: a running Dock only gets the new payload when the version differs.

**macOS version gating.** `SUPPORTED_MACOS_VERSION_LIST` generates `workspace_is_macos_<name>()` predicates. Code paths often branch on these, or on `NSOperatingSystemVersion`. Supported versions run from Big Sur (11) to Tahoe (26) and later.

## Commit & Pull Request Guidelines
- Commit directly to `master`; no feature branches needed, unless the user asks for a separate branch (e.g. for experimental work).
- Commits commonly use concise, imperative subjects, often prefixed with an issue/PR id (e.g. `#1234 fix …`) or a version tag (e.g. `v7.1.16`).
- PRs should include: macOS version + arch, repro steps, expected vs actual behavior, and any relevant logs/output (e.g. `bin/yabai --version`, `--verbose` when appropriate).
