# Refactor and feature plan: overview

This plan improves the Swift port of the fork in 14 sequential phases. The 2026-10-22 review produced it: eight
read-only agents covered architecture, IPC/config, the platform layer, the scripting addition, build/tests,
rendering/UX, feature gaps and Swift quality, and their key claims were checked against the code.

Each phase has its own file with the exact work, split into **subphases**. Live progress is in [status.md](status.md).
Manual checks for the user are collected in [live-checks.md](live-checks.md).

## Phases

| Phase | Title | Summary |
|---|---|---|
| [1](phase-1.md) | Gates and tooling | CI with concise logs; OSAXEmbed enumerates its inputs; de-flake the socket tests; fix doc drift. Every later commit runs these gates. |
| [2](phase-2.md) | Crash and robustness fixes | Public `AXUIElementGetPid`; checked CF casts; guarded SLS notification payloads with a typed enum; `@try` around private KVC; deprecated timer; Mach-O bounds; symbol-availability log; IPC length cap, client timeout and malformed-message reply; no traps in JSON/signal code. |
| [3](phase-3.md) | Scripting addition hardening | Fade timer runs only while fading; Dock code patch gated on known Dock UUIDs; guarded reads in the payload core; client checks the payload socket owner. |
| [4](phase-4.md) | Core lifecycle and event loop | One window teardown/untile path; `forget(_:)` for per-window tables; AX callbacks carry `WindowID`; keyed delayed events with a single timer; `FocusState`; a `Startup` sequence. |
| [5](phase-5.md) | Platform responsiveness | Hung-app AX breaker; Mission Control exit without 100 ms polling; cached space/display lists; batched space lookups; no sync ordered-in query on the focus path; deprecated CG calls and the `objc_msgSend` cast replaced. |
| [6](phase-6.md) | YabaiCore simplification | Generic token lookup and a dead-code sweep; shared rule/signal key-value scanner; Swift parsing instead of `vsscanf`/`strtof`, verified by differential tests; layout math moved into YabaiCore. |
| [7](phase-7.md) | Daemon model cleanup | No force unwraps in tree mutation; no raw-pointer or sentinel state; a split `Window` model; typed service errors with tested plist/argument builders; one tab bar code path per operation (an enum backend, no protocols). |
| [8](phase-8.md) | Swift strictness and diagnostics | `MemberImportVisibility`/`ExistentialAny`; strict memory safety in YabaiCore (and a measured trial elsewhere); OSSignposter intervals; an optional lint target. |
| [9](phase-9.md) | Configuration management | Errors name the valid values; a warning when several config files exist; dry-run parsing; a yabairc command extractor; `yabai -m config --check` with `file:line` output; `yabai -m config --reload` without a restart. |
| [10](phase-10.md) | IPC features | `yabai -m batch` (one round trip, one flush); `yabai -m subscribe` (JSON-lines event stream). |
| [11](phase-11.md) | Rendering and UX | Reduce Motion; one AX resize path; render dedupe; borders move in one update; animation alpha/display-link fixes; cheaper tab-bar hover; focus-follows-mouse fixes. |
| [12](phase-12.md) | Tree and window features | `insert=` rule effect; window labels usable as `WINDOW_SEL` (i3 marks); float frame restore; tree snapshots with `space --undo`; skhd mode recipes; space-to-display pinning by label. |
| [13](phase-13.md) | Mouse and layout features | Drag the gap between splits to resize; drop ghost preview; save and restore layouts. |
| [14](phase-14.md) | Replace make with just | A `justfile` with every make target; scripts and `update-yabai-fork` call just; the makefile is deleted. Added by the user on 2026-10-22. |

