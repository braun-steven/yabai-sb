import ApplicationServices
import CoreGraphics
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: The spaces of yabai: the views of every space (a table from the space id to its view), the layout and padding
// commands for spaces, the focus and moves of spaces through the scripting addition, and the moves of windows between
// spaces. Ported from src/space_manager.c.
//

/// `struct space_manager`
final class SpaceManager
{
    var view = Table<UInt64, View>(capacity: 23)
    var current_space_id: UInt64 = 0
    var last_space_id: UInt64 = 0
    var did_begin = false
    var layout = VIEW_DEFAULT
    var top_padding: Int32 = 0
    var bottom_padding: Int32 = 0
    var left_padding: Int32 = 0
    var right_padding: Int32 = 0
    var window_gap: Int32 = 0
    var auto_padding = false
    var tree_default_orientation = TREE_ORIENTATION_AUTO
    var tree_workspace_tabbed = false
    var tree_autotiling = false
    var labels: OpaquePointer?
    var skip_window_focus_animation = false
    var space_layout = (YabaiC.space_layout(), YabaiC.space_layout(), YabaiC.space_layout(), YabaiC.space_layout(),
                        YabaiC.space_layout(), YabaiC.space_layout(), YabaiC.space_layout(), YabaiC.space_layout())
    var space_layout_count: Int32 = 0
    var space_layout_spec: UnsafeMutablePointer<CChar>?
    var space_layout_gen: UInt32 = 0
    var space_layout_passes: Int32 = 0
}

/// `g_space_manager` (see the NOTE of g_display_manager)
nonisolated(unsafe) let g_space_manager = SpaceManager()

func space_manager_global() -> SpaceManager
{
    g_space_manager
}

/// `space_manager_spacing`: the padding or gap of the space manager that flag names.
func space_manager_spacing(_ flag: view_flag) -> ReferenceWritableKeyPath<SpaceManager, Int32>
{
    switch flag {
    case VIEW_TOP_PADDING:    \.top_padding
    case VIEW_BOTTOM_PADDING: \.bottom_padding
    case VIEW_LEFT_PADDING:   \.left_padding
    case VIEW_RIGHT_PADDING:  \.right_padding
    case VIEW_WINDOW_GAP:     \.window_gap
    default:                  preconditionFailure("space_manager_spacing: \(flag.rawValue) is not a spacing")
    }
}

/// `add_and_clamp_to_zero`
private func addAndClampToZero(_ a: Int32, _ b: Int32) -> Int32
{
    return a + b <= 0 ? 0 : a + b
}

/// `space_manager_query_view`
func space_manager_query_view(_ sm: SpaceManager, _ sid: UInt64) -> View?
{
    if sm.did_begin { return space_manager_find_view(sm, sid) }

    return sm.view.find(sid)
}

/// `space_manager_find_view`: the view of a space; it is created when the space is new.
@discardableResult
func space_manager_find_view(_ sm: SpaceManager, _ sid: UInt64) -> View
{
    if let found = sm.view.find(sid) { return found }

    let created = viewCreate(sid)
    sm.view.add(sid, created)
    return created
}

/// `space_manager_refresh_view`
func space_manager_refresh_view(_ sm: SpaceManager, _ sid: UInt64)
{
    let target = space_manager_find_view(sm, sid)
    if target.pointee.layout == VIEW_FLOAT { return }

    view_update_and_flush(target)
}

/// `space_manager_mark_view_invalid`
func space_manager_mark_view_invalid(_ sm: SpaceManager, _ sid: UInt64)
{
    let target = space_manager_find_view(sm, sid)
    if target.pointee.layout == VIEW_FLOAT { return }

    clearViewFlag(target, VIEW_IS_VALID)
}

/// `space_manager_untile_window`
func space_manager_untile_window(_ target: View, _ win: Window)
{
    if target.pointee.layout == VIEW_FLOAT { return }

    window_manager_adjust_layer(win, CGWindowLevelKey.normalWindow.rawValue)
    if view_remove_window(target, win) { view_flush(target) }
}

/// `space_manager_set_layout_for_space`
func space_manager_set_layout_for_space(_ sm: SpaceManager, _ sid: UInt64, _ layout: view_type)
{
    let target = space_manager_find_view(sm, sid)
    target.pointee.layout = layout
    view_clear(target)

    if target.pointee.layout != VIEW_FLOAT {
        window_manager_validate_and_check_for_windows_on_space(sm, window_manager_global(), sid)
    }
}

