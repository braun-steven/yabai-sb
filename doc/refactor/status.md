# Refactor status

This is the single source of truth for progress. The protocol is in [overview.md](overview.md), sections "State and
handoff" and "Resume protocol".

Status values: `todo`, `in-progress`, `done`, `blocked`, `skipped`. Find a subphase's commit with
`git log --oneline --grep '^P<ID> '`.

## Run settings

- live_tests: deferred
- plan written at: f5a3bc4b (2026-10-22)

## Phase 1: Gates and tooling

phase: in-progress · mode: nested

| ID | Title | Status | Notes |
|---|---|---|---|
| P1.1 | `scripts/ci.sh`, `make ci-quick` and `make ci` | done | `scripts/ci.sh quick\|full` with per-step logs in `.build/ci/`. Tree has 0 compiler warnings, so the allowlist is empty. Gates: `make ci` passed (build 4s, test 6s, install 32s, osax-test 9s, check-build 97s). Broken-file check failed as expected and was reverted. No live checks. |
| P1.2 | OSAXEmbed enumerates its inputs | done | Inputs are the 10 `osax/` native files plus the 2 scripts, enumerated from `osax/` (same set as the old list, no new files). Gates: `make ci` passed (build 5s, test 14s, install 32s, osax-test 7s, check-build 92s). Touching `Core.swift` rebuilds the payload; a no-op build keeps its mtime; a new file in `osax/` triggers a rebuild. Default `make` output shows only `[n / m] OSAX`; the "Build and embed" step name appears with `swift build -v`. No live checks. |
| P1.3 | Baseline measurements | done | Numbers in "Baseline (P1.3)" at the end of this file, measured at `e3047f40`. No source changes. Gates: `make ci` passed. No live checks. |
| P1.4 | Fix documentation drift and add the refactor plan to AGENTS.md | done | `doc/architecture.md` names the Swift symbols that replaced the C ones (`WindowManager.treeView(for:)`, `treeFocus(direction:for:)`, `setWindowLayout(_:_:)`, `treeSplit(_:for:)`, `Con.visibleWindowCount()`, `Con.raiseTabs(force:)`, `WindowManager.cardDidOrder(_:)`). `doc/testing-refactor.md` open ends: ISSUES.md 5 to 7 are fixed, no `withKnownIssue` remains. Stale "C" comments reworded in `YabaiCore` `ViewArea`, `Area`, `SpaceList`, `MessageParse`, `Message.swift:186` and `CPrivate.h:57`. `AGENTS.md` row added. Diff checked: only comments and docs changed. Gates: `make ci-quick` passed (0 warnings), `make install` passed (CPrivate header touched). No live checks. |

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
- 2026-10-22 13:23 · phase agent · P1 · start (nested) · start P1.1 subphase agent
- 2026-10-22 13:23 · subphase agent · P1.1 · start · add scripts/ci.sh, makefile targets, docs; run gates
- 2026-10-22 13:40 · subphase agent · P1.1 · done · P1.2 (OSAXEmbed inputs) is next; it depends on P1.1 and can start now
- 2026-10-22 13:30 · subphase agent · P1.2 · start · enumerate osax/ in OSAXEmbed; verify rebuild and no-op; run gates
- 2026-10-22 13:45 · subphase agent · P1.2 · done · P1.3 (baseline measurements) is next; it depends on P1.1 and can start now
- 2026-10-22 13:38 · subphase agent · P1.3 · start · measure baseline (make ci, sanitizers, coverage, binary size, grep counts); no source changes
- 2026-10-22 13:44 · subphase agent · P1.3 · done · P1.4 (documentation drift) is next; it has no dependencies and can start now
- 2026-10-22 13:50 · subphase agent · P1.4 · start · fix doc drift (architecture.md, testing-refactor.md, C comments), AGENTS.md row; gates
- 2026-10-22 13:50 · subphase agent · P1.4 · done · make ci-quick and make install passed; the phase agent runs the phase close (make ci) for P1

## Discovered

Out-of-scope findings, as `- P<ID>: <finding> (<file:line>)`.

- P1.4: C-style names remain in doc comments outside the four files P1.4 named: `YabaiCore/Query.swift`, `Client.swift`, `Message.swift` (e.g. `:56`, `:238`), `EventSignal.swift`, `SpaceLayout.swift`, `SpaceWindow.swift`, `Rule.swift` (e.g. `Rule.swift:360`, `:373`, `:505`, `:518`). Plus "Ported from src/..." provenance lines (`Rule.swift:6`, `SpaceWindow.swift:7`, `Sources/Yabai/IPC/Client.swift:8`, `Sources/YabaiCore/Client.swift:4`).

## Baseline (P1.3)

Measured on the tree at `e3047f40` (P1.2 done), before any Phase 1 source change. The commit that records these numbers
is the P1.3 commit itself. Full logs are in `.build/ci/` (`p1.3-*.log` for the commands run by hand).

- `make ci` (`scripts/ci.sh full`, all steps PASS, about 2 min 28 s wall; log `.build/ci/p1.3-make-ci.log`): build 8 s,
  test 14 s, install 32 s, osax-test 2 s, check-build 92 s.
- Tests from `make ci` (`grep 'Test run with' .build/ci/test.log`): 236 tests in 28 suites passed in 1.195 s, then
  83 tests in 2 suites passed in 0.556 s. osax-test (`.build/ci/osax-test.log`): 9 tests in 1 suite passed in 1.450 s.
- `xcrun swift test --sanitize=thread` (`.build/ci/p1.3-tsan.log`): pass, 44 s wall. 236 tests passed in 5.501 s and
  83 tests in 1.746 s. 0 ThreadSanitizer reports.
- `xcrun swift test --sanitize=address` (`.build/ci/p1.3-asan.log`): pass, 32 s wall. 236 tests passed in 3.353 s and
  83 tests in 5.033 s. 0 AddressSanitizer reports.
- `make coverage` (`.build/ci/p1.3-coverage.log`, 44 s): TOTAL 15535 lines, 8926 missed, 42.54% line coverage. 17 of the
  94 `Sources/` files are at 0.00%. The 10 with the most missed lines (all 0.00%): `Yabai/SpaceManager+Operations.swift`
  (352 missed), `Yabai/Workspace.swift` (240), `Yabai/Yabai.swift` (229), `Yabai/Service.swift` (227),
  `Yabai/ProcessManager.swift` (177), `Yabai/EventHandler+Space.swift` (150),
  `Yabai/WindowManager+Reconciliation.swift` (149), `Yabai/Platform/SkyLight+Windows.swift` (109),
  `Yabai/MissionControl.swift` (106), `Yabai/Platform/MachO.swift` (94). The other 7 at 0.00% are `IPC/Client.swift`
  (67), `CPrivate/include/CPrivate.h` (61), `Yabai/Log.swift` (49), `CPrivate/CPrivate.c` (30), `CPrivate/Notify.m`
  (20), `Yabai/main.swift` (19) and `Yabai/Platform/CoreDock.swift` (12).
- Release binary (`stat -f %z bin/yabai`, after `make install` in `make ci`): 8889912 bytes.
- Counts over `grep -rn ... --include=*.swift Sources`:
  - `grep -rn '!' --include=*.swift Sources | grep -v '!=' | wc -l` (rough force-unwrap count): 443
  - `grep -rn 'unsafeBitCast' --include=*.swift Sources | wc -l`: 7
  - `grep -rn 'Unmanaged' --include=*.swift Sources | wc -l`: 33
  - `grep -rnE 'preconditionFailure|fatalError|fatal\(' --include=*.swift Sources | wc -l`: 25
