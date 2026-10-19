import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The spaces of yabai: the views of every space (a table from the space id to its view), the layout and padding
// commands for spaces, the focus and moves of spaces through the scripting addition, and the moves of windows between
// spaces. Ported from src/space_manager.c.
//

/// The outcome of a space command: success, or why it failed (`Response.failSpaceOp` words the failures every space
/// command shares).
enum SpaceOperationResult: Sendable
{
    case success
    case missingSource
    case missingDestination
    case invalidSource
    case invalidDestination
    case invalidType
    case sameSpace
    case sameDisplay
    case inMissionControl
    case scriptingAdditionFailed
}

/// `struct space_manager`
final class SpaceManager
{
    var view: [SpaceID: View] = [:]
    var current_space_id: SpaceID?
    var last_space_id: SpaceID?
    var did_begin = false
    var layout = ViewType.default
    var top_padding: Int = 0
    var bottom_padding: Int = 0
    var left_padding: Int = 0
    var right_padding: Int = 0
    var window_gap: Int = 0
    var auto_padding = false
    var tree_default_orientation = TreeOrientation.auto
    var tree_workspace_tabbed = false
    var tree_autotiling = false
    var labels = LabelList<SpaceID>()
    var skip_window_focus_animation = false
    var space_layouts: [SpaceLayout] = []
    var space_layout_spec: String?
    var space_layout_gen: UInt32 = 0
    var space_layout_passes = 0
}

/// `g_space_manager` (see the NOTE of g_display_manager)
nonisolated(unsafe) let g_space_manager = SpaceManager()

func space_manager_global() -> SpaceManager
{
    g_space_manager
}

extension SpaceManager
{
    static var shared: SpaceManager { g_space_manager }
}

extension ViewSpacing
{
    /// The default of the space manager, for the views without their own value.
    var spaceManager: ReferenceWritableKeyPath<SpaceManager, Int>
    {
        switch self {
        case .topPadding:    \.top_padding
        case .bottomPadding: \.bottom_padding
        case .leftPadding:   \.left_padding
        case .rightPadding:  \.right_padding
        case .windowGap:     \.window_gap
        }
    }
}

/// `add_and_clamp_to_zero`
private func addAndClampToZero(_ a: Int, _ b: Int) -> Int
{
    return a + b <= 0 ? 0 : a + b
}

/// `space_manager_query_view`
func space_manager_query_view(_ sm: SpaceManager, _ sid: SpaceID) -> View?
{
    if sm.did_begin { return space_manager_find_view(sm, sid) }

    return sm.view[sid]
}

/// `space_manager_find_view`: the view of a space; it is created when the space is new.
@discardableResult
func space_manager_find_view(_ sm: SpaceManager, _ sid: SpaceID) -> View
{
    if let found = sm.view[sid] { return found }

    let created = View.create(sid: sid)
    sm.view[sid] = created
    return created
}

/// `space_manager_refresh_view`
func space_manager_refresh_view(_ sm: SpaceManager, _ sid: SpaceID)
{
    let target = space_manager_find_view(sm, sid)
    if target.layout == .float { return }

    target.updateAndFlush()
}

/// `space_manager_mark_view_invalid`
func space_manager_mark_view_invalid(_ sm: SpaceManager, _ sid: SpaceID)
{
    let target = space_manager_find_view(sm, sid)
    if target.layout == .float { return }

    target.isValid = false
}

/// `space_manager_untile_window`
func space_manager_untile_window(_ target: View, _ win: Window)
{
    if target.layout == .float { return }

    win.adjustLayer(to: .normal)
    if target.remove(win) { target.flush() }
}

/// `space_manager_set_layout_for_space`
func space_manager_set_layout_for_space(_ sm: SpaceManager, _ sid: SpaceID, _ layout: ViewType)
{
    let target = space_manager_find_view(sm, sid)
    target.layout = layout
    target.clear()

    if target.layout != .float {
        WindowManager.shared.validateAndCheckForWindows(on: sid)
    }
}

/// `space_manager_set_gap_for_space`
func space_manager_set_gap_for_space(_ sm: SpaceManager, _ sid: SpaceID, _ type: ValueType?, _ gap: Int) -> Bool
{
    let target = space_manager_find_view(sm, sid)
    if target.layout == .float { return false }

    if type == .abs {
        target.windowGap = gap
    } else if type == .rel {
        target.windowGap = addAndClampToZero(target.windowGap, gap)
    }

    target.updateAndFlush()

    return true
}

