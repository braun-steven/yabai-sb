# Repository Guidelines

yabai is a tiling window manager for macOS 27 on arm64, written in Swift 6.4. It talks to private macOS
frameworks (SkyLight, AX, CoreDock) through the `CPrivate` C target, and injects a scripting addition
(Swift core + manual retain/release ObjC adapter) into Dock. This is a personal fork.

## Read first, by topic

| Before you… | Read |
|---|---|
| write or review Swift, C/Swift bridges, `Package.swift` or `CPrivate` | `doc/swift-conventions.md` |
| change the event loop, isolation, managers, tree, IPC, rules/signals, rendering | `doc/architecture.md` |
| run live tests, deploy, sanitizers or analyze crashes | `doc/live-testing.md` |
| change build scripts, the makefile or toolchain handling | `doc/building.md` |
| touch the scripting addition or reload a payload | `doc/payload-updates.md`, `doc/osax-prototypes.md` |

When something costs real time, record the pitfall in the matching doc in the same commit.

For Codex: translate Claude's `Edit` to `apply_patch` and `Bash` to the shell tool; edit source files with
patches, not shell scripts. `output-summarizer` is a role for a subagent that runs long-output commands and
returns concise results (no definition exists in this checkout): give it the exact command, working
directory, question and result format, or capture logs and inspect failures yourself. Run state-changing
commands yourself.

## Commands

- `make`: debug build, published atomically to `bin/yabai`. `make install`: release build (no install).
  `make asan` / `make tsan`: sanitizer builds.
- `make test` (= `swift test`); one test: `swift test --filter <name>`. `make osax-test`: payload core tests.
- `swift test --filter Golden`: byte-for-byte IPC regression snapshot (`tests/YabaiTests/Golden/commands.txt`).
  Only after an intended response change: `GOLDEN_RECORD=1 swift test --filter Golden`, then review every
  changed record.
- `make man`: regenerate `doc/yabai.1` from `doc/yabai.asciidoc` (edit only the Asciidoc).
- `./scripts/codesign ./bin/yabai`: re-sign after rebuilding to keep Accessibility permission.
- Deploying: agents use `bash scripts/live-tests/deploy.sh install` (read `doc/live-testing.md` first).
  `update-yabai-fork` needs sudo in a real terminal; the user runs it, after you commit.
- `bash scripts/payload-history.sh [--grep <re>] [--show <rev>]`: payload history.
- After a CPrivate change, also run `make install`: some link errors only appear in release.

IMPORTANT: builds must stay warning-free (Swift and C warnings are errors). There is no linter.

## Rules

- Whenever a new feature is added, update the "Fork changes" list at the top of `README.md` in the same
  commit. Fixes to existing fork features get no entry.
- New commands need handler parsing, `doc/yabai.asciidoc` documentation (`make man`) and usually a
  CHANGELOG entry.
- Keep `YabaiCore` free of CPrivate and window server access. Add CPrivate wrappers only when Swift cannot
  call the API; remaining C/ObjC is C11 with manual retain/release.
- Window manager state is `@WM`; events go through `EventLoop.post` (delayed: `post(_:after:)`). Never a
  `Task {}` per event or `DispatchQueue.asyncAfter`: both reorder events.
- Log through the component loggers (`Logger.events`, `.windows`, …), never `print`/`fputs`.
- Bump `OSAX_VERSION` for payload behavior or protocol changes.

## Tests

- Swift Testing (`@Test`, `#expect`). Tests live in `tests/`, not `Tests/` (case-insensitive filesystem).
- Tests that change global managers belong in the serialized `DaemonState` suite and must not touch the
  window server. Golden replay leaves config behind: set the defaults a test depends on explicitly.
- Deploys restart yabai and reset all layouts: tell the user beforehand and restore the installed binary
  afterward.

## Commits

- Commit directly to `main` unless the user asks for a branch. Concise, imperative subjects, optionally
  prefixed with an issue id (`#1234 fix …`) or version tag (`v7.1.16`).
- PRs include macOS version + arch, repro steps, expected vs actual behavior and relevant logs
  (`bin/yabai --version`, `--verbose`).