/// `space_manager_set_gap_for_space`
func space_manager_set_gap_for_space(_ sm: SpaceManager, _ sid: UInt64, _ type: Int32, _ gap: Int32) -> Bool
{
    let target = space_manager_find_view(sm, sid)
    if target.pointee.layout == VIEW_FLOAT { return false }

    if type == TYPE_ABS {
        target.pointee.window_gap = gap
    } else if type == TYPE_REL {
        target.pointee.window_gap = addAndClampToZero(target.pointee.window_gap, gap)
    }

    view_update_and_flush(target)

    return true
}

/// `space_manager_toggle_view_flag`
private func spaceManagerToggleViewFlag(_ sm: SpaceManager, _ sid: UInt64, _ flag: view_flag) -> Bool
{
    let target = space_manager_find_view(sm, sid)
    if target.pointee.layout == VIEW_FLOAT { return false }

    if hasViewFlag(target, flag) {
        clearViewFlag(target, flag)
    } else {
        setViewFlag(target, flag)
    }

    view_update_and_flush(target)

    return true
}

/// `space_manager_toggle_gap_for_space`
func space_manager_toggle_gap_for_space(_ sm: SpaceManager, _ sid: UInt64) -> Bool
{
    return spaceManagerToggleViewFlag(sm, sid, VIEW_ENABLE_GAP)
}

/// `space_manager_toggle_mission_control`
func space_manager_toggle_mission_control(_ sid: UInt64)
{
    _ = space_manager_focus_space(sid)
    CoreDock.sendNotification("com.apple.expose.awake")
}

/// `space_manager_toggle_show_desktop`
func space_manager_toggle_show_desktop(_ sid: UInt64)
{
    _ = space_manager_focus_space(sid)
    CoreDock.sendNotification("com.apple.showdesktop.awake")
}

/// `space_manager_set_layout_for_all_spaces`: the views without their own layout take the layout.
func space_manager_set_layout_for_all_spaces(_ sm: SpaceManager, _ layout: view_type)
{
    sm.layout = layout

    for target in sm.view.values {
        if !hasViewFlag(target, VIEW_LAYOUT) {
            if space_is_user(target.pointee.sid) {
                target.pointee.layout = layout
                view_clear(target)

                if target.pointee.layout != VIEW_FLOAT {
                    window_manager_validate_and_check_for_windows_on_space(sm, window_manager_global(), target.pointee.sid)
                }
            }
        }
    }
}

/// `space_manager_set_spacing_for_all_spaces`
func space_manager_set_spacing_for_all_spaces(_ sm: SpaceManager, _ flag: view_flag, _ value: Int32)
{
    sm[keyPath: space_manager_spacing(flag)] = value

    for target in sm.view.values {
        if !hasViewFlag(target, flag) {
            view_spacing(target, flag).pointee = value
            view_update_and_flush(target)
        }
    }
}

/// `space_manager_apply_auto_padding`
private func spaceManagerApplyAutoPadding(_ target: View, _ autoPadding: Bool)
{
    if target.pointee.auto_padding == autoPadding { return }

    target.pointee.auto_padding = autoPadding
    if target.pointee.layout == VIEW_FLOAT { return }

    view_update_and_flush(target)
}

/// `space_manager_set_auto_padding_for_all_spaces`
func space_manager_set_auto_padding_for_all_spaces(_ sm: SpaceManager, _ autoPadding: Bool)
{
    sm.auto_padding = autoPadding

    for target in sm.view.values {
        if !hasViewFlag(target, VIEW_AUTO_PADDING) {
            spaceManagerApplyAutoPadding(target, autoPadding)
        }
    }
}

/// `space_manager_set_auto_padding_for_space`
func space_manager_set_auto_padding_for_space(_ sm: SpaceManager, _ sid: UInt64, _ autoPadding: Bool)
{
    let target = space_manager_find_view(sm, sid)
    setViewFlag(target, VIEW_AUTO_PADDING)
    spaceManagerApplyAutoPadding(target, autoPadding)
}

