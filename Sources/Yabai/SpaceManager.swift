import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The spaces of yabai: the views of every space (a table from the space id to its view), their invalidation and
// refresh, and the commands that focus, switch, swap, move, create and destroy spaces through the scripting addition.
// The layout and padding commands of spaces are in SpaceManager+Layout.swift.
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

final class SpaceManager
{
    /// See the NOTE of `DisplayManager.shared`.
    nonisolated(unsafe) static let shared = SpaceManager()

    var views: [SpaceID: View] = [:]
    var currentSpaceID: SpaceID?
    var lastSpaceID: SpaceID?
    var didBegin = false
    var layout = ViewType.default
    var topPadding: Int = 0
    var bottomPadding: Int = 0
    var leftPadding: Int = 0
    var rightPadding: Int = 0
    var windowGap: Int = 0
    var autoPadding = false
    var treeDefaultOrientation = TreeOrientation.auto
    var treeWorkspaceTabbed = false
    var treeAutotiling = false
    var labels = LabelList<SpaceID>()
    var skipWindowFocusAnimation = false
    var spaceLayouts: [SpaceLayout] = []
    var spaceLayoutSpec: String?
    var spaceLayoutGeneration: UInt32 = 0
    var spaceLayoutPasses = 0

    /// The view of a space; before `begin()` only a known one, after it the view is created when the space is new.
    func queryView(for sid: SpaceID) -> View?
    {
        if didBegin { return view(for: sid) }

        return views[sid]
    }

    /// The view of a space; it is created when the space is new.
    @discardableResult
    func view(for sid: SpaceID) -> View
    {
        if let found = views[sid] { return found }

        let created = View.create(sid: sid)
        views[sid] = created
        return created
    }

    func refreshView(for sid: SpaceID)
    {
        let target = view(for: sid)
        if target.layout == .float { return }

        target.updateAndFlush()
    }

    func markViewInvalid(for sid: SpaceID)
    {
        let target = view(for: sid)
        if target.layout == .float { return }

        target.isValid = false
    }

    func markSpacesInvalid(on did: DisplayID)
    {
        guard let spaceList = did.spaces else { return }

        let sid = did.currentSpace
        for space in spaceList {
            if space == sid, let sid {
                refreshView(for: sid)
            } else {
                markViewInvalid(for: space)
            }
        }
    }

    func markSpacesInvalid()
    {
        for did in DisplayID.all {
            markSpacesInvalid(on: did)
        }
    }

    func refreshApplicationWindows() -> Bool
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

    /// The views of the spaces of a new display keep their names, and take the new ids.
    func handleDisplayAdd(_ did: DisplayID)
    {
        guard let spaceList = did.spaces else { return }

        var viewList: [View?] = views.values.sorted(by: { $0.sid < $1.sid }).map { Optional($0) }
        var uuidList: [CFString?] = viewList.map { $0?.uuid }

        for sid in spaceList {
            guard let uuid = SLS.spaceNameObject(connection_global(), sid) else { continue }

            for j in 0..<viewList.count {
                guard let viewUUID = uuidList[j], let target = viewList[j] else { continue }
                if !CFEqual(viewUUID, uuid) { continue }

                uuidList[j] = nil
                viewList[j] = nil

                views.removeValue(forKey: target.sid)

                labels.replace(id: target.sid, with: sid)

                target.sid = sid
                target.uuid = uuid

                if views[sid] == nil { views[sid] = target }
                break
            }
        }

        currentSpaceID = SpaceID.active
        lastSpaceID = currentSpaceID
    }

    /// The defaults of the space manager and an empty table of views.
    func resetToDefaults()
    {
        layout = .tree
        autoPadding = false
        treeDefaultOrientation = .auto
        treeWorkspaceTabbed = false
        treeAutotiling = false
        labels = LabelList<SpaceID>()
        skipWindowFocusAnimation = false
        //
        // NOTE: The views are keyed by space id.
        //

        views = [:]
    }

    /// Creates the views of every space of every display.
    func begin()
    {
        resetToDefaults()

        for did in DisplayID.all {
            guard let spaceList = did.spaces else { continue }

            for sid in spaceList {
                let created = View.create(sid: sid)
                if views[sid] == nil { views[sid] = created }
            }
        }

        currentSpaceID = SpaceID.active
        lastSpaceID = currentSpaceID
        didBegin = true
    }
}

extension ViewSpacing
{
    /// The default of the space manager, for the views without their own value.
    var spaceManager: ReferenceWritableKeyPath<SpaceManager, Int>
    {
        switch self {
        case .topPadding:    \.topPadding
        case .bottomPadding: \.bottomPadding
        case .leftPadding:   \.leftPadding
        case .rightPadding:  \.rightPadding
        case .windowGap:     \.windowGap
        }
    }
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

/// `space_manager_swap_space_with_space_on_display`: swaps two spaces that are on different displays.
private func spaceManagerSwapSpaceWithSpaceOnDisplay(_ aSid: SpaceID, _ bSid: SpaceID) -> SpaceOperationResult
{
    let wm = WindowManager.shared
    let sm = SpaceManager.shared

    let windowAnimationDuration = wm.windowAnimationDuration
    wm.windowAnimationDuration = 0.0

    let aWindows = aSid.windows(includingMinimized: true) ?? []
    let bWindows = bSid.windows(includingMinimized: true) ?? []

    let aView = sm.views[aSid]!
    let bView = sm.views[bSid]!

    sm.views.removeValue(forKey: aSid)
    sm.views.removeValue(forKey: bSid)

    aView.sid = bSid
    bView.sid = aSid

    let uuid = aView.uuid
    aView.uuid = bView.uuid
    bView.uuid = uuid

    sm.views[aSid] = bView
    sm.views[bSid] = aView

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
        sm.markViewInvalid(for: sid)
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