/// Toggles the padding or gap switch of a view.
private func spaceManagerToggleView(_ sm: SpaceManager, _ sid: SpaceID, _ setting: ReferenceWritableKeyPath<View, Bool>) -> Bool
{
    let target = space_manager_find_view(sm, sid)
    if target.layout == .float { return false }

    target[keyPath: setting].toggle()

    target.updateAndFlush()

    return true
}

/// `space_manager_toggle_gap_for_space`
func space_manager_toggle_gap_for_space(_ sm: SpaceManager, _ sid: SpaceID) -> Bool
{
    return spaceManagerToggleView(sm, sid, \.isGapEnabled)
}

/// `space_manager_toggle_mission_control`
func space_manager_toggle_mission_control(_ sid: SpaceID)
{
    _ = space_manager_focus_space(sid)
    CoreDock.sendNotification("com.apple.expose.awake")
}

/// `space_manager_toggle_show_desktop`
func space_manager_toggle_show_desktop(_ sid: SpaceID)
{
    _ = space_manager_focus_space(sid)
    CoreDock.sendNotification("com.apple.showdesktop.awake")
}

/// `space_manager_set_layout_for_all_spaces`: the views without their own layout take the layout.
func space_manager_set_layout_for_all_spaces(_ sm: SpaceManager, _ layout: ViewType)
{
    sm.layout = layout

    for target in sm.view.values.sorted(by: { $0.sid < $1.sid }) {
        if !target.overrides.contains(.layout) {
            if space_is_user(target.sid) {
                target.layout = layout
                target.clear()

                if target.layout != .float {
                    WindowManager.shared.validateAndCheckForWindows(on: target.sid)
                }
            }
        }
    }
}

/// `space_manager_set_spacing_for_all_spaces`
func space_manager_set_spacing_for_all_spaces(_ sm: SpaceManager, _ spacing: ViewSpacing, _ value: Int)
{
    sm[keyPath: spacing.spaceManager] = value

    for target in sm.view.values.sorted(by: { $0.sid < $1.sid }) {
        if !target.overrides.contains(spacing.override) {
            target[keyPath: spacing.view] = value
            target.updateAndFlush()
        }
    }
}

/// `space_manager_apply_auto_padding`
private func spaceManagerApplyAutoPadding(_ target: View, _ autoPadding: Bool)
{
    if target.autoPadding == autoPadding { return }

    target.autoPadding = autoPadding
    if target.layout == .float { return }

    target.updateAndFlush()
}

/// `space_manager_set_auto_padding_for_all_spaces`
func space_manager_set_auto_padding_for_all_spaces(_ sm: SpaceManager, _ autoPadding: Bool)
{
    sm.auto_padding = autoPadding

    for target in sm.view.values.sorted(by: { $0.sid < $1.sid }) {
        if !target.overrides.contains(.autoPadding) {
            spaceManagerApplyAutoPadding(target, autoPadding)
        }
    }
}

/// `space_manager_set_auto_padding_for_space`
func space_manager_set_auto_padding_for_space(_ sm: SpaceManager, _ sid: SpaceID, _ autoPadding: Bool)
{
    let target = space_manager_find_view(sm, sid)
    target.overrides.insert(.autoPadding)
    spaceManagerApplyAutoPadding(target, autoPadding)
}

/// `space_manager_set_padding_for_space`
func space_manager_set_padding_for_space(_ sm: SpaceManager, _ sid: SpaceID, _ type: ValueType?, _ top: Int, _ bottom: Int, _ left: Int, _ right: Int) -> Bool
{
    let target = space_manager_find_view(sm, sid)
    if target.layout == .float { return false }

    if type == .abs {
        target.topPadding     = top
        target.bottomPadding  = bottom
        target.leftPadding    = left
        target.rightPadding   = right
    } else if type == .rel {
        target.topPadding     = addAndClampToZero(target.topPadding, top)
        target.bottomPadding  = addAndClampToZero(target.bottomPadding, bottom)
        target.leftPadding    = addAndClampToZero(target.leftPadding, left)
        target.rightPadding   = addAndClampToZero(target.rightPadding, right)
    }

    target.updateAndFlush()

    return true
}

