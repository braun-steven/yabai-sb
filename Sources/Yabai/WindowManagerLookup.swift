import CoreGraphics
import Foundation
import CPrivate
import AppKit
import YabaiCore

//
// NOTE: Finding windows for the window selectors: by stacking rank on a space, at a point, in a direction,
// in the order of the tree, among the tabs of a tabbed container, and by area. Ported from
// src/window_manager_lookup.c.
//

/// `window_manager_find_window_on_space_by_rank_filtering_window`: the window with the rank (from 1, top first) among the
/// known windows of the space, without filterWid.
func window_manager_find_window_on_space_by_rank_filtering_window(_ wm: WindowManager, _ sid: SpaceID, _ rank: Int, _ filterWid: WindowID?) -> Window?
{
    guard let windowList = space_window_list(sid, false) else { return nil }

    var j = 0
    for wid in windowList {
        if wid == filterWid { continue }

        guard let target = window_manager_find_window(wm, wid) else { continue }

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
private func windowManagerFindWindowAtPointFrom(_ wm: WindowManager, _ point: CGPoint, _ startWid: WindowID?, _ order: Int32) -> Window?
{
    var point = point
    var windowPoint = CGPoint.zero
    var windowID: UInt32 = 0
    var windowCid: Int32 = 0

    SLSFindWindowAndOwner(connection_global(), Int32(bitPattern: startWid?.rawValue ?? 0), order, 0, &point, &windowPoint, &windowID, &windowCid)
    while windowID != 0 && connection_global() == windowCid {
        SLSFindWindowAndOwner(connection_global(), Int32(bitPattern: windowID), -1, 0, &point, &windowPoint, &windowID, &windowCid)
    }

    guard let foundID = WindowID(nonzero: windowID) else { return nil }
    return window_manager_find_window(wm, foundID)
}

/// `window_manager_find_window_at_point_filtering_window`
func window_manager_find_window_at_point_filtering_window(_ wm: WindowManager, _ point: CGPoint, _ filterWid: WindowID) -> Window?
{
    return windowManagerFindWindowAtPointFrom(wm, point, filterWid, -1)
}

/// `window_manager_find_window_at_point`
func window_manager_find_window_at_point(_ wm: WindowManager, _ point: CGPoint) -> Window?
{
    return windowManagerFindWindowAtPointFrom(wm, point, nil, 1)
}

/// `window_manager_find_window_below_cursor`
func window_manager_find_window_below_cursor(_ wm: WindowManager) -> Window?
{
    return window_manager_find_window_at_point(wm, SLS.cursorLocation(connection_global()))
}

/// `window_manager_find_closest_managed_window_in_direction`
func window_manager_find_closest_managed_window_in_direction(_ wm: WindowManager, _ target: Window, _ direction: Direction) -> Window?
{
    guard let owner = wm.treeView(for: target) else { return nil }
    guard let node = owner.tree?.find(target.id) else { return nil }

    guard let result = node.neighbor(direction, wrapping: .off, hasOutput: false).target else { return nil }
    guard result.isLeaf, result != node else { return nil }

    return result.windowID.flatMap { window_manager_find_window(wm, $0) }
}

/// `window_manager_active_tree_view`
private func windowManagerActiveTreeView(_ sm: SpaceManager) -> View?
{
    guard let sid = space_manager_active_space() else { return nil }
    let owner = space_manager_find_view(sm, sid)
    return owner.tree != nil ? owner : nil
}

/// `window_manager_find_window_for_con`
private func windowManagerFindWindowForCon(_ wm: WindowManager, _ node: Con?) -> Window?
{
    guard let node, node.isLeaf, let wid = node.windowID else { return nil }
    return window_manager_find_window(wm, wid)
}

/// The leaf of the window in the tree of the active space.
private func windowManagerActiveCon(_ sm: SpaceManager, _ target: Window) -> Con?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }
    return owner.tree?.find(target.id)
}

/// `window_manager_find_prev_managed_window`
func window_manager_find_prev_managed_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    guard let node = windowManagerActiveCon(sm, target) else { return nil }
    return windowManagerFindWindowForCon(wm, node.previousLeaf)
}

/// `window_manager_find_next_managed_window`
func window_manager_find_next_managed_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    guard let node = windowManagerActiveCon(sm, target) else { return nil }
    return windowManagerFindWindowForCon(wm, node.nextLeaf)
}

/// `window_manager_find_first_managed_window`
func window_manager_find_first_managed_window(_ sm: SpaceManager, _ wm: WindowManager) -> Window?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }
    return windowManagerFindWindowForCon(wm, owner.tree?.firstLeaf)
}

