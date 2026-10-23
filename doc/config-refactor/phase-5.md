# Phase 5: Remove yabairc

**Goal:** no code, test, script or doc reads, spawns, checks or mentions a yabairc, except the changelog history.

**Prerequisites:** phases 2 to 4. **Phase gate:** `just ci`.

**Background:** find every reference with `grep -rn -i 'yabairc\|execConfigFile\|extractYabaiCommands\|configFiles'
Sources tests scripts examples doc README.md AGENTS.md justfile`. At plan time this matched, among others:
`Sources/Yabai/Yabai.swift`, `Headless.swift`, `IPC/Client.swift`, `IPC/ConfigCheck.swift`, `IPC/ConfigReload.swift`,
`IPC/MessageCheck.swift`, `IPC/MessageConfig.swift`, `SpaceManager.swift`, `WindowManager.swift`,
`YabaiCore/ConfigFileSearch.swift`, `YabaiCore/YabaircExtractor.swift`, their tests, `SkhdRecipesTests.swift`,
`BatchMessageTests.swift`, `scripts/check-build.py`, `scripts/osax/compatibility.py`, `scripts/live-tests/ipc_compare.sh`,
`doc/architecture.md`, `doc/building.md`, `doc/live-testing.md` and `README.md`.

| ID | Title | Depends on |
|---|---|---|
| C5.1 | Delete the yabairc code paths | — |
| C5.2 | Rewrite the docs | C5.1 |

---

## C5.1 Delete the yabairc code paths

**Steps**

1. Delete `Daemon.execConfigFile` and the sh spawn, `resetConfigToStartupDefaults` if C3.3 left it unused (keep the
   reset inventory comment only if the engine still refers to it, rewritten for reconcile), `Headless.record(configFile:)`
   and `configFiles`, the leftover-yabairc warning from C2.1, and any yabairc wording in comments.
2. Move `YabaircExtractor.swift` from `YabaiCore` into the test target (`tests/YabaiTests/Support/ShellCommandExtractor.swift`,
   renamed to say what it is now for: extracting `yabai -m` commands from skhd bindings) together with its tests, and
   cut what only the yabairc needed. `SkhdRecipesTests` keeps working.
3. Delete `examples/yabairc` and the equivalence test from C2.3. `scripts/check-build.py` lists `examples/yabai.toml`
   instead.
4. Update the comments in `scripts/osax/compatibility.py` and `scripts/live-tests/ipc_compare.sh` ("a deploy reapplies
   yabai.toml").
5. Run the background grep again: only `CHANGELOG.md` history and this plan may match.
6. Golden: re-record if records change (they should not), and list them.

**Acceptance:** the grep is clean outside `CHANGELOG.md` and `doc/config-refactor/`; `just ci` passes.

**Gate:** quick + release. **Commit:** `C5.1 Remove yabairc support`.

---

## C5.2 Rewrite the docs

**Steps**

1. `doc/yabai.asciidoc` (`just man`): the CONFIGURATION section documents the file locations, every table and key, value
   types, overrides, auto-reload, `config_loaded`, `--check-config`; FILES lists `yabai.toml`; every example that says
   "put this in your yabairc" says `yabai.toml` and shows TOML where it is a setting.
2. `README.md`: the configuration section and the examples (`config --check`, `config --reload`, pins "put the commands
   in your yabairc") use `yabai.toml`; the "Fork changes" entry is final.
3. `doc/architecture.md`: startup sequence, config loading, reconcile, watcher. `doc/live-testing.md`: deploys reapply
   `yabai.toml`; the P4.7-style startup list; the space_layout pitfall rephrased for `[[space]]`. `doc/building.md` if it
   mentions the yabairc. `AGENTS.md`: the commands list mentions `yabai --check-config`.
4. CHANGELOG: one breaking entry: "The yabairc is no longer read; the config is `yabai.toml`".
5. A live check for the user to delete `~/.config/yabai/yabairc` once they are happy.

**Acceptance:** no doc describes the yabairc as current; `just man` output is committed.

**Gate:** quick. **Commit:** `C5.2 Document yabai.toml as the only config`.
