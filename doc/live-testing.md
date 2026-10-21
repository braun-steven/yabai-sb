# Testing and debugging yabai live

Notes for agents verifying changes on the user's machine. They cover the unit tests, the live
harness, deploying test builds, the scripting addition (SA), sanitizers and crash analysis. Every
point below was learned the hard way; read it before running anything live.

## Unit tests

- `make test` wraps `swift test`. SwiftPM's OSAXEmbed plugin generates the
  embedded arrays automatically, including on a fresh checkout; no preparation command is needed.
  `tests/YabaiCoreTests/` covers pure logic; `tests/YabaiTests/` uses `@testable import Yabai`.
  Run a single test with `swift test --filter <name>`, or the golden IPC replay with
  `swift test --filter Golden` (`goldenReplay`, `tests/YabaiTests/GoldenTests.swift`).
  Builds must be warning-free; any warning is new. Sanitizer daemon builds are `make asan` / `make tsan`.
- The golden replay runs on a daemon state without displays, spaces or windows, but in the test process: a command
  in `tests/YabaiTests/Golden/commands.txt` that acts on a display, space or window would act on the user's
  real one. Only add commands that fail before they act, or that only change the daemon's own state.
- Keep manager-mutating tests in the serialized `DaemonState` suite (`tests/YabaiTests/DaemonState.swift`). Its
  `.daemonFixture` trait resets the config, managers, rules and signals before every test, so a test sees the
  defaults; set any other value a test depends on in the test itself. Tests must not invoke window server side effects.
