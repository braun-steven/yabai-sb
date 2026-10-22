# Phase 13: Mouse and layout features

**Goal:** resize splits by dragging the gap between them, see where a dragged window will land, and save and restore
whole layouts.

**Prerequisites:** phases 11 (P11.2 frame path) and 12 (P12.4 `TreeSnapshot`). **Phase gate:** `make ci`, plus
`swift test --sanitize=thread`.

Read `MouseHandler.swift` and `EventHandler+Mouse.swift` fully before P13.1–P13.3. The event tap must stay fast: a slow
callback gets the tap disabled.

| ID | Title | Depends on |
|---|---|---|
| P13.1 | Split-gap hit testing | — |
| P13.2 | Drag the gap between splits to resize | P13.1 |
| P13.3 | Drop ghost preview while dragging | — |
| P13.4 | `space --save-layout` | — |
| P13.5 | `space --restore-layout` | P13.4 |

---

## P13.1 Split-gap hit testing

**Steps**

1. Add a pure function in YabaiCore:
   - Inputs: the laid-out tree (`LayoutNode` from P6.4, with the computed areas), `window_gap`, and a point.
   - Output: `SplitHandle?`, the container (path or id), the index of the boundary between child *i* and *i+1*, and the
     orientation.
   - Only `splith`/`splitv` containers have handles; tabbed containers don't.
   - A point matches when it lies in the gap strip between two adjacent children, widened by 2 pt on each side.
2. Tests: rows for nested splits, gaps of 0 (no handle unless within ±2 pt of the boundary), and points inside windows
   (nil).

**Gate:** quick. **Commit:** `P13.1 Find the split boundary under a point`.

---

## P13.2 Drag the gap between splits to resize

**Steps**

1. Add `config mouse_drag_split on|off`, default `off`.
2. In the event tap, on left mouse down without modifiers:
   - when the option is on, hit-test the active space's tree (P13.1) from a snapshot of areas cached at flush time;
     don't walk the live tree in the tap callback;
   - on a hit, consume the event and start a split drag.
3. Drag updates go through `EventLoop.post` (coalesced like other mouse moves). Each update:
   - converts the pointer delta into a ratio change for the two adjacent children, with the same math as
     `adjustWindowRatio` (`WindowManager+Geometry.swift`);
   - clamps the ratio so neither child gets smaller than its minimum, using the existing minimum size logic;
   - lays out and flushes.

   Mouse up ends the drag.
4. Optional cursor feedback: set the resize cursor if this is possible from the daemon without an app window. If not,
   skip it and note that.
5. Tests: the delta → ratio math as a pure function, with rows.
6. Docs: asciidoc config entry, README (tree section), CHANGELOG.

**Live check:** with the option on, drag the gap between two tiled windows (horizontal and vertical, nested): the split
moves smoothly; clicks inside windows and on the desktop are unaffected. With it off, nothing changes.

**Gate:** quick + sanitizers. **Commit:** `P13.2 Resize splits by dragging the gap between them`.

---

## P13.3 Drop ghost preview while dragging

**Where:**

- `MouseHandler.showDropFeedback` and `TreeView.showFeedback` already draw an outline of the drop target: half or
  whole window, or swap.
- `WindowAnimation.buildProxy` can capture a window image.

**Steps**

1. Add `config mouse_drop_preview outline|ghost`, default `outline`, which is today's behavior.
2. In `ghost` mode:
   - capture the dragged window's image once at drag start (reuse the proxy capture);
   - show it scaled into the destination rect at 50 % alpha in the feedback window;
   - for a swap, also show the target window's ghost in the source rect.
3. Dedupe updates like the existing drop feedback, only when the target changes.
4. Free the captured image on drag end and on cancellation.
5. Docs: asciidoc, README, CHANGELOG.

**Live check:** with `ghost`, drag-insert, drag-swap and drag-stack all show a scaled translucent preview; memory doesn't
grow across 20 drags (`vmmap -summary $(pgrep -x yabai)`).

**Gate:** quick + sanitizers. **Commit:** `P13.3 Preview the drop target with a ghost of the dragged window`.

---

## P13.4 `space --save-layout`

**Goal:** `yabai -m space --save-layout <name>` writes the active space's tree to
`$XDG_CONFIG_HOME/yabai/layouts/<name>.json`, falling back to `~/.config/yabai/layouts/`.

**Steps**

1. Extend `TreeSnapshot` (P12.4) into `LayoutFile: Codable`:
   - `version: 1`;
   - the tree;
   - for each leaf, a **matcher** instead of the window id: `app` (bundle id, plus the application name as fallback),
     `title` (the exact title at save time), and `role`/`subrole`.
2. Validate the name: `[A-Za-z0-9._-]+`, no slashes. Create the directory if it is missing. Write atomically (temp file +
   rename).
3. Reply with the path.
4. Tests: the encoding of a fixture tree is stable (inline snapshot of the JSON); invalid names fail.
5. Docs: asciidoc, README, CHANGELOG (one entry with P13.5).

**Gate:** quick. **Commit:** `P13.4 Save a space layout to a JSON file`.

---

## P13.5 `space --restore-layout`

**Goal:** `yabai -m space --restore-layout <name>` rebuilds the tree of the active space from a saved layout, using the
windows that are on the space now.

**Steps**

1. Load and validate the file: version, and a structure check, with clear errors naming the file.
2. Matching is a pure function in YabaiCore: (leaf matchers, current windows with app, title and role) → assignment.
   - Greedy by score: same bundle id (required), then exact title, then title similarity (common prefix length), then
     role.
   - Each window is used at most once.
3. Build the tree with the matched windows in their slots. Collapse slots without a window, and containers left with one
   child. Append unmatched windows after the focused window, as new windows are today.
4. Flush once. Reply with `restored <n> of <m> windows`.
5. v1 has no placeholders: windows that open later aren't placed. Document this.
6. Tests:
   - the matcher as rows: duplicates, missing apps, title changes;
   - restoring a saved fixture gives the expected `treeDump` (headless).
7. Docs: asciidoc and README, with an example skhd binding.

**Live check:** arrange a space (nested tabs and splits with 4+ windows), save it, scramble it (`space --balance` and
some warps), then restore it: the arrangement returns. Close one app and restore again: the remaining windows fill the
layout without gaps.

**Gate:** quick. **Commit:** `P13.5 Restore a saved space layout onto the current windows`.
