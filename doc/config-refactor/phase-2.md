# Phase 2: Check and load at startup

**Goal:** the daemon finds `yabai.toml`, checks it completely, and applies it in-process before the managers adopt the
existing windows. `config --check` and a new offline `yabai --check-config` check the TOML file. The user's config
exists as TOML.

**Prerequisites:** phase 1. **Phase gate:** `just ci`.

**Background:**

- `Daemon.configFileChoice(explicit:)` and `execConfigFile` (`Sources/Yabai/Yabai.swift`) pick and spawn the yabairc;
  `ConfigFileSearch` (`Sources/YabaiCore/ConfigFileSearch.swift`) holds the candidate logic.
  `WindowManager.explicitConfigFile` keeps the `-c` path.
- `configCheckReport(path:script:)` (`Sources/Yabai/IPC/ConfigCheck.swift`) builds the `<path>:<line>: <text>` report
  and the summary `checked N commands, M failures, K skipped`; `checkMessage` (`IPC/MessageCheck.swift`) is the dry run.
- The startup order is in `Daemon.run` and in `doc/architecture.md`, "Startup sequence". `Config.current.applySpaceDefaults()`
  runs first in the managers' `WM.sync` block, then `WindowManager.initialize`, `SpaceManager.begin`,
  `WindowManager.begin`.
- `doc/refactor/status.md` "Discovered" P9.2: candidates are compared as paths, not files.

| ID | Title | Depends on |
|---|---|---|
| C2.1 | Find `yabai.toml` | — |
| C2.2 | Check a `yabai.toml`: `config --check` and `yabai --check-config` | C2.1 |
| C2.3 | Convert the example and the user's config | C2.2 |
| C2.4 | Apply the file at startup, before windows are adopted | C2.3 |

---

## C2.1 Find `yabai.toml`

**Steps**

1. `ConfigFileSearch` candidates become `$XDG_CONFIG_HOME/yabai/yabai.toml` and `~/.config/yabai/yabai.toml`. `-c
   <file>` still wins.
2. Compare candidates by resolved path (`realpath` in the Yabai caller), so one file reached twice through a symlink is
   not reported as ignored. Mark Discovered P9.2 obsolete (overview rule 4).
3. When no `yabai.toml` exists but a yabairc does at an old location, log a warning and notify once:
   `yabairc is no longer read; convert it to <path>/yabai.toml`. This check and its message are deleted in C5.1.
4. Do not change what startup runs yet: `execConfigFile` keeps spawning whatever the old code chose until C2.4. Give the
   new search its own function (`Daemon.configFile(explicit:)`) used by C2.2 and C2.4.
5. Tests: update `ConfigFileSearchTests` (pure candidate logic); a symlink case.

**Acceptance:** tests cover both candidates, `-c`, a symlink, and the leftover-yabairc warning decision.

**Gate:** quick. **Commit:** `C2.1 Search for yabai.toml`.

---

## C2.2 Check a `yabai.toml`: `config --check` and `yabai --check-config`

**Steps**

1. New `@WM func configFileReport(path:source:) -> ConfigFileReport` in `Sources/Yabai/IPC/ConfigCheck.swift`, replacing
   `configCheckReport`. It decodes (C1.2), lowers (C1.3) and runs `checkMessage` on each entry. Each failure line is
   `<path>:<line>: <keyPath>: <text>` (C1.4 lines; a document error without a line prints `<path>: <keyPath>: <text>`).
   Summary: `checked N settings, M failures`. The "skipped" count and the `note:` lines go away: nothing is dynamic.
2. `config --check [<file>]` uses it; without a file it checks `Daemon.configFile(explicit:)`. Same exit status as today
   (1 on failure, failures on stderr).
3. Offline: `yabai --check-config [<file>]` in the argument parser checks a file without a running daemon and without
   the window server, printing the same report. Find out first whether `checkMessage` reads manager state for the
   config, rule and signal domains; if it does, run it against the empty managers (headless defaults) and note in the
   docs that selectors that name existing spaces or displays are only checked by the daemon. If that is not possible
   without touching the window server, skip step 3, record why, and keep `config --check` only.
4. `config --reload` keeps its old behavior in this subphase, but its check step now fails with a clear message when the
   chosen file is a TOML file (it is replaced in C3.3).
5. Tests: replace `ConfigCheckTests` cases with TOML fixtures (a bad value, a bad type, an unknown key, a valid file);
   assert the exact report lines. Golden: re-record the `config --check` records and list them in the commit body.
6. Docs: asciidoc `config --check`, `yabai --check-config` (`just man`), CHANGELOG.

**Acceptance:** a file with a bad value reports `<file>:<line>: config.window_gap: unknown value 'x' …` with the
correct line; `yabai --check-config` gives the same report as `config --check` for the fixtures (or step 3 is recorded as
skipped with the reason).