/// `space_manager_toggle_padding_for_space`
func space_manager_toggle_padding_for_space(_ sm: SpaceManager, _ sid: SpaceID) -> Bool
{
    return spaceManagerToggleView(sm, sid, \.isPaddingEnabled)
}

/// `space_manager_find_tree_view`: the view of a space when it is a tree with a root.
private func spaceManagerFindTreeView(_ sm: SpaceManager, _ sid: SpaceID) -> View?
{
    let target = space_manager_find_view(sm, sid)
    return target.layout == .tree && target.tree != nil ? target : nil
}

/// `space_manager_rotate_space`
func space_manager_rotate_space(_ sm: SpaceManager, _ sid: SpaceID, _ degrees: Int) -> Bool
{
    guard let target = spaceManagerFindTreeView(sm, sid) else { return false }

    target.tree!.rotate(by: degrees)
    target.updateAndFlush()

    return true
}

/// `space_manager_mirror_space`
func space_manager_mirror_space(_ sm: SpaceManager, _ sid: SpaceID, _ axis: WindowSplit) -> Bool
{
    guard let target = spaceManagerFindTreeView(sm, sid) else { return false }

    target.tree!.mirror(axis == .x ? .vertical : .horizontal)
    target.updateAndFlush()

    return true
}

/// `space_manager_balance_space`
func space_manager_balance_space(_ sm: SpaceManager, _ sid: SpaceID) -> Bool
{
    guard let target = spaceManagerFindTreeView(sm, sid) else { return false }

    target.tree!.balance()
    target.updateAndFlush()

    return true
}

/// `space_manager_tile_window_on_space_with_insertion_point`
func space_manager_tile_window_on_space_with_insertion_point(_ sm: SpaceManager, _ win: Window, _ sid: SpaceID, _ insertionPoint: WindowID?) -> View
{
    let target = space_manager_find_view(sm, sid)
    if target.layout == .float { return target }

    win.adjustLayer(to: .below)
    target.add(win, insertionPoint: insertionPoint)
    target.flush()

    return target
}

/// `space_manager_tile_window_on_space`
func space_manager_tile_window_on_space(_ sm: SpaceManager, _ win: Window, _ sid: SpaceID) -> View
{
    return space_manager_tile_window_on_space_with_insertion_point(sm, win, sid, nil)
}

/// `space_manager_toggle_window_split`
func space_manager_toggle_window_split(_ sm: SpaceManager, _ win: Window)
{
    guard let sid = win.id.space else { return }

    let target = space_manager_find_view(sm, sid)
    if target.layout != .tree { return }

    _ = WindowManager.shared.setWindowLayout(win, .toggleSplit)
}

//
// NOTE: Every space in the order Mission Control numbers them, display by display. The list lives in
// temporary storage.
//

/// Every space in the order Mission Control numbers them.
func missionControlSpaces() -> [SpaceID]
{
    var result: [SpaceID] = []

    for display in display_manager_copy_managed_display_spaces() {
        guard let spaces = display["Spaces"] as? [NSDictionary] else { continue }

        for space in spaces {
            guard let sid = (space["id64"] as? NSNumber).flatMap({ SpaceID(nonzero: $0.uint64Value) }) else { continue }
            result.append(sid)
        }
    }

    return result
}

/// `space_manager_mission_control_space_list`: nil without spaces.
func space_manager_mission_control_space_list() -> [SpaceID]?
{
    let spaces = missionControlSpaces()
    return spaces.isEmpty ? nil : spaces
}

/// `space_manager_mission_control_index`: the Mission Control number of a space, or 0.
func space_manager_mission_control_index(_ sid: SpaceID) -> Int
{
    return (SpaceList.indexOf(spaces: missionControlSpaces(), sid: sid) ?? -1) + 1
}

/// `space_manager_mission_control_space`: the space with a Mission Control number, or nil.
func space_manager_mission_control_space(_ desktopID: Int) -> SpaceID?
{
    let spaces = missionControlSpaces()
    guard desktopID >= 1 && desktopID <= spaces.count else { return nil }

    return spaces[desktopID - 1]
}

/// `space_manager_cursor_space`
func space_manager_cursor_space() -> SpaceID?
{
    return display_manager_cursor_display_id().flatMap(display_space_id)
}

