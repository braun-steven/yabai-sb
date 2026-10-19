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

/// `g_space_manager` (see the NOTE of `DisplayManager.shared`)
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
            if target.sid.isUser {
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

/// `space_manager_swap_space_with_space_on_display`: swaps two spaces that are on different displays.
private func spaceManagerSwapSpaceWithSpaceOnDisplay(_ aSid: SpaceID, _ bSid: SpaceID) -> SpaceOperationResult
{
    let wm = WindowManager.shared
    let sm = space_manager_global()

    let windowAnimationDuration = wm.windowAnimationDuration
    wm.windowAnimationDuration = 0.0

    let aWindows = aSid.windows(includingMinimized: true) ?? []
    let bWindows = bSid.windows(includingMinimized: true) ?? []

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
        bSid.moveWindows(aWindows)
    }

    if !bWindows.isEmpty {
        aSid.moveWindows(bWindows)
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
    if MissionControl.shared.isActive { return .inMissionControl }

    let actingDid = actingSid.display
    let selectorDid = selectorSid.display

    if actingSid == selectorSid { return .sameSpace }
    if actingDid != selectorDid { return spaceManagerSwapSpaceWithSpaceOnDisplay(actingSid, selectorSid) }

    let actingPrevSid = actingSid.previous
    let selectorPrevSid = selectorSid.previous

    let actingPrevDid = actingPrevSid.flatMap { $0.display }
    let selectorPrevDid = selectorPrevSid.flatMap { $0.display }

    let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid

    let actingMCI = actingSid.missionControlIndex
    let selectorMCI = selectorSid.missionControlIndex
    var success = true

    //
    // NOTE: A prev space is nil only where the sid is first, so the branches that move past it bind it.
    //
    if actingSidIsFirst && !selectorSidIsFirst && selectorMCI - actingMCI == 1 {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == SpaceID.active)
    } else if !actingSidIsFirst && selectorSidIsFirst && actingMCI - selectorMCI == 1 {
        success = scripting_addition_move_space_after_space(selectorSid, actingSid, selectorSid == SpaceID.active)
    } else if actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
        success = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
        let second = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == SpaceID.active)
        success = success && second
    } else if !actingSidIsFirst && selectorSidIsFirst, let actingPrevSid {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == SpaceID.active)
        let second = scripting_addition_move_space_after_space(selectorSid, actingPrevSid, false)
        success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst, let actingPrevSid, let selectorPrevSid {
        if actingMCI > selectorMCI {
            success = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
            let second = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == SpaceID.active)
            success = success && second
        } else {
            success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == SpaceID.active)
            let second = scripting_addition_move_space_after_space(selectorSid, actingPrevSid, false)
            success = success && second
        }
    }

    return success ? .success : .scriptingAdditionFailed
}

/// `space_manager_move_space_to_space`
func space_manager_move_space_to_space(_ actingSid: SpaceID, _ selectorSid: SpaceID) -> SpaceOperationResult
{
    if MissionControl.shared.isActive { return .inMissionControl }

    let actingDid = actingSid.display
    let selectorDid = selectorSid.display

    if actingSid == selectorSid { return .sameSpace }
    if actingDid != selectorDid { return .sameDisplay }

    let actingPrevSid = actingSid.previous
    let selectorPrevSid = selectorSid.previous

    let actingPrevDid = actingPrevSid.flatMap { $0.display }
    let selectorPrevDid = selectorPrevSid.flatMap { $0.display }

    let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid
    var success = true

    if actingSidIsFirst && !selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == SpaceID.active)
    } else if !actingSidIsFirst && selectorSidIsFirst {
        success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == SpaceID.active)
        let second = scripting_addition_move_space_after_space(selectorSid, actingSid, false)
        success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
        if actingSid.missionControlIndex > selectorSid.missionControlIndex {
            success = scripting_addition_move_space_after_space(actingSid, selectorPrevSid, actingSid == SpaceID.active)
        } else {
            success = scripting_addition_move_space_after_space(actingSid, selectorSid, actingSid == SpaceID.active)
        }
    }

    return success ? .success : .scriptingAdditionFailed
}

