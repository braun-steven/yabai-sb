# Static config status

This is the single source of truth for progress. The protocol is in [overview.md](overview.md) and, with the
substitutions listed there, in `doc/refactor/overview.md` sections "State and handoff" and "Resume protocol".

Status values: `todo`, `in-progress`, `done`, `blocked`, `skipped`. Find a subphase's commit with
`git log --oneline --grep '^C<ID> '`.

## Run settings

- live_tests: deferred
- plan written at: 27e6e7aa (2026-10-23)

## Phase 1: TOML document model

phase: done
mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| C1.1 | Add the TOMLDecoder dependency | done | TOMLDecoder 0.4.5 pinned exact in Package.swift (YabaiCore; YabaiCoreTests for the smoke test). Criteria met: pure Swift, MIT, typed throws, syntax error line only in TOMLError.description. Release binary 9679832 to 10167880 bytes (+0.49 MB, before any code uses it). No live check. Convention bullet in doc/swift-conventions.md. |
| C1.2 | `ConfigDocument` and strict decoding | done | `ConfigDocument` types and `ConfigDocument.decode` (`ConfigDocument.swift`, `ConfigDocumentDecoding.swift`); 27 rows of one problem each plus collection, empty-file, full-document and syntax-line tests in `tests/YabaiCoreTests/ConfigDocumentTests.swift`. Deviations: (1) the key order of a table is the one `TOMLTable.keys` gives (plain values, then arrays, then inline tables), not file order, because the file order across those kinds is not public; C1.4 can restore it. (2) Value types are checked by kind only (bool, integer, float, string; arrays only for `space_layout`); the type each option takes is left to the handlers (C2.2). Signal `active` is a TOML boolean; its yes/no spelling is C1.3. No live check. |
| C1.3 | Lower a document to IPC messages | done | `ConfigDocument.lowered()` (`ConfigLowering.swift`) gives `ConfigEntry` (arguments, keyPath, kind) in apply order. Booleans are on/off (rules, options) or yes/no (signal `active`); colors print as `0x` + 8 hex digits; an empty `space_layout` lowers to `off`. Tests in `tests/YabaiCoreTests/ConfigLoweringTests.swift`: a sample for each of the 61 options, the target format against `extractYabaiCommands`, rule/signal/option rows, and a property (300 documents, run 10 times). Deviations: the acceptance yabairc is written in lowered order (exact compare), not file order; no InlineSnapshotTesting in YabaiCoreTests, so the yabairc text and literal arrays are the expectations; `ConfigEntry` has no `line` yet (C1.4). No live check. Gate quick passed. |
| C1.4 | Line numbers for key paths | done | `TOMLKeyLocator` (`TOMLKeyLocator.swift`) scans the source once and records the line of every key, table header and inline-table key; a path not in the file gives its nearest enclosing key or header (`config.space_layout[2]` gives the key line). `ConfigDocument.decode` fills the line of each semantic error from it and keeps the parser line for syntax errors. Design choice: the document keeps no lines (so it stays Equatable on values only); `lowered(locator:)` fills `ConfigEntry.line` from a locator of the same source, and `lowered()` without one leaves it nil. Tests in `tests/YabaiCoreTests/TOMLKeyLocatorTests.swift` (rows per construct, the Target format, a property of 300 documents run 10 times); rows in `ConfigDocumentTests.swift` and `ConfigLoweringTests.swift`. The `targetFormat` fixture now lives once in `ConfigDocumentTests.swift`. Deviations: array elements have the key line, not their own line; only `\"` and `\\` are decoded in quoted keys; the C1.2 key order is not restored (the locator could sort by line). No live check. Gate quick passed. |

## Phase 2: Check and load at startup

