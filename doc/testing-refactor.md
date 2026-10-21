# Testing refactor

A phased plan to strengthen the Swift test suite. One agent works on one phase at a time (never two at once), in
order. At the end of its phase, each agent writes a handover entry at the bottom of this file.

## How to work on a phase

1. Read `AGENTS.md`, `doc/swift-conventions.md` and `doc/live-testing.md` ("Unit tests"). Then read the handover
   entries below, especially the previous phase's.
2. Do only your phase. If you find something that belongs to a later phase, write it in your handover; don't do it.
3. **Hard rules:**
   - Tests never act on the window server or the scripting addition. They run in the user's session, and small
     fake ids can be real windows or spaces.
   - Tests that touch the global managers go in the `DaemonState` suite.
   - No protocols for dependency injection: use pure static helpers that take explicit inputs, or the headless
     flag (Phase 1).
   - Builds stay warning-free.
4. **Verify before you commit:**
   - `make test`
   - `swift test --filter Golden`: unchanged, unless you re-recorded on purpose and reviewed every changed record.
   - `make install`, if production code changed (release-only link errors).
   - `make coverage COVERAGE_FILTER='<files of your phase>'`
5. Commit on `main`, one or a few commits per phase, with concise imperative subjects. Don't commit unrelated
   working-tree changes.
6. Update the Status table and add a handover entry (template at the end). Record pitfalls that cost real time in
   `doc/swift-conventions.md` or `doc/live-testing.md` as well, in the same commit.

## Status

| Phase | Topic | Status |
|---|---|---|
| 0 | Infrastructure: fixture trait, dependencies, coverage | done (`56c21609`) |
| 1 | Headless mode | done (`65772e64`) |
| 2 | Tree model properties | done (see the Phase 2 handover) |
| 3 | Opening and closing windows | open |
| 4 | Layout geometry | open |
| 5 | Window commands end to end | open |
| 6 | Rules, signals, config | open |
| 7 | Parser robustness, pure helpers, extractions | open |
| 8 | Tidy-up and docs | open |

## Background (as of Phase 0)

- **Baseline:** 144 Swift Testing tests (62 YabaiCore, 82 Yabai) plus the golden IPC replay
  (`tests/YabaiTests/Golden/`); 9 osax payload tests (`make osax-test`).
- **Line coverage baseline:** 29.5% in total.
  - YabaiCore: about 95%.
  - `Con.swift` 87%, `TreeView.swift` 37%, `View.swift` 28%, `IPC/MessageWindow.swift` 20%.
  - `WindowManager+Layout/Tree/Geometry` 0%, `WindowManager+Rules` 31%, `Helpers.swift` 28%.
- **Test infrastructure:**
  - `tests/YabaiTests/DaemonState.swift`: `@Suite(.serialized, .daemonFixture)`. `DaemonFixture.reset()` resets
    the config, managers, rules and signals before every test; `Golden.fixture()` calls it.
  - `tests/YabaiTestSupport/`: a shared target with the id literals. It cannot depend on the executable `Yabai`,
    so daemon fixtures stay in `tests/YabaiTests/`.
  - Tree fixtures: `treeTestLeaf` / `treeTestSplit` (`tests/YabaiTests/TreeFixtures.swift`).
  - Selector fixture: `FixtureContext: SelectorContext` (`tests/YabaiCoreTests/MessageTests.swift:7`).
- **Dependencies (test-only):**
  - **PropertyBased 2.0.1:** `await propertyCheck(count:input:...) { ... }`. It is async and takes `#isolation`, so
    it works in `@WM` tests. Use `Gen.int(in:)`, `.array(of:)`, `Gen.element(of:)`, `Gen.case`, `zip`, `.map`. To
    reproduce a failure, add `@Test(.fixedSeed("…"))`.
  - **CustomDump 1.7.3:** `expectNoDifference`.
  - **SnapshotTesting / InlineSnapshotTesting 1.19.6:** snapshots go in `tests/YabaiTests/__Snapshots__/`, which
    the target excludes. Re-record with `SNAPSHOT_TESTING_RECORD=all`.
- **What can be tested headless:**
  - Fully pure: `Con` (`Con.swift`), `View.add` / `View.remove` (`TreeView.swift:157/204`), `Con.layOut`,
    `View.rootArea(in:)`, `updateTree`, `frame(for:)`, `collect*Order`, `borderArea`.
  - Behind a single gate: most `WindowManager+Tree/Layout/Geometry` operations stop only at `View.flush()`, which
    reads `sid.isVisible` (SkyLight) and then applies frames through AX.
