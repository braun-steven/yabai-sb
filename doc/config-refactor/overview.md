# Static config plan: overview

This plan replaces the yabairc shell script with a static TOML file, `yabai.toml`, and removes yabairc support
completely. It has 6 sequential phases. It was written on 2026-10-23 at commit `27e6e7aa`, after the 14-phase refactor
plan in [`doc/refactor/`](../refactor/overview.md) was done.

Each phase has its own file with the exact work, split into **subphases** (`C<phase>.<sub>`). Live progress is in
[status.md](status.md). Manual checks for the user are collected in [live-checks.md](live-checks.md).

**Status: complete.** All 6 phases were done on 2026-10-23 (`C6 Close phase`); see [status.md](status.md) for the notes,
the open "Discovered" items and the pending live checks.

## Why

Today the daemon spawns the yabairc with `sh` (`Daemon.execConfigFile`, `Sources/Yabai/Yabai.swift`) and nobody waits for
it. Its roughly 100 `yabai -m` lines reach the daemon as separate IPC messages, after the managers have already adopted
and tiled the existing windows. `config --check` emulates sh to find those lines (`YabaircExtractor.swift`) and skips
anything dynamic. `config --reload` resets everything and runs the script again, so every setter with a side effect runs
again: the P9.6 live check found that this flattens tabbed containers (`doc/refactor/status.md`, "Discovered").

A static file gives:

1. **All-or-nothing validation.** The whole file is parsed and checked before anything changes; nothing is skipped as
   "dynamic shell".
2. **Correct startup order.** The file is applied in-process before the managers adopt windows, so gaps, rules and
   `space_layout` are in place for the first layout pass.
3. **Non-destructive reload.** Reload compares the file with the running state and applies only the differences, so it
   is safe to reload on every save (auto-reload).
4. **No process and no IPC round trip per setting**, and a JSON Schema for editor completion.

## Decisions

Taken with the user on 2026-10-23:

| Topic | Decision |
|---|---|
| yabairc | Removed completely, including the extractor in `YabaiCore`, the sh spawn and the yabairc candidates. No upstream compatibility. |
| Parser | SwiftPM dependency: [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) (pure Swift library target, TOML 1.1, MIT, typed throws, generic `TOMLTable`/`TOMLArray` API, syntax errors carry a line number). Pinned `exact:`. C1.1 verifies it; if it fails the criteria there, the subphase is blocked and the user decides. |
| Runtime IPC | `yabai -m config <option> <value>`, `rule --add/--remove` and `signal --add/--remove` keep working as **overrides**: they last until the next reload or restart, which goes back to the file. `config --overrides` lists them. |
| Scripting addition | Built in: `[daemon] load_scripting_addition = true` makes the daemon run `sudo -n <own path> --load-sa` at startup and after `dock_did_restart`. Needs the sudoers entry the user already has. |
| Migration | No conversion tool. An agent converts `examples/yabairc` and the user's `~/.config/yabai/yabairc` by hand in C2.3. |

Defaults chosen by the planner (the user can change them in this file before the run starts):

| Topic | Default |
|---|---|
| File location | `$XDG_CONFIG_HOME/yabai/yabai.toml`, else `~/.config/yabai/yabai.toml`. `yabai -c <file>` keeps working. No dotfile in `$HOME`. |
| Option names | The same names as the IPC options (`window_gap`, `tab_bar_font`, …), in a `[config]` table, so every file key maps 1:1 to `yabai -m config <name>` and the man page documents one name. |
| Value types | TOML booleans for on/off values (options with more choices, such as `window_shadow`, also take the strings); integers and floats native; colors as integers (`0xff51afef`); `space_layout` as an array of strings; everything else as the IPC string (`scratchpad_grid = "40:40:1:1:38:38"`). |
| Unknown keys | An error, so typos are caught. |
| Invalid file | At startup: run with the built-in defaults, log and notify, keep watching the file. On reload: keep the running config, log and notify. |
| Auto-reload | On by default (`[daemon] auto_reload = true`); the file's directory is watched, so editors that save by rename work. |
| Rules on reload | As today: rules apply to windows created after they are set. `yabai -m rule --apply` stays. At startup, rules exist before the managers adopt windows, so the existing windows get them. |
| Startup hook | A new signal event `config_loaded` fires after the file was applied (startup and every reload). It replaces "run something at the end of the yabairc". |
| skhd recipes | `SkhdRecipesTests` still checks the `yabai -m` commands of `examples/skhdrc`, which is shell, so the extractor moves into the test target instead of being deleted. |