/// `space_manager_prev_space`
func space_manager_prev_space(_ sid: SpaceID) -> SpaceID?
{
    return SpaceList.neighbour(spaces: missionControlSpaces(), sid: sid, offset: -1)
}

/// `space_manager_next_space`
func space_manager_next_space(_ sid: SpaceID) -> SpaceID?
{
    return SpaceList.neighbour(spaces: missionControlSpaces(), sid: sid, offset: 1)
}

/// `space_manager_first_space`
func space_manager_first_space() -> SpaceID?
{
    return missionControlSpaces().first
}

/// `space_manager_last_space`
func space_manager_last_space() -> SpaceID?
{
    return missionControlSpaces().last
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
    if wm.focusedWindowID == nil { return false }

    return psn_equals(front, &wm.focusedWindowPSN)
}

/// `space_manager_focused_window`
private func spaceManagerFocusedWindow() -> Window?
{
    var front = SLS.frontProcess()

    let wm = WindowManager.shared
    let pendingFocus = pending_window_focus()

    if space_manager_can_use_known_focus(&front, wm, pendingFocus) {
        if let focusedID = wm.focusedWindowID, let target = wm.window(for: focusedID) { return target }
    }

    return wm.focusedWindow
}

/// `space_manager_active_space`: the space of the focused window, or of the active display; nil when neither is known.
func space_manager_active_space() -> SpaceID?
{
    var did: DisplayID? = nil
    let focused = spaceManagerFocusedWindow()

    if let focused { did = focused.id.displayID }
    if did == nil { did = display_manager_active_display_id() }

    return did.flatMap(display_space_id)
}

/// The windows of a space, as `space_window_list` lists them.
private func spaceWindowIDs(_ sid: SpaceID) -> [WindowID]
{
    return space_window_list(sid, true) ?? []
}

/// `space_manager_move_window_list_to_space`
func space_manager_move_window_list_to_space(_ sid: SpaceID, _ windows: [WindowID])
{
    if SLS.hasBridgedWindowOperation {
        SLS.bridgedMoveWindows(windows, toSpace: sid)
    } else if !scripting_addition_move_window_list_to_space(sid, windows) {
        SLSSpaceSetCompatID(connection_global(), sid.rawValue, 0x79616265)
        var rawWindows = windows.map(\.rawValue)
        SLSSetWindowListWorkspace(connection_global(), &rawWindows, Int32(rawWindows.count), 0x79616265)
        SLSSpaceSetCompatID(connection_global(), sid.rawValue, 0x0)
    }
}

//
// NOTE: The bridged operation moves windows asynchronously. Laying out or focusing a window before it has
// arrived on its new space places it on the wrong display, or makes macOS switch to the space it came from.
// The wait is bounded, because it blocks the event loop and a window may not be moved at all.
//

/// `space_manager_wait_for_window_on_space`
func space_manager_wait_for_window_on_space(_ wid: WindowID, _ sid: SpaceID, _ timeoutMS: Int) -> Bool
{
    var i = 0
    while i < timeoutMS / 10 {
        if wid.space == sid { return true }
        usleep(10000)
        i += 1
    }

    return wid.space == sid
}

/// `space_manager_wait_for_windows_on_space`
func space_manager_wait_for_windows_on_space(_ windows: [WindowID], _ sid: SpaceID, _ timeoutMS: Int) -> Bool
{
    var arrived = 0

    var i = 0
    while i < timeoutMS / 10 {
        while arrived < windows.count && windows[arrived].space == sid { arrived += 1 }
        if arrived == windows.count { return true }

        usleep(10000)
        i += 1
    }

    while arrived < windows.count && windows[arrived].space == sid { arrived += 1 }
    return arrived == windows.count
}

/// `space_manager_move_window_to_space`
func space_manager_move_window_to_space(_ sid: SpaceID, _ win: Window)
{
    if SLS.hasBridgedWindowOperation {
        SLS.bridgedMoveWindows([win.id], toSpace: sid)
    } else if !scripting_addition_move_window_to_space(sid, win.id) {
        var windows = [win.id.rawValue]
        SLSSpaceSetCompatID(connection_global(), sid.rawValue, 0x79616265)
        SLSSetWindowListWorkspace(connection_global(), &windows, 1, 0x79616265)
        SLSSpaceSetCompatID(connection_global(), sid.rawValue, 0x0)
    }
}

