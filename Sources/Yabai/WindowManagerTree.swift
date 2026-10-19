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
private func windowManagerTreeDisplayInDirection(_ owner: View, _ direction: Direction) -> DisplayID?
{
    guard let sourceDid = space_display_id(owner.sid),
          let did = display_manager_find_closest_display_in_direction(sourceDid, direction) else { return nil }
    if let sid = display_space_id(did), space_is_fullscreen(sid) { return nil }
    return did
}

//
// NOTE: Focuses the display in the direction like i3 focuses an output: on a tree space the window
// that was focused there last, otherwise whatever macOS focuses on that display.
//

/// `window_manager_tree_focus_display`
private func windowManagerTreeFocusDisplay(_ wm: WindowManager, _ did: DisplayID)
{
    let sid = display_space_id(did)
    let owner = sid.map { space_manager_find_view(space_manager_global(), $0) }
    let leaf = owner?.layout == .tree && owner?.tree != nil ? owner?.tree?.focusedDescendant : nil

    if let leaf, leaf.isLeaf {
        windowManagerFocusWindowID(wm, leaf.windowID)
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

    switch node.neighbor(direction, wrapping: wm.focus_wrapping, hasOutput: did != nil) {
    case .focus(let result):
        guard result.isLeaf else { return .invalidDestinationNode }
        if result.windowID == target.id && node.isLeaf { return .invalidDestinationNode }
        owner.tree?.select(nil)
        windowManagerFocusWindowID(wm, result.windowID)
    case .output:
        owner.tree?.select(nil)
        guard let did else { return .invalidDestinationNode }
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

    owner.tree?.select(parent)
    if space_is_visible(owner.sid) { tree_selection_show(parent) }

    return .success
}

/// `window_manager_tree_focus_child`
func window_manager_tree_focus_child(_ wm: WindowManager, _ target: Window?) -> WindowOperationResult
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }

    guard let selected = owner.tree?.findSelected(), selected.children.count != 0 else { return .invalidDestinationNode }

    let child = selected.focusOrder[0]
    if child.isLeaf {
        owner.tree?.select(nil)
        windowManagerFocusWindowID(wm, child.windowID)
    } else {
        owner.tree?.select(child)
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
private func windowManagerTreeMoveToDisplay(_ sm: SpaceManager, _ wm: WindowManager, _ owner: View, _ node: Con, _ did: DisplayID, _ direction: Direction)
{
    owner.tree?.select(nil)

    //
    // NOTE: A display without a current space has no space to move the node to.
    //

    guard let sid = display_space_id(did) else { return }
    let dstView = space_manager_find_view(sm, sid)

    if dstView.layout == .tree {
        let focus = node.focusedDescendant

        node.detach()
        owner.tree!.flatten()

        if view_is_invalid(dstView) { view_update(dstView) }
        tree_view_attach_from_direction(dstView, node, direction)
        let moved = windowManagerTreeSetView(wm, node, dstView)
        windowManagerTreeWaitForView(moved, dstView)
        dstView.tree!.flatten()

        focus.focus()
        windowManagerTreeApply(owner)
        windowManagerTreeApply(dstView)

        if focus.isLeaf { windowManagerFocusWindowID(wm, focus.windowID) }
        return
    }

    // the C code collected at most 256 windows (a fixed array)
    var windowList: [WindowID?] = []

    var leaf = node.firstLeaf
    while let current = leaf, windowList.count < 256 {
        windowList.append(current.windowID)
        if current == node.lastLeaf { break }
        leaf = current.nextLeaf
    }

    for windowID in windowList {
        if let windowID, let target = window_manager_find_window(wm, windowID) { window_manager_send_window_to_space(sm, wm, target, sid, false) }
    }

    if let focus = (windowList.first ?? nil).flatMap({ window_manager_find_window(wm, $0) }) {
        window_manager_focus_window_with_raise(&focus.application.psn, focus.id, focus.ref)
    }
}

/// `window_manager_tree_move_direction`
func window_manager_tree_move_direction(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ direction: Direction) -> WindowOperationResult
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return .invalidSourceView }
    guard let node = windowManagerTreeActingCon(owner, target) else { return .invalidSourceNode }

    let did = windowManagerTreeDisplayInDirection(owner, direction)

    switch node.move(direction, in: owner.tree!, hasOutput: did != nil) {
    case .done:
        windowManagerTreeApply(owner)
    case .output:
        guard let did else { return .invalidDestinationNode }
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
func window_manager_tree_focus_candidate(_ wm: WindowManager, _ owner: View?, _ target: Window) -> WindowID?
{
    guard let owner, owner.layout == .tree else { return nil }

    //
    // NOTE: macOS often focuses another window of the application before the window is reported as
    // destroyed. The window then is the previously focused one, and the choice of macOS is replaced.
    // That window can be on another space or display, so a window of the same application counts too.
    //

    var wasFocused = target.id == wm.focused_window_id
    if !wasFocused && target.id == wm.last_window_id {
        if let focusedID = wm.focused_window_id, let focused = window_manager_find_window(wm, focusedID) {
            wasFocused = focused.application == target.application || window_manager_find_tree_view(wm, focused) == owner
        }
    }

    if !wasFocused { return nil }

    guard let node = owner.tree?.find(target.id), let candidate = node.focusCandidate else { return nil }
    return candidate.isLeaf ? candidate.windowID : nil
}

/// `window_manager_tree_focus_after_close`: nothing without a candidate.
func window_manager_tree_focus_after_close(_ wm: WindowManager, _ owner: View, _ windowID: WindowID?)
{
    guard let windowID, space_is_visible(owner.sid) else { return }
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

    node.split(orientation)
    windowManagerTreeApply(owner)

    return .success
}
