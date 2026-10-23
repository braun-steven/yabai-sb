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

phase: done
mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| C2.1 | Find `yabai.toml` | done | `ConfigFileSearch.candidates` takes `homeDotfile` (no `~/.yabai.toml`); `choose` takes `resolve` (realpath via `resolvedPath` in Yabai.swift), so a link to the chosen file is not ignored; `Daemon.configFile(explicit:)` is the yabai.toml search (not applied yet); startup calls `Daemon.warnLeftoverYabairc` before `execConfigFile`, which still runs the yabairc. The notice names the first yabai.toml candidate as the target. Tests: 17 in `tests/YabaiCoreTests/ConfigFileSearchTests.swift` (both candidates, `-c`, symlinks, the notice decision). CHANGELOG Changed line; architecture "Startup sequence" step 11. Discovered P9.2 marked obsolete in `doc/refactor/status.md`. Gate quick passed (431 + 257 tests, 0 warnings). No live check. |
| C2.2 | Check a `yabai.toml`: `config --check` and `yabai --check-config` | done | `configFileReport` (`IPC/ConfigCheck.swift`) decodes and lowers yabai.toml and runs `checkMessage` on each setting, with `<file>:<line>: <key path>: <message>` lines and `checked N settings, M failures`; `yabai --check-config [<file>]` (`main.swift`, `YabaiOptions.swift`) runs the same code through `WM.sync` with no daemon; `config --reload` keeps the yabairc extractor check (`configCheckReport`) and refuses a `.toml` file (`ConfigFileSearch.isTOML`). The config and rule parsers read no manager state; the check reads `WindowManager.shared.rules` only for `rule --apply <label>`, and `checkMessage` names no SkyLight, CG or AX call. Deviations: a `[[space]]` label or pin cannot be checked without the session, so it is a `note:` line and counted as `K not checked`, not dropped; the yabairc report stays for reload until C3.3. Tests: `tests/YabaiTests/ConfigCheckTests.swift` rewritten for TOML (fixtures, problems with lines, space note, file and offline reads, reload refusal) with the yabairc report kept; `isTOML` rows in `ConfigFileSearchTests.swift`. Docs: man page (`just man`), CHANGELOG, README "Config check and reload". Golden: no record changed. Gate quick passed (437 + 258 tests, 0 warnings). Live check added. |
| C2.3 | Convert the example and the user's config | done | `examples/yabai.toml` (30 settings; the rules, signals and daemon line are commented TOML) and `examples/batch.sh` (the batch heredoc; `BatchExampleTests` now reads it). `examples/yabairc` is unchanged until C5.1. `~/.config/yabai/yabai.toml` was written by hand (outside the repository, nothing else there changed): `[daemon] load_scripting_addition = true`, `[config]` with 46 settings, 1 `[[signal]]` (`dock_did_restart`), 50 `[[rule]]`, commented TOML for the commented yabairc lines. Check output: user file `checked 97 settings, 0 failures`, exit 0, no notes; example `checked 30 settings, 0 failures`, exit 0. Mechanical comparison (a temporary test, deleted, not committed) of the yabairc with the lowered user file: 98 messages, of which 1 is the `sudo` line (not a message); the 50 rules match in order; the signal matches (applied after rules, by design); the 46 config settings match as sets, except one false difference from the test's own pair split of `space_layout`, whose words match in order. Deviations: the startup `sudo yabai --load-sa` became `load_scripting_addition` (no effect before phase 4); the global options that came after the rules now sit in `[config]` (apply order); `echo` dropped; `window_animation_duration 0.00` is `0.0`; `rule --apply normal-window-layer` is a comment (rules apply at startup); the `pkill` line is a comment (shell). Example: `window_gap 06` is `6`; the equivalence test compares numbers by value. Tests: `exampleTomlHasTheSettingsOfTheExampleYabairc` (YabaiCoreTests), `exampleFileChecksClean` (YabaiTests, DaemonState). Gate quick passed (438 + 259 tests, 0 warnings). Live check added. |
| C2.4 | Apply the file at startup, before windows are adopted | done | `ConfigLoader.swift`: `loadStartupConfig` reads and checks the startup file with the `config --check` code (`configFileCheck`, which now also returns the entries) before the managers start; a file with a failure applies nothing and is logged and notified. `LoadedConfig.apply(_:)` runs the entries of one `ConfigStep` through `handleMessage` in the startup `WM.sync` block: `settings` (before initialize), `managerSettings` (`tab_bar_font`, `external_bar`, after initialize and begin), `spaces`, `rulesAndSignals` (before `WindowManager.begin`). The yabairc is no longer run at startup; `execConfigFile` stays for `config --reload`. Deviations: (1) the file's settings run after `applySpaceDefaults`, not before it as the plan says, because that call would reset `layout`, `auto_padding`, the tree options and `skip_window_focus_animation` the file sets; (2) the startup debug lines are `checking the config file`, `applying the config file settings`, `... manager settings`, `... spaces`, `... rules and signals`. `configFileCheck` and `configMessage` are shared with the check; `failureTexts` is internal. Headless records `configEntries`. Tests: `tests/YabaiTests/ConfigLoaderTests.swift` (6 tests: steps per entry kind, the file applied in its steps, an invalid file, a missing file, a failing setting counted while the others run, the example applies cleanly). Golden: no record changed. Docs: man page (CONFIGURATION section, `--config`, reload and pin text), README static config section and TOC, CHANGELOG, architecture startup sequence. Gate quick passed (444 + 259 tests, 0 warnings). Live check added. Fix (C2.4 Fix): the file is applied before `ConfigObserver.start`, which only reacts to later sets, so a `menubar_opacity` other than 1.0 in yabai.toml was not applied until the next space or fullscreen change. The startup block now applies the menu bar alpha once after `ConfigObserver.start` (fullscreen rule as in EventHandler+Space.swift); the shadow, opacity, border and tab bar groups are covered by window adoption and the first layout flush. NOTE comment in `Yabai.swift`, step 10 in architecture.md. |

