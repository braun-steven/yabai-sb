import CoreGraphics
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of space and display events: spaces created, destroyed and changed, and displays
// added, removed, moved and resized.
//

extension EventHandler
{
    func slsSpaceCreated(_ sid: SpaceID)
    {
        let type = SLS.spaceType(SLS.connection, sid)

        if type == 0 || type == 4 {
            debug("EVENT_HANDLER_SLS_SPACE_CREATED: \(Int64(bitPattern: sid.rawValue)), \(type)\n")
            SpaceManager.shared.view(for: sid)
            EventSignals.shared.push(.spaceCreated, .space(sid))
            SpaceManager.shared.scheduleSpaceLayout(after: 1.0, resetPasses: false)
        }
    }

    func slsSpaceDestroyed(_ sid: SpaceID)
    {
        let sm = SpaceManager.shared

        if let view = sm.views[sid] {
            debug("EVENT_HANDLER_SLS_SPACE_DESTROYED: \(Int64(bitPattern: sid.rawValue))\n")
            _ = sm.labels.remove(id: sid)
            sm.views.removeValue(forKey: sid)
            view.destroy()
            EventSignals.shared.push(.spaceDestroyed, .space(sid))
            sm.scheduleSpaceLayout(after: 1.0, resetPasses: false)
        }
    }

    //
    // NOTE: Brings the menu bar, the windows of the applications and the layout of the current space up to
    // date after the active space or display changed.
    //

    private func refreshCurrentSpace()
    {
        let wm = WindowManager.shared
        let sm = SpaceManager.shared

        if Config.current.window.menuBarOpacity != 1.0 {
            let isFullscreen = sm.currentSpaceID.map { $0.isFullscreen } ?? false
            let alpha: Float = isFullscreen ? 1.0 : Config.current.window.menuBarOpacity
            SLS.setMenuBarAlpha(SLS.connection, alpha)
        }

        let view = sm.currentSpaceID.map { sm.view(for: $0) }

        if sm.refreshApplicationWindows() {
            if let focusedWindow = wm.focusedWindow, wm.hasLostFocusedEvent(for: focusedWindow.id) {
                windowDidReceiveFocus(focusedWindow)
                wm.removeLostFocusedEvent(for: focusedWindow.id)
            }
        }

        if !MissionControl.shared.isActive, let sid = sm.currentSpaceID, sid.isUser {
            wm.validateAndCheckForWindows(on: sid)

            if let view, view.isInvalid {
                view.update()
            }

            if let view, view.isDirty {
                view.flush()
            }
        }
    }

    func spaceChanged()
    {
        let sm = SpaceManager.shared

        sm.lastSpaceID = sm.currentSpaceID
        sm.currentSpaceID = SpaceID.active

        debug("EVENT_HANDLER_SPACE_CHANGED: \(Int64(bitPattern: sm.currentSpaceID?.rawValue ?? 0))\n")
        refreshCurrentSpace()

        EventSignals.shared.push(.spaceChanged)
    }

    func displayChanged()
    {
        let dm = DisplayManager.shared
        let sm = SpaceManager.shared

        let newDid = DisplayID.active
        if dm.currentDisplayID == newDid {
            debug("EVENT_HANDLER_DISPLAY_CHANGED: newly activated display \(dm.currentDisplayID?.rawValue ?? 0) was already active (\(newDid?.rawValue ?? 0))! ignoring event..\n")
            return
        }

        dm.lastDisplayID = dm.currentDisplayID
        dm.currentDisplayID = newDid

        sm.lastSpaceID = sm.currentSpaceID
        sm.currentSpaceID = dm.currentDisplayID.flatMap { $0.currentSpace }

        let expectedDisplayID = sm.currentSpaceID.flatMap { $0.display }
        if dm.currentDisplayID != expectedDisplayID {
            debug("EVENT_HANDLER_DISPLAY_CHANGED: \(dm.currentDisplayID?.rawValue ?? 0) \(Int64(bitPattern: sm.currentSpaceID?.rawValue ?? 0)) did not match \(expectedDisplayID?.rawValue ?? 0)! ignoring event..\n")
            return
        }

        debug("EVENT_HANDLER_DISPLAY_CHANGED: \(dm.currentDisplayID?.rawValue ?? 0) \(Int64(bitPattern: sm.currentSpaceID?.rawValue ?? 0))\n")
        refreshCurrentSpace()

        EventSignals.shared.push(.displayChanged)
    }

    func displayAdded(_ did: DisplayID)
    {
        debug("EVENT_HANDLER_DISPLAY_ADDED: \(did)\n")
        SpaceManager.shared.handleDisplayAdd(did)
        WindowManager.shared.handleDisplayAddAndRemove(did)
        SpaceManager.shared.scheduleSpaceLayout(after: 1.0, resetPasses: true)
        EventSignals.shared.push(.displayAdded, .display(did))
    }

    func displayRemoved(_ did: DisplayID)
    {
        debug("EVENT_HANDLER_DISPLAY_REMOVED: \(did)\n")
        _ = DisplayManager.shared.labels.remove(id: did)
        WindowManager.shared.handleDisplayAddAndRemove(DisplayID.main)
        SpaceManager.shared.scheduleSpaceLayout(after: 1.0, resetPasses: true)
        EventSignals.shared.push(.displayRemoved, .display(did))
    }

    func displayMoved(_ did: DisplayID)
    {
        debug("EVENT_HANDLER_DISPLAY_MOVED: \(did)\n")
        SpaceManager.shared.markSpacesInvalid()
        SpaceManager.shared.scheduleSpaceLayout(after: 1.0, resetPasses: true)
        EventSignals.shared.push(.displayMoved, .display(did))
    }

    func displayResized(_ did: DisplayID)
    {
        debug("EVENT_HANDLER_DISPLAY_RESIZED: \(did)\n")
        SpaceManager.shared.markSpacesInvalid(on: did)
        EventSignals.shared.push(.displayResized, .display(did))
    }
}