/// `space_manager_find_first_user_space_for_display`
private func spaceManagerFindFirstUserSpaceForDisplay(_ did: DisplayID) -> SpaceID?
{
    return displaySpaces(did)?.first(where: { space_is_user($0) })
}

/// `space_manager_is_space_last_user_space`: whether no other user space is on the display of sid.
func space_manager_is_space_last_user_space(_ sid: SpaceID) -> Bool
{
    guard let did = space_display_id(sid), let spaces = displaySpaces(did) else { return true }

    for other in spaces {
        if sid == other { continue }
        if space_is_user(other) { return false }
    }

    return true
}

/// `space_manager_user_list`: whether each space of a list is a user space.
func spaceUserList(_ spaces: [SpaceID]) -> [Bool]
{
    return spaces.map { space_is_user($0) }
}

/// `space_manager_swap_space_with_space_on_display`: swaps two spaces that are on different displays.
private func spaceManagerSwapSpaceWithSpaceOnDisplay(_ aSid: SpaceID, _ bSid: SpaceID) -> SpaceOperationResult
{
    let wm = WindowManager.shared
    let sm = space_manager_global()

    let windowAnimationDuration = wm.windowAnimationDuration
    wm.windowAnimationDuration = 0.0

    let aWindows = spaceWindowIDs(aSid)
    let bWindows = spaceWindowIDs(bSid)

    let aView = sm.view[aSid]!
    let bView = sm.view[bSid]!

    sm.view.removeValue(forKey: aSid)
    sm.view.removeValue(forKey: bSid)

    aView.sid = bSid
    bView.sid = aSid

    let uuid = aView.uuid
    aView.uuid = bView.uuid
    bView.uuid = uuid

    sm.view[aSid] = bView
    sm.view[bSid] = aView

    if !aWindows.isEmpty {
        space_manager_move_window_list_to_space(bSid, aWindows)
    }

    if !bWindows.isEmpty {
        space_manager_move_window_list_to_space(aSid, bWindows)
    }

    sm.labels.swap(aSid, bSid)

    aView.update()
    bView.update()

    aView.flush()
    bView.flush()

    wm.windowAnimationDuration = windowAnimationDuration
    return .success
}

/// `space_manager_swap_space_with_space`
func space_manager_swap_space_with_space(_ actingSid: SpaceID, _ selectorSid: SpaceID) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }

    let actingDid = space_display_id(actingSid)
    let selectorDid = space_display_id(selectorSid)

    if actingSid == selectorSid { return .sameSpace }
    if actingDid != selectorDid { return spaceManagerSwapSpaceWithSpaceOnDisplay(actingSid, selectorSid) }

    let actingPrevSid = space_manager_prev_space(actingSid)
    let selectorPrevSid = space_manager_prev_space(selectorSid)

    let actingPrevDid = actingPrevSid.flatMap(space_display_id)
    let selectorPrevDid = selectorPrevSid.flatMap(space_display_id)

    let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid

    let actingMCI = space_manager_mission_control_index(actingSid)
    let selectorMCI = space_manager_mission_control_index(selectorSid)
    var success = true

    //
    // NOTE: A prev space is nil only where the sid is first, so the branches that move past it bind it.
    //
    if actingSidIsFirst && !selectorSidIsFirst && selectorMCI - actingMCI == 1 {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
    } else if !actingSidIsFirst && selectorSidIsFirst && actingMCI - selectorMCI == 1 {
        success = scripting_addition_move_space_after_space(selectorSid, actingSid, selectorSid == space_manager_active_space())
    } else if actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
        success = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
        let second = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == space_manager_active_space())
        success = success && second
    } else if !actingSidIsFirst && selectorSidIsFirst, let actingPrevSid {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
        let second = scripting_addition_move_space_after_space(selectorSid, actingPrevSid, false)
        success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst, let actingPrevSid, let selectorPrevSid {
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

    return success ? .success : .scriptingAdditionFailed
}

/// `space_manager_move_space_to_space`
func space_manager_move_space_to_space(_ actingSid: SpaceID, _ selectorSid: SpaceID) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }

    let actingDid = space_display_id(actingSid)
    let selectorDid = space_display_id(selectorSid)

    if actingSid == selectorSid { return .sameSpace }
    if actingDid != selectorDid { return .sameDisplay }

    let actingPrevSid = space_manager_prev_space(actingSid)
    let selectorPrevSid = space_manager_prev_space(selectorSid)

    let actingPrevDid = actingPrevSid.flatMap(space_display_id)
    let selectorPrevDid = selectorPrevSid.flatMap(space_display_id)

    let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid
    var success = true

    if actingSidIsFirst && !selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
    } else if !actingSidIsFirst && selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
        let second = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
        success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
        if space_manager_mission_control_index(actingSid) > space_manager_mission_control_index(selectorSid) {
            success = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == space_manager_active_space())
        } else {
            success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == space_manager_active_space())
        }
    }

    return success ? .success : .scriptingAdditionFailed
}