- **Hazards:**
  - `ScriptingAddition.send` really reaches Dock (`/tmp/yabai-sa_$USER.socket`). It is called from
    `addManagedWindow` (`purifyWindow`), `adjustLayer`, `tile`/`untile`, `stackWindow`, `toggleShadow` and
    `setSticky`.
  - `View.create` calls SkyLight: build views with `View(sid:)` and seed `SpaceManager.shared.views[sid]`.
  - Any AX accessor on a `Window` whose `ref` is nil traps.
  - Use large fake space ids (`0xFFFF_0000` and up).
  - The `space`/`display` domains and `query --windows/--spaces/--displays` read `SpaceID.active`/`DisplayID.active`
    on their first line, so they are out of scope.
  - There is no event-loop drain API. Call the handlers' functions directly.

## Phase 1: Headless mode

**Goal:** a runtime flag that only tests turn on. When it is on, the code paths that end in the window server or
Dock record what they would do instead.

**Current state:**
- `Sources/Yabai/Headless.swift` exists, uncommitted. It contains `Headless.enable()`, `isEnabled`, `drain()`,
  `record(message:)`, `@WM apply(_ placements:)`, and the `RecordedPlacement` and `HeadlessLog` types.
- `apply` records the frames that differ from `frameRequest` and sets `frame` and `frameRequest`, like an instant
  window server.
- Review the file, then add the gates.

**Tasks:**
1. Add the gates:
   - **`View.flush()`** (`View.swift:100`): `if Headless.isEnabled { flushHeadless() } else if sid.isVisible {…}`.
   - **`View.flushHeadless()`**, next to `flushTree` in `TreeView.swift`: set `isDirty = false`, run
     `captureWindows` (private in that file), then `Headless.apply`. It skips bars, feedback and `Border.refresh`.
   - **`WindowManager.animateWindows` / `animateWindow`** (`WindowAnimation.swift` ~367): with headless on, call
     `Headless.apply` and return. This also bypasses `Window.frameNeedsUpdate`, which reads `SLS.windowBounds`.
   - **`ScriptingAddition.send`** (~312): with headless on, record the bytes and return `true`.
   - **`payloadIsCurrent`** (~419): with headless on, return `true`.
2. Turn it on in `DaemonFixture.reset()` with `Headless.enable()`. Never turn it off in tests.
3. Tests (in DaemonState):
   - A flush of a seeded view records the expected placements, and a second flush records nothing.
   - `ScriptingAddition.shared.setLayer(...)` records one message with the right opcode and does not touch the
     socket.
4. Docs: describe headless mode in `doc/live-testing.md` "Unit tests", and record the fake-id hazard there.

**Done when:** the gates are in, the tests pass, `make install` succeeds, and `otool -L bin/yabai` shows no test
libraries.

## Phase 2: Tree model properties

Add `tests/YabaiTests/TreePropertyTests.swift` (in DaemonState).

- **Text dump:** add a `Con` text dump helper in the test target (layout, window ids, percent, selection), and
  compare dumps with `expectNoDifference`.
- **Generator:** add generators for `Direction`, `ConLayout` and operation enums to `YabaiTestSupport` if they live
  in YabaiCore; otherwise put them in the test target.
- **Property:** run a random sequence of operations over 1–12 windows: `attach`/open, `detach`, `insert(toward:)`,
  `split`, `setLayout`, `toggleLayout`, `move(_:in:hasOutput:)`, `swap`, `rotate`, `mirror`, `balance`, `resize`
  (after `layOut`), `flatten`.
- **Invariants after every step:**
  - Every window appears exactly once.
  - The children's percents sum to 1 (±1e-4).
  - No empty container except the root.
  - The parent and child links agree.
  - `findSelected()` is a live leaf.
- **Round trips:** `rotate(90)` four times, `mirror` twice and `swap` twice each restore the dump.
- **Example tests:**
  - `forceOrientation`, `descend`, `nextLeaf` / `previousLeaf`, `focusCandidate`, `tabbedAncestor`.
  - `neighbor` for every `FocusWrapping` mode (a parameterized table).
  - `place(_:of:)` for every position, and the workspace-tabbed layout (`treeWorkspaceTabbed = true`).

**Done when:** `Con.swift` coverage is at least 92%, and the property tests pass at count 200 or more.

## Phase 3: Opening and closing windows

Add `tests/YabaiTests/ViewInsertionTests.swift`.