/// `space_manager_move_space_to_display`
func space_manager_move_space_to_display(_ sm: SpaceManager, _ sid: SpaceID?, _ did: DisplayID) -> SpaceOperationResult
{
    if MissionControl.shared.isActive { return .inMissionControl }
    guard let sid else { return .missingSource }

    let sDid = sid.display
    if sDid == did { return .invalidDestination }

    if sid.isLastUserSpace { return .invalidSource }

    guard let dSid = did.currentSpace else { return .missingDestination }

    let focusSpace = sid == SpaceID.active

    //
    // NOTE: A visible space must be replaced on its display before the move, even when it is
    // not focused. Otherwise the WindowServer keeps it shown on the destination display next
    // to that display's current space, and its menubar stays on screen above the real one.
    //

    guard let spaceList = sDid.flatMap({ $0.spaces }) else { return .missingSource }

    let user = spaceList.map { $0.isUser }
    let visibleSid = sDid.flatMap { $0.currentSpace }
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
    let curIndex = newDid.currentSpace.map { $0.missionControlIndex } ?? 0
    let newIndex = newSid.missionControlIndex

    let count = abs(newIndex - curIndex)
    if count == 0 {
        newDid.focus(space: newSid)
        return true
    }

    let point = newDid.center
    let curDid = DisplayID.underCursor

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
        newDid.activate()
        if SpaceID.active != newSid {
            CGPostMouseEventC(point, false, true)
            CGPostMouseEventC(point, false, false)
        }
    }

    return true
}

/// `space_manager_focus_space`
func space_manager_focus_space(_ sid: SpaceID) -> SpaceOperationResult
{
    if MissionControl.shared.isActive { return .inMissionControl }

    let curSid = SpaceID.active
    if curSid == sid { return .sameSpace }

    let curDid = curSid.flatMap { $0.display }
    let newDid = sid.display
    let focusDisplay = curDid != newDid

    if scripting_addition_focus_space(sid) {
        if focusDisplay, let newDid {
            newDid.focus(space: sid)
        }
    } else if let newDid {
        _ = space_manager_focus_space_using_gesture(newDid, sid)
    }

    return .success
}

/// `space_manager_switch_space`
func space_manager_switch_space(_ sid: SpaceID) -> SpaceOperationResult
{
    if MissionControl.shared.isActive { return .inMissionControl }

    guard let curSid = SpaceID.active else { return .missingSource }
    if curSid == sid { return .sameSpace }

    let curDid = curSid.display
    let did = sid.display

    if curDid != did {
        _ = spaceManagerSwapSpaceWithSpaceOnDisplay(curSid, sid)
        if let curDid { curDid.focus(space: curSid) }
        return .success
    }

    return scripting_addition_focus_space(sid) ? .success : .scriptingAdditionFailed
}

/// `space_manager_destroy_space`
func space_manager_destroy_space(_ sid: SpaceID?) -> SpaceOperationResult
{
    if MissionControl.shared.isActive { return .inMissionControl }

    guard let sid else { return .missingSource }
    if !sid.isUser { return .invalidType }
    if sid.isLastUserSpace { return .invalidSource }

    let did = sid.display
    let firstSid = did?.spaces?.first(where: { $0.isUser })

    if !scripting_addition_destroy_space(sid) { return .scriptingAdditionFailed }

    if let firstSid {
        WindowManager.shared.validateAndCheckForWindows(on: firstSid)
    }

    return .success
}

/// `space_manager_add_space`
func space_manager_add_space(_ sid: SpaceID?) -> SpaceOperationResult
{
    if MissionControl.shared.isActive { return .inMissionControl }
    guard let sid else { return .missingSource }

    return scripting_addition_create_space(sid) ? .success : .scriptingAdditionFailed
}

/// `space_manager_mark_spaces_invalid_for_display`
func space_manager_mark_spaces_invalid_for_display(_ sm: SpaceManager, _ did: DisplayID)
{
    guard let spaceList = did.spaces else { return }

    let sid = did.currentSpace
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
    for did in DisplayID.all {
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
    guard let spaceList = did.spaces else { return }

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

    sm.current_space_id = SpaceID.active
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

    for did in DisplayID.all {
        guard let spaceList = did.spaces else { continue }

        for sid in spaceList {
            let created = View.create(sid: sid)
            if sm.view[sid] == nil { sm.view[sid] = created }
        }
    }

    sm.current_space_id = SpaceID.active
    sm.last_space_id = sm.current_space_id
    sm.did_begin = true
}