/// `space_manager_set_padding_for_space`
func space_manager_set_padding_for_space(_ sm: SpaceManager, _ sid: UInt64, _ type: Int32, _ top: Int32, _ bottom: Int32, _ left: Int32, _ right: Int32) -> Bool
{
    let target = space_manager_find_view(sm, sid)
    if target.pointee.layout == VIEW_FLOAT { return false }

    if type == TYPE_ABS {
        target.pointee.top_padding    = top
        target.pointee.bottom_padding = bottom
        target.pointee.left_padding   = left
        target.pointee.right_padding  = right
    } else if type == TYPE_REL {
        target.pointee.top_padding    = addAndClampToZero(target.pointee.top_padding, top)
        target.pointee.bottom_padding = addAndClampToZero(target.pointee.bottom_padding, bottom)
        target.pointee.left_padding   = addAndClampToZero(target.pointee.left_padding, left)
        target.pointee.right_padding  = addAndClampToZero(target.pointee.right_padding, right)
    }

    view_update_and_flush(target)

    return true
}

/// `space_manager_toggle_padding_for_space`
func space_manager_toggle_padding_for_space(_ sm: SpaceManager, _ sid: UInt64) -> Bool
{
    return spaceManagerToggleViewFlag(sm, sid, VIEW_ENABLE_PADDING)
}

/// `space_manager_find_tree_view`: the view of a space when it is a tree with a root.
private func spaceManagerFindTreeView(_ sm: SpaceManager, _ sid: UInt64) -> View?
{
    let target = space_manager_find_view(sm, sid)
    return target.pointee.layout == VIEW_TREE && target.pointee.tree != nil ? target : nil
}

/// `space_manager_rotate_space`
func space_manager_rotate_space(_ sm: SpaceManager, _ sid: UInt64, _ degrees: Int32) -> Bool
{
    guard let target = spaceManagerFindTreeView(sm, sid) else { return false }

    tree_rotate(target.pointee.tree, degrees)
    view_update_and_flush(target)

    return true
}

/// `space_manager_mirror_space`
func space_manager_mirror_space(_ sm: SpaceManager, _ sid: UInt64, _ axis: window_split) -> Bool
{
    guard let target = spaceManagerFindTreeView(sm, sid) else { return false }

    tree_mirror(target.pointee.tree, axis == SPLIT_X ? CON_VERTICAL : CON_HORIZONTAL)
    view_update_and_flush(target)

    return true
}

/// `space_manager_balance_space`
func space_manager_balance_space(_ sm: SpaceManager, _ sid: UInt64) -> Bool
{
    guard let target = spaceManagerFindTreeView(sm, sid) else { return false }

    tree_balance(target.pointee.tree)
    view_update_and_flush(target)

    return true
}

/// `space_manager_tile_window_on_space_with_insertion_point`
func space_manager_tile_window_on_space_with_insertion_point(_ sm: SpaceManager, _ win: Window, _ sid: UInt64, _ insertionPoint: UInt32) -> View
{
    let target = space_manager_find_view(sm, sid)
    if target.pointee.layout == VIEW_FLOAT { return target }

    window_manager_adjust_layer(win, CGWindowLevelKey.backstopMenu.rawValue)
    view_add_window(target, win, insertionPoint)
    view_flush(target)

    return target
}

/// `space_manager_tile_window_on_space`
func space_manager_tile_window_on_space(_ sm: SpaceManager, _ win: Window, _ sid: UInt64) -> View
{
    return space_manager_tile_window_on_space_with_insertion_point(sm, win, sid, 0)
}

/// `space_manager_toggle_window_split`
func space_manager_toggle_window_split(_ sm: SpaceManager, _ win: Window)
{
    let target = space_manager_find_view(sm, window_space(win.pointee.id))
    if target.pointee.layout != VIEW_TREE { return }

    _ = window_manager_set_window_layout(window_manager_global(), win, WINDOW_LAYOUT_TOGGLE_SPLIT)
}

//
// NOTE: Every space in the order Mission Control numbers them, display by display. The list lives in
// temporary storage.
//