/// `window_manager_find_last_managed_window`
func window_manager_find_last_managed_window(_ sm: SpaceManager, _ wm: WindowManager) -> Window?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }
    return windowManagerFindWindowForCon(wm, owner.tree?.lastLeaf)
}

/// `window_manager_find_recent_managed_window`
func window_manager_find_recent_managed_window(_ wm: WindowManager) -> Window?
{
    guard let lastWindowID = wm.last_window_id, let target = window_manager_find_window(wm, lastWindowID) else { return nil }
    if wm.managedView(for: target) == nil { return nil }

    return target
}

//
// NOTE: The stack.* selectors pick tabs of the closest tabbed container. A tab that holds a
// container resolves to the window focused in it last.
//

/// `window_manager_find_tab`: the tab of the window and its tabbed container.
private func windowManagerFindTab(_ sm: SpaceManager, _ target: Window) -> (tab: Con, tabbed: Con)?
{
    guard var node = windowManagerActiveCon(sm, target) else { return nil }
    guard let parent = node.tabbedAncestor else { return nil }

    while node.parent != parent { node = node.parent! }
    return (node, parent)
}

/// A tab of the tabbed container around a window.
private enum TabPosition
{
    /// The tab at an offset from the tab of the window.
    case offset(Int)
    /// The tab at an index (from 0).
    case index(Int)
    case last
}

/// `window_manager_find_tab_window`
private func windowManagerFindTabWindow(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ position: TabPosition) -> Window?
{
    guard let found = windowManagerFindTab(sm, target) else { return nil }
    let (tab, tabbed) = found

    let index = switch position {
    case .offset(let offset): tab.index! + offset
    case .index(let index):   index
    case .last:               tabbed.children.count - 1
    }
    if index < 0 || index >= tabbed.children.count { return nil }

    return windowManagerFindWindowForCon(wm, tabbed.children[index].focusedDescendant)
}

/// `window_manager_find_prev_window_in_stack`
func window_manager_find_prev_window_in_stack(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, .offset(-1))
}

/// `window_manager_find_next_window_in_stack`
func window_manager_find_next_window_in_stack(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, .offset(1))
}

/// `window_manager_find_first_window_in_stack`
func window_manager_find_first_window_in_stack(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, .index(0))
}

/// `window_manager_find_last_window_in_stack`
func window_manager_find_last_window_in_stack(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, .last)
}

/// `window_manager_find_recent_window_in_stack`
func window_manager_find_recent_window_in_stack(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window) -> Window?
{
    guard let found = windowManagerFindTab(sm, target), found.tabbed.children.count >= 2 else { return nil }
    let (tab, tabbed) = found

    let recent = tabbed.focusOrder[0] == tab ? tabbed.focusOrder[1] : tabbed.focusOrder[0]
    return windowManagerFindWindowForCon(wm, recent.focusedDescendant)
}

/// `window_manager_find_window_in_stack`: the tab at the index (from 1).
func window_manager_find_window_in_stack(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ index: Int) -> Window?
{
    return windowManagerFindTabWindow(sm, wm, target, .index(index - 1))
}

/// `window_manager_find_managed_window_by_area`: the visible leaf with the largest area (the first one), or the smallest
/// (the last one).
private func windowManagerFindManagedWindowByArea(_ sm: SpaceManager, _ wm: WindowManager, _ largest: Bool) -> Window?
{
    guard let owner = windowManagerActiveTreeView(sm) else { return nil }

    var bestID: WindowID?
    var bestArea: Float = largest ? 0 : Float.greatestFiniteMagnitude

    var node = owner.tree?.firstLeaf
    while let leaf = node, leaf.isLeaf {
        if leaf.isVisible {
            let area = leaf.area.w * leaf.area.h
            if largest ? area > bestArea : area <= bestArea {
                bestID = leaf.windowID
                bestArea = area
            }
        }

        node = leaf.nextLeaf
    }

    return bestID.flatMap { window_manager_find_window(wm, $0) }
}

/// `window_manager_find_largest_managed_window`
func window_manager_find_largest_managed_window(_ sm: SpaceManager, _ wm: WindowManager) -> Window?
{
    return windowManagerFindManagedWindowByArea(sm, wm, true)
}

/// `window_manager_find_smallest_managed_window`
func window_manager_find_smallest_managed_window(_ sm: SpaceManager, _ wm: WindowManager) -> Window?
{
    return windowManagerFindManagedWindowByArea(sm, wm, false)
}
