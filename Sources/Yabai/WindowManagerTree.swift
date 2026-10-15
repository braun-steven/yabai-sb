import Foundation
import AppKit
import CPrivate

//
// NOTE: i3 navigation in the container tree of a space: focus and move in a direction, into the parent
// or child container, and across displays when a direction leaves the tree. Ported from
// src/window_manager_tree.c.
//

/// `window_manager_tree_display_in_direction`: the display in the direction, unless its space is a fullscreen space.
private func windowManagerTreeDisplayInDirection(_ owner: View, _ direction: Int32) -> UInt32
{
    let did = display_manager_find_closest_display_in_direction(space_display_id(owner.pointee.sid), direction)
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
    let leaf = owner.pointee.layout == VIEW_TREE && owner.pointee.tree != nil ? tree_descend_focused(owner.pointee.tree) : nil

    if let leaf, con_is_leaf(leaf) {
        windowManagerFocusWindowID(wm, leaf.pointee.window_id)
    } else {
        display_manager_focus_display(did, sid)
    }
}

/// `window_manager_tree_focus_direction`: without a window (no window has focus) it fails like for an unmanaged one.
func window_manager_tree_focus_direction(_ wm: WindowManager, _ target: Window?, _ direction: Int32) -> window_op_error
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let node = windowManagerTreeActingCon(owner, target) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    let did = windowManagerTreeDisplayInDirection(owner, direction)
    var result: Con?

    switch tree_next(node, direction, wm.focus_wrapping, did != 0, &result) {
    case TREE_RESULT_DONE:
        guard let result, con_is_leaf(result) else { return WINDOW_OP_ERROR_INVALID_DST_NODE }
        if result.pointee.window_id == target.pointee.id && con_is_leaf(node) { return WINDOW_OP_ERROR_INVALID_DST_NODE }
        tree_select(owner.pointee.tree, nil)
        windowManagerFocusWindowID(wm, result.pointee.window_id)
    case TREE_RESULT_OUTPUT:
        tree_select(owner.pointee.tree, nil)
        windowManagerTreeFocusDisplay(wm, did)
    case TREE_RESULT_NONE:
        return WINDOW_OP_ERROR_INVALID_DST_NODE
    default:
        break
    }

    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_tree_focus_parent`
func window_manager_tree_focus_parent(_ wm: WindowManager, _ target: Window?) -> window_op_error
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let node = windowManagerTreeActingCon(owner, target) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }
    guard let parent = node.pointee.parent else { return WINDOW_OP_ERROR_INVALID_DST_NODE }

    tree_select(owner.pointee.tree, parent)
    if space_is_visible(owner.pointee.sid) { tree_selection_show(parent) }

    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_tree_focus_child`
func window_manager_tree_focus_child(_ wm: WindowManager, _ target: Window?) -> window_op_error
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    guard let selected = tree_find_selected(owner.pointee.tree), selected.pointee.child_count != 0 else { return WINDOW_OP_ERROR_INVALID_DST_NODE }

    let child = selected.focus[0]
    if con_is_leaf(child) {
        tree_select(owner.pointee.tree, nil)
        windowManagerFocusWindowID(wm, child.pointee.window_id)
    } else {
        tree_select(owner.pointee.tree, child)
        if space_is_visible(owner.pointee.sid) { tree_selection_show(child) }
    }

    return WINDOW_OP_ERROR_SUCCESS
}

//
// NOTE: Moves the container to the space on the display in the direction, like i3 and sway move a
// container to the next output. On a tree space it keeps its structure and arrives on the side it
// comes from (tree_attach_from_direction). On other spaces every window is sent there on its own.
//