/// Every space in the order Mission Control numbers them.
func missionControlSpaces() -> [UInt64]
{
    var result: [UInt64] = []

    for display in display_manager_copy_managed_display_spaces() {
        guard let spaces = display["Spaces"] as? [NSDictionary] else { continue }

        for space in spaces {
            result.append((space["id64"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    return result
}

/// `space_manager_mission_control_space_list`, in temporary storage; count gets the number of spaces.
func space_manager_mission_control_space_list(_ count: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<UInt64>?
{
    count.pointee = 0

    let spaces = missionControlSpaces()
    if spaces.isEmpty { return nil }

    count.pointee = Int32(spaces.count)
    return temporaryList(spaces)
}

/// `space_manager_mission_control_index`: the Mission Control number of a space, or 0.
func space_manager_mission_control_index(_ sid: UInt64) -> Int32
{
    return Int32((SpaceList.indexOf(spaces: missionControlSpaces(), sid: sid) ?? -1) + 1)
}

/// `space_manager_mission_control_space`: the space with a Mission Control number, or 0.
func space_manager_mission_control_space(_ desktopID: Int32) -> UInt64
{
    let spaces = missionControlSpaces()
    guard desktopID >= 1 && Int(desktopID) <= spaces.count else { return 0 }

    return spaces[Int(desktopID) - 1]
}

/// `space_manager_cursor_space`
func space_manager_cursor_space() -> UInt64
{
    return display_space_id(display_manager_cursor_display_id())
}

/// `space_manager_prev_space`
func space_manager_prev_space(_ sid: UInt64) -> UInt64
{
    return SpaceList.neighbour(spaces: missionControlSpaces(), sid: sid, offset: -1)
}

/// `space_manager_next_space`
func space_manager_next_space(_ sid: UInt64) -> UInt64
{
    return SpaceList.neighbour(spaces: missionControlSpaces(), sid: sid, offset: 1)
}

/// `space_manager_first_space`
func space_manager_first_space() -> UInt64
{
    return missionControlSpaces().first ?? 0
}

/// `space_manager_last_space`
func space_manager_last_space() -> UInt64
{
    return missionControlSpaces().last ?? 0
}

//
// NOTE: Asking the frontmost application for its focused window is an accessibility round trip, which
// blocks for up to the accessibility timeout when the application does not respond. When the front
// process still owns the window that last received focus, and no focus change has been reported since,
// that window is still the focused one and the question can be skipped. The display and space of the
// window are always looked up again.
//

/// `space_manager_can_use_known_focus`
func space_manager_can_use_known_focus(_ front: UnsafeMutablePointer<ProcessSerialNumber>, _ wm: WindowManager, _ pendingFocus: Bool) -> Bool
{
    if pendingFocus { return false }
    if wm.focused_window_id == 0 { return false }

    return psn_equals(front, &wm.focused_window_psn)
}

/// `space_manager_focused_window`
private func spaceManagerFocusedWindow() -> Window?
{
    var front = SLS.frontProcess()

    let wm = window_manager_global()
    let pendingFocus = pending_window_focus()

    if space_manager_can_use_known_focus(&front, wm, pendingFocus) {
        if let target = window_manager_find_window(wm, wm.focused_window_id) { return target }
    }

    return window_manager_focused_window(wm)
}

/// `space_manager_active_space`: the space of the focused window, or of the active display.
func space_manager_active_space() -> UInt64
{
    var did: UInt32 = 0
    let focused = spaceManagerFocusedWindow()

    if let focused { did = window_display_id(focused.pointee.id) }
    if did == 0 { did = display_manager_active_display_id() }
    if did == 0 { return 0 }

    return display_space_id(did)
}

/// The windows of a space, as `space_window_list` lists them.
private func spaceWindowIDs(_ sid: UInt64) -> [UInt32]
{
    var count: Int32 = 0
    guard let list = space_window_list(sid, &count, true) else { return [] }

    return Array(UnsafeBufferPointer(start: list, count: Int(count)))
}

/// `space_manager_move_window_list_to_space`
func space_manager_move_window_list_to_space(_ sid: UInt64, _ windowList: UnsafeMutablePointer<UInt32>, _ windowCount: Int32)
{
    var windows = Array(UnsafeBufferPointer(start: windowList, count: Int(windowCount)))

    if SLS.hasBridgedWindowOperation {
        SLS.bridgedMoveWindows(windows, toSpace: sid)
    } else if !scripting_addition_move_window_list_to_space(sid, &windows, Int32(windows.count)) {
        SLSSpaceSetCompatID(connection_global(), sid, 0x79616265)
        SLSSetWindowListWorkspace(connection_global(), &windows, Int32(windows.count), 0x79616265)
        SLSSpaceSetCompatID(connection_global(), sid, 0x0)
    }
}

/// Moves a list of windows to a space, as `space_manager_move_window_list_to_space` does.
private func moveWindows(_ windows: [UInt32], to sid: UInt64)
{
    var list = windows
    space_manager_move_window_list_to_space(sid, &list, Int32(list.count))
}

//
// NOTE: The bridged operation moves windows asynchronously. Laying out or focusing a window before it has
// arrived on its new space places it on the wrong display, or makes macOS switch to the space it came from.
// The wait is bounded, because it blocks the event loop and a window may not be moved at all.
//

/// `space_manager_wait_for_window_on_space`
func space_manager_wait_for_window_on_space(_ wid: UInt32, _ sid: UInt64, _ timeoutMS: Int32) -> Bool
{
    var i: Int32 = 0
    while i < timeoutMS / 10 {
        if window_space(wid) == sid { return true }
        usleep(10000)
        i += 1
    }

    return window_space(wid) == sid
}

/// `space_manager_wait_for_windows_on_space`
func space_manager_wait_for_windows_on_space(_ windowList: UnsafeMutablePointer<UInt32>, _ windowCount: Int32, _ sid: UInt64, _ timeoutMS: Int32) -> Bool
{
    var arrived: Int32 = 0

    var i: Int32 = 0
    while i < timeoutMS / 10 {
        while arrived < windowCount && window_space(windowList[Int(arrived)]) == sid { arrived += 1 }
        if arrived == windowCount { return true }

        usleep(10000)
        i += 1
    }

    while arrived < windowCount && window_space(windowList[Int(arrived)]) == sid { arrived += 1 }
    return arrived == windowCount
}

/// `space_manager_move_window_to_space`
func space_manager_move_window_to_space(_ sid: UInt64, _ win: Window)
{
    if SLS.hasBridgedWindowOperation {
        SLS.bridgedMoveWindows([win.pointee.id], toSpace: sid)
    } else if !scripting_addition_move_window_to_space(sid, win.pointee.id) {
        var windows = [win.pointee.id]
        SLSSpaceSetCompatID(connection_global(), sid, 0x79616265)
        SLSSetWindowListWorkspace(connection_global(), &windows, 1, 0x79616265)
        SLSSpaceSetCompatID(connection_global(), sid, 0x0)
    }
}

/// `space_manager_find_first_user_space_for_display`
private func spaceManagerFindFirstUserSpaceForDisplay(_ did: UInt32) -> UInt64
{
    return displaySpaces(did)?.first(where: { space_is_user($0) }) ?? 0
}

/// `space_manager_is_space_last_user_space`: whether no other user space is on the display of sid.
func space_manager_is_space_last_user_space(_ sid: UInt64) -> Bool
{
    guard let spaces = displaySpaces(space_display_id(sid)) else { return true }

    for other in spaces {
        if sid == other { continue }
        if space_is_user(other) { return false }
    }

    return true
}

/// `space_manager_user_list`: whether each space of a list is a user space.
func spaceUserList(_ spaces: [UInt64]) -> [Bool]
{
    return spaces.map { space_is_user($0) }
}

/// `space_manager_swap_space_with_space_on_display`: swaps two spaces that are on different displays.
private func spaceManagerSwapSpaceWithSpaceOnDisplay(_ aSid: UInt64, _ bSid: UInt64) -> space_op_error
{
    let wm = window_manager_global()
    let sm = space_manager_global()

    let windowAnimationDuration = wm.window_animation_duration
    wm.window_animation_duration = 0.0

    let aWindows = spaceWindowIDs(aSid)
    let bWindows = spaceWindowIDs(bSid)

    let aView = sm.view.find(aSid)!
    let bView = sm.view.find(bSid)!

    sm.view.remove(aSid)
    sm.view.remove(bSid)

    aView.pointee.sid = bSid
    bView.pointee.sid = aSid

    let uuid = aView.pointee.uuid
    aView.pointee.uuid = bView.pointee.uuid
    bView.pointee.uuid = uuid

    sm.view.add(aSid, bView)
    sm.view.add(bSid, aView)

    if !aWindows.isEmpty {
        moveWindows(aWindows, to: bSid)
    }

    if !bWindows.isEmpty {
        moveWindows(bWindows, to: aSid)
    }

    label_swap_ids(sm.labels, aSid, bSid)

    view_update(aView)
    view_update(bView)

    view_flush(aView)
    view_flush(bView)

    wm.window_animation_duration = windowAnimationDuration
    return SPACE_OP_ERROR_SUCCESS
}

/// `space_manager_swap_space_with_space`
func space_manager_swap_space_with_space(_ actingSid: UInt64, _ selectorSid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }

    let actingDid = space_display_id(actingSid)
    let selectorDid = space_display_id(selectorSid)

    if actingSid == selectorSid { return SPACE_OP_ERROR_SAME_SPACE }
    if actingDid != selectorDid { return spaceManagerSwapSpaceWithSpaceOnDisplay(actingSid, selectorSid) }

    let actingPrevSid = space_manager_prev_space(actingSid)
    let selectorPrevSid = space_manager_prev_space(selectorSid)

    let actingPrevDid = actingPrevSid != 0 ? space_display_id(actingPrevSid) : 0
    let selectorPrevDid = selectorPrevSid != 0 ? space_display_id(selectorPrevSid) : 0

    let actingSidIsFirst = actingPrevSid == 0 || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == 0 || selectorPrevDid != selectorDid

    let actingMCI = space_manager_mission_control_index(actingSid)
    let selectorMCI = space_manager_mission_control_index(selectorSid)
    var success = true

    if actingSidIsFirst && !selectorSidIsFirst && selectorMCI - actingMCI == 1 {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
    } else if !actingSidIsFirst && selectorSidIsFirst && actingMCI - selectorMCI == 1 {
        success = scripting_addition_move_space_after_space(selectorSid, actingSid, selectorSid == space_manager_active_space())
    } else if actingSidIsFirst && !selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
        let second = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == space_manager_active_space())
        success = success && second
    } else if !actingSidIsFirst && selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
        let second = scripting_addition_move_space_after_space(selectorSid, actingPrevSid, false)
        success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst {
        if actingMCI > selectorMCI {
            success = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
            let second = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == space_manager_active_space())
            success = success && second
        } else {
            success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
            let second = scripting_addition_move_space_after_space(selectorSid, actingPrevSid, false)
            success = success && second
        }
    }

    return success ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION
}

/// `space_manager_move_space_to_space`
func space_manager_move_space_to_space(_ actingSid: UInt64, _ selectorSid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }

    let actingDid = space_display_id(actingSid)
    let selectorDid = space_display_id(selectorSid)

    if actingSid == selectorSid { return SPACE_OP_ERROR_SAME_SPACE }
    if actingDid != selectorDid { return SPACE_OP_ERROR_SAME_DISPLAY }

    let actingPrevSid = space_manager_prev_space(actingSid)
    let selectorPrevSid = space_manager_prev_space(selectorSid)

    let actingPrevDid = actingPrevSid != 0 ? space_display_id(actingPrevSid) : 0
    let selectorPrevDid = selectorPrevSid != 0 ? space_display_id(selectorPrevSid) : 0

    let actingSidIsFirst = actingPrevSid == 0 || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == 0 || selectorPrevDid != selectorDid
    var success = true

    if actingSidIsFirst && !selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
    } else if !actingSidIsFirst && selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
        let second = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
        success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst {
        if space_manager_mission_control_index(actingSid) > space_manager_mission_control_index(selectorSid) {
            success = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == space_manager_active_space())
        } else {
            success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
        }
    }

    return success ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION
}