- **Fixture:** `Window(id:)` with an `Application()`, a `View(sid:)` seeded into `SpaceManager.shared.views`,
  `WindowManager.shared.window[id]` and `managedWindows[id] = view`. Don't use `addManagedWindow`. Set focus with
  `focusedWindowID` or `setPendingFocus`.
- **`View.add(_:insertionPoint:)` cases:**
  - Into an empty view.
  - Next to the focused window.
  - With an insertion point, including stack.
  - Into a tabbed container.
  - With autotile.
  - With `tree_default_orientation` set to auto or a fixed value.
- **`View.remove` cases:** flattening, the focus candidate, the last window resetting the root.
- **Snapshots:** expected trees as `assertInlineSnapshot` text dumps (reuse the Phase 2 dump).

**Done when:** `View.add` and `View.remove` are fully covered, and `TreeView.swift` coverage is at least 60%.

## Phase 4: Layout geometry

Add `tests/YabaiTests/LayoutTests.swift`.

- **Properties over random trees and root areas, with gaps and padding:**
  - Leaf frames lie within the root area.
  - Siblings don't overlap and are exactly one gap apart.
  - The integer remainder goes to the last child.
  - Tabbed children share the card frame minus the bar (`Con.cardInset`; set `tab_bar_style` explicitly).
  - Zoom-parent and zoom-fullscreen frames (`frame(for:)`).
  - `needsFlush`.
- **Placement snapshots:** take the headless log of a flush through the SnapshotTesting `.lines` strategy (add it to
  `YabaiTestSupport`) for about 6 canonical layouts: 50/50; 3-way with gaps; nested; tabbed; stacked with padding;
  auto padding on and off.

**Done when:** `TreeView.swift` coverage is at least 85% for its pure parts, and `View.swift` at least 60%.

## Phase 5: Window commands end to end

Add `tests/YabaiTests/WindowCommandTests.swift`.

- **Flow:** seed a view with 2–4 windows and make one the acting window with `setPendingFocus`. Run
  `Golden.run("window …")` (`GoldenTests.swift`), then check the response bytes, the tree dump and
  `Headless.drain()`.
- **Commands** (their paths are pure up to `flush`):
  - `--ratio rel:/abs:`
  - `--resize` (managed edges)
  - `--split`
  - `--layout`
  - `--swap` / `--warp` in one view, by id and by direction
  - `--toggle zoom-parent|zoom-fullscreen`
  - `--insert`, only if `target.id.space` is harmless; otherwise note it in the handover.
- **Selectors through `CSelectorContext`:** directions, `recent`, `stack.next/prev/first/last`, ids, unknown ids.
  Write them as parameterized rows of (command, expected response, expected tree).
- **Extraction:** pull the ratio→delta arithmetic out of `adjustWindowRatio` (`WindowManager+Geometry.swift:17`)
  into a static function, and test its edge cases.

**Done when:** `WindowManager+Layout/Tree/Geometry` coverage is at least 60%.

## Phase 6: Rules, signals, config

- **Rules:** add `tests/YabaiTests/RuleTests.swift` and move the rule parts of `WindowManagerTests` into it. Cover:
  - `addRule` with label replacement.
  - `removeRule` by label and by index (the swap-remove order shows in `--list`).
  - `removeOneShotRules`, `queryWindowRules`.
  - Precedence in `combineMatchingRuleEffects`: exclusions, regex, role and subrole.
  - Direct tests of `handleDomainRule` / `handleDomainSignal` (`IPC/MessageQuery.swift`).
- **Config:** a parameterized round trip over the option table, which `MessageConfigTests` already enumerates. For
  each option, set a valid value and read it back normalized; an invalid value gives the documented error.
- **Golden:** add the remaining config setters (padding, opacity, border, `external_bar`, `space_layout`,
  `scratchpad_grid`, `layout`, `auto_padding`, `mouse_action2`), `rule --apply` with no match, and edge tokens.
  Re-record and review.

**Done when:** `WindowManager+Rules` coverage is at least 70% and `MessageQuery` at least 75%.

## Phase 7: Parser robustness, pure helpers, extractions

- **Never crash:** property tests of random token arrays (keywords, separators, Unicode, invalid UTF-8) through
  the YabaiCore parsers: `WindowCommand`, `SpaceCommand`, `QueryCommand`, `RuleCommand`, `parseRule`,
  `parseSignal`, and the selectors with `FixtureContext`. Each must succeed or throw `CommandError`. Never use
  `handleMessage` here: random input could run real space or display commands.