/// `space_manager_move_space_to_display`
func space_manager_move_space_to_display(_ sm: SpaceManager, _ sid: SpaceID?, _ did: DisplayID) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }
    guard let sid else { return .missingSource }

    let sDid = space_display_id(sid)
    if sDid == did { return .invalidDestination }

    if space_manager_is_space_last_user_space(sid) { return .invalidSource }

    guard let dSid = display_space_id(did) else { return .missingDestination }

    let focusSpace = sid == space_manager_active_space()

    //
    // NOTE: A visible space must be replaced on its display before the move, even when it is
    // not focused. Otherwise the WindowServer keeps it shown on the destination display next
    // to that display's current space, and its menubar stays on screen above the real one.
    //

    guard let spaceList = sDid.flatMap(displaySpaces) else { return .missingSource }

    let user = spaceUserList(spaceList)
    let visibleSid = sDid.flatMap(display_space_id)
    let replacementSid = visibleSid.flatMap { SpaceList.moveReplacement(spaces: spaceList, user: user, sid: sid, visible: $0) }

    //
    // NOTE: The scripting addition takes a plain space id, and it packs nil as 0, "no replacement space".
    //
    if scripting_addition_move_space_to_display(sid, dSid, replacementSid, focusSpace) {
        space_manager_mark_view_invalid(sm, sid)
        if focusSpace {
            _ = space_manager_focus_space(sid)
        }
        return .success
    }

    return .scriptingAdditionFailed
}

/// `space_manager_focus_space_using_gesture`: switches spaces with the gestures of the Dock, without its animation.
@discardableResult
func space_manager_focus_space_using_gesture(_ newDid: DisplayID, _ newSid: SpaceID) -> Bool
{
    let curIndex = display_space_id(newDid).map(space_manager_mission_control_index) ?? 0
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
    eventDockControl.setIntegerValueField(DockSwipe.typeField, value: Int64(DockSwipe.eventType))
    eventDockControl.setIntegerValueField(DockSwipe.hidTypeField, value: DockSwipe.hidType)
    eventDockControl.setIntegerValueField(DockSwipe.motionField, value: DockSwipe.motionHorizontal)
    eventDockControl.setDoubleValueField(DockSwipe.progressField, value: sign)
    eventDockControl.setDoubleValueField(DockSwipe.velocityXField, value: sign * 9999.0)

    for _ in 0..<count {
        eventDockControl.setIntegerValueField(DockSwipe.phaseField, value: DockSwipe.phaseBegan)
        eventDockControl.post(tap: .cgSessionEventTap)
        eventDockControl.setIntegerValueField(DockSwipe.phaseField, value: DockSwipe.phaseEnded)
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
func space_manager_focus_space(_ sid: SpaceID) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }

    let curSid = space_manager_active_space()
    if curSid == sid { return .sameSpace }

    let curDid = curSid.flatMap(space_display_id)
    let newDid = space_display_id(sid)
    let focusDisplay = curDid != newDid

    if scripting_addition_focus_space(sid) {
        if focusDisplay, let newDid {
            display_manager_focus_display(newDid, sid)
        }
    } else if let newDid {
        _ = space_manager_focus_space_using_gesture(newDid, sid)
    }

    return .success
}

/// `space_manager_switch_space`
func space_manager_switch_space(_ sid: SpaceID) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }

    guard let curSid = space_manager_active_space() else { return .missingSource }
    if curSid == sid { return .sameSpace }

    let curDid = space_display_id(curSid)
    let did = space_display_id(sid)

    if curDid != did {
        _ = spaceManagerSwapSpaceWithSpaceOnDisplay(curSid, sid)
        if let curDid { display_manager_focus_display(curDid, curSid) }
        return .success
    }

    return scripting_addition_focus_space(sid) ? .success : .scriptingAdditionFailed
}