## Target format

```toml
#:schema ./yabai.schema.json

[daemon]
auto_reload = true
load_scripting_addition = true

[config]
mouse_follows_focus = false
window_shadow = "float"            # also true / false
window_gap = 10
active_window_border_color = 0xff51afef
tab_bar_font = "system:12"
space_layout = ["15", "10:5", "10:5:1b"]
scratchpad_grid = "40:40:1:1:38:38"
external_bar = "all:0:0"

[[space]]                          # per-space settings, labels and pins
index = 11
label = "chat"
pin = "1"                          # DISPLAY_SEL
window_gap = 0

[[rule]]                           # the keys of `rule --add`; order is kept
app = "^Calendar$"
space = 9
insert = "stack"

[[rule]]
label = "Finder"
app = "^Finder$"
title = { not = "^(Copy|Move)$" }  # title!=…
manage = false

[[signal]]
event = "window_focused"
action = "sketchybar --trigger window_focus"
```

## Design

```text
yabai.toml ──TOMLDecoder──▶ TOMLTable ──decode──▶ ConfigDocument (YabaiCore, pure, Equatable)
                                                     │ lower
                                                     ▼
                                    [ConfigEntry]: IPC tokens + key path + line
                                                     │ checkMessage (dry run, existing)
                                                     ▼
                                    ConfigFileReport (failures as <file>:<line>: <key path>: <text>)
                                                     │ apply engine (@WM, one handler, no IPC)
                                                     ▼
                       existing ConfigOption / rule / signal / space handlers, only for values that differ
```

- **One parser per setting.** The document is lowered to the same token streams `yabai -m` sends, and those go through
  the existing `checkMessage` and handlers. No second implementation of any option's parsing.
- **`YabaiCore` stays pure**: the dependency, `ConfigDocument`, decoding, lowering and line lookup live there; checking
  and applying live in `Sources/Yabai`.
- **Apply order** (startup and reload): global `[config]` options, `space_layout`, then `[[space]]` labels, pins and
  per-space options, then rules, then signals, then `config_loaded`.
- **Diff, not replay.** An option is applied only when its current value differs from the file's (C3.1, C3.2). Rules and
  signals are replaced only when their list differs.

## Phases

| Phase | Title | Summary |
|---|---|---|
| [1](phase-1.md) | TOML document model | TOMLDecoder dependency; `ConfigDocument` with strict decoding; lowering to IPC tokens; key path to line lookup. All in `YabaiCore`, nothing in the daemon changes. |
| [2](phase-2.md) | Check and load at startup | `yabai.toml` file search; `config --check` and offline `yabai --check-config` on TOML; the example and the user's config converted; the file applied in-process before windows are adopted. |
| [3](phase-3.md) | Non-destructive reload | Setters skip unchanged values; the diff apply engine; `config --reload` and `config --overrides`; auto-reload on save; the `config_loaded` signal event. |
| [4](phase-4.md) | Built-in scripting addition loading | `load_scripting_addition`: `sudo -n yabai --load-sa` at startup and after the Dock restarts, off the event loop. |
| [5](phase-5.md) | Remove yabairc | The spawn, the extractor (moved to tests), the headless config-file record and every yabairc reference deleted; docs rewritten. |
| [6](phase-6.md) | Editor and tooling support | JSON Schema kept in sync by a test; `config --dump` prints the running config as TOML. |

## Roles, rules, gates and procedures

Everything in [`doc/refactor/overview.md`](../refactor/overview.md) sections "Roles", "Rules for every agent", "Gates",
"State and handoff", "Resume protocol", "Orchestrator procedure", "Phase agent procedure" and "Live tests" applies, with
these substitutions:

| In doc/refactor | Here |
|---|---|
| `doc/refactor/…` (overview, phase files, `status.md`, `live-checks.md`) | `doc/config-refactor/…` |
| subphase ids `P<phase>.<sub>`, commits `P4.2 …`, `P<N> Close phase` | `C<phase>.<sub>`, commits `C2.3 …`, `C<N> Close phase` |
| phases 1 to 14 | phases 1 to 6 |
| plan commit `Add refactor plan` | `Add static config plan` |
| stash names `refactor-abandoned-<ID>-…` | `config-refactor-abandoned-<ID>-…` |
| line numbers taken at `f5a3bc4b` | taken at `27e6e7aa` |