- **Parameterized tests:**
  - `AnimationEasing.value(at:)` over `allCases`: endpoints, and monotonic for the non-overshoot curves.
  - `RGBAColor(hex:)`, `CGRect.clampedX/YRadius`, `isInTriangle`, `Float.clamped`.
  - `MouseDropAction.insertDirection`, `MouseModifiers(flags)`.
  - `TabBar.separatorColor` / `cardPadding`, `TabBarGlass.tint`.
- **Pure extractions, each with tests:**
  - The `applyGrid` arithmetic (`WindowManager+Placement.swift:45-87`) → YabaiCore `Grid.frame(in:padding:gap:)`.
  - `DisplayID.closestDisplay` → YabaiCore over `[Area]`. `AreaTests` then tests the real function.
  - The animation tick interpolation (`WindowAnimation.swift` ~179) → a static `interpolate`.
  - The enable/inset decision in `Border.refresh` → a pure value.
  - `DisplayManager.orderedBuiltinLast` → takes an `isBuiltin` closure.
- **One image snapshot** of `TabBar.drawTitle(in:…)` into an offscreen `CGContext`, at `perceptualPrecision` 0.98.
  Disable it if it is flaky across OS builds.
- **Exit tests** (`#expect(processExitsWith: .failure)`), only where a trap is the contract: `WM.assumeIsolated`
  off `yabai.wm`.

**Done when:** `Helpers.swift` coverage is at least 70%. After an extraction, an optional smoke test:
`bash scripts/live-tests/deploy.sh install`, then `restore`. Tell the user first; it resets the layouts.

## Phase 8: Tidy-up and docs

- Convert loop-in-body tests to `@Test(arguments:)` where they check independent cases (`MessageTests`,
  `TabBarTests`, `QueryTests`).
- Run `swift test --sanitize=thread` and `swift test --sanitize=address`.
- Final `make coverage`, compared with the baseline above.
- Update `doc/live-testing.md` "Unit tests": headless mode, property seeds, snapshot re-recording, coverage. Update
  the `AGENTS.md` Tests section too.
- These aren't user features, so there is no README "Fork changes" entry.

## Out of scope

- A fake display/space platform for the `space`/`display` domains and the window/space/display queries.
- Event-loop tests.
- CI: there are no macOS 27 runners.

---

## Handover log

Template:

```
### Phase N — <topic> (<commit hashes>)
- Did: <what changed, files>
- Coverage: <before → after for the phase's files>
- Issues / pitfalls: <surprises, bugs found (withKnownIssue + ISSUES.md), anything that cost time>
- Next phase should know: <open ends, deviations from this plan>
```

### Phase 0: Infrastructure (`56c21609`)
- **Did:**
  - `Package.swift`: test-only dependencies (PropertyBased, CustomDump, SnapshotTesting/InlineSnapshotTesting)
    and the `YabaiTestSupport` target, which holds the single copy of `IdentifierLiterals.swift`. Every test file
    imports it.
  - `DaemonFixture` (a recursive `TestScoping` trait) on `DaemonState`. The `TreeTests.init` workaround is gone.
  - `MouseHandlerTests` moved into DaemonState.
  - `.timeLimit(.minutes(1))` on the `SAConnection` tests.
  - `make coverage` (`scripts/coverage.sh`).
- **Coverage:** baseline only (see Background).
- **Issues / pitfalls:**
  - The per-test reset exposed `auto_padding_split_in_tab`. It only passed with the `tab_bar_style i3` that the
    golden replay left behind; the default `glass` cards inset the tabs. The test now sets `i3`.
  - Swift Build puts coverage data in `.build/out/Products/Debug/codecov/default.profdata` and the test binaries in
    `.build/out/Products/Debug/*.xctest/Contents/MacOS/`. `scripts/coverage.sh` derives the path from
    `swift test --show-codecov-path`.
  - swift-syntax comes as a prebuilt for the installed toolchain, so a cold test build takes about 20 s.
- **Next phase should know:** the plan put generators and a text snapshot strategy in `YabaiTestSupport` during
  Phase 0. They are deferred to the first phase that needs them (2 and 4), so the target has no unused code.

### Phase 1: Headless mode (`65772e64`)
- **Did:**
  - `Sources/Yabai/Headless.swift` (reviewed, unchanged) and the gates: `View.flush()` → `flushHeadless()`
    (`TreeView.swift`, next to `flushTree`), `animateWindows`/`animateWindow`, `ScriptingAddition.send`
    (records the bytes, returns `true`) and `payloadIsCurrent` (returns `true`).
  - `DaemonFixture.reset()` calls `Headless.enable()`.
  - `tests/YabaiTests/HeadlessTests.swift` (in DaemonState): a flush records the placements once, and `setLayer`
    records one `SA_OPCODE_WINDOW_LAYER` message.
  - `doc/live-testing.md` "Unit tests": headless mode and the fake-id hazard.