/// `space_manager_destroy_space`
func space_manager_destroy_space(_ sid: SpaceID?) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }

    guard let sid else { return .missingSource }
    if !space_is_user(sid) { return .invalidType }
    if space_manager_is_space_last_user_space(sid) { return .invalidSource }

    let did = space_display_id(sid)
    let firstSid = did.flatMap(spaceManagerFindFirstUserSpaceForDisplay)

    if !scripting_addition_destroy_space(sid) { return .scriptingAdditionFailed }

    if let firstSid {
        WindowManager.shared.validateAndCheckForWindows(on: firstSid)
    }

    return .success
}

/// `space_manager_add_space`
func space_manager_add_space(_ sid: SpaceID?) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }
    guard let sid else { return .missingSource }

    return scripting_addition_create_space(sid) ? .success : .scriptingAdditionFailed
}

/// `space_manager_is_window_on_space`
func space_manager_is_window_on_space(_ sid: SpaceID, _ win: Window) -> Bool
{
    return win.id.spaces.contains(sid)
}

/// `space_manager_mark_spaces_invalid_for_display`
func space_manager_mark_spaces_invalid_for_display(_ sm: SpaceManager, _ did: DisplayID)
{
    guard let spaceList = displaySpaces(did) else { return }

    let sid = display_space_id(did)
    for space in spaceList {
        if space == sid, let sid {
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
    let wm = WindowManager.shared

    var refreshCount = wm.applicationRefreshCount
    if refreshCount == 0 { return false }

    let windowCount = wm.window.count
    var i = 0
    while i < refreshCount {
        let application = wm.applicationRefresh(at: i)
        debug("space_manager_refresh_application_windows: \(application.name) has windows that are not yet resolved\n")

        if wm.addExistingApplicationWindows(application, refreshIndex: i) {
            refreshCount -= 1
            i -= 1
        }

        i += 1
    }

    return windowCount != wm.window.count
}

/// `space_manager_handle_display_add`: the views of the spaces of a new display keep their names, and take the new ids.
func space_manager_handle_display_add(_ sm: SpaceManager, _ did: DisplayID)
{
    guard let spaceList = displaySpaces(did) else { return }

    var viewList: [View?] = sm.view.values.sorted(by: { $0.sid < $1.sid }).map { Optional($0) }
    var uuidList: [CFString?] = viewList.map { $0?.uuid }

    for sid in spaceList {
        guard let uuid = SLS.spaceNameObject(connection_global(), sid) else { continue }

        for j in 0..<viewList.count {
            guard let viewUUID = uuidList[j], let target = viewList[j] else { continue }
            if !CFEqual(viewUUID, uuid) { continue }

            uuidList[j] = nil
            viewList[j] = nil

            sm.view.removeValue(forKey: target.sid)

            sm.labels.replace(id: target.sid, with: sid)

            target.sid = sid
            target.uuid = uuid

            if sm.view[sid] == nil { sm.view[sid] = target }
            break
        }
    }

    sm.current_space_id = space_manager_active_space()
    sm.last_space_id = sm.current_space_id
}

/// `space_manager_init`: the defaults of the space manager and an empty table of views.
func space_manager_init(_ sm: SpaceManager)
{
    sm.layout = .tree
    sm.auto_padding = false
    sm.tree_default_orientation = .auto
    sm.tree_workspace_tabbed = false
    sm.tree_autotiling = false
    sm.labels = LabelList<SpaceID>()
    sm.skip_window_focus_animation = false
    //
    // NOTE: The views are keyed by space id.
    //

    sm.view = [:]
}

/// `space_manager_begin`: creates the views of every space of every display.
func space_manager_begin(_ sm: SpaceManager)
{
    space_manager_init(sm)

    for did in displayManagerActiveDisplays() {
        guard let spaceList = displaySpaces(did) else { continue }

        for sid in spaceList {
            let created = View.create(sid: sid)
            if sm.view[sid] == nil { sm.view[sid] = created }
        }
    }

    sm.current_space_id = space_manager_active_space()
    sm.last_space_id = sm.current_space_id
    sm.did_begin = true
}