/// `space_manager_move_space_to_display`
func space_manager_move_space_to_display(_ sm: SpaceManager, _ sid: UInt64, _ did: UInt32) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }
    if sid == 0 { return SPACE_OP_ERROR_MISSING_SRC }

    let sDid = space_display_id(sid)
    if sDid == did { return SPACE_OP_ERROR_INVALID_DST }

    if space_manager_is_space_last_user_space(sid) { return SPACE_OP_ERROR_INVALID_SRC }

    let dSid = display_space_id(did)
    if dSid == 0 { return SPACE_OP_ERROR_MISSING_DST }

    let focusSpace = sid == space_manager_active_space()

    //
    // NOTE: A visible space must be replaced on its display before the move, even when it is
    // not focused. Otherwise the WindowServer keeps it shown on the destination display next
    // to that display's current space, and its menubar stays on screen above the real one.
    //

    guard let spaceList = displaySpaces(sDid) else { return SPACE_OP_ERROR_MISSING_SRC }

    let user = spaceUserList(spaceList)
    let replacementSid = SpaceList.moveReplacement(spaces: spaceList, user: user, sid: sid, visible: display_space_id(sDid))

    if scripting_addition_move_space_to_display(sid, dSid, replacementSid, focusSpace) {
        space_manager_mark_view_invalid(sm, sid)
        if focusSpace {
            _ = space_manager_focus_space(sid)
        }
        return SPACE_OP_ERROR_SUCCESS
    }

    return SPACE_OP_ERROR_SCRIPTING_ADDITION
}