Additional rules for this plan:

1. **The user's config is live data.** Only C2.3 writes outside the repository, and only the new file
   `~/.config/yabai/yabai.toml`. No agent deletes or edits `~/.config/yabai/yabairc`; the user removes it after phase 5.
2. **Golden.** Records that change because of this plan (`config --check`, `config --reload`, new commands) are
   re-recorded with `GOLDEN_RECORD=1 swift test --filter Golden`, reviewed, and listed in the commit body.
3. **Docs per subphase.** A subphase that changes user-visible behavior updates `doc/yabai.asciidoc` (`just man`) and
   `CHANGELOG.md` in the same commit. The README "Fork changes" entry for the static config is added once, in C2.4,
   and extended by later phases.
4. **Discovered items made obsolete** by this plan (P9.2 symlinked yabairc, P9.6 reload loop, P12.5 `;` chains) are
   marked "obsolete: config-refactor C<ID>" in `doc/refactor/status.md` by the subphase that makes them so.

### Prompts

Use the prompts of `doc/refactor/overview.md` with the substitutions above. The phase prompt becomes:

```text
You are the phase agent for phase <N> of the static config plan in /Users/steven/projects/yabai.
Read AGENTS.md, doc/config-refactor/overview.md, doc/refactor/overview.md (roles, rules, gates,
resume protocol, prompts; apply the substitutions in doc/config-refactor/overview.md),
doc/config-refactor/phase-<N>.md and doc/config-refactor/status.md. If you have no Agent tool,
reply exactly FLAT_MODE_REQUIRED and stop. Otherwise follow "Phase agent procedure": run the
resume protocol, then for each subphase that is not done start one Haiku subphase agent
(subagent_type general-purpose, model haiku, effort high, foreground) with the subphase prompt,
review its commit, and close the phase. Reply with a short summary: subphases
done/blocked/skipped, commits, live checks added.
```

The subphase prompt becomes:

```text
You implement subphase C<ID> of the static config plan in /Users/steven/projects/yabai.
Read, in this order: AGENTS.md; doc/config-refactor/overview.md; doc/refactor/overview.md
sections "Rules for every agent", "Gates", "State and handoff" and "Resume protocol" (apply the
substitutions from doc/config-refactor/overview.md); the section "C<ID>" in
doc/config-refactor/phase-<N>.md; doc/config-refactor/status.md; and the docs AGENTS.md lists
for the files you touch. Run the resume protocol for C<ID> only. Set C<ID> to in-progress in
status.md, do exactly the steps of C<ID>, meet its Acceptance, run its Gate, add any Live check
to doc/config-refactor/live-checks.md, set C<ID> to done with a one-line note, append a handoff
entry, and commit everything as "C<ID> <imperative summary>". Do not deploy, sudo, push or
rewrite history. If you cannot meet the acceptance, leave the tree as is, set C<ID> to blocked
with the exact reason and what you tried, append a handoff entry, commit only status.md as
"C<ID> Record blocker", and reply with the reason. Reply with: commit hash, files changed, gate
results, live checks added, open concerns.
```

## Deploy timing

After C2.4 the daemon reads only `yabai.toml`. Deploying a build from before C2.3 with C2.4 would start yabai without a
config, so C2.3 must be done before C2.4 (the dependency is in the phase table). Recommended live-check points for the
user: after phase 2 (startup), phase 3 (reload) and phase 4 (needs `sudo`). Deploys restart yabai and reset all layouts.

## Backlog

Not scheduled; each needs a user decision.

- Includes (`include = ["rules.toml"]`) or per-host sections.
- Writing runtime overrides back into the file.
- Re-applying changed rules to existing windows on reload.
- Moving skhd bindings into `yabai.toml` (a built-in hotkey daemon is already in the refactor backlog).

## Kick-off

Start a new Claude Code session on Opus 5.5 in the repository root and give it:

```text
Goal: execute the static config plan. You are the orchestrator described in
doc/config-refactor/overview.md (procedures in doc/refactor/overview.md, with the substitutions
listed there). Read AGENTS.md and both overviews, then follow "Orchestrator procedure" until
every phase in doc/config-refactor/status.md is done (or blocked with a reason). Start one phase
agent at a time (Opus), which starts one Haiku high-effort subphase agent per subphase; every
subphase ends in a commit on main. Do not deploy or use sudo. If interrupted, the next session
resumes from doc/config-refactor/status.md with the same instruction.
```
