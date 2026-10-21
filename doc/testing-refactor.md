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
| 3 | Opening and closing windows | done (see the Phase 3 handover) |
| 4 | Layout geometry | done (see the Phase 4 handover) |
| 5 | Window commands end to end | done (see the Phase 5 handover; coverage goal not reached) |
| 6 | Rules, signals, config | done (see the Phase 6 handover) |
| 7 | Parser robustness, pure helpers, extractions | done (see the Phase 7 handover) |
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

### Phase 3: Opening and closing windows
- **Did:**
  - `tests/YabaiTests/ViewInsertionTests.swift` (in DaemonState): a `Workspace` fixture (a tree view at space
    `0xFFFF_0100`, area 1200×800, windows `w<n>` with an `Application()` registered in `window` and `managedWindows`).
    30 tests, trees as inline `treeDump` snapshots:
    - `View.add`: empty view, after the focused window, an unfocused window staying behind the focus, a duplicate, no
      focused window, a focused window of another space, a selected container (focus parent) versus a selected leaf,
      the passed insertion point (in and outside the tree), the view's insertion point for all four directions
      (parameterized) and stack (new tab, existing tab), an insertion point without a direction, a tab of a tabbed
      container, autotiling (split along the longer side, tabs left alone), `tree_default_orientation` (5 rows) and
      `tree_workspace_layout` tabbed.
    - `View.attach(_:from:)` for a container from another display, `View.destroy` unmanaging the windows, and
      `Con.title` (`H[Safari V[iTerm2 T[Safari iTerm2]]]`, window title, application name).
    - `View.remove`: a window not in the tree, shares going to the siblings, flattening, the last tab closing its
      container, the insertion point, `treeFocusCandidate` before closing, and the last window resetting the root.
  - `ViewTests` uses space `0xFFFF_0000` instead of `1`.
  - `doc/live-testing.md` "Unit tests": the view test fixture and inline snapshot recording.
- **Coverage:** `View.add` and `View.remove` fully covered. `TreeView.swift` 53% → 62% (from the Phase 2 state),
  `View.swift` 32% → 39%, `Con.swift` 100%. Total 30.7% → 31.6%. 188 tests (62 YabaiCore, 126 Yabai).
- **Issues / pitfalls:**
  - No bugs found.
  - Layouts print by raw value in the dump (`splith`, `splitv`, `tabbed(splith)`).
  - `assertInlineSnapshot` without a closure records into the source on the first run and fails once. Review the
    recorded trees: one test first recorded a tree that did not test what its name said (a workspace-level tabbed
    container never empties); it now uses a stack insertion point.
  - The `updateAutoPadding() == true` branch of `add`/`remove` is not exercised: it goes through
    `updateWithAutoPadding`, which reads `sid.display` from SkyLight and keeps the old area when that is nil. Line
    coverage counts the line as covered.
- **Next phase should know:**
  - Reuse the `Workspace` fixture shape for Phase 4/5 (it is `private` to the file; move it to `TreeFixtures.swift`
    when a second file needs it).
  - Auto padding on and off (Phase 4 snapshots) needs a display frame without SkyLight: either a headless gate in
    `updateWithAutoPadding` (e.g. a fixed headless display frame) or set `isUnpadded`/`area` by hand as
    `ViewTests` does. Decide in Phase 4.
  - The rest of `TreeView.swift` that is still uncovered: `needsFlush`/`frame(for:)` zoom (Phase 4), and bars,
    tab ordering, feedback and `flushTree`, which reach SkyLight or the payload (`collectTabOrder`/`raiseTabs` are
    pure up to `ScriptingAddition.orderWindows` and could be tested headless).