/// `space_manager_focus_space_using_gesture`: switches spaces with the gestures of the Dock, without its animation.
@discardableResult
func space_manager_focus_space_using_gesture(_ newDid: UInt32, _ newSid: UInt64) -> Bool
{
    let curIndex = space_manager_mission_control_index(display_space_id(newDid))
    let newIndex = space_manager_mission_control_index(newSid)

    let count = abs(newIndex - curIndex)
    if count == 0 {
        display_manager_focus_display(newDid, newSid)
        return true
    }

    let point = display_center(newDid)
    let curDid = display_manager_cursor_display_id()

    let focusDisplay = curDid != newDid
    if focusDisplay { CGWarpMouseCursorPosition(point) }

    //
    // NOTE(asmvik): MacOS does not have an API that allows for space activation.
    // However, we can synthesize a sequence of high velocity gestures to skip the
    // animation instead.
    //
    // :Attribution
    // https://github.com/jurplel/InstantSpaceSwitcher
    // https://github.com/thenickdude/wacom-driver-fix/blob/bdfda9a788934c88d09d31ea6a42664b9ba1471e/Readme.md
    // Technique first observed in practice, and reverse-engineered from, BetterTouchTool.
    //

    guard let eventDockControl = CGEvent(source: nil) else { return false }

    let sign: Double = (newIndex - curIndex) > 0 ? 1.0 : -1.0
    eventDockControl.setIntegerValueField(CGEventField(rawValue: UInt32(kCGSEventTypeField))!, value: Int64(kCGSEventDockControl))
    eventDockControl.setIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGestureHIDType))!, value: Int64(kIOHIDEventTypeDockSwipe))
    eventDockControl.setIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGestureSwipeMotion))!, value: Int64(kCGGestureMotionHorizontal))
    eventDockControl.setDoubleValueField(CGEventField(rawValue: UInt32(kCGEventGestureSwipeProgress))!, value: sign)
    eventDockControl.setDoubleValueField(CGEventField(rawValue: UInt32(kCGEventGestureSwipeVelocityX))!, value: sign * 9999.0)

    for _ in 0..<count {
        eventDockControl.setIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGesturePhase))!, value: Int64(kCGSGesturePhaseBegan))
        eventDockControl.post(tap: .cgSessionEventTap)
        eventDockControl.setIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGesturePhase))!, value: Int64(kCGSGesturePhaseEnded))
        eventDockControl.post(tap: .cgSessionEventTap)
    }

    if focusDisplay {
        display_manager_set_active_display_id(newDid)
        if space_manager_active_space() != newSid {
            CGPostMouseEventC(point, false, true)
            CGPostMouseEventC(point, false, false)
        }
    }

    return true
}

