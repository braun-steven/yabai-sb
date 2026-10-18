import Foundation
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: i3 navigation in the container tree of a space: focus and move in a direction, into the parent
// or child container, and across displays when a direction leaves the tree. Ported from
// src/window_manager_tree.c.
//

/// `window_manager_tree_display_in_direction`: the display in the direction, unless its space is a fullscreen space.
private func windowManagerTreeDisplayInDirection(_ owner: View, _ direction: Direction) -> UInt32
{
    let did = display_manager_find_closest_display_in_direction(space_display_id(owner.sid), direction)
    if did == 0 || space_is_fullscreen(display_space_id(did)) { return 0 }
    return did
}

//
// NOTE: Focuses the display in the direction like i3 focuses an output: on a tree space the window
// that was focused there last, otherwise whatever macOS focuses on that display.
//

/// `window_manager_tree_focus_display`
private func windowManagerTreeFocusDisplay(_ wm: WindowManager, _ did: UInt32)
{
    let sid = display_space_id(did)
    let owner = space_manager_find_view(space_manager_global(), sid)
    let leaf = owner.layout == .tree && owner.tree != nil ? tree_descend_focused(owner.tree) : nil

    if let leaf, con_is_leaf(leaf) {
        windowManagerFocusWindowID(wm, leaf.window_id)
    } else {
        display_manager_focus_display(did, sid)
    }
}

/// `window_manager_tree_focus_direction`: without a window (no window has focus) it fails like for an unmanaged one.
func window_manager_tree_focus_direction(_ wm: WindowManager, _ target: Window?, _ direction: Direction) -> WindowOperationResult
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }
    guard let node = windowManagerTreeActingCon(owner, target) else { return .invalidSourceNode }

    let did = windowManagerTreeDisplayInDirection(owner, direction)
    var result: Con?

    switch tree_next(node, direction, wm.focus_wrapping, did != 0, &result) {
    case .done:
        guard let result, con_is_leaf(result) else { return .invalidDestinationNode }
        if result.window_id == target.id && con_is_leaf(node) { return .invalidDestinationNode }
        tree_select(owner.tree, nil)
        windowManagerFocusWindowID(wm, result.window_id)
    case .output:
        tree_select(owner.tree, nil)
        windowManagerTreeFocusDisplay(wm, did)
    case .none:
        return .invalidDestinationNode
    }

    return .success
}

/// `window_manager_tree_focus_parent`
func window_manager_tree_focus_parent(_ wm: WindowManager, _ target: Window?) -> WindowOperationResult
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }
    guard let node = windowManagerTreeActingCon(owner, target) else { return .invalidSourceNode }
    guard let parent = node.parent else { return .invalidDestinationNode }

    tree_select(owner.tree, parent)
    if space_is_visible(owner.sid) { tree_selection_show(parent) }

    return .success
}

/// `window_manager_tree_focus_child`
func window_manager_tree_focus_child(_ wm: WindowManager, _ target: Window?) -> WindowOperationResult
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }

    guard let selected = tree_find_selected(owner.tree), selected.child_count != 0 else { return .invalidDestinationNode }

    let child = selected.focus[0]
    if con_is_leaf(child) {
        tree_select(owner.tree, nil)
        windowManagerFocusWindowID(wm, child.window_id)
    } else {
        tree_select(owner.tree, child)
        if space_is_visible(owner.sid) { tree_selection_show(child) }
    }

    return .success
}

//
// NOTE: Moves the container to the space on the display in the direction, like i3 and sway move a
// container to the next output. On a tree space it keeps its structure and arrives on the side it
// comes from (tree_attach_from_direction). On other spaces every window is sent there on its own.
//