- Headless mode (`Sources/Yabai/Headless.swift`): `DaemonFixture.reset()` turns it on, and it stays on for the rest
  of the test process; the daemon never enables it. `View.flush()` then applies the tree's frames to the window
  models (`flushHeadless`: no AX, tab bars, feedback windows or borders), `animateWindows`/`animateWindow` do the
  same without reading `SLS.windowBounds`, and `ScriptingAddition.send` records the message bytes instead of
  reaching Dock (`payloadIsCurrent` is true). `Headless.drain()` returns and clears the recorded placements and
  messages (`tests/YabaiTests/HeadlessTests.swift`). `View.update()` (and auto padding) lays a view out in
  `Headless.displayFrame` (1440×900 at the origin, reset per test) instead of asking SkyLight for the display; or
  lay out a seeded view with `view.area = …` and `updateTree()`. The window selectors that look in the active space's tree
  (`first`, `last`, `prev`, `next`, `largest`, `smallest`, `stack.*`) use `Headless.activeSpace` (nil unless a test
  sets it) instead of `SpaceID.active`, so they find a seeded view instead of the user's space. `SpaceID.active`
  itself still asks SkyLight: the golden replay's `space` failures depend on the user's session having an active space.
  `config focus_follows_mouse` only stores the mode (no event tap on the user's mouse), and `config external_bar`
  (`SpaceManager.markSpacesInvalid`) only marks the seeded views, refreshing the view of `Headless.activeSpace`. Gaps: `ScriptingAddition.orderIn` still queries
  `SLS.windowIsOrderedIn` before it sends, and `View.create` asks SkyLight for the space's uuid.
- Fake ids are real ids in the test process: windows, spaces and displays of the user's session have small ids, so
  a call that reaches the window server with `1` or `2` can act on a real one. Use large fake ids
  (`0xFFFF_0000` and up) and keep headless mode in the path.
- Shared test helpers (the id literals) live in the `YabaiTestSupport` target (`tests/YabaiTestSupport/`), which
  cannot depend on the executable `Yabai`: daemon fixtures stay in `tests/YabaiTests/`.
- `make coverage` (`scripts/coverage.sh`) prints the line coverage of `Sources/` per file;
  `make coverage COVERAGE_FILTER='Con|TreeView'` limits the files shown. Write `+` in a file name as `.`
  (`WindowManager.Tree`): make drops the backslash of `\+`, and the files silently disappear from the table.
- Make decisions testable through pure internal helpers taking explicit inputs (e.g.
  `WindowManager.canUseKnownFocus`, `Process.launchRetryDelay`, `treeCollectWindowOrder`),
  keeping side effects in the caller. Swift tests use `@Test` and `#expect`.
- View tests (`tests/YabaiTests/ViewInsertionTests.swift`, `LayoutTests.swift`) use the `Workspace` fixture
  (`TreeFixtures.swift`): a tree view seeded into `SpaceManager.shared.views` and its windows into
  `WindowManager.shared.window` / `managedWindows` (never `addManagedWindow`, which reaches the window server and
  Dock). They call `View.add` / `View.remove` / `flush` and compare `treeDump` text with `assertInlineSnapshot(of:as:
  .lines)`, or the placements of a headless flush with `.descriptionLines` (`tests/YabaiTestSupport/Snapshotting.swift`).
  A snapshot without a trailing closure is recorded into the test source on the first run (which fails once); check
  every recorded tree and frame by hand before committing. After an intended change, re-record with
  `SNAPSHOT_TESTING_RECORD=all swift test --filter <suite>` (inline and image snapshots; each recorded one fails),
  run again without it, and review the diff. With `autoPadding` on, a view lays itself out again in
  the headless display frame, replacing the area the fixture set.
- Window command tests (`tests/YabaiTests/WindowCommandTests.swift`) send `window …` messages through
  `handleMessage` (`Golden.run`) to a `Workspace` view, with the acting window set by `Workspace.act` (focus and
  `setPendingFocus`); `windowCommand` replaces `w<n>` tokens with the fake ids. Rows of (command, failure, tree) check
  the response, the `treeDump` and that the command flushed what it changed. Only commands that stay off the window
  server up to the flush belong there: not `--focus <window>`, `--space`, `--display`, `--stack`, `--insert`,
  `--toggle split`, the `mouse` selector, or `--move`/`--grid`/relative `--resize` of unmanaged windows (they ask
  SkyLight for the window's space, focus windows or reach AX).
- Rule, query and config tests (`tests/YabaiTests/RuleTests.swift`, `MessageQueryTests.swift`, `MessageConfigTests.swift`)
  send messages through `Golden.run` too. Rules are applied to `Workspace` windows made real by hand (`role`, `subrole`,
  `isRoot`, `isMovable`; `Workspace.openForRules`), and the payload messages they send are checked from
  `Headless.drain()`. Leave out `space=`, `display=`, `native-fullscreen=` and `grid=` (AX of a fake window traps), and
  apply `manage=on`/`sticky=off` only to windows that are still managed: an unmanaged window is tiled on
  `SpaceID.active`, the user's space. `scratchpad=` also sets `manage=off`. SkyLight reports the user's display for a
  fake window or space, so leave out `query --displays` of them and the display/space/visibility properties. `query`
  prints window ids as 32-bit signed values, so the fake ids are negative there. Config values other than 0 for
  `window_animation_duration` check SIP and request Screen Recording permission: never send them.
- `View(sid:)` leaves `isGapEnabled` and `isPaddingEnabled` off (`View.create` turns them on): set both before testing
  gaps or padding of a fixture view, or the spacing silently has no effect.
- Layout property tests (`tests/YabaiTests/LayoutTests.swift`) lay out random `TreeModel` trees with random areas,
  gaps and tab bar settings and check the areas (`layoutViolations`). Set `tab_bar_style` and the other bar values
  explicitly: the default glass card insets tabbed containers.
- Tree property tests (`tests/YabaiTests/TreePropertyTests.swift`) apply random operations to a tree and check its
  invariants after every step. Compare trees with `treeDump` and `expectNoDifference`. A failure prints a seed: add
  `@Test(.fixedSeed("…"))` to replay it. Each run draws a new seed, so a rare failure can pass the first runs: run a
  new property ten times or so (`swift test --filter DaemonState` in a loop) before committing. Generators of the
  YabaiCore enums are in `tests/YabaiTestSupport/Generators.swift`.
- Parser property tests (`tests/YabaiCoreTests/ParserPropertyTests.swift`) send random messages (keywords, key-value
  pairs, long digit runs, non-finite and hexadecimal floats, invalid UTF-8) through the YabaiCore parsers and
  selectors, with `FixtureContext` (`tests/YabaiCoreTests/FixtureContext.swift`) for the lookups; each must parse or
  throw a response line. Never send random messages through `handleMessage`: they could run real space or display
  commands. Build random tokens as bytes: a `Token` decodes into a `String`, so re-encoding it loses invalid UTF-8.
  Mostly random tokens rarely form a valid rule or signal: give each domain its own keys and values, and check that the
  success paths are reached (count them once by hand) when changing a generator.
- PropertyBased generators: `Gen.element(of:)` yields an Optional; pick by index (`Gen<Int>.int(in:).map { choices[$0] }`,
  which also shrinks towards the first choice). `Gen.oneOf`/`frequency` of several mapped generators and inline tuple
  tables in `@Test(arguments:)` can exceed the type checker's time limit: declare the parts as typed `let`s,
  `.eraseToAny()` them, and put argument rows in a typed `static let`. A `propertyCheck` closure throws `any Error`,
  so a `do`/`catch` of typed errors inside it needs `do throws(CommandError)`.
- Pure helpers are tested with parameterized rows (`HelperTests.swift`, `MouseValueTests`, `BorderDecisionTests`,
  `WindowAnimationTickTests`, `DisplayManagerTests`; `GridTests.swift` and `AreaTests.swift` in YabaiCore). Keep the
  decisions of window-server code in such helpers (`Grid.frame`, `Area.closest`, `Border.isEnabled`/`BorderShape`,
  `WindowAnimation.interpolate`/`proxyTransform`, `DisplayManager.orderedBuiltinLast`).
- Image snapshots (`TabBarTests.titlesDrawnIntoTabs`) are PNGs in `tests/YabaiTests/__Snapshots__/<test file>/`,
  compared with `perceptualPrecision: 0.98`. The first run records and fails; look at the image before committing.
  Text rendering depends on the OS build: when an update changes it, disable that test and record it again
  (`SNAPSHOT_TESTING_RECORD=all`).
- Exit tests (`#expect(processExitsWith: .failure)`, `WMIsolationTests`) run their body in a child test process, only
  where a trap is the contract (`WM.assumeIsolated` off yabai.wm).
- Tree tests (`tests/YabaiTests/TreeTests.swift`) build containers with `Con(layout:)`, `treeTestLeaf` and
  `treeTestSplit` (`tests/YabaiTests/TreeFixtures.swift`); the border tests use these fixtures too. In tests a tab
  bar has no glass panel, so its `cardID` is nil.
- Independent cases are parameterized: `@Test(arguments:)` over a typed table of rows (`windowCommandRows` in
  `MessageTests.swift`), so each failing row shows its arguments and the others still run. In a `@WM` suite the
  table is a `nonisolated static let`.
- The suite also runs under the sanitizers (`swift test --sanitize=thread|address`, see "Sanitizers"); run both
  after changing tests with sockets, threads or timeouts.

## The live harness

It lives in `scripts/live-tests/`. Run it from that directory:

| File | Purpose |
|---|---|
| `live.py setup` | records the focused window, then opens TextEdit (3 documents), Script Editor (2) and Calculator on space 4 |
| `live.py run <label>` | 28 checks: relayout, tabs (incl. front-to-back order), rapid focus, cross-display send, focus follows mouse, alt-drag, stalled client, frozen app, animations, native fullscreen |
| `live.py extra <label>` | 50 SA space switches (Dock pid, footprint), space focus with a frozen front app, tabbed container warped to display 2 and back, swap across displays |
| `live.py launch <label>` | launch-retry backoff for an app frozen right after launch; needs every test app closed |
| `live.py cleanup` | quits the test apps, resets config, shows space 11 on display 2, focuses the window recorded by `setup` |
| `bench.py <label>` | medians for tab focus, rotate, split focus |
| `perf.py <label> --samples 50 --out <file>` | repeated CLI/socket latency, observed completion, binary identity and process memory |
| `space_tail.py <label> --out <file>` | isolated alternating-space tail probe; distinguish confirmation queries between commands from command-only mode |
| `border_perf.swift` | persistent ScreenCaptureKit pixel probe for visible focus-border changes and moving edges |
| `border_geometry.swift` | read-only check that four border edges surround each supplied untabbed window at its actual WindowServer frame |
| `bounds`, `mouse`, `freeze` | Swift helpers; `live.py` compiles them when missing or outdated (ignored by git) |
| `mirror.swift` | mirrors one display onto the other to simulate an unplug and a replug (see below); compile it with `xcrun swiftc -O mirror.swift -o mirror` (the binary is ignored by git) |
| `deploy.sh [install\|asan\|tsan\|restore]` | builds, signs, installs and restarts a test build; `restore` puts the previous binary back (see below) |
| `sa_version.py` | prints the version and attribute bits of the payload loaded in Dock |
| `ipc_compare.sh` | ~200 IPC commands that only query (the json of every query), fail before they act, or add and remove labeled rules and signals; diff its output between the installed build and a test build, each right after a restart |
| `crashes.py [n]` | summarizes the newest yabai crash reports |

Builds from before and after the JSONEncoder queries format query json differently; normalize both outputs with `jq -S .` per response before diffing.

### Comparing performance builds

`perf.py <label> --samples 50 --out <results.json>` records raw timings, nearest-rank
percentiles, failures, binary identity, tree/config state, RSS and physical footprint.
Use the standard six-window fixture on space 4. Save configuration first; hold
`tree_autotiling off`, `tree_workspace_layout default`, `tree_default_orientation horizontal`,
`focus_follows_mouse off`, `mouse_follows_focus off` and `window_animation_duration 0`
through every matched block. Rebuild a flat test tree with space 4's layout float → tree
under these settings, then balance. Restore the user's configuration afterward.
Autotiling on creates nested trees during reinsertion and invalidates flat-layout comparisons.

The command metrics include CLI process startup; socket queries omit it. Observed completion
metrics include polling and observer-helper startup, so they are upper bounds. Metrics labeled
as pairs include both directions; do not present them as one move or resize. Run at least two
blocks per build with the same fixture, then recheck the original build after restore for drift.

`border_perf.swift` measures command-to-composited-border latency with a persistent
ScreenCaptureKit stream. Compile it with `swiftc -O -warnings-as-errors -swift-version 6
-parse-as-library border_perf.swift -o /tmp/yabai-border-perf`, then run
`/tmp/yabai-border-perf <label> <results.json> 40` (focus) or append `move` (floating edge movement).
It temporarily uses 6px red/blue borders and restores configuration. Move Calculator clear of
the sampled edge midpoints (the live harness uses 2300,1150); an occluded pixel must fail
calibration, not count as a fast update. ScreenCaptureKit's display timestamp measures the
composited frame, not physical light output or internal border drawing CPU time. Keep capture
stopped during the general latency/memory blocks to avoid adding capture overhead to them.
The performance helpers reject a locked desktop before starting and before saving results.
Discard any run spanning a lock; successful IPC commands alone do not prove that an AX action
was applied. Keep explicit window ids matched across builds when comparing captured borders;
query order can select a different blank document after a restart.

For a newly created window's stale border, use an empty space 4 and create four disposable iTerm2
windows one at a time with `osascript -e 'tell application "iTerm2" to create window with default profile'`.
After each creation, wait for tiling to settle and check all ids returned so far with
`/tmp/yabai-border-geometry <window_border_width> <id>...`; compile the helper as described in its header.
Use untabbed windows with borders enabled and `window_border_hide_single off`; save and restore any
settings changed for the test. Check the intermediate one-, two- and three-window states too: the next
window's relayout can repair a stale ring. The helper checks geometry and ordering, not rendered color.
Close only the disposable windows afterward. SkyLight notifications must be subscribed before initial
tiling: AX completion can precede the final WindowServer frame, so subscribing afterward can miss the
resize that would move the border out of the window's creation frame.

Rules for the user's machine:

- The user does not touch keyboard or touchpad during live tests and watches the window that runs the agent
  (usually iTerm2). Record its id before the first live step and focus it again
  (`yabai -m window --focus <id>`) after the last one, also when a step fails or a deploy restarted yabai.

- Two 2560×1440 displays. Display 1 has spaces 1–10, display 2 has 11–15. Spaces 1–3, 9–11 and 15
  hold the user's windows: use only 4–8 and 12–14. The harness uses 4, 5 and 12.
- Recheck the connected displays before every live run: the two-display setup can become laptop-only.
  Use the current geometry, restore the spaces that were actually visible, and explicitly skip
  cross-display checks when display 2 is missing.
- Before `setup`, check `pgrep -lx TextEdit`, `"Script Editor"`, `Calculator`; if one runs, ask the
  user. `setup` records the focused window in `.focused-window` and `cleanup` focuses it again;
  `launch` needs the test apps closed, so it runs after a `cleanup`.
- Run the live harness outside the command sandbox. `mouse trusted` must print `true` in the same
  execution environment as the harness; Accessibility permission in an unrestricted shell does not
  establish posting access inside a sandbox. `CGEvent.post` silently drops denied events, leaving
  focus and frames unchanged. The helper rejects denied posting and `run` checks access before
  changing the fixture, then checks move, sweep and drag subprocess failures.
- `setup` adds windows to the ones already on space 4, so run `cleanup` before every `setup`. After a
  benchmark or an IPC capture (which leave their windows behind) a `setup` without `cleanup` gives 10
  tiled windows where the checks expect 5: `tree is a flat row again`, `rapid focus east x3` and `autofocus
  sweep ends on window under cursor` fail, with the same build that passes 28/28 on a clean space (P9, ASan).
- Every deploy restarts yabai, and a restart loses the trees: all spaces, including the user's, come
  back as a flat splith row (tabbed containers are gone). Rebuild a test layout after each deploy,
  and tell the user that their layouts were reset.
- The native ctrl+←/→ space shortcuts are disabled (symbolic hotkeys 79/81), so the harness skips
  that check. Don't change the user's settings.
- A config getter is not always valid setter input: `focus_follows_mouse` returns `disabled`, but
  restore it with `off`. Focusing the already-focused space returns an error; guard that operation
  in strict helpers. Locate tabbed containers recursively: a window's `--layout tabbed` can wrap
  only that branch rather than change the workspace root.
- While the screen is locked, AX reports no windows of any application (System Events too): a daemon that
  starts then spends tens of seconds in AX timeouts, `live.py run` finds no windows, and bench numbers drop
  because moves no longer apply. Check `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`
  (a scratch Swift script) before a live run, and stop if it is 1.
- A frozen application blocks every accessibility call to it for about 1 s (the AX timeout).
  `kill -STOP` right after `open` only parks the app on yabai's `finishedLaunching` observation, so no
  retries happen; `freeze com.apple.TextEdit` stops it from a KVO callback the moment it has
  finished launching, which exercises the `kAXErrorCannotComplete` retry path. Always `kill -CONT` in a
  `finally`.
- The tree follows i3: a splith container inside a splith container is not flattened. After
  `--layout splith` on a nested tabbed container the tree stays nested, and later checks that expect a
  flat row (and tab-order checks) fail for the wrong reason. `flatten_row()` warps every window next
  to a window at the root. `window <a> --stack <b>` builds a tabbed container; `window --focus parent`
  then `window --warp east` moves the whole container to the display on the right.
- Debug output (`yabai -m config debug_output on`) goes to stdout, i.e.
  `/tmp/yabai_$USER.out.log`, not the error log; warnings and fatal errors go to the error log. Each line is
  flushed when it is written. `live.py`'s launch check matches the lines "retrying", "giving up" and
  "could not observe" (once per attempt) of `Logger.events`/`Logger.processes`. Turn it off again afterwards.
- To test a display removal and re-add (`space_layout` reconcile, `SpaceManager.handleDisplayAdd`) without the
  user unplugging a cable, mirror display 2 onto display 1: `./mirror 2 3 <stop file>` in the background (the
  arguments are the `id`s of `query --displays`, mirrored first), wait until `query --displays` lists one display,
  check, then `touch <stop file>` to unmirror. The mirror reverts when the tool exits, and after 240 s at the latest.
  macOS moves the spaces of the mirrored display over, but merges its visible space into space 1; on unmirror it
  moves them back and puts those windows on a new space (a new id). With `space_layout 15 10:5 10:5:1b` each
  direction takes one reconcile pass (create one space, then destroy it), seen with `debug_output on` (P9 review).
- To check that signal commands run, add a labeled temporary signal and remove it:
  `yabai -m signal --add label=claude_test event=space_changed action="echo \$YABAI_SPACE_INDEX >> <file>"`,
  then `yabai -m signal --remove claude_test`.
- A `config` command returns before the renderers apply it: borders, tab bars, opacity, the
  menu bar alpha and shadows change in the event after the message. A check that reads the window server right after a
  `config` set must wait for it (a following `query` returns once it is applied). `window_border on` with ~20 windows
  takes about 1.5 s in both builds; the old build only blocked the `config` command instead.
- The menu bar alpha set by `menubar_opacity` does not show in `CGWindowListCopyWindowInfo` (the `Menubar` window
  keeps alpha 1), so that setting cannot be checked from the window list.
- Script Editor can leave an invisible window without an AX reference (`Untitled.scpt`) on the fixture space:
  `query --windows --space` lists it as tiled, `query --windows --window <id>` cannot find it and it is not in the
  tree. Take the tiled windows from the leaves of `query --tree`, or a bench cycles focus through it.
- Mission Control could not be opened from an agent shell (2026-10-20: `open -a "Mission Control"`, the CoreDock
  `com.apple.expose.awake` notification and System Events key codes all left it closed), so its enter/exit handling
  needs the user's gesture or keyboard.

Always run a baseline on the installed binary before changing anything, so before/after numbers
come from the same session. Reference numbers from the `fix-left-out-findings` session (release builds):

| Measure | master build | branch |
|---|---|---|
| `run` checks | 26/27 | 28/28 |
| bench tab focus / rotate / split focus (median) | 45 / 136 / 40 ms | 36 / 74–79 / 33 ms |
| space focus with a frozen front app | 2020 ms | 13 ms |
| query during launch retries of a frozen app (median) | 6.9 s (forever) | 12 ms, gives up after 12 attempts |
| query while another client stalls | 3.8 s | 0.8 s |

## Deploying a test build

- Agents deploy test builds themselves with `bash scripts/live-tests/deploy.sh install` (or `asan`,
  `tsan`). The user allowed exactly that command (`Bash(bash scripts/live-tests/deploy.sh:*)` in the
  git-ignored `.claude/settings.local.json`). The auto-mode classifier blocks every other way of
  replacing `~/.local/bin/yabai`; don't work around it. Run the script by this exact command: from the
  repository root, without `cd` or other commands chained in front of it. The shell keeps its working
  directory between tool calls, so run the harness in a subshell, `(cd scripts/live-tests && python3 live.py …)`,
  or the next `deploy.sh` call fails with "No such file or directory".
- The first deploy backs up the installed binary to `~/.local/state/yabai/yabai.before-deploy`; later
  deploys keep that backup. When you are done testing, run `bash scripts/live-tests/deploy.sh restore`,
  which puts the backup back, checks it with `cmp` and deletes it. Never leave a test build installed,
  unless the user takes over. The user deploys a branch for good with `update-yabai-fork` in a real terminal (it needs `sudo`).
- Tell the user after each deploy: it restarts yabai and resets their layouts (see above).
- `deploy.sh` signs with the `yabai-cert` identity (`3A6E8695…`), so the Accessibility permission is
  kept. Check with `codesign -d -r- ~/.local/bin/yabai`. That certificate is self-signed and not trusted for code
  signing (`CSSMERR_TP_NOT_TRUSTED`), so `security find-identity -v` hides it; `scripts/codesign` falls back to it
  when no identity is valid.
- Expected noise in `/tmp/yabai_$USER.err.log` while a test build is installed:
  `sudo: a terminal is required…` (the sudoers rule for `--load-sa` is pinned to the hash of the binary
  that `update-yabai-fork` installed) and `yabairc: line 164: 0xff285577: command not found`.
- `pgrep -x yabai` can list two pids for several seconds after a restart: the second is a `yabai -m` client from the
  yabairc (e.g. `config layout tree` lays out every space again). `live.py` therefore checks the oldest, `pgrep -ox yabai`.

## Scripting addition

- `make osax-test` and `swift test --package-path osax --sanitize=address` / `--sanitize=thread`
  exercise the Swift payload core against a recording backend, including a mock Mach task
  for loader failures. Daemon sanitizer builds do not instrument the injected payload.
- `bash scripts/live-tests/deploy.sh install` embeds the Swift payload (2.1.36); it does not reload
  Dock's payload by itself. The unused Objective-C prototype and core-selection option are removed.
  Follow [osax-prototypes.md](osax-prototypes.md), including the
  old-payload check, terminal reload and restoration. The compatibility wrapper uses empty space
  13 rather than 12 and preserves the user's runtime config and visible spaces.

- A test build cannot load its payload by itself (sudoers, see above), so Dock keeps the old payload.
  That is the moment to test how a new daemon behaves with an old payload, which ignores unknown
  opcodes. Do it before reloading.
- `--load-sa` installs the payload of the binary at `~/.local/bin/yabai`, so a reload of a new payload
  needs the test build installed (`deploy.sh install`) while the user runs it; `deploy.sh restore` afterwards.
  The restored binary matches the sudoers rule, so its yabairc puts its own payload back when it starts
  (check with `sa_version.py`).
- Reloading takes the user two runs of `! sudo ~/.local/bin/yabai --load-sa` (full path; `sudo`'s PATH
  may not include `~/.local/bin`). The first run installs the new payload files and restarts Dock. The
  `dock_did_restart` signal in the yabairc would inject the payload into the new Dock, but its
  `sudo` fails, so Dock has no payload at all until the second run injects it.
- Verify with `python3 scripts/live-tests/sa_version.py`. On macOS 27 (arm64) the
  attributes are `0x5f`: everything in `OSAX_ATTRIB_ALL`, but not `SET_WINDOW`. The Dock function behind
  `SA_OPCODE_WINDOW_FOCUS` is not found, and nothing calls `scripting_addition_focus_window` (the disabled
  `#if 0` branch of `window_manager_focus_window_with_raise` did not survive the Swift port, see the NOTE in
  `WindowManagerFocus.swift`), so that opcode cannot be tested live.
- After the reload Dock is fresh: its footprint grows for the first few hundred operations. To look for a
  leak, measure `vmmap -summary $(pgrep -x Dock) | grep "Physical footprint"` over several rounds and
  compare the later ones (52.2 → 52.9 → 52.9 → 53.0 MB over 600 space switches).
- To find out how Dock's runtime handles one of its ivars without injecting code, read its class
  metadata: `otool -arch arm64e -ov /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock` (the
  binary has no plain `arm64` slice). `0x100000000 __mh_execute_header` in that output is a NULL pointer
  plus the image base. `flags 0x80` is `RO_IS_ARC`. An ivar of an ARC class with no strong or weak ivar
  layout (Swift classes, e.g. `DockCore.DisplaySpaces`) is "unretained" for `object_setInstanceVariable`,
  which then only stores the pointer, although Swift owns a reference in the field. The payload therefore
  writes `_currentSpace` itself and retains the new value and releases the old one (`set_current_space`).
- The payload is built without ARC (`#error` guard at the top of `payload.m`). Its socket thread has an
  `@autoreleasepool` per message; never `release` literals or other autoreleased objects.

## Sanitizers

- The unit tests run under both: `swift test --sanitize=thread` and `swift test --sanitize=address` (about four
  times slower). A test process that dies with "unexpected signal code 13" got a SIGPIPE: the test process does not
  ignore it as the daemon does. Set `SO_NOSIGPIPE` on a test socket right after creating it, because `setsockopt`
  fails with EINVAL once the peer has closed. Do not let a test's outcome depend on a short deadline either: ASan
  and parallel tests stretch the timing (`withSAPeer` in `SAConnectionTests.swift`). To find the test, run the
  helper under lldb with `process handle SIGPIPE -s true` (with `DYLD_FRAMEWORK_PATH`/`DYLD_LIBRARY_PATH` set to the
  platform's `Developer/Library/Frameworks` and `Developer/usr/lib`, and the ASan runtime in
  `DYLD_INSERT_LIBRARIES`). The signal reaches the process, not the writing thread, so the backtraces only show
  what was running; skipping groups of tests (`--skip`) narrows it down faster.
- Confirm the runtime is loaded: `vmmap $(pgrep -x yabai) | grep -m1 -o "libclang_rt[^ ]*"`.
- Before a run, note the size of the error log (`wc -c < /tmp/yabai_$USER.err.log`) and afterwards scan
  only the new part: `tail -c +<size+1> /tmp/yabai_$USER.err.log | grep -E "Sanitizer|runtime error|SUMMARY"`.
- Look at the pid in each report (`==12345==` or `pid=12345`). Reports from pids other than the daemon's
  come from processes it forked, e.g. the process that runs signal commands.
- Former TSan noise: two "data races" in the C `APPLICATION_LAUNCHED` handler (its first `debug` line
  reading `process->name`/`pid` written by `process_create`), from the C event queue, which TSan did not
  model. The handler is `applicationLaunched` in `Sources/Yabai/EventHandlers.swift` now and the queue is
  dispatch, which TSan models; they have not shown up since the Swift event loop (P7). A report there is new.
- Fixed on `fix-left-out-findings`: the forked signal process called `exit()`, which ran CoreSpotlight's
  PowerLog finalizers in a fork of a multithreaded process and crashed (`_os_log_find` /
  `_dispatch_mgr_queue_push` under `exit` < `event_signal_flush`). It then used `_exit()`; since P7 of the
  Swift port the daemon no longer forks for signals, it starts each command with `posix_spawn`. Any child
  of a fork must leave with `_exit()`.

## Crash reports

- macOS writes `~/Library/Logs/DiagnosticReports/yabai-<date>.ips` for every crashed yabai process,
  including forked children and sanitizer aborts. Count them before and after a run and summarize new
  ones with `scripts/live-tests/crashes.py`. An `.ips` file is a JSON header line followed by a JSON body; the crashed
  thread has `"triggered": true`.
- Reports from release builds with the same stack as a sanitizer report show that a bug is not caused by
  the sanitizer, and their dates show whether it predates the branch.
