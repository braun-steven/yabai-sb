import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The commands that focus, switch, swap, move, create and destroy spaces, mostly through the scripting addition.
//

extension SpaceManager
{
    func toggleMissionControl(on sid: SpaceID)
    {
        try? focusSpace(sid)
        CoreDock.sendNotification("com.apple.expose.awake")
    }

    func toggleShowDesktop(on sid: SpaceID)
    {
        try? focusSpace(sid)
        CoreDock.sendNotification("com.apple.showdesktop.awake")
    }

    /// Swaps two spaces that are on different displays.
    private func swapSpaceAcrossDisplays(_ aSid: SpaceID, with bSid: SpaceID)
    {
        WindowManager.shared.withoutAnimations {
            let aWindows = aSid.windows(includingMinimized: true) ?? []
            let bWindows = bSid.windows(includingMinimized: true) ?? []

            let aView = views[aSid]!
            let bView = views[bSid]!

            views[aSid] = nil
            views[bSid] = nil

            aView.sid = bSid
            bView.sid = aSid

            let uuid = aView.uuid
            aView.uuid = bView.uuid
            bView.uuid = uuid

            views[aSid] = bView
            views[bSid] = aView

            if !aWindows.isEmpty {
                bSid.moveWindows(aWindows)
            }

            if !bWindows.isEmpty {
                aSid.moveWindows(bWindows)
            }

            labels.swap(aSid, bSid)

            aView.update()
            bView.update()

            aView.flush()
            bView.flush()
        }
    }

    func swapSpace(_ actingSid: SpaceID, with selectorSid: SpaceID) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }

        let actingDid = actingSid.display
        let selectorDid = selectorSid.display

        if actingSid == selectorSid { throw .sameSpace }
        if actingDid != selectorDid {
            swapSpaceAcrossDisplays(actingSid, with: selectorSid)
            return
        }

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
            success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
        } else if !actingSidIsFirst && selectorSidIsFirst && actingMCI - selectorMCI == 1 {
            success = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: selectorSid == SpaceID.active)
        } else if actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
            success = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: false)
            let second = ScriptingAddition.shared.moveSpace(actingSid, after: selectorPrevSid, focus: actingSid == SpaceID.active)
            success = success && second
        } else if !actingSidIsFirst && selectorSidIsFirst, let actingPrevSid {
            success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
            let second = ScriptingAddition.shared.moveSpace(selectorSid, after: actingPrevSid, focus: false)
            success = success && second
        } else if !actingSidIsFirst && !selectorSidIsFirst, let actingPrevSid, let selectorPrevSid {
            if actingMCI > selectorMCI {
                success = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: false)
                let second = ScriptingAddition.shared.moveSpace(actingSid, after: selectorPrevSid, focus: actingSid == SpaceID.active)
                success = success && second
            } else {
                success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
                let second = ScriptingAddition.shared.moveSpace(selectorSid, after: actingPrevSid, focus: false)
                success = success && second
            }
        }

        if !success { throw .scriptingAdditionFailed }
    }

    func moveSpace(_ actingSid: SpaceID, to selectorSid: SpaceID) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }

        let actingDid = actingSid.display
        let selectorDid = selectorSid.display

        if actingSid == selectorSid { throw .sameSpace }
        if actingDid != selectorDid { throw .sameDisplay }

        let actingPrevSid = actingSid.previous
        let selectorPrevSid = selectorSid.previous

        let actingPrevDid = actingPrevSid.flatMap { $0.display }
        let selectorPrevDid = selectorPrevSid.flatMap { $0.display }

        let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
        let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid
        var success = true

        if actingSidIsFirst && !selectorSidIsFirst {
            success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
        } else if !actingSidIsFirst && selectorSidIsFirst {
            success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
            let second = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: false)
            success = success && second
        } else if !actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
            if actingSid.missionControlIndex > selectorSid.missionControlIndex {
                success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorPrevSid, focus: actingSid == SpaceID.active)
            } else {
                success = ScriptingAddition.shared.moveSpace(actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
            }
        }

        if !success { throw .scriptingAdditionFailed }
    }

    func moveSpace(_ sid: SpaceID?, toDisplay did: DisplayID) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }
        guard let sid else { throw .missingSource }

        let sDid = sid.display
        if sDid == did { throw .invalidDestination }

        if sid.isLastUserSpace { throw .invalidSource }

        guard let dSid = did.currentSpace else { throw .missingDestination }

        let isActive = sid == SpaceID.active

        //
        // NOTE: A visible space must be replaced on its display before the move, even when it is
        // not focused. Otherwise the WindowServer keeps it shown on the destination display next
        // to that display's current space, and its menubar stays on screen above the real one.
        //

        guard let spaceList = sDid.flatMap({ $0.spaces }) else { throw .missingSource }

        let user = spaceList.map { $0.isUser }
        let visibleSid = sDid.flatMap { $0.currentSpace }
        let replacementSid = visibleSid.flatMap { SpaceList.moveReplacement(spaces: spaceList, user: user, sid: sid, visible: $0) }

        //
        // NOTE: The scripting addition takes a plain space id, and it packs nil as 0, "no replacement space".
        //
        if ScriptingAddition.shared.moveSpace(sid, toDisplayOf: dSid, previous: replacementSid, focus: isActive) {
            markViewInvalid(for: sid)
            if isActive {
                try? focusSpace(sid)
            }
            return
        }

        throw .scriptingAdditionFailed
    }

    /// Switches spaces with the gestures of the Dock, without its animation.
    @discardableResult
    func focusSpaceUsingGesture(_ newSid: SpaceID, on newDid: DisplayID) -> Bool
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

    func focusSpace(_ sid: SpaceID) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }

        let curSid = SpaceID.active
        if curSid == sid { throw .sameSpace }

        let curDid = curSid.flatMap { $0.display }
        let newDid = sid.display
        let focusDisplay = curDid != newDid

        if ScriptingAddition.shared.focusSpace(sid) {
            if focusDisplay, let newDid {
                newDid.focus(space: sid)
            }
        } else if let newDid {
            _ = focusSpaceUsingGesture(sid, on: newDid)
        }
    }

    func switchSpace(to sid: SpaceID) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }

        guard let curSid = SpaceID.active else { throw .missingSource }
        if curSid == sid { throw .sameSpace }

        let curDid = curSid.display
        let did = sid.display

        if curDid != did {
            swapSpaceAcrossDisplays(curSid, with: sid)
            if let curDid { curDid.focus(space: curSid) }
            return
        }

        if !ScriptingAddition.shared.focusSpace(sid) { throw .scriptingAdditionFailed }
    }

    func destroySpace(_ sid: SpaceID?) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }

        guard let sid else { throw .missingSource }
        if !sid.isUser { throw .invalidType }
        if sid.isLastUserSpace { throw .invalidSource }

        let did = sid.display
        let firstSid = did?.spaces?.first(where: { $0.isUser })

        if !ScriptingAddition.shared.destroySpace(sid) { throw .scriptingAdditionFailed }

        if let firstSid {
            WindowManager.shared.validateAndCheckForWindows(on: firstSid)
        }
    }

    /// Creates a space on the display of sid.
    func addSpace(onDisplayOf sid: SpaceID?) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }
        guard let sid else { throw .missingSource }

        if !ScriptingAddition.shared.createSpace(sid) { throw .scriptingAdditionFailed }
    }
}
