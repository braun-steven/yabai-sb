# Refactor status

This is the single source of truth for progress. The protocol is in [overview.md](overview.md), sections "State and
handoff" and "Resume protocol".

Status values: `todo`, `in-progress`, `done`, `blocked`, `skipped`. Find a subphase's commit with
`git log --oneline --grep '^P<ID> '`.

## Run settings

- live_tests: deferred
- plan written at: f5a3bc4b (2026-10-22)

## Phase 1: Gates and tooling

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P1.1 | `scripts/ci.sh`, `make ci-quick` and `make ci` | todo | |
| P1.2 | OSAXEmbed enumerates its inputs | todo | |
| P1.3 | Baseline measurements | todo | |
| P1.4 | Fix documentation drift and add the refactor plan to AGENTS.md | todo | |

## Phase 2: Crash and robustness fixes

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P2.1 | Public `AXUIElementGetPid` and checked CF casts | todo | |
| P2.2 | Typed, length-checked SLS notification payloads | todo | |
| P2.3 | CPrivate hardening: KVC guard, timer, Mach-O bounds, region ownership | todo | |
| P2.4 | Log private-symbol availability at startup | todo | |
| P2.5 | IPC hardening: length cap, malformed-message reply, client timeout | todo | |
| P2.6 | No traps in JSON encoding and signal parsing | todo | |

## Phase 3: Scripting addition hardening

phase: todo · mode: — · osax_bumped: —

| ID | Title | Status | Notes |
|---|---|---|---|
| P3.1 | Fade timer runs only while fades are active | todo | |
| P3.2 | Gate the Dock animation patch on known Dock UUIDs | todo | |
| P3.3 | Guarded reads in the payload core | todo | |
| P3.4 | Daemon checks the payload socket's owner | todo | |

## Phase 4: Core lifecycle and event loop

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P4.1 | One window teardown path | todo | |
| P4.2 | One untile/unmanage path | todo | |
| P4.3 | `forget(_:)` for per-window tables | todo | |
| P4.4 | AX window callbacks carry a `WindowID` | todo | |
| P4.5 | Single timer and keyed delayed events in `EventLoop` | todo | |
| P4.6 | `FocusState` | todo | |
| P4.7 | Explicit startup sequence | todo | |

## Phase 5: Platform responsiveness

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P5.1 | Hung-app AX breaker | todo | |
| P5.2 | Mission Control exit without the 100 ms window-list poll | todo | |
| P5.3 | Cache the space list and display arrangement | todo | |
| P5.4 | Batch space lookups while waiting for windows | todo | |
| P5.5 | No synchronous ordered-in query on the border order path | todo | |
| P5.6 | Replace deprecated CG event calls | todo | |
| P5.7 | Typed message send for the bridged move operation (optional) | todo | |

## Phase 6: YabaiCore simplification

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P6.1 | Generic token lookup and dead-code sweep | todo | |
| P6.2 | Shared key-value scanner for rules and signals | todo | |
| P6.3 | Swift number and pattern parsing, verified against libc | todo | |
| P6.4 | Layout math in YabaiCore | todo | |

## Phase 7: Daemon model cleanup

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P7.1 | No force unwraps in tree mutation | todo | |
| P7.2 | No raw-pointer or sentinel state | todo | |
| P7.3 | Split the `Window` model | todo | |
| P7.4 | Typed service errors and tested builders | todo | |
| P7.5 | One tab bar code path per operation | todo | |

## Phase 8: Swift strictness and diagnostics

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P8.1 | `MemberImportVisibility` and `ExistentialAny` | todo | |
| P8.2 | Strict memory safety in YabaiCore | todo | |
| P8.3 | Measured trials: strict memory safety in Yabai, nonisolated(nonsending) by default | todo | |
| P8.4 | OSSignposter intervals | todo | |
| P8.5 | Optional lint target | todo | |

## Phase 9: Configuration management

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P9.1 | Failure messages name the valid values | todo | |
| P9.2 | Warn when several config files exist | todo | |
| P9.3 | Dry-run parsing for config, rule and signal commands | todo | |
| P9.4 | yabairc command extractor | todo | |
| P9.5 | `yabai -m config --check [file]` | todo | |
| P9.6 | `yabai -m config --reload [file]` | todo | |

## Phase 10: IPC features

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P10.1 | Batch message encoding | todo | |
| P10.2 | `yabai -m batch` | todo | |
| P10.3 | Subscriber registry and event encoding | todo | |
| P10.4 | `yabai -m subscribe` | todo | |

## Phase 11: Rendering and UX

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P11.1 | Respect Reduce Motion for window animations | todo | |
| P11.2 | One AX frame-setting path | todo | |
| P11.3 | Skip identical tab bar and selection renders | todo | |
| P11.4 | Move border edges in one update | todo | |
| P11.5 | Animation: alpha once per proxy, display link on the right screen | todo | |
| P11.6 | Cheaper tab bar hover | todo | |
| P11.7 | Focus-follows-mouse fixes | todo | |

## Phase 12: Tree and window features

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P12.1 | Rule effect `insert=` | todo | |
| P12.2 | Window labels and `LABEL` in `WINDOW_SEL` | todo | |
| P12.3 | Restore the floating frame (verify first) | todo | |
| P12.4 | Tree snapshots and `space --undo` | todo | |
| P12.5 | skhd binding-mode recipes | todo | |
| P12.6 | Pin labelled spaces to displays | todo | |

## Phase 13: Mouse and layout features

phase: todo · mode: — 

| ID | Title | Status | Notes |
|---|---|---|---|
| P13.1 | Split-gap hit testing | todo | |
| P13.2 | Drag the gap between splits to resize | todo | |
| P13.3 | Drop ghost preview while dragging | todo | |
| P13.4 | `space --save-layout` | todo | |
| P13.5 | `space --restore-layout` | todo | |

## Handoff log

Append only. Format: `YYYY-MM-DD HH:MM · role · ID · event · next step`.

- 2026-10-22 · planner · — · plan written · orchestrator starts phase 1

## Discovered

Out-of-scope findings, as `- P<ID>: <finding> (<file:line>)`.
