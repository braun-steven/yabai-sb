import CoreGraphics
import Foundation
import CPrivate
import YabaiC

//
// NOTE: Finding windows for the window selectors: by stacking rank on a space, at a point, in a direction,
// in the order of the tree, among the tabs of a tabbed container, and by area. Ported from
// src/window_manager_lookup.c.
//

/// `window_manager_find_window_on_space_by_rank_filtering_window`: the window with the rank (from 1, top first) among the
/// known windows of the space, without filterWid.
func window_manager_find_window_on_space_by_rank_filtering_window(_ wm: UnsafeMutablePointer<window_manager>, _ sid: UInt64, _ rank: Int32, _ filterWid: UInt32) -> Window?
{
    var count: Int32 = 0
    guard let windowList = space_window_list(sid, &count, false) else { return nil }

    var j: Int32 = 0
    for i in 0..<Int(count) {
        if windowList[i] == filterWid { continue }

        guard let target = window_manager_find_window(wm, windowList[i]) else { continue }

        j += 1
        if j == rank { return target }
    }

    return nil
}

//
// NOTE: The window at point, starting below start_wid (order -1) or from the top (start_wid 0, order 1).
// Windows of our own connection (borders, tab bars) are skipped.
//

/// `window_manager_find_window_at_point_from`
private func windowManagerFindWindowAtPointFrom(_ wm: UnsafeMutablePointer<window_manager>, _ point: CGPoint, _ startWid: UInt32, _ order: Int32) -> Window?
{
    var point = point
    var windowPoint = CGPoint.zero
    var windowID: UInt32 = 0
    var windowCid: Int32 = 0

    SLSFindWindowAndOwner(connection_global(), Int32(bitPattern: startWid), order, 0, &point, &windowPoint, &windowID, &windowCid)
    while windowID != 0 && connection_global() == windowCid {
        SLSFindWindowAndOwner(connection_global(), Int32(bitPattern: windowID), -1, 0, &point, &windowPoint, &windowID, &windowCid)
    }

    return window_manager_find_window(wm, windowID)
}

/// `window_manager_find_window_at_point_filtering_window`
func window_manager_find_window_at_point_filtering_window(_ wm: UnsafeMutablePointer<window_manager>, _ point: CGPoint, _ filterWid: UInt32) -> Window?
{
    return windowManagerFindWindowAtPointFrom(wm, point, filterWid, -1)
}

/// `window_manager_find_window_at_point`
func window_manager_find_window_at_point(_ wm: UnsafeMutablePointer<window_manager>, _ point: CGPoint) -> Window?
{
    return windowManagerFindWindowAtPointFrom(wm, point, 0, 1)
}

/// `window_manager_find_window_below_cursor`
func window_manager_find_window_below_cursor(_ wm: UnsafeMutablePointer<window_manager>) -> Window?
{
    return window_manager_find_window_at_point(wm, SLS.cursorLocation(connection_global()))
}

/// `window_manager_find_closest_managed_window_in_direction`
func window_manager_find_closest_managed_window_in_direction(_ wm: UnsafeMutablePointer<window_manager>, _ target: Window, _ direction: Int32) -> Window?
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return nil }
    guard let node = tree_find_window(owner.pointee.tree, target.pointee.id) else { return nil }

    var result: Con?
    if tree_next(node, direction, FOCUS_WRAPPING_OFF, false, &result) != TREE_RESULT_DONE { return nil }
    guard let result, con_is_leaf(result), result != node else { return nil }

    return window_manager_find_window(wm, result.pointee.window_id)
}

/// `window_manager_active_tree_view`
private func windowManagerActiveTreeView(_ sm: UnsafeMutablePointer<space_manager>) -> View?
{
    let owner = spaceManagerFindView(sm, space_manager_active_space())
    return owner.pointee.tree != nil ? owner : nil
}

/// `window_manager_find_window_for_con`
private func windowManagerFindWindowForCon(_ wm: UnsafeMutablePointer<window_manager>, _ node: Con?) -> Window?
{
    guard let node, con_is_leaf(node) else { return nil }
    return window_manager_find_window(wm, node.pointee.window_id)
}

/// The leaf of the window in the tree of the active space.
private func windowManagerActiveCon(_ sm: UnsafeMutablePointer<space_manager>, _ target: Window) -> Con?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }
    return tree_find_window(owner.pointee.tree, target.pointee.id)
}

/// `window_manager_find_prev_managed_window`
func window_manager_find_prev_managed_window(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    guard let node = windowManagerActiveCon(sm, target) else { return nil }
    return windowManagerFindWindowForCon(wm, tree_prev_leaf(node))
}

