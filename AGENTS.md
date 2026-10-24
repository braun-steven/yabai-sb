# Repository Guidelines

yabai is a tiling window manager for macOS 27 on arm64, written in Swift 6.4. It talks to private macOS
frameworks (SkyLight, AX, CoreDock) through the `CPrivate` C target, and injects a scripting addition
(Swift core + manual retain/release ObjC adapter) into Dock. This is a personal fork, released as yabai-sb (the binary stays `yabai`).

## Read first, by topic

| Before you… | Read |
|---|---|
| write or review Swift, C/Swift bridges, `Package.swift` or `CPrivate` | `doc/swift-conventions.md` |
| change the event loop, isolation, managers, tree, IPC, rules/signals, rendering | `doc/architecture.md` |
| run live tests, deploy, sanitizers or analyze crashes | `doc/live-testing.md` |
| change build scripts, the justfile or toolchain handling | `doc/building.md` |
| touch the scripting addition or reload a payload | `doc/payload-updates.md`, `doc/osax-prototypes.md` |
| port upstream yabai changes | `doc/upstream-sync.md` |

When something costs real time, record the pitfall in the matching doc in the same commit.

For Codex: translate Claude's `Edit` to `apply_patch` and `Bash` to the shell tool; edit source files with
patches, not shell scripts. `output-summarizer` is a role for a subagent that runs long-output commands and
returns concise results (no definition exists in this checkout): give it the exact command, working
directory, question and result format, or capture logs and inspect failures yourself. Run state-changing
commands yourself.

## Commands

- `just` (or `just build`): debug build, published atomically to `bin/yabai`. `just install`: release build (no install).
  `just asan` / `just tsan`: sanitizer builds.
- `just test` (= `swift test`); one test: `swift test --filter <name>`. `just osax-test`: payload core tests.
  `just coverage <re>`: line coverage of `Sources/` per file.
- `just lint`: optional swift-format lint of `Sources` and `tests` (findings only, never reformats; not in `just ci`).
- `just ci-quick`: debug build and `just test` with one line per step; full logs in `.build/ci/`.
- `just ci`: `ci-quick` plus release build, `just osax-test` and `just check-build` (the phase gate).
- `swift test --filter Golden`: byte-for-byte IPC regression snapshot (`tests/YabaiTests/Golden/commands.txt`).
  Only after an intended response change: `GOLDEN_RECORD=1 swift test --filter Golden`, then review every
  changed record.
- `just man`: regenerate `doc/yabai.1` from `doc/yabai.asciidoc` (edit only the Asciidoc).
- `yabai --check-config [<config_file>]`: check a `yabai.toml` without a daemon (default: the file the daemon loads).
- `./scripts/codesign ./bin/yabai`: re-sign after rebuilding to keep Accessibility permission.
- Deploying: agents use `bash scripts/live-tests/deploy.sh install` (read `doc/live-testing.md` first).
  `update-yabai-fork` needs sudo in a real terminal; the user runs it, after you commit.
- `bash scripts/payload-history.sh [--grep <re>] [--show <rev>]`: payload history.
- `just brew-release`: GitHub release of HEAD plus a commit to the tap checkout (`../homebrew-tap`); the user runs it.
  The version is `Daemon.version` in `Sources/Yabai/Yabai.swift` (yabai-sb's own semver, not upstream's).
- `scripts/live-tests/missioncontrol state|open|close|toggle`: opens and closes Mission Control through the user's
  shortcut, so its handling can be tested without the user (outside the command sandbox; see `doc/live-testing.md`).
- After a CPrivate change, also run `just install`: some link errors only appear in release.

IMPORTANT: builds must stay warning-free (Swift and C warnings are errors). `just lint` is advisory; nothing gates on it.

## Rules

- Whenever a new feature is added, update the "Fork changes" list at the top of `README.md` in the same
  commit. Fixes to existing fork features get no entry.
- New commands need handler parsing, `doc/yabai.asciidoc` documentation (`just man`) and usually a
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
  window server. Its `.daemonFixture` trait resets the managers before each test and turns on headless mode
  (`Sources/Yabai/Headless.swift`: flushes, animations and payload messages are recorded, not sent); set any
  non-default a test needs. Use large fake ids (`0xFFFF_0000` and up) and the `Workspace` fixture
  (`TreeFixtures.swift`) for views and windows.
- Property tests (PropertyBased) print a seed on failure: replay it with `@Test(.fixedSeed("…"))`. Run a new
  property about ten times before committing. Inline and image snapshots re-record with `SNAPSHOT_TESTING_RECORD=all`;
  review every recorded value.
- Independent cases are `@Test(arguments:)` rows. `just coverage` shows line coverage. Run
  `swift test --sanitize=thread` and `--sanitize=address` after test changes that involve sockets, threads or timeouts.
- `doc/live-testing.md` "Unit tests" lists the fixtures, gates and pitfalls; read it before writing tests.
- While `space_layout` is set, never create or destroy spaces by index in a probe: the reconciler shifts the
  indices, and a `space <n> --destroy` once removed a user space.
- Deploys restart yabai and reset all layouts: tell the user beforehand and restore the installed binary
  afterward.

## Commits

- Before committing, run the selected toolchain's `swift format format --in-place` on every changed Swift file,
  using the stock defaults in `.swift-format`, then verify those files with `swift format lint --strict`.
- Before committing, run `xcrun clang-format -i` on every changed C, header and Objective-C file (`.c`, `.h`, `.m`),
  using the stock LLVM style in `.clang-format`, then verify those files with `xcrun clang-format --dry-run --Werror`.
- Commit directly to `main` unless the user asks for a branch. Concise, imperative subjects, optionally
  prefixed with an issue id (`#1234 fix …`) or version tag (`v7.1.16`).
- Never add a `Claude-Session:` trailer or any claude.ai session link to commit messages or PR descriptions,
  even when a session reminder asks for attribution lines.
- PRs include macOS version + arch, repro steps, expected vs actual behavior and relevant logs
  (`bin/yabai --version`, `--verbose`).