- **Coverage:** `Headless.swift` 97%; `View.swift` 28% → 32%, `TreeView.swift` 37% → 40%. Total 29.5% → 29.9%.
  146 tests.
- **Issues / pitfalls:**
  - The SA opcodes (`SA_OPCODE_*`) come from `import OSAX`, not `CPrivate`.
  - `View.update()` / `updateWithAutoPadding` ask SkyLight for `sid.display`. Lay out a seeded view with
    `view.area = …` and `updateTree()`, then `flush()`.
- **Next phase should know:**
  - Once any DaemonState test has run, headless mode is on for the whole process, also for parallel tests outside
    the suite. That is harmless today, because none of them flushes or sends.
  - `ScriptingAddition.orderIn` calls `SLS.windowIsOrderedIn` before `send`, so the gate does not cover it. Avoid
    it, or gate it in a later phase.
  - `ViewTests` still uses `View(sid: 1)`. It never reaches the window server today; Phase 3/4 should move it to a
    large id.
  - `flushHeadless` skips `renderBars`, `raiseTabs` and `showSelection`, so tab order messages (`orderWindows`) are
    not recorded by a flush.

### Phase 2: Tree model properties
- **Did:**
  - `tests/YabaiTestSupport/Generators.swift`: `Gen<Direction>.direction`, `Gen<InsertDirection>.insertDirection`,
    `Gen<ConOrientation>.orientation`. They pick a case by an `Int` index, so failures shrink towards the first case.
  - `tests/YabaiTests/TreeFixtures.swift`: `treeDump(_:)` (layout, last split of tabbed containers, share, focus
    order when it differs from the child order, `*` for the selection) and `treeTestWindowBase` (`0xFFFF_0000`;
    windows print as `w<n>` above it).
  - `tests/YabaiTests/TreePropertyTests.swift` (in DaemonState):
    - `TreeOperation` (16 operations, with its generator) and `TreeModel`, which applies them like the window
      manager: `open` like `View.add`, `close` like `View.remove` (detach, destroy, flatten), the acting container
      is the selection or a window like `treeActingCon`, `focusParent` selects the parent.
    - `operationsKeepInvariants`: 300 random runs of 1–12 windows and 1–40 operations, with
      `tree_workspace_layout` split and tabbed (`treeWorkspaceTabbed`).
    - `roundTripsRestoreTree`: 200 runs; rotate 90 ×4, 90 then 270, 180 ×2, mirror ×2 per orientation, swap ×2.
    - `TreeExampleTests`: `forceOrientation`, `descend`, first/last/next/previous leaf, `windowCount`,
      `focusCandidate`, `tabbedAncestor`, a 42-row `neighbor` table (3 wrapping modes × with/without a display),
      `place` for both positions (new window and window of the tree), a target in another tree, and the
      workspace-tabbed layout through `place`, `attach(_:from:)` and `insert(_:toward:)`.
- **Coverage:** `Con.swift` 87% → 100%. Total 29.9% → 30.7%. 158 tests (62 YabaiCore, 96 Yabai).
- **Issues / pitfalls:**
  - No bugs found. As a check that the property can fail, `resize` was run once without its `fixPercent`: the
    property caught it and shrank the input to 3 steps.
  - Deviation: the plan's invariant "`findSelected()` is a live leaf" does not hold by design: the selection is a
    container after `window --focus parent`, and the window manager clears it on most operations. The model checks
    instead that at most one container is selected and that `root.focusedDescendant` is a window. It also checks
    that the focus order is a permutation of the children, that every share is positive, and that no last split is
    tabbed.
  - `rotate` sets `lastSplit` of splits, so rotation round trips do not restore it. The dump therefore shows
    `lastSplit` only for tabbed containers, where it matters.
  - `expectNoDifference(a, b)` marks the first argument with `−` and the second with `+`. Pass the actual dump first.
- **Next phase should know:**
  - Reuse `treeDump` for the inline snapshots of Phase 3, and `TreeModel` if a random tree is useful. Its
    `apply(.open…)` mirrors `View.add`'s anchor choice without the insertion point.
  - To reproduce a property failure, copy the seed from the failure message into `@Test(.fixedSeed("…"))`.
  - The older `TreeTests` still use small ids (`treeTestLeaf(root, 1)`). They never reach the window server.
