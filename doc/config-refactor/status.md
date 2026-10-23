# Static config status

This is the single source of truth for progress. The protocol is in [overview.md](overview.md) and, with the
substitutions listed there, in `doc/refactor/overview.md` sections "State and handoff" and "Resume protocol".

Status values: `todo`, `in-progress`, `done`, `blocked`, `skipped`. Find a subphase's commit with
`git log --oneline --grep '^C<ID> '`.

## Run settings

- live_tests: deferred
- plan written at: 27e6e7aa (2026-10-23)

## Phase 1: TOML document model

phase: in-progress
mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| C1.1 | Add the TOMLDecoder dependency | done | TOMLDecoder 0.4.5 pinned exact in Package.swift (YabaiCore; YabaiCoreTests for the smoke test). Criteria met: pure Swift, MIT, typed throws, syntax error line only in TOMLError.description. Release binary 9679832 to 10167880 bytes (+0.49 MB, before any code uses it). No live check. Convention bullet in doc/swift-conventions.md. |
| C1.2 | `ConfigDocument` and strict decoding | todo | |
| C1.3 | Lower a document to IPC messages | todo | |
| C1.4 | Line numbers for key paths | todo | |

## Phase 2: Check and load at startup

phase: todo

| ID | Title | Status | Notes |
|---|---|---|---|
| C2.1 | Find `yabai.toml` | todo | |
| C2.2 | Check a `yabai.toml`: `config --check` and `yabai --check-config` | todo | |
| C2.3 | Convert the example and the user's config | todo | |
| C2.4 | Apply the file at startup, before windows are adopted | todo | |

## Phase 3: Non-destructive reload

phase: todo

| ID | Title | Status | Notes |
|---|---|---|---|
| C3.1 | Setters skip unchanged values | todo | |
| C3.2 | The diff apply engine | todo | |
| C3.3 | `config --reload` on the engine, and `config --overrides` | todo | |
| C3.4 | Auto-reload on save | todo | |
| C3.5 | The `config_loaded` signal event | todo | |

## Phase 4: Built-in scripting addition loading

phase: todo

| ID | Title | Status | Notes |
|---|---|---|---|
| C4.1 | Run `sudo -n yabai --load-sa` from the daemon | todo | |
| C4.2 | Load at startup and after the Dock restarts | todo | |

## Phase 5: Remove yabairc

phase: todo

| ID | Title | Status | Notes |
|---|---|---|---|
| C5.1 | Delete the yabairc code paths | todo | |
| C5.2 | Rewrite the docs | todo | |

## Phase 6: Editor and tooling support

phase: todo

| ID | Title | Status | Notes |
|---|---|---|---|
| C6.1 | JSON Schema for `yabai.toml` | todo | |
| C6.2 | `config --dump` prints the running config as TOML | todo | |

## Handoff log

Append only. Format: `YYYY-MM-DD HH:MM · role · ID · event · next step`.

- 2026-10-23 · planner · — · plan written · orchestrator starts phase 1
- 2026-10-23 18:57 · phase agent · C1 · started (nested) · C1.1
- 2026-10-23 19:01 · phase agent · C1.1 · done (commit pending) · C1.2 (ConfigDocument); the TOML line is only in the description, so C1.2 must parse it or use C1.4 for the line

## Discovered

Out-of-scope findings for later, one line each with the subphase ID and a file reference.