/// `space_manager_focus_space`
func space_manager_focus_space(_ sid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }

    let curSid = space_manager_active_space()
    if curSid == sid { return SPACE_OP_ERROR_SAME_SPACE }

    let curDid = space_display_id(curSid)
    let newDid = space_display_id(sid)
    let focusDisplay = curDid != newDid

    if scripting_addition_focus_space(sid) {
        if focusDisplay {
            display_manager_focus_display(newDid, sid)
        }
    } else {
        _ = space_manager_focus_space_using_gesture(newDid, sid)
    }

    return SPACE_OP_ERROR_SUCCESS
}

/// `space_manager_switch_space`
func space_manager_switch_space(_ sid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }

    let curSid = space_manager_active_space()
    if curSid == sid { return SPACE_OP_ERROR_SAME_SPACE }

    let curDid = space_display_id(curSid)
    let did = space_display_id(sid)

    if curDid != did {
        _ = spaceManagerSwapSpaceWithSpaceOnDisplay(curSid, sid)
        display_manager_focus_display(curDid, curSid)
        return SPACE_OP_ERROR_SUCCESS
    }

    return scripting_addition_focus_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION
}

/// `space_manager_destroy_space`
func space_manager_destroy_space(_ sid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }

    if sid == 0 { return SPACE_OP_ERROR_MISSING_SRC }
    if !space_is_user(sid) { return SPACE_OP_ERROR_INVALID_TYPE }
    if space_manager_is_space_last_user_space(sid) { return SPACE_OP_ERROR_INVALID_SRC }

    let did = space_display_id(sid)
    let firstSid = spaceManagerFindFirstUserSpaceForDisplay(did)

    if !scripting_addition_destroy_space(sid) { return SPACE_OP_ERROR_SCRIPTING_ADDITION }

    if firstSid != 0 {
        window_manager_validate_and_check_for_windows_on_space(space_manager_global(), window_manager_global(), firstSid)
    }

    return SPACE_OP_ERROR_SUCCESS
}