/// `window_manager_tree_move_to_display`
private func windowManagerTreeMoveToDisplay(_ sm: SpaceManager, _ wm: WindowManager, _ owner: View, _ node: Con, _ did: UInt32, _ direction: Direction)
{
    tree_select(owner.tree, nil)

    let sid = display_space_id(did)
    let dstView = space_manager_find_view(sm, sid)

    if dstView.layout == .tree {
        let focus = tree_descend_focused(node)

        tree_detach(node)
        tree_flatten(owner.tree)

        if view_is_invalid(dstView) { view_update(dstView) }
        tree_view_attach_from_direction(dstView, node, direction)
        let moved = windowManagerTreeSetView(wm, node, dstView)
        windowManagerTreeWaitForView(moved, dstView)
        tree_flatten(dstView.tree)

        if let focus { tree_focus(focus) }
        windowManagerTreeApply(owner)
        windowManagerTreeApply(dstView)

        if let focus, con_is_leaf(focus) { windowManagerFocusWindowID(wm, focus.window_id) }
        return
    }

    // the C code collected at most 256 windows (a fixed array)
    var windowList: [UInt32] = []

    var leaf = tree_first_leaf(node)
    while let current = leaf, windowList.count < 256 {
        windowList.append(current.window_id)
        if current == tree_last_leaf(node) { break }
        leaf = tree_next_leaf(current)
    }

    for windowID in windowList {
        if let target = window_manager_find_window(wm, windowID) { window_manager_send_window_to_space(sm, wm, target, sid, false) }
    }

    if let focus = windowList.first.flatMap({ window_manager_find_window(wm, $0) }) {
        window_manager_focus_window_with_raise(&focus.application.psn, focus.id, focus.ref)
    }
}

/// `window_manager_tree_move_direction`
func window_manager_tree_move_direction(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ direction: Direction) -> WindowOperationResult
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }
    guard let node = windowManagerTreeActingCon(owner, target) else { return .invalidSourceNode }

    let did = windowManagerTreeDisplayInDirection(owner, direction)

    switch tree_move(owner.tree, node, direction, did != 0) {
    case .done:
        windowManagerTreeApply(owner)
    case .output:
        windowManagerTreeMoveToDisplay(sm, wm, owner, node, did, direction)
    case .none:
        return .invalidDestinationNode
    }

    return .success
}

//
// NOTE: When the focused window of a tree space closes, i3 focuses the window that was focused
// before it in the same container. Computed before the window is taken out of the tree.
//

/// `window_manager_tree_focus_candidate`
func window_manager_tree_focus_candidate(_ wm: WindowManager, _ owner: View?, _ target: Window) -> UInt32
{
    guard let owner, owner.layout == .tree else { return 0 }

    //
    // NOTE: macOS often focuses another window of the application before the window is reported as
    // destroyed. The window then is the previously focused one, and the choice of macOS is replaced.
    // That window can be on another space or display, so a window of the same application counts too.
    //

    var wasFocused = target.id == wm.focused_window_id
    if !wasFocused && target.id == wm.last_window_id {
        if let focused = window_manager_find_window(wm, wm.focused_window_id) {
            wasFocused = focused.application == target.application || window_manager_find_tree_view(wm, focused) == owner
        }
    }

    if !wasFocused { return 0 }

    guard let node = tree_find_window(owner.tree, target.id), let candidate = tree_focus_candidate(node) else { return 0 }
    return con_is_leaf(candidate) ? candidate.window_id : 0
}

/// `window_manager_tree_focus_after_close`
func window_manager_tree_focus_after_close(_ wm: WindowManager, _ owner: View, _ windowID: UInt32)
{
    if windowID == 0 || !space_is_visible(owner.sid) { return }
    windowManagerFocusWindowID(wm, windowID)
}

/// The orientation of `window --split`: a fixed one, or across the orientation of the parent container (`toggle`).
enum SplitOrientation: Equatable, Sendable
{
    case fixed(ConOrientation)
    case toggle
}

/// `window_manager_tree_split`
func window_manager_tree_split(_ wm: WindowManager, _ target: Window?, _ split: SplitOrientation) -> WindowOperationResult
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }
    guard let node = windowManagerTreeActingCon(owner, target) else { return .invalidSourceNode }

    let orientation: ConOrientation
    switch split {
    case .fixed(let fixed):
        orientation = fixed
    case .toggle:
        let parent = node.parent ?? node
        orientation = parent.layout == .splitH ? .vertical : .horizontal
    }

    tree_split(node, orientation)
    windowManagerTreeApply(owner)

    return .success
}