/// `window_manager_find_next_managed_window`
func window_manager_find_next_managed_window(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    guard let node = windowManagerActiveCon(sm, target) else { return nil }
    return windowManagerFindWindowForCon(wm, tree_next_leaf(node))
}

/// `window_manager_find_first_managed_window`
func window_manager_find_first_managed_window(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>) -> Window?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }
    return windowManagerFindWindowForCon(wm, tree_first_leaf(owner.pointee.tree))
}

/// `window_manager_find_last_managed_window`
func window_manager_find_last_managed_window(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>) -> Window?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }
    return windowManagerFindWindowForCon(wm, tree_last_leaf(owner.pointee.tree))
}

/// `window_manager_find_recent_managed_window`
func window_manager_find_recent_managed_window(_ wm: UnsafeMutablePointer<window_manager>) -> Window?
{
    guard let target = window_manager_find_window(wm, wm.pointee.last_window_id) else { return nil }
    if window_manager_find_managed_window(wm, target) == nil { return nil }

    return target
}

//
// NOTE: The stack.* selectors pick tabs of the closest tabbed container. A tab that holds a
// container resolves to the window focused in it last.
//

/// `window_manager_find_tab`: the tab of the window and its tabbed container.
private func windowManagerFindTab(_ sm: UnsafeMutablePointer<space_manager>, _ target: Window) -> (tab: Con, tabbed: Con)?
{
    guard var node = windowManagerActiveCon(sm, target) else { return nil }
    guard let parent = tree_tabbed_ancestor(node) else { return nil }

    while node.pointee.parent != parent { node = node.pointee.parent }
    return (node, parent)
}

/// `window_manager_find_tab_window`
private func windowManagerFindTabWindow(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window, _ index: Int32, _ relative: Bool) -> Window?
{
    guard let found = windowManagerFindTab(sm, target) else { return nil }
    let (tab, tabbed) = found

    let index = relative ? con_index(tab) + index : index == Int32.max ? tabbed.pointee.child_count - 1 : index
    if index < 0 || index >= tabbed.pointee.child_count { return nil }

    return windowManagerFindWindowForCon(wm, tree_descend_focused(tabbed.pointee.children[Int(index)]))
}

/// `window_manager_find_prev_window_in_stack`
func window_manager_find_prev_window_in_stack(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, -1, true)
}

/// `window_manager_find_next_window_in_stack`
func window_manager_find_next_window_in_stack(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, 1, true)
}

/// `window_manager_find_first_window_in_stack`
func window_manager_find_first_window_in_stack(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, 0, false)
}

/// `window_manager_find_last_window_in_stack`
func window_manager_find_last_window_in_stack(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, Int32.max, false)
}

/// `window_manager_find_recent_window_in_stack`
func window_manager_find_recent_window_in_stack(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window) -> Window?
{
    guard let found = windowManagerFindTab(sm, target), found.tabbed.pointee.child_count >= 2 else { return nil }
    let (tab, tabbed) = found

    let recent = tabbed.pointee.focus[0] == tab ? tabbed.pointee.focus[1] : tabbed.pointee.focus[0]
    return windowManagerFindWindowForCon(wm, tree_descend_focused(recent))
}

/// `window_manager_find_window_in_stack`: the tab at the index (from 1).
func window_manager_find_window_in_stack(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ target: Window, _ index: Int32) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, index - 1, false)
}

/// `window_manager_find_managed_window_by_area`: the visible leaf with the largest area (the first one), or the smallest
/// (the last one).
private func windowManagerFindManagedWindowByArea(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ largest: Bool) -> Window?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }

    var bestID: UInt32 = 0
    var bestArea: Float = largest ? 0 : Float.greatestFiniteMagnitude

    var node = tree_first_leaf(owner.pointee.tree)
    while let leaf = node, con_is_leaf(leaf) {
        if tree_con_is_visible(leaf) {
            let area = leaf.pointee.area.w * leaf.pointee.area.h
            if largest ? area > bestArea : area <= bestArea {
                bestID = leaf.pointee.window_id
                bestArea = area
            }
        }

        node = tree_next_leaf(leaf)
    }

    return bestID != 0 ? window_manager_find_window(wm, bestID) : nil
}

/// `window_manager_find_largest_managed_window`
func window_manager_find_largest_managed_window(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>) -> Window?
{
    return windowManagerFindManagedWindowByArea(sm, wm, true)
}

/// `window_manager_find_smallest_managed_window`
func window_manager_find_smallest_managed_window(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>) -> Window?
{
    return windowManagerFindManagedWindowByArea(sm, wm, false)
}