/// `space_manager_add_space`
func space_manager_add_space(_ sid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }
    if sid == 0 { return SPACE_OP_ERROR_MISSING_SRC }

    return scripting_addition_create_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION
}

/// `space_manager_is_window_on_space`
func space_manager_is_window_on_space(_ sid: UInt64, _ win: Window) -> Bool
{
    return window_space_list(win.pointee.id).contains(sid)
}

/// `space_manager_mark_spaces_invalid_for_display`
func space_manager_mark_spaces_invalid_for_display(_ sm: SpaceManager, _ did: UInt32)
{
    guard let spaceList = displaySpaces(did) else { return }

    let sid = display_space_id(did)
    for space in spaceList {
        if space == sid {
            space_manager_refresh_view(sm, sid)
        } else {
            space_manager_mark_view_invalid(sm, space)
        }
    }
}

/// `space_manager_mark_spaces_invalid`
func space_manager_mark_spaces_invalid(_ sm: SpaceManager)
{
    for did in displayManagerActiveDisplays() {
        space_manager_mark_spaces_invalid_for_display(sm, did)
    }
}

/// `space_manager_refresh_application_windows`: adds the windows of the applications that have unresolved windows.
func space_manager_refresh_application_windows(_ sm: SpaceManager) -> Bool
{
    let wm = window_manager_global()

    var refreshCount = Int(window_manager_application_refresh_count(wm))
    if refreshCount == 0 { return false }

    let windowCount = wm.window.count
    var i = 0
    while i < refreshCount {
        let application = window_manager_application_refresh_at(wm, Int32(i))
        debug("space_manager_refresh_application_windows: \(String(cString: application.pointee.name)) has windows that are not yet resolved\n")

        if window_manager_add_existing_application_windows(sm, wm, application, Int32(i)) {
            refreshCount -= 1
            i -= 1
        }

        i += 1
    }

    return windowCount != wm.window.count
}

/// `space_manager_handle_display_add`: the views of the spaces of a new display keep their names, and take the new ids.
func space_manager_handle_display_add(_ sm: SpaceManager, _ did: UInt32)
{
    guard let spaceList = displaySpaces(did) else { return }

    var viewList: [View?] = sm.view.values.map { Optional($0) }
    var uuidList: [CFString?] = viewList.map { $0?.pointee.uuid?.takeUnretainedValue() }

    for sid in spaceList {
        guard let uuid = SLS.spaceNameObject(connection_global(), sid) else { continue }

        for j in 0..<viewList.count {
            guard let viewUUID = uuidList[j], let target = viewList[j] else { continue }
            if !CFEqual(viewUUID, uuid) { continue }

            uuidList[j] = nil
            viewList[j] = nil

            sm.view.remove(target.pointee.sid)
            target.pointee.uuid?.release()

            label_replace_id(sm.labels, target.pointee.sid, sid)

            target.pointee.sid = sid
            target.pointee.uuid = Unmanaged.passRetained(uuid)

            sm.view.add(sid, target)
            break
        }
    }

    sm.current_space_id = space_manager_active_space()
    sm.last_space_id = sm.current_space_id
}

/// `space_manager_init`: the defaults of the space manager and an empty table of views.
func space_manager_init(_ sm: SpaceManager)
{
    sm.layout = VIEW_TREE
    sm.auto_padding = false
    sm.tree_default_orientation = TREE_ORIENTATION_AUTO
    sm.tree_workspace_tabbed = false
    sm.tree_autotiling = false
    sm.labels = nil
    sm.skip_window_focus_animation = false
    //
    // NOTE: The table of views is keyed by the space id.
    //

    sm.view = Table(capacity: 23)
}

/// `space_manager_begin`: creates the views of every space of every display.
func space_manager_begin(_ sm: SpaceManager)
{
    space_manager_init(sm)

    for did in displayManagerActiveDisplays() {
        guard let spaceList = displaySpaces(did) else { continue }

        for sid in spaceList {
            sm.view.add(sid, viewCreate(sid))
        }
    }

    sm.current_space_id = space_manager_active_space()
    sm.last_space_id = sm.current_space_id
    sm.did_begin = true
}
