# Phase 12: Tree and window features

**Goal:** the i3/AeroSpace features that power users expect most, built on the existing tree:

- placement rules;
- window labels as selectors;
- float frame memory;
- undo;
- binding-mode recipes;
- space-to-display pinning.

**Prerequisites:** phases 4, 6 and 9 (P9.1 error style). **Phase gate:** `make ci`.

Every new command or rule key needs:

- parsing in YabaiCore;
- handlers;
- `doc/yabai.asciidoc` + `make man`;
- a CHANGELOG entry;
- a README "Fork changes" entry;
- golden commands for the failure paths;
- `WindowCommandTests` / `ViewInsertionTests` rows for the tree effects, using the `Workspace` fixture and fake ids.

| ID | Title | Depends on |
|---|---|---|
| P12.1 | Rule effect `insert=` | — |
| P12.2 | Window labels and `LABEL` in `WINDOW_SEL` | — |
| P12.3 | Restore the floating frame (verify first) | — |
| P12.4 | Tree snapshots and `space --undo` | — |
| P12.5 | skhd binding-mode recipes | — |
| P12.6 | Pin labelled spaces to displays | — |

---

## P12.1 Rule effect `insert=`

**Goal:** `yabai -m rule --add app='^Slack$' insert=stack` puts new Slack windows as tabs next to the focused window;
`insert=east|west|north|south` splits that way. This is i3's `for_window` and AeroSpace's `on-window-detected`.

**Steps**

1. Parse `insert='<DIR_SEL|stack>'` in `YabaiCore/Rule.swift` as a new rule effect (`RuleEffects.insert:
   InsertDirection?`), using the P6.2 scanner. `InsertDirection` is in `MessageParse.swift`.
2. Apply it where a new window gets tiled: find where rules are applied to a new window (`WindowManager+Rules.swift`)
   and where tiling picks the insertion point (`EventHandler.tileWindowBatched` / `View.add`).
   - The effect acts like `window --insert <dir>` issued on the focused window of the target view right before the new
     window is added.
   - Reuse the same code path the `--insert` command uses, and don't leave a pending insertion behind for later windows.
3. Interactions to define and test:
   - with `tree_autotiling on`, the rule wins;
   - if the focused window is in another view than the one the window lands in, the rule applies to that view's focused
     window, or is ignored if the view is empty;
   - with `manage=off`, there is no effect.
4. `rule --list` / query output includes `insert`. Check how other effects are serialized; golden-record the list
   output, and review it.
5. Docs: a rule property entry in asciidoc after `scratchpad=`, an example in the README.

**Live check:** a rule `app=Terminal insert=stack`; open several Terminal windows; they appear as tabs in the focused
container.

**Gate:** quick. **Commit:** `P12.1 Add the insert= rule effect for tree placement`.

---

## P12.2 Window labels and `LABEL` in `WINDOW_SEL`

**Goal:** `yabai -m window --label term` labels the focused window; `yabai -m window term --focus` and `yabai -m window
--swap term` act on it. This works like i3 marks, and like the existing `space --label` and `display --label`.

**Steps**

1. Add `--label ['<LABEL>']` to the window domain, mirroring `display --label`:
   - no argument removes the label;
   - a label is unique, so assigning it to another window moves it, as i3 marks do;
   - the same reserved-word rules as space labels apply. Find the validation for space labels and reuse it, so a
     label can't shadow `prev`, `next`, numbers or directions.
2. Store the labels on `WindowManager` (`[String: WindowID]`), and clear them in `forget(_:)` (P4.3).
3. Add `LABEL` to `WINDOW_SEL` resolution, after the built-in selectors, exactly like `SPACE_SEL`. An unknown label
   fails with the usual "could not locate" style message.
4. Query: windows get a `"label"` field (empty string if none). Update `Serialize` and the JSON key order expectations,
   and golden-record.
5. Scratchpad labels are a separate namespace, given as the argument of `window --toggle`. Document that a window
   label and a scratchpad label may coincide without conflict.
6. Docs: `WINDOW_SEL` grammar line, a `window --label` entry, README, CHANGELOG.

**Gate:** quick. **Commit:** `P12.2 Label windows and select them by label`.

---

## P12.3 Restore the floating frame (verify first)

**Goal:** a window toggled from tiled to floating returns to the frame it last had while floating, instead of
keeping the tiled frame. This was requested upstream in #845.

**Steps**

1. Verify the current behavior first by reading `WindowManager+Toggles.swift` (the float toggle) and
   `WindowManager+Management.swift`. If a floating frame is already remembered, mark the subphase `skipped` with the
   evidence.