## Phase 3: Non-destructive reload

phase: in-progress
mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| C3.1 | Setters skip unchanged values | done | The option factories in `MessageConfig.swift` write and run their effects only for a changed value (focus_follows_mouse, space_layout, external_bar and the spacing setters check too), so a repeated set notifies nothing (ConfigObserver, Config notes; architecture and swift-conventions updated). `SpaceManager.setLayout(_:for:)` and `setLayoutForAllSpaces` leave a space with its layout alone, which also covers `space --layout`; per-view spacing skips unchanged views. Deviations: a `tab_bar_font` equal to the current name is skipped when the font is already loaded (a nil font, which no startup path leaves, is always set: WindowManager.initialize loads the default font), and a `--space` set of the current value still inserts its override. Tests: `tests/YabaiTests/MessageConfigTests.swift` (every config case set twice, tabbed container, external bar, tab bar flag and font, no notify per group). CHANGELOG, asciidoc (`just man`), refactor P9.6 marked fixed. Gate quick passed (450 + 259 tests, 0 warnings). No live check. |
| C3.2 | The diff apply engine | done | `ConfigLoader` (ConfigLoader.swift: `applied`, `defaults`, `reset`) and `ConfigLoader.reconcile(to:step:)` (ConfigReconcile.swift); `LoadedConfig.apply(step)` runs it, so startup is the reconcile against the defaults at each step. Options compare their own print with the lowered word (`sameConfigValue`: numbers and colors by value); a removed option goes back to the default printed by the first reconcile; `tab_bar_font` runs while no font is loaded. Spaces: label, pin and options by index; a per-space option also runs without its override (closes the C3.1 open item). A removed entry is found by its label, its pin and label go through handleMessage, and its per-space values are reset by `resetSpaceOption`, the one direct change (no message removes an override). Rules and signals: the lists are parsed as `rule --add` and `signal --add` parse them, `Rule`, `RulePattern`, `EventSignal` and `SignalTable` are Equatable now, and the running list is replaced when it differs (a repeated equal `space_layout` runs nothing, which closes the C3.1 open item). Deviations: the running print is compared, so the file's per-option value is not kept; the set path of a [[space]] reads SkyLight by index, so headless tests cover only the label-addressed removal (live check added). Fix (C3.2 Fix): a float the print rounds is compared at the print's decimals (`sameConfigValue`), so it records nothing on a second reconcile. Tests: `tests/YabaiTests/ConfigReconcileTests.swift` (10: no-op, one gap, removed option, runtime override, tab bar font, rule order, signal, removed space by label, the property run ten times, value comparison). Gate quick passed (461 + 259 tests, 0 warnings). Live check added. |
| C3.3 | `config --reload` on the engine, and `config --overrides` | done | `config --reload [<file>]` (`IPC/ConfigReload.swift`) reads and checks the file with `config --check`'s code (`checkConfigFile`, `configFileCheck`), replies with the failures and changes nothing on failure, else reconciles each `ConfigStep` in order and replies `reloaded <file>: <n> changes`. `ConfigLoader.reconcile` returns `ConfigReconcileResult` (changes, failures): changes are the messages that ran without a failure, the per-space resets and the list replacements (one for the list, plus its entries as messages). `config --overrides` is `configOverrideLines` (`ConfigReconcile.swift`), the running value against the applied document lowered, or the defaults where the file does not set it; the startup captures the defaults at its settings step even without a file, so the comparison is right after a runtime change. The P9.6 loop check is removed from `checkDomain`; Discovered P9.6 (loop) is marked obsolete. Reload no longer calls `resetConfigToStartupDefaults` or `execConfigFile`, and `configCheckReport` has only tests: C5.1 deletes them. Deviations: the reply does not count failures (they are logged); the per-space overrides are listed by the Mission Control index, which a test cannot name (live check). Tests: `tests/YabaiTests/ConfigReloadTests.swift` rewritten (14 tests: failure, reload applies and puts runtime changes back, unchanged file records nothing, font, file of the daemon, missing and two files, check notes, overrides lines, rules and signals, defaults without a file, argument). The C2.2 live check expectation for `--reload` of a TOML file is updated. Golden: no record changed. Docs: asciidoc (`just man`), CHANGELOG, README, architecture. Gate quick passed (465 + 259 tests, 0 warnings). Live check added. |
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
- 2026-10-23 19:43 · subphase agent · C2.2 · started · C2.2 (configFileReport, config --check on yabai.toml, yabai --check-config, config --reload refuses TOML, tests, docs)
- 2026-10-23 19:44 · subphase agent · C2.2 · done (commit pending) · C2.3 (convert the example and the user's config; `yabai --check-config` checks both files); `config --reload` still runs the yabairc and refuses `.toml`
- 2026-10-23 19:47 · subphase agent · C2.3 · started · C2.3 (examples/yabai.toml, examples/batch.sh, ~/.config/yabai/yabai.toml, equivalence and check tests)
- 2026-10-23 19:50 · subphase agent · C2.3 · done (commit pending) · C2.4 (apply yabai.toml at startup); the user file is in place (check: 97 settings, 0 failures), the example and batch.sh are committed with it
- 2026-10-23 20:00 · subphase agent · C2.4 · started · C2.4 (ConfigLoader, startup order, headless record, tests, docs)
- 2026-10-23 20:00 · subphase agent · C2.4 · done (commit pending) · C3.1 (setters skip unchanged values); the startup applies yabai.toml and no longer runs the yabairc, `config --reload` still runs it until C3.3; the file's settings run after `applySpaceDefaults` (deviation, see the C2.4 note)
- 2026-10-23 20:02 · subphase agent · C2.4 · fix started · C2.4 Fix (menu bar alpha from yabai.toml applied after ConfigObserver.start)
- 2026-10-23 20:02 · subphase agent · C2.4 · fix done (commit pending) · C3.1 (setters skip unchanged values)
- 2026-10-23 20:20 · phase agent · C2 · closed, just ci passed (second run; the first failed on the transient SwiftPM cache line) · phase 3. Summary: the daemon finds `yabai.toml` (`Daemon.configFile`, XDG then ~/.config, symlinks compared by realpath), checks it with `config --check` and offline `yabai --check-config` (`configFileReport`/`configFileCheck`), and applies it in-process at startup in `ConfigStep` order between the manager starts (`ConfigLoader.swift`); the yabairc is no longer run at startup but `config --reload` still runs it until C3.3. `examples/yabai.toml` and `~/.config/yabai/yabai.toml` exist (97 settings, 0 failures; reviewed against the yabairc: 50 rules in order, 46 options, the dock_did_restart signal). Deviations: `[config]` settings run after `applySpaceDefaults` (which would overwrite them), with `tab_bar_font`/`external_bar` after the managers begin; `[[space]]` entries are notes in the check (not checkable offline); the menu bar alpha is applied once after `ConfigObserver.start` (C2.4 fix). For phase 3: `ConfigObserver` starts after the startup apply, so the reload engine runs with the observer active; startup `sudo yabai --load-sa` is lost until phase 4 (Discovered). Close fixes: `scripts/check-build.py` copies all of `examples/` and counts only real diagnostic lines (the test name of a `Syntax error:` fixture failed it).
- 2026-10-23 21:02 · phase agent · C3 · started (nested) · C3.1
- 2026-10-23 21:06 · subphase agent · C3.1 · started · C3.1 (option factories write only changed values, setLayout and spacing skip unchanged views, tests, docs)
- 2026-10-23 21:10 · subphase agent · C3.1 · done (commit pending) · C3.2 (the diff apply engine); the setters skip equal values, so C3.2 can diff against the running state without re-notifying. Open for C3.2: a repeated `space_layout` does not reschedule the space layout pass, and a `--space` set of an equal value still inserts its override.
- 2026-10-23 21:21 · subphase agent · C3.2 · started · C3.2 (ConfigLoader.reconcile per step, Equatable rules and signals, tests, docs)
- 2026-10-23 21:25 · subphase agent · C3.2 · done (commit pending) · C3.3 (`config --reload` on the engine: run `ConfigLoader.shared.reconcile` for each step in order, with the file read by the reload; do not call `resetConfigToStartupDefaults`, the defaults come from the first reconcile; keep the nil check of `tab_bar_font`)
- 2026-10-23 21:32 · subphase agent · C3.3 · started · C3.3 (reload reads yabai.toml and reconciles, config --overrides, P9.6 check removed, tests, docs)
- 2026-10-23 22:10 · subphase agent · C3.3 · done (commit pending) · C3.4 (auto-reload on save); the reload reconciles, so C3.4 calls `ConfigLoader.reconcile` through the same `configFileCheck` path as `config --reload`; `config --overrides` lists runtime overrides, and the C3.3 live check covers the per-space form

## Discovered

Out-of-scope findings for later, one line each with the subphase ID and a file reference.

- C3.2: the C3.1 note "a nil font, as at startup" is wrong: `WindowManager.initialize` loads the default font (`Sources/Yabai/WindowManager+Startup.swift`); a nil font comes only from `resetConfigToStartupDefaults`, so the reload path is where the nil check of `tab_bar_font` matters. Fixed by C3.2 Fix (`Sources/Yabai/IPC/MessageConfig.swift` NOTE).
- C3.2: a float that the option prints with fewer decimals than the file (`window_border_width` %.4f, `window_opacity_duration` %f) never compares equal, so the reconcile runs it at every reload; a print with more digits would avoid that (`Sources/Yabai/IPC/MessageConfig.swift`). Fixed by C3.2 Fix (`sameConfigValue`, `Sources/Yabai/ConfigReconcile.swift`).
- C1.2/C1.4: keys inside a table are decoded in `TOMLTable.keys` order (plain values, arrays, inline tables), not file order; sorting by `TOMLKeyLocator` lines would restore it (`Sources/YabaiCore/ConfigDocumentDecoding.swift`).
- C1.4: array elements (`config.space_layout[2]`) report the key's line, and quoted keys decode only `\"` and `\\` (`Sources/YabaiCore/TOMLKeyLocator.swift`).
- C1 close (orchestrator): `just check-build` once failed its clean build on SwiftPM cache lines (`warning: 'swift-collections': skipping cache due to an error: The file “maintenance.lock” doesn’t exist.`); `scripts/check-build.py` fails any `warning:` line, even from SwiftPM itself. A rerun passed. Decide whether to ignore SwiftPM cache lines there (`scripts/check-build.py`). Resolved (user decision, 2026-10-23): check-build ignores these lines.
- C2.1: the leftover-yabairc notice (`yabairc is no longer read; convert it to <path>`) is shown while the yabairc still runs, until C2.4 applies yabai.toml; the wording is the plan's. Consider a "still run" variant for the C2.1 to C2.3 window (`Sources/YabaiCore/ConfigFileSearch.swift`, `leftoverYabaircNotice`).
- C2.2: a `[[space]]` key path counts the table's position (`space[0].label` for the table with `index = 2`), not the `index` value (`Sources/YabaiCore/ConfigDocumentDecoding.swift`, `spaceEntry`); the message is right, the name may mislead.
- C2.2: a daemon started with `-c <yabairc>` answers `config --check` without a file by checking that yabairc as TOML, so it reports syntax errors until C2.4 (`Sources/Yabai/IPC/ConfigCheck.swift`, `readConfigFile`).
- C2.3: from C2.4 until C4.2, the startup `sudo yabai --load-sa` of the user's yabairc is no longer run (`load_scripting_addition` takes effect only in phase 4); only the `dock_did_restart` signal loads the scripting addition (`~/.config/yabai/yabai.toml`, `[daemon]`). Decide whether to load it by hand until phase 4.
- C2.3: `examples/yabairc` still holds the batch heredoc, now also in `examples/batch.sh`; delete it with the yabairc in C5.1 (`examples/yabairc`).
- C2.4: `yabai -c <yabairc>` at startup now reads that file as `yabai.toml`, so a yabairc passed with `-c` fails the check and the daemon starts with the defaults (`Sources/Yabai/ConfigLoader.swift`, `loadStartupConfig`).
- C2.4: a yabairc without a yabai.toml gives two startup notices, the leftover-yabairc notice and "could not locate config file" (`Sources/Yabai/ConfigLoader.swift`); drop the second when a yabairc exists.
- C2.4: `[daemon] auto_reload` and `load_scripting_addition` are decoded but not applied until C3.4 and C4.2 (`Sources/YabaiCore/ConfigDocumentDecoding.swift`).
- C2 close: the SwiftPM `maintenance.lock` cache line failed `just check-build` again (01-clean.log); a rerun passed. It recurs, so ignoring SwiftPM `skipping cache` lines in `scripts/check-build.py` is worth deciding. Resolved: see the C1 close line.
- C3.3: the per-space overrides in `config --overrides` are listed by Mission Control index (`SpaceID.missionControlIndex`, a window server read), so no headless test covers them; the live check does (`Sources/Yabai/ConfigReconcile.swift`, `configOverrideLines`).
- C3.3: `resetConfigToStartupDefaults` and `Daemon.execConfigFile` have no caller now, `ConfigFileSearch.isTOML` has none outside its tests, and `configCheckReport` has only tests (`Sources/Yabai/IPC/ConfigReload.swift`, `Sources/Yabai/Yabai.swift`, `Sources/YabaiCore/ConfigFileSearch.swift`); C5.1 deletes them.
- C3.3: a failure of a message that runs during a reload is only logged; the reply shows the changes alone, so a reload that partly failed looks like a success to the client (`Sources/Yabai/IPC/ConfigReload.swift`).