/// `window_manager_tree_move_to_display`
private func windowManagerTreeMoveToDisplay(_ sm: SpaceManager, _ wm: WindowManager, _ owner: View, _ node: Con, _ did: UInt32, _ direction: Int32)
{
    tree_select(owner.pointee.tree, nil)

    let sid = display_space_id(did)
    let dstView = space_manager_find_view(sm, sid)

    if dstView.pointee.layout == VIEW_TREE {
        let focus = tree_descend_focused(node)

        tree_detach(node)
        tree_flatten(owner.pointee.tree)

        if view_is_invalid(dstView) { view_update(dstView) }
        tree_view_attach_from_direction(dstView, node, direction)
        let moved = windowManagerTreeSetView(wm, node, dstView)
        windowManagerTreeWaitForView(moved, dstView)
        tree_flatten(dstView.pointee.tree)

        if let focus { tree_focus(focus) }
        windowManagerTreeApply(owner)
        windowManagerTreeApply(dstView)

        if let focus, con_is_leaf(focus) { windowManagerFocusWindowID(wm, focus.pointee.window_id) }
        return
    }

    // the C code collected at most 256 windows (a fixed array)
    var windowList: [UInt32] = []

    var leaf = tree_first_leaf(node)
    while let current = leaf, windowList.count < 256 {
        windowList.append(current.pointee.window_id)
        if current == tree_last_leaf(node) { break }
        leaf = tree_next_leaf(current)
    }

    for windowID in windowList {
        if let target = window_manager_find_window(wm, windowID) { window_manager_send_window_to_space(sm, wm, target, sid, false) }
    }

    if let focus = windowList.first.flatMap({ window_manager_find_window(wm, $0) }) {
        window_manager_focus_window_with_raise(&focus.pointee.application.pointee.psn, focus.pointee.id, focus.pointee.ref)
    }
}

/// `window_manager_tree_move_direction`
func window_manager_tree_move_direction(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ direction: Int32) -> window_op_error
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let node = windowManagerTreeActingCon(owner, target) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    let did = windowManagerTreeDisplayInDirection(owner, direction)

    switch tree_move(owner.pointee.tree, node, direction, did != 0) {
    case TREE_RESULT_DONE:
        windowManagerTreeApply(owner)
    case TREE_RESULT_OUTPUT:
        windowManagerTreeMoveToDisplay(sm, wm, owner, node, did, direction)
    case TREE_RESULT_NONE:
        return WINDOW_OP_ERROR_INVALID_DST_NODE
    default:
        break
    }

    return WINDOW_OP_ERROR_SUCCESS
}

//
// NOTE: When the focused window of a tree space closes, i3 focuses the window that was focused
// before it in the same container. Computed before the window is taken out of the tree.
//

/// `window_manager_tree_focus_candidate`
func window_manager_tree_focus_candidate(_ wm: WindowManager, _ owner: View?, _ target: Window) -> UInt32
{
    guard let owner, owner.pointee.layout == VIEW_TREE else { return 0 }

    //
    // NOTE: macOS often focuses another window of the application before the window is reported as
    // destroyed. The window then is the previously focused one, and the choice of macOS is replaced.
    // That window can be on another space or display, so a window of the same application counts too.
    //

    var wasFocused = target.pointee.id == wm.focused_window_id
    if !wasFocused && target.pointee.id == wm.last_window_id {
        if let focused = window_manager_find_window(wm, wm.focused_window_id) {
            wasFocused = focused.pointee.application == target.pointee.application || window_manager_find_tree_view(wm, focused) == owner
        }
    }

    if !wasFocused { return 0 }

    guard let node = tree_find_window(owner.pointee.tree, target.pointee.id), let candidate = tree_focus_candidate(node) else { return 0 }
    return con_is_leaf(candidate) ? candidate.pointee.window_id : 0
}

/// `window_manager_tree_focus_after_close`
func window_manager_tree_focus_after_close(_ wm: WindowManager, _ owner: View, _ windowID: UInt32)
{
    if windowID == 0 || !space_is_visible(owner.pointee.sid) { return }
    windowManagerFocusWindowID(wm, windowID)
}

/// `window_manager_tree_split`: orientation -1 splits across the orientation of the parent.
func window_manager_tree_split(_ wm: WindowManager, _ target: Window?, _ orientation: Int32) -> window_op_error
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let node = windowManagerTreeActingCon(owner, target) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    var orientation = orientation
    if orientation < 0 {
        let parent = node.pointee.parent ?? node
        orientation = Int32(parent.pointee.layout == CON_SPLITH ? CON_VERTICAL.rawValue : CON_HORIZONTAL.rawValue)
    }

    tree_split(node, ConOrientation(rawValue: UInt32(orientation)))
    windowManagerTreeApply(owner)

    return WINDOW_OP_ERROR_SUCCESS
}