phase: in-progress
mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| C2.1 | Find `yabai.toml` | done | `ConfigFileSearch.candidates` takes `homeDotfile` (no `~/.yabai.toml`); `choose` takes `resolve` (realpath via `resolvedPath` in Yabai.swift), so a link to the chosen file is not ignored; `Daemon.configFile(explicit:)` is the yabai.toml search (not applied yet); startup calls `Daemon.warnLeftoverYabairc` before `execConfigFile`, which still runs the yabairc. The notice names the first yabai.toml candidate as the target. Tests: 17 in `tests/YabaiCoreTests/ConfigFileSearchTests.swift` (both candidates, `-c`, symlinks, the notice decision). CHANGELOG Changed line; architecture "Startup sequence" step 11. Discovered P9.2 marked obsolete in `doc/refactor/status.md`. Gate quick passed (431 + 257 tests, 0 warnings). No live check. |
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
- 2026-10-23 19:07 · phase agent · C1.2 · started · C1.2 (ConfigDocument, decoding, tests)
- 2026-10-23 19:09 · subphase agent · C1.2 · done (commit pending) · C1.3 (lower a ConfigDocument to IPC words); the key order of a table is not file order (see the C1.2 note)
- 2026-10-23 19:13 · subphase agent · C1.3 · started · C1.3 (ConfigLowering.swift, ConfigLoweringTests.swift)
- 2026-10-23 19:25 · subphase agent · C1.3 · done · C1.4 (line numbers for key paths; ConfigEntry gets its line there)
- 2026-10-23 19:19 · phase agent · C1.4 · started · C1.4 (TOMLKeyLocator.swift, line in ConfigDocumentError and ConfigEntry)
- 2026-10-23 19:24 · subphase agent · C1.4 · done · C2.1 (find yabai.toml); the locator is `TOMLKeyLocator(source:).line(for:)`, lowering takes `lowered(locator:)`
- 2026-10-23 19:27 · phase agent · C1 · closed, just ci passed · phase 2. Summary: YabaiCore now decodes yabai.toml (`ConfigDocument.decode`, all problems collected, lines via `TOMLKeyLocator`), lowers it to `yabai -m` words in apply order (`lowered(locator:)`), no daemon change. For phase 2: build the locator from the same text that was decoded; value ranges and per-option types (e.g. a bool option given an integer, out-of-range colors written in decimal) are left to the handlers in C2.2; keys inside a table follow `TOMLTable.keys` order, not file order (see Discovered).
- 2026-10-23 19:33 · phase agent · C2 · started (nested) · C2.1
- 2026-10-23 19:36 · subphase agent · C2.1 · started · C2.1 (ConfigFileSearch homeDotfile and resolve, Daemon.configFile, leftover warning, tests)
- 2026-10-23 19:37 · subphase agent · C2.1 · done · C2.2 (configFileReport on the yabai.toml search). Open: the leftover notice says "no longer read" while the yabairc still runs until C2.4 (text as the plan gives it)

## Discovered

Out-of-scope findings for later, one line each with the subphase ID and a file reference.

- C1.2/C1.4: keys inside a table are decoded in `TOMLTable.keys` order (plain values, arrays, inline tables), not file order; sorting by `TOMLKeyLocator` lines would restore it (`Sources/YabaiCore/ConfigDocumentDecoding.swift`).
- C1.4: array elements (`config.space_layout[2]`) report the key's line, and quoted keys decode only `\"` and `\\` (`Sources/YabaiCore/TOMLKeyLocator.swift`).
- C1 close (orchestrator): `just check-build` once failed its clean build on SwiftPM cache lines (`warning: 'swift-collections': skipping cache due to an error: The file “maintenance.lock” doesn’t exist.`); `scripts/check-build.py` fails any `warning:` line, even from SwiftPM itself. A rerun passed. Decide whether to ignore SwiftPM cache lines there (`scripts/check-build.py`).
- C2.1: the leftover-yabairc notice (`yabairc is no longer read; convert it to <path>`) is shown while the yabairc still runs, until C2.4 applies yabai.toml; the wording is the plan's. Consider a "still run" variant for the C2.1 to C2.3 window (`Sources/YabaiCore/ConfigFileSearch.swift`, `leftoverYabaircNotice`).