The [backlog](#backlog) lists work the plan leaves out on purpose, because it needs a user decision.

## Roles

| Role | Model | Started by | Job |
|---|---|---|---|
| **Orchestrator** | Opus 5.5 (the session the user starts) | user | Runs the phases in order, one phase agent at a time, and checks each phase's result. It never edits source code itself, except in flat mode (see below). |
| **Phase agent** | Opus 5.5 (`Agent`: `subagent_type: general-purpose`, `model: opus`) | orchestrator | Owns one phase. Runs its subphases in order, each with its own subphase agent; reviews each commit; fixes or re-delegates; closes the phase. |
| **Subphase agent** | Haiku 5.5, high effort (`Agent`: `subagent_type: general-purpose`, `model: haiku`, `effort: high`) | phase agent | Implements exactly one subphase, runs its gate, updates `status.md` and commits. |

Run every agent in the **foreground**: start one, wait for its result, then start the next. Subphases are sequential.
They share one working tree and one `.build`, and concurrent SwiftPM builds block each other.

**Flat mode.** A phase agent may be unable to start agents (no `Agent` tool in its tool list). It then returns at once
with the single line `FLAT_MODE_REQUIRED`, without touching anything. For that phase the orchestrator takes over the
phase agent's duties itself: it starts the Haiku subphase agents, reviews their commits and closes the phase. Record
`mode: flat` for that phase in `status.md`.

## Rules for every agent

1. **Read first.** Read `AGENTS.md`, this overview, your phase file and `status.md`, plus the docs that AGENTS.md lists
   for your topic (`doc/swift-conventions.md` for any Swift or C change, `doc/architecture.md` for event loop, managers
   and tree, `doc/live-testing.md` "Unit tests" before writing tests, and `doc/payload-updates.md` with
   `doc/osax-prototypes.md` for the payload).
2. **Find code by symbol, not by line.** Line numbers in the phase files were taken at commit `f5a3bc4b` and drift. Locate
   code with `grep -rn '<symbol>' Sources tests osax`.
3. **Conventions win.** If a step contradicts `doc/swift-conventions.md` or `AGENTS.md`, follow the conventions and record
   the deviation in the subphase notes in `status.md`. Examples: no protocols for dependency injection, `@WM` state, events
   only through `EventLoop.post`, component loggers instead of `print`, no new CPrivate wrappers unless Swift can't make
   the call.
4. **Stay in scope.** Do only your subphase. If you find something else worth fixing, add a line under "Discovered"
   in `status.md`; don't fix it.
5. **Gates** (see the next section) must pass before a commit. Never commit a red build, failing tests or new warnings.
6. **No live actions.** No `deploy.sh`, no `sudo`, no `--load-sa`, no `update-yabai-fork`, no `--restart-service`, no
   `launchctl`, no injection. When a subphase says **Live check**, append the check to `live-checks.md` (template
   inside) and go on. The only exception is `live_tests: allowed` in `status.md`; see "Live tests".
7. **Commits.** Commit directly on `main` (AGENTS.md), one commit per subphase, subject `P<phase>.<sub> <imperative
   summary>` (e.g. `P4.2 Forget per-window render state when a window is removed`). The commit includes the
   `status.md` update. Follow-up fixes are separate commits, `P4.2 Fix …`. Never amend, rebase, force, push or rewrite
   history.
8. **Docs in the same commit.** A new command or option means handler parsing, `doc/yabai.asciidoc` + `just man`, and
   a CHANGELOG entry. A new feature also gets a "Fork changes" entry in `README.md`. Record any pitfall that cost time
   in the matching doc.
9. **Tests.** Swift Testing (`@Test`, `#expect`), in `tests/`. Tests that change managers go in the `DaemonState` suite
   and must not touch the window server (large fake ids `0xFFFF_0000+`, `Workspace` fixture). Run a new property test
   about ten times before committing. For socket, thread or timeout work, also run `swift test --sanitize=thread` and
   `--sanitize=address`.
10. **Golden and snapshots.** After an intended response change: `GOLDEN_RECORD=1 swift test --filter Golden`, then
    review every changed record and list the changed records in the commit body. Re-record snapshots with
    `SNAPSHOT_TESTING_RECORD=all` and review each value.
11. **Noisy output.** `scripts/ci.sh` (phase 1) writes full logs to `.build/ci/` and prints a short summary. Before phase 1
    exists, pipe through `tail -n 60` and grep the log instead of reading it whole.
12. **No destructive git.** Never `git reset --hard`, `git checkout -- <path>`, `git clean`, or `git stash drop`. To set
    work aside, use `git stash push -u -m "refactor-abandoned-<ID>-<reason>"`, and record that in the handoff log.

## Gates

| Gate | Command | When |
|---|---|---|
| quick | `just ci-quick` (debug build + `swift test`, warnings fail) | every subphase, before its commit |
| payload | `just osax-test` | a subphase that touches `osax/` or `Plugins/OSAXEmbed` |
| release | `just install` (release build into `bin/yabai`; it installs nothing) | a subphase that touches `Sources/CPrivate`, `Package.swift` or `@_cdecl` exports |
| sanitizers | `swift test --sanitize=thread`, then `swift test --sanitize=address` | sockets, threads, timeouts, payload core |
| full | `just ci` (quick + release + payload + check-build) | end of every phase, run by the phase agent |

Before phase 1 added the CI recipes, phase agents used direct make targets; this is a historical note.

## State and handoff

`status.md` is the single source of truth, and it is versioned with the work. It holds:

- **Run settings**: `live_tests: deferred | allowed`.
- **One table per phase**: `| ID | Title | Status | Notes |`. Status is one of `todo`, `in-progress`, `done`,
  `blocked`, `skipped`. Find the commit of a `done` subphase with `git log --oneline --grep '^P4.2 '`.
- **Phase lines**: phase status, `mode` (`nested` or `flat`), and `osax_bumped` (phase 3).
- **Handoff log**: append-only. One entry per agent start and end: `YYYY-MM-DD HH:MM · role · ID · event · next step`.
- **Discovered**: out-of-scope findings for later.

**Starting a subphase.** Set it to `in-progress` in `status.md` and add a handoff entry. This change stays uncommitted
until the subphase's commit.

**Finishing a subphase.** Set it to `done`, add a notes line (what changed, any deviation, live checks added) and a
handoff entry, and commit everything together.

### Resume protocol (any role, after an interruption)

1. Run `git status --short` and `git log --oneline -15`. Read `status.md`, including its uncommitted changes
   (`git diff doc/refactor/status.md`).
2. If `doc/refactor/` is untracked (the plan was never committed), commit it first: `Add refactor plan`.
3. For each `in-progress` subphase:
   - **A commit `P<ID> …` exists and the tree is clean.** It finished, but its status update was lost. Set it to
     `done` and commit `P<ID> Record completion`.
   - **The working tree has changes.** Read `git diff`.
     - If they belong to this subphase and are coherent, continue from there: finish the steps, run the gate, commit.
     - If they are broken or unrelated, stash them (rule 12), note the stash in the handoff log, and restart the
       subphase from a clean tree.
   - **No commit and no changes.** Start the subphase normally.
4. Never redo a `done` subphase. If a `done` subphase turns out wrong, add a follow-up commit `P<ID> Fix …`.
5. Continue with the first subphase that is not `done` or `skipped`, in table order.

## Orchestrator procedure

1. Run the resume protocol (step 2 commits the plan if needed).
2. For each phase from 1 to 14 whose phase status is not `done`:
   1. Start a phase agent with the **phase prompt** below. Wait for it.
   2. If it returns `FLAT_MODE_REQUIRED`, run the phase yourself in flat mode with the phase agent procedure.
   3. Check the result:
      - every subphase is `done`, `skipped` or `blocked`, each with a reason;
      - the phase is marked `done`;
      - `git status` is clean;
      - `just ci` passes; let the output-summarizer agent run it if available, otherwise capture its concise summary.
   4. If the check fails, start a fresh phase agent with the same prompt. The resume protocol picks up where the last
      one stopped. After two failed attempts on the same phase, stop and report to the user.
   5. A `blocked` subphase does not stop the run unless a later subphase lists it under **Depends on**. The phase file
      then says to skip the dependent subphase, and the phase agent records why.
3. At the end, summarize for the user:
   - phases completed;
   - blocked and skipped items;
   - pending entries in `live-checks.md`;
   - the "Discovered" list.

   Remind the user to run `update-yabai-fork` in a real terminal after reviewing.

### Phase prompt (orchestrator → phase agent)

```text
You are the phase agent for phase <N> of the refactor plan in /Users/steven/projects/yabai.
Read AGENTS.md, doc/refactor/overview.md (roles, rules, gates, resume protocol, prompts),
doc/refactor/phase-<N>.md and doc/refactor/status.md. If you have no Agent tool, reply exactly
FLAT_MODE_REQUIRED and stop. Otherwise follow "Phase agent procedure" in the overview: run the
resume protocol, then for each subphase that is not done start one Haiku subphase agent
(subagent_type general-purpose, model haiku, effort high, foreground) with the subphase prompt
from the overview, review its commit, and close the phase. Reply with a short summary: subphases
done/blocked/skipped, commits, live checks added.
```

## Phase agent procedure

1. Run the resume protocol. Set the phase to `in-progress` (`mode: nested`) in `status.md` if it isn't already.
2. For each subphase in table order that is not `done` or `skipped`:
   1. Check **Depends on**. If a dependency is `blocked` or `skipped`, mark this subphase `skipped` with the reason.
   2. Start a subphase agent with the **subphase prompt**. Wait for it.
   3. **Review.** Check `git log --oneline -3`, then read `git show --stat HEAD` and the diff. Check it against the
      subphase's **Acceptance**, the conventions, and the scope. Run the subphase's gate yourself.
   4. If something is wrong, start a new subphase agent with the **fix prompt**, at most twice. After that, fix it
      yourself in a `P<ID> Fix …` commit, or mark the subphase `blocked` with a precise reason and a stash name.
   5. If the agent says it could not finish, use the same two-strikes rule.
3. **Close.** Run `just ci`. Fix failures through a fix agent, or yourself. Then:
   - mark the phase `done`;
   - add a short phase summary to the handoff log: what changed, deviations, anything the next phase must know;
   - commit `P<N> Close phase`.

### Subphase prompt (phase agent → subphase agent)

```text
You implement subphase P<ID> of the refactor plan in /Users/steven/projects/yabai.
Read, in this order: AGENTS.md; doc/refactor/overview.md sections "Rules for every agent",
"Gates", "State and handoff" and "Resume protocol"; the section "P<ID>" in
doc/refactor/phase-<N>.md; doc/refactor/status.md; and the docs AGENTS.md lists for the files
you touch. Run the resume protocol for P<ID> only. Set P<ID> to in-progress in status.md, do
exactly the steps of P<ID>, meet its Acceptance, run its Gate, add any Live check to
doc/refactor/live-checks.md, set P<ID> to done with a one-line note, append a handoff entry,
and commit everything as "P<ID> <imperative summary>". Do not deploy, sudo, push or rewrite
history. If you cannot meet the acceptance, leave the tree as is, set P<ID> to blocked with the
exact reason and what you tried, append a handoff entry, commit only status.md as
"P<ID> Record blocker", and reply with the reason. Reply with: commit hash, files changed,
gate results, live checks added, open concerns.
```

### Fix prompt (phase agent → subphase agent)

```text
You fix subphase P<ID> of the refactor plan in /Users/steven/projects/yabai. Read AGENTS.md,
doc/refactor/overview.md ("Rules for every agent", "Gates"), section P<ID> of
doc/refactor/phase-<N>.md, and status.md. The last commit(s) for P<ID> have these problems:
<list concrete problems with file:line and the expected result>. Fix only these, run the gate
of P<ID>, and commit as "P<ID> Fix <summary>" (status.md note updated). Reply with commit hash
and gate results.
```

## Live tests

`live_tests: deferred` is the default. Agents then never deploy; they list the live checks in `live-checks.md`, and the
user works through them, ideally after each phase.

The user may set `live_tests: allowed` in `status.md`. A phase agent may then, at phase close and only once per phase:

- deploy with `bash scripts/live-tests/deploy.sh install`, from the repository root, nothing chained before it;
- run the phase's live checks that need no `sudo`, following `doc/live-testing.md`;
- run `bash scripts/live-tests/deploy.sh restore`.

Deploys restart yabai and reset the user's layouts, so mention that in the phase summary. Payload reloads always need the
user (`sudo`), so they always stay in `live-checks.md`.

## Backlog

These are not scheduled. Each needs a user decision first.

- **Declarative `yabai.toml` config** with a JSON Schema and auto-reload. It builds on phase 9: a TOML parser or a
  dependency, plus precedence rules with yabairc.
- **`--json` response envelope** `{ok,error,data}`: a second output contract to keep stable.
- **Dropping swift-algorithms, swift-subprocess or `SortedDictionary`.** This conflicts with
  `doc/swift-conventions.md`, which prefers these packages. Revisit only if build time or binary size matters.
- **Payload features**:
  - eased fades and fade-in on window creation;
  - PiP scale math (`dw / 4` in `do_window_scale`), which needs live investigation;
  - screen-capture exclusion (`SLSSetWindowSharingState`, unverified on macOS 27);
  - backdrop blur;
  - Mission Control space names;
  - one SLS transaction per relayout;
  - built-in re-injection on `dock_did_restart`.
- **Larger features**:
  - window hint overlay;
  - master-stack preset;
  - built-in hotkey daemon with modes (skhd covers it);
  - scrollable columns layout;
  - window swallowing;
  - menu bar item (use `subscribe` with SketchyBar instead);
  - optional `tree_auto_balance` (removed deliberately);
  - focus-follows-mouse dwell delay.
- **Tooling**:
  - self-hosted CI runner (no hosted macOS 27 runners exist);
  - move the test-only packages into a separate package;
  - one signing-identity source for `justfile` and `deploy.sh`;
  - rename `just install` to `just release`;
  - replace the font-dependent PNG snapshot;
  - merge the three `Event` dispatch switches.
- **Measurement only**: wired memory of glass tab bars with 1, 5 and 20 bars (`vm_stat`), compared with the i3 style.
- **Headless test seam** (`Sources/Yabai/Headless.swift`, about 10 checks in 7 files): deliberate and documented in
  `doc/live-testing.md`. Revisit only if it grows.

## Kick-off

Start a new Claude Code session on Opus 5.5 in the repository root and give it:

```text
Goal: execute the refactor plan. You are the orchestrator described in doc/refactor/overview.md.
Read AGENTS.md and doc/refactor/overview.md, then follow "Orchestrator procedure" exactly until
every phase in doc/refactor/status.md is done (or blocked with a reason). Start one phase agent
at a time (Opus), which starts one Haiku high-effort subphase agent per subphase; every subphase
ends in a commit on main. Do not deploy or use sudo. If interrupted, the next session resumes
from doc/refactor/status.md with the same instruction.
```