**Gate:** quick. **Commit:** `C2.2 Check yabai.toml with config --check and yabai --check-config`.

---

## C2.3 Convert the example and the user's config

**Steps**

1. Write `examples/yabai.toml` from `examples/yabairc`: every `yabai -m` setting in TOML, comments kept and adapted.
   Lines that are shell (`sudo yabai --load-sa`, heredocs, `echo`) become `[daemon]` settings or a comment explaining the
   replacement. The batch heredoc that `BatchMessageTests` reads moves to `examples/batch.sh`; repoint the test.
   Leave `examples/yabairc` in place until C5.1.
2. Write `~/.config/yabai/yabai.toml` from `~/.config/yabai/yabairc` by hand, the same way, keeping the user's comments.
   - `sudo yabai --load-sa` and its `dock_did_restart` signal become `[daemon] load_scripting_addition = true` with a
     comment that it takes effect from phase 4 on; until then keep the signal as a `[[signal]]` entry so behavior does
     not change after C2.4.
   - Commented-out yabairc lines stay as commented-out TOML.
   - `echo "yabai configuration loaded.."` is dropped.
   - Do not touch or delete the yabairc (overview rule 1). If `~/.config/yabai/yabai.toml` already exists, stop and set
     C2.3 to `blocked`.
3. Check both files with `bin/yabai --check-config <file>` (C2.2). Both must report 0 failures. If C2.2 skipped the
   offline check, check the user's file with a temporary `DaemonState` test that reads the path from an environment
   variable, and do not commit that test.
4. Add a test that `examples/yabai.toml` checks clean, and a test that every setting of `examples/yabairc` has its
   lowered equivalent in `examples/yabai.toml` (compare the extracted words with the lowered words as sets of lines,
   ignoring the shell-only lines listed in the test).
5. The user's file is not in the repository; put its check output in the status notes and add a live check (below).

**Live check:** open `~/.config/yabai/yabai.toml` next to the yabairc and confirm the conversion (settings, rules in the
same order, signals, comments) before deploying C2.4.

**Acceptance:** both files check clean; the equivalence test passes.

**Gate:** quick. **Commit:** `C2.3 Convert the example yabairc to yabai.toml`.

---

## C2.4 Apply the file at startup, before windows are adopted

**Steps**

1. New `@WM` `ConfigLoader` (`Sources/Yabai/ConfigLoader.swift`) with `load(path:) -> ConfigFileReport` and
   `apply(_ entries: [ConfigEntry])`, which runs each entry through the existing handler in-process (build a `Message`
   from the words as the message loop does, call the domain's handler, collect failures). No IPC and no `Task`.
2. Startup: read and check the file before the managers' `WM.sync` block. Inside it, apply in the overview's order:
   - `[config]` options and `space_layout` before `Config.current.applySpaceDefaults()`, so the views are created with
     them. Options whose setter needs a running manager (see the reset inventory at the top of
     `IPC/ConfigReload.swift`: the event tap, the space caches, scratchpad layers) are applied after the manager they
     need has begun; list each such option in a comment;
   - `[[space]]` entries after `SpaceManager.begin`;
   - rules and signals before `WindowManager.begin`, so the adopted windows get the rules.
   Replace the `startup: running the config file` step with `startup: checking the config file` and `startup: applying
   the config file` debug lines at their new places, and keep `doc/architecture.md` "Startup sequence" and the P4.7 list
   in sync.
3. An invalid file: log every failure line, notify `configuration: <file> has M errors; using defaults`, apply nothing.
   A missing file: log, notify, defaults.
4. `execConfigFile` is no longer called at startup (deleted in C5.1). Keep the `spacePinReconcile` pass, now directly
   after the apply.
5. Headless: record the applied entries (`Headless.record(configEntries:)`) instead of the file name, so tests can see
   them.
6. Tests (`DaemonState`): a fixture file applies its options, spaces, rules and signals; rules are present before a
   window is added; an invalid file applies nothing; ordering (`space_layout` before space labels).
7. Docs: asciidoc "CONFIGURATION" section rewritten for `yabai.toml` (`just man`); README "Fork changes" entry
   ("Static `yabai.toml` config instead of the yabairc script"); CHANGELOG.

**Live check:** deploy, then: the startup log shows the new steps in order; `yabai -m config window_gap` and
`yabai -m rule --list` match the file; windows open at startup on the spaces their rules name; no relayout flash after
startup; `yabai -m signal --list` shows the signals.

**Acceptance:** tests pass; the startup sequence doc matches the code.

**Gate:** quick. **Commit:** `C2.4 Apply yabai.toml in-process at startup`.