### Phase 4: Layout geometry
- **Did:**
  - Headless display frame: `Headless.displayFrame` (1440×900 at the origin; `DaemonFixture.reset()` restores it).
    `View.updateWithAutoPadding` lays out in it instead of asking SkyLight for the display, so `View.update`,
    `updateAndFlush`, `clear` and auto padding work in tests. `WindowOrder` is `Equatable`.
  - `tests/YabaiTestSupport/Snapshotting.swift`: `.descriptionLines`, one line per element's description.
  - The `Workspace` fixture and `wid(_:)` moved from `ViewInsertionTests.swift` to `TreeFixtures.swift`.
  - `tests/YabaiTests/LayoutTests.swift` (in DaemonState):
    - Properties over `TreeModel` trees, random root areas (integral, 600–3000 × 400–2000), gaps 0–20 and random tab
      bar settings (`BarSettings`: on/off, height, offset −40…20, glass/i3, backdrop, card padding), laid out through
      `View.updateTree`: `layoutFillsTheRootArea` (300 runs; `layoutViolations`: within the root, splits filled one
      gap apart, each child within 0.5 of its share and integral, the last child ends with the split, tabs share the
      card frame below the bar and keep the bar's height), `zoomedWindowsGetTheFrameOfTheirParentOrTheRoot` (100) and
      `flushPlacesEveryWindowAtItsFrame` (100: the headless placements equal `frame(for:)` with a zoomed window,
      `needsFlush` is false afterwards, and a second flush records nothing).
    - Examples: tabbed card frames and offsets, `Con.cardInset`, the remainder of the last child, `needsFlush` at
      1.5 px (parameterized) and with zoom, `ViewSpacing`, `View.clear`, `borderArea` (active tab, hidden tab, split,
      unknown window, no backdrop, zoom), `collectTabOrder` / `collectCardOrder` / `raiseTabs` (one payload message).
    - Placement snapshots (`.descriptionLines` of the headless flush; trees as `.lines`): halves, three ways with
      gaps, nested splits with padding, tabbed with a glass card, stacked with i3 bars and padding. Auto padding on
      and off (parameterized) checks the placements of one, two and again one window with `#expect`.
  - `doc/live-testing.md` "Unit tests": the headless display frame, the `Workspace` fixture, `.descriptionLines`,
    the layout properties.
- **Coverage:** `TreeView.swift` 62% → 66%: every line that stays off the window server is covered except the
  card-id branch of `collectTabOrder` (2 lines, needs a glass panel). The 178 other uncovered lines are tab bar
  rendering, feedback windows, `flushTree`, `focusWindow`, `cardDidOrder` and `refreshBars`, which reach SkyLight.
  `View.swift` 39% → 75% (left: `View.create` and the SkyLight branch of `updateWithAutoPadding`). `Con.swift`
  100%. Total 31.6% → 32.1%. 206 tests (62 YabaiCore, 144 Yabai), one known issue.
- **Issues / pitfalls:**
  - Bug found: a split shorter than its gaps (or whose rounded shares leave nothing) gives its last child a
    negative length, which a flush then re-places every time (`CGRect` standardizes the size). `ISSUES.md` 5,
    `negativeLengthInASplitShorterThanItsGaps` with `withKnownIssue`. The layout property skips splits with less
    than a pixel per child, the flush property skips trees with a negative length. Fix in its own commit.
  - Property failures depend on the random seed: the flush property passed the first full run and failed in a later
    one. Run new properties ten times or so (`swift test --filter DaemonState` in a loop) before committing.
  - `TabBarStyle.glass` with a backdrop insets tabbed containers by `cardPadding`; every layout test sets the bar
    explicitly.
- **Next phase should know:**
  - `View.update()` now works headless, so Phase 5 commands that end in `updateAndFlush` lay out in the 1440×900
    display frame; set `Headless.displayFrame` when a test needs another one. `View.create` still calls SkyLight.
  - Use `Workspace` (`TreeFixtures.swift`) and `.descriptionLines` with `PlacementLine` (in `LayoutTests.swift`;
    move it to `TreeFixtures.swift` if Phase 5 needs it) for the headless placements.
  - `focusWindow` and `cardDidOrder` read `sid.isVisible` (SkyLight); window commands that focus may reach them.

### Phase 5: Window commands end to end
- **Did:**
  - Headless gate: `Headless.activeSpace` (nil by default; `DaemonFixture.reset()` clears it). The window selectors
    that look in the active space's tree (`first`, `last`, `prev`, `next`, `largest`, `smallest`, `stack.*`) use it
    instead of `SpaceID.active` (`WindowManager.activeTreeView`). `SpaceID.active` itself is unchanged: see the issues.
  - Extraction: `WindowManager.ratioDelta(from:type:ratio:size:)` (`WindowManager+Geometry.swift`), the ratio→delta
    arithmetic of `adjustWindowRatio`.
  - `PlacementLine` and `drainPlacements()` moved from `LayoutTests.swift` to `TreeFixtures.swift`.
  - `tests/YabaiTests/WindowCommandTests.swift` (in DaemonState), 20 tests (about 130 cases). Messages go through
    `Golden.run`; `windowCommand` turns `w<n>` into fake ids, `Workspace.act` sets focus and `setPendingFocus`,
    `Workspace.settle` flushes before the command. Rows of `CommandCase` (command, failure, `treeDump`), each also
    checking that every window is placed at its frame afterwards (`expectPlaced`):
    - On `w1 | w2 | w3` (36 rows): `--ratio rel:/abs:` (clamping, unknown type = abs, last child, parse failure),
      `--resize` (managed edges, a failing edge, `abs`), `--split`, `--layout` (all six values), `--swap`/`--warp`
      by direction and by id, `--focus parent` with `--layout`/`--ratio`, chained commands and a leading selector.
    - On `w1 | T[w2 w3 w4] | w5` (20 rows): the same commands from a tab, `--focus parent|child` chains, `--stack`
      onto itself.
    - Selectors (29 rows, `--swap <sel>`, the tree order checked): directions, `prev/next/first/last`,
      `largest/smallest`, `recent`, `stack.prev/next/first/last/recent/<n>`, ids, an unknown id, a missing value, a
      leading selector; plus the failures without an active space or a managed recent window.
    - The only window (9 rows), an unmanaged acting window (10 rows), no acting window.
    - Placements (inline snapshots): `--ratio`, zoom-parent on the space (= fullscreen) and of a tab, zoom-fullscreen.
    - `treeFocusCandidate`, `treeFocusAfterClose`, `--focus north` without a neighbor, `ratioDelta` (12 rows).
  - Docs: `doc/live-testing.md` "Unit tests" (the window command tests, `Headless.activeSpace`, the coverage filter).
- **Coverage:** `WindowManager+Geometry` 0% → 75%, `+Layout` 0% → 48%, `+Tree` 8% → 50% (the three together 4%
  → 54%), `+Lookup` 0% → 78%, `IPC/MessageWindow` 20% → 62%. Total 32.1% → 35.3%. 226 tests (62 YabaiCore, 164
  Yabai), 5 known issues.
- **Issues / pitfalls:**
  - **Done criterion not met:** Layout/Tree/Geometry reach 54%, not 60%. What is left reaches the window server:
    `setWindowInsertion` (`--insert`) asks SkyLight for `target.id.space`, which is nil for a fake window, so it only
    fails with "the acting window is not managed."; `stackWindow` of two windows and `--swap`/`--warp` across views
    move windows between spaces (`SpaceID.moveWindow(s)`, `SLS.hasBridgedWindowOperation`); `treeMove` to another
    display, `treeFocusDisplay`; a successful `treeFocus`/`treeFocusChild` onto a leaf calls `focusWithRaise`, which
    traps on the nil `ref` of a fake window; `moveWindow`/relative `resizeWindow` of unmanaged windows use AX.
    Covering these needs more headless gates (e.g. for `Window.space` and `SpaceID.moveWindows`); decide whether
    that is worth it.
  - Bug found: `--ratio abs:nan`, `--ratio rel:nan`, `--resize right:nan:0` and `--resize right:inf:0` succeed and
    redistribute every share (`ISSUES.md` 6, `nonFiniteValuesLeaveTheTree` with `withKnownIssue`). The parser's `%f`
    accepts `nan`/`inf`. Fix in its own commit; Phase 7's parser properties should include non-finite floats.
  - A first gate in `SpaceID.active` broke the golden replay: `space --foo` then failed with "could not locate the
    space to act on!" instead of the unknown command. The `space` records of the golden replay depend on the user's
    session having an active space; the gate was narrowed to `activeTreeView`.
  - `make coverage COVERAGE_FILTER='WindowManager\+Tree'` silently shows nothing: write `.` for `+`.
  - Behavior worth knowing, matching the manual: `--swap` acts on windows even with a selected container, `--warp`
    and `--layout` act on the selection; `--layout` of a selected container changes its parent (i3); zoom-parent of a
    window directly on the space becomes zoom-fullscreen; `smallest` picks the visible tab (the glass card is smaller).
- **Next phase should know:**
  - The rule tests of Phase 6 can reuse `Golden.run` and `Workspace`; `windowCommand` and `CommandCase` are internal
    to the test target.
  - Static argument tables in a `@WM` suite must be `nonisolated static let`, or `@Test(arguments:)` fails to compile.
  - Commands that end in `focusWithRaise` (`--focus <window>`, a direction focus that finds a leaf) trap on a fake
    window's nil `ref`; check with `Con.neighbor` first, as `focusInADirectionWithoutANeighborFails` does.

### Phase 6: Rules, signals, config
- **Did:**
  - Headless gates: `WindowManager.setFocusFollowsMouse` only stores the mode (it installed a real HID event tap in the
    test process), and `SpaceManager.markSpacesInvalid` (`config external_bar`) marks only the seeded views and
    refreshes the view of `Headless.activeSpace` (it walked the user's displays and created views of their spaces).
  - `DaemonFixture.reset()` also resets `Log.verbose` and the event tap's mouse modifier.
  - `tests/YabaiTests/RuleTests.swift`: the rule tests of `WindowManagerTests` (moved), a 7-row table of
    `removeOneShotRules` (the swapped-in rule is checked again), and in DaemonState:
    - The rule list through `rule` messages: `--add` replacing a label (swap-remove, then append), `--remove` by index
      and label (the order shows in `--list`), labels comparing canonically (é), the `--list` json and its flags, 11
      failure rows.
    - `combineMatchingRuleEffects` with rules parsed from messages: a 23-row table (later rules override, exclusions,
      unanchored and case-sensitive extended regexes, title, role/subrole limits to standard windows, a window managed
      by a rule, the manage round, one-shot rules and their `matched` mark).
    - `rule --apply` on `Workspace` windows (`openForRules`): by label, index, all, inline, an inline rule that a label
      shadows, no match, non-root windows; manage=off/on, sticky, sub-layer, opacity (with and without a fade),
      mouse_follows_focus, scratchpad (taken label, `scratchpad_below`), one-shot rules not applied again. The tree
      and the payload messages (`drainPayloadCalls`) are checked.
    - `signal` messages: list order by event, label replacement across events, removal by index and label, failures.
  - `tests/YabaiTests/MessageQueryTests.swift` (DaemonState): `query --windows --window` (by id, acting window, a tab,
    unknown id), `--spaces --window`, `--tree --space` (tree, float layout), `--spaces`/`--windows --space` of a
    labeled seeded view, a label without a view, and six `recent` selectors that print nothing.
  - `MessageConfigTests.swift`: a 65-row round trip over all 59 options (a non-default value prints normalized, an
    invalid one fails and keeps the value), a check that the rows cover every option, `external_bar`'s three-field
    scan, `--space` spacing overrides with the headless placements, `layout` keeping a view's override, `external_bar`
    marking the seeded views.
  - Golden: 61 new records: the remaining setters (padding, opacity, border, external_bar, space_layout,
    scratchpad_grid, layout, auto_padding, mouse_action2), edge tokens (empty value, `config ''`, 1e3, `-0`, 0x, é,
    out of range integers), `rule --apply` with no match, without a selector and with a bare word, a Unicode and an
    empty label. Every record was reviewed.
  - `doc/live-testing.md` "Unit tests": the two gates, the rule/query/config tests and their limits, the
    `View(sid:)` gap pitfall.
- **Coverage:** `WindowManager+Rules` 31% → 89%, `IPC/MessageQuery` 48% → 82%, `IPC/MessageConfig` 80% → 98%,
  `YabaiCore/RuleCommand` 96% → 100%. Total 35.3% → 40.0%. 259 tests (62 YabaiCore, 197 Yabai), 11 known issues.
- **Issues / pitfalls:**
  - Bug found: integer tokens wrap at 32 bits (`Token.positiveInteger`): `config window_gap 2147483648` sets
    −2147483648, `tab_bar_height 99999999999` sets 1215752191 (`ISSUES.md` 7, `integerValuesOutOfRangeFail` with
    `withKnownIssue`; the golden replay records the wrapped height). Fix in its own commit.
  - Quirks pinned as they are (not bugs by the manual, but surprising): `external_bar` with fewer than three fields
    or a mode longer than five bytes prints the value instead of failing, and ignores text after the third field
    (`main:1:2:3`); colors print without zero padding (`0x0`); an empty value prints the option; `config ''` returns
    nothing; `scratchpad=` implies `manage=off`, so a rule whose scratchpad label is taken still floats the window; an
    invalid regex fails the rule at parse time (`RulePattern.admits` only lets an invalid pattern through for rules
    built in code); `-1` is no index (`value '-1' is not a valid option for RULE_SEL`).
  - `View(sid:)` leaves gaps and padding off: a `--space ws window_gap` test recorded no placements until the
    fixture set `isGapEnabled`/`isPaddingEnabled` (recorded in `doc/live-testing.md`).
  - SkyLight answers display queries for fake windows and spaces with the user's display, and `query` prints the
    fake window ids as negative Int32 values. The query tests avoid the session-dependent fields.
- **Next phase should know:**
  - Phase 7's parser properties should include long digit runs (ISSUES.md 7) and non-finite floats (ISSUES.md 6).
  - Left uncovered in `WindowManager+Rules`: the space/display, native-fullscreen and grid effects of
    `applyRuleEffects` (AX of a fake window). In `MessageQuery`: the queries of all displays/spaces/windows and the
    display queries of a space or window (live session).
  - `EventSignal.swift` (14%) is the signal runner (`posix_spawn` of the actions); it was not in this phase's scope.

### Phase 7: Parser robustness, pure helpers, extractions (`f2946bf8`, `024d430d`)
- **Did:**
  - `tests/YabaiCoreTests/ParserPropertyTests.swift`: 7 properties of 3000 random messages each through `WindowCommand`,
    `SpaceCommand`, `DisplayCommand`, `ConfigCommand.parseScope`/`parseName`, `QueryCommand`, `RuleCommand` and
    `parseRule`, `SignalCommand` (and so `parseSignal`), and the window/space/display/insert selectors resolved through
    `FixtureContext`. Commands are parsed in a loop like `runCommands`. Tokens are bytes: keywords of every domain,
    key-value pairs with the keys of rules or signals, long digit runs, `nan`/`inf`/hexadecimal floats, Unicode, and
    random bytes with invalid UTF-8. Each message must parse or throw a failure that ends in a newline.
  - `FixtureContext` moved from `MessageTests.swift` to `tests/YabaiCoreTests/FixtureContext.swift`; its
    `stackPosition` lookup no longer traps on a position below 1.
  - Parameterized tests: `AnimationEasing` over `allCases` (endpoints, monotonic within 0...1, in-out curves point
    symmetric, sample values), `RGBAColor(hex:)`, `clampedX/YRadius`, `containsIncludingEdges`, `isInTriangle` (both
    orientations, edges and corners outside, degenerate triangles), `Float.clamped`, `OSTimer.milliseconds` (wrap,
    large timestamps), `ProcessSerialNumber.isSame`, `UnixSocket` against a listening socket in `/tmp`
    (`HelperTests.swift`); `MouseDropAction.insertDirection`, `MouseModifiers(flags)`, `MouseModifierKey`
    (`MouseValueTests`); `TabBar.separatorColor`, `TabBar.cardPadding`, `TabBarGlass.tint` (replaces
    `tab_bar_glass_tint_default`).
  - Extractions, each with tests:
    - `Grid.frame(in:padding:gap:)` in YabaiCore (`Rule.swift`, next to `Grid`); `applyGrid` passes the display
      bounds and the view's padding and gap. `GridTests.swift`: a table, padding, gaps, clamping, a grid of zero
      rows, and a property that a cell spans the one-cell frames it covers.
    - `Area.closest(in:among:)` in YabaiCore; `DisplayID.closestDisplay` maps it over `DisplayID.all`. `AreaTests`
      now tests it instead of its own copy of the loop, plus all four directions and ties.
    - `WindowAnimation.progress(at:since:duration:)`, `interpolate(from:to:at:)` and `proxyTransform(of:at:)` from the
      display link tick (`WindowAnimationTickTests`).
    - `Border.isEnabled(_:shows:visible:tiled:scratchpad:windowCount:)` (autoclosures, so the window and the window
      server are only asked when they decide, as before) and `BorderShape` (insets, radius, area; `Border.shape`)
      from `Border.refresh` (`BorderDecisionTests`, which also checks when the autoclosures run).
    - `DisplayManager.orderedBuiltinLast(_:enabled:isBuiltin:)`, nonisolated (`DisplayManagerTests`).
  - Image snapshot `TabBarTests.titlesDrawnIntoTabs` (Menlo 12, i3 and glass, an icon, a truncated title, icon only,
    title only; `__Snapshots__/TabBarTests/titlesDrawnIntoTabs.1.png`, reviewed) and `nothingIsDrawnIntoATabWithoutRoom`.
  - Exit test `WMIsolationTests.assumeIsolatedTrapsOffTheQueue`, plus the passing cases on the queue.
  - `doc/live-testing.md` "Unit tests": parser properties, PropertyBased pitfalls, the helper tests, image snapshots,
    exit tests.
- **Coverage:** `Helpers.swift` 28% → 100%. YabaiCore parsers: `Selector`, `MessageParse`, `Rule`, `RuleCommand`,
  `Area` 100%, `Message` 99%, `WindowCommand` 99%, `SpaceCommand` 99%, `QueryCommand` 99%, `SignalCommand` 97% (the
  `preconditionFailure` that `parseSignal` rules out). Total 40.0% → 42.1%. 306 tests (77 YabaiCore, 229 Yabai), 11
  known issues; the suite passed eight runs in a row.
- **Issues / pitfalls:**
  - No crash found: every random message parsed or failed with a response line, including the inputs of ISSUES.md 6
    and 7 (they succeed with wrong values, which the properties do not judge).
  - The first generator was too shallow: 4 of 2000 rules and no signal parsed. Counting the successes once by hand
    showed it; rule and signal messages now draw pairs from their own keys, and half start with valid pairs.
  - Type-checker timeouts, optional `Gen.element(of:)`, `do throws(CommandError)` in property closures and the lost
    invalid UTF-8 of re-encoded tokens cost time; all are in `doc/live-testing.md`.
  - Quirk pinned, not filed: with a gap, the cells of a grid of three or more columns are not equally wide and the
    gaps between them differ (`middleCellOfThreeColumns`): the bounds shrink by the gap before they are divided. It
    is the arithmetic of the C code; ask the user whether it should change.
  - The optional deploy smoke test was skipped: the user asked not to replace the live binary. The extractions are
    covered by unit tests only; `make install` built `bin/yabai` (no test libraries in `otool -L`).
- **Next phase should know:**
  - Phase 8's `@Test(arguments:)` conversions: inline tuple tables can time out the type checker; use typed static
    tables, and `nonisolated static let` in `@WM` suites.
  - The image snapshot depends on the OS's text rendering; it is the only file snapshot so far.
  - `TabBar.drawTitle` is `@WM` (the class is), so its test lives in the DaemonState `TabBarTests`.