2. Otherwise, store `lastFloatingFrame: CGRect?` on `Window`:
   - set when a floating window is tiled again, and when a floating window is moved or resized while floating;
   - on toggle to floating, apply it with `setFrame` if it still fits on a current display (intersects the display's
     visible frame by at least 50 %); else center the window at its current size.
3. Clear it in `forget(_:)`.
4. Tests (headless): toggle float, change the frame, toggle tile, toggle float again; the frame is restored.

**Live check:** float a window, resize it, tile it, float it again: it returns to its floating size and place.

**Gate:** quick. **Commit:** `P12.3 Restore the last floating frame when a window floats again`.

---

## P12.4 Tree snapshots and `space --undo`

**Goal:** undo the last tree-changing command on a space. The snapshot format is reused for layout saving in P13.4.

**Steps**

1. In YabaiCore, define `struct TreeSnapshot: Codable, Equatable`, a recursive node with:
   - `layout`;
   - `ratio`/sizes;
   - `focusIndex`;
   - for leaves, `windowID`.

   Add pure conversions in the Yabai target: `Con → TreeSnapshot` and `TreeSnapshot + window table → Con`. Rebuilding
   must reproduce the same `treeDump`; property-test round trips on generated trees with the generators in
   `TreePropertyTests` (ten runs).
2. Keep a per-space ring buffer of 10 snapshots (`SpaceManager` or `View`), and push before each tree-changing window or
   space command:
   - warp, swap, layout, split, ratio, insert, stack, `--toggle split`, balance, rotate and mirror, if they exist in the
     tree layout.

   Hook this at one place in the command handler, keyed by command kind, not in each handler.
3. Add `space --undo` (on the selected space):
   - pop the last snapshot;
   - if its window set equals the current window set of the space, rebuild the tree and flush;
   - otherwise fail with `cannot undo: the windows on this space changed` and drop the snapshot.
4. Clear the buffer when windows are added to or removed from the space, since undo across window changes isn't
   supported.
5. Docs: asciidoc, README, CHANGELOG.

**Acceptance:** round-trip properties pass ten runs, and `WindowCommandTests` rows show warp → undo restores the
`treeDump`.

**Gate:** quick. **Commit:** `P12.4 Snapshot trees and undo tree commands with space --undo`.

---

## P12.5 skhd binding-mode recipes

**Steps**

1. Add `examples/skhdrc` (or extend the existing example if there is one) with:
   - a **resize mode** (`:: resize @`, hjkl resizing via `window --resize` or `--ratio rel:`, escape to leave);
   - a **layout mode** (tabbed, splith, splitv, insert directions, undo from P12.4, balance);
   - a **move mode** (warp, and move to space n).

   Each mode shows feedback through a border color change: `yabai -m config active_window_border_color` or the option
   names in use.
2. Verify every yabai command in the file against `doc/yabai.asciidoc`, and run each through `yabai -m config --check`
   logic: the P9.4 extractor and P9.3 check inside a unit test that loads the file.
3. Link it from the README tree section.

**Gate:** quick. **Commit:** `P12.5 Add skhd binding-mode recipes`.

---

## P12.6 Pin labelled spaces to displays

**Goal:** AeroSpace's `workspace-to-monitor-force-assignment`. A labelled space returns to its display whenever that
display is connected.

**Steps**

1. Add `space <SPACE_SEL> --pin ['<DISPLAY_SEL>']`:
   - this requires the space to have a label; fail otherwise;
   - no argument removes the pin;
   - store the pin as `[spaceLabel: displayUUID]`, because display indices change.
2. Reconcile on startup, display added, display removed and display moved, and on `space --label` changes:
   - for each pin whose display is connected and whose space is elsewhere, move the space with the existing space-move
     machinery (`space --display`), which requires the scripting addition;
   - post the reconcile through `EventLoop.post(_:after:key:)` with a key, so bursts of display events coalesce (P4.5).
3. Without the scripting addition, log once and do nothing.
4. Query: spaces get `"pinned-display"`: the display's index, or 0 when not pinned. Check the serialization style for
   optional ints in the existing code and follow it.
5. Pins live in memory. The yabairc re-creates them at startup. Document that.
6. Tests: the reconcile decision is a pure function (pins, current placement, connected displays → list of moves).
7. Docs: asciidoc, README, CHANGELOG.

**Live check:** label a space, pin it to the external display, unplug the display and plug it back: the space returns to
the external display.

**Gate:** quick. **Commit:** `P12.6 Pin labelled spaces to displays`.
