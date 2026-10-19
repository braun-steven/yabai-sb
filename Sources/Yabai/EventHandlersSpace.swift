import CoreGraphics
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of space and display events: spaces created, destroyed and changed, and displays
// added, removed, moved and resized. Ported from src/event_handlers_space.c.
//

//
// NOTE: The signals of these events get the id as their context pointer, as the C producers posted it.
//

private func signalContext(_ id: SpaceID) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: UInt(id.rawValue))
}

private func signalContext(_ id: DisplayID) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: Int(id.rawValue))
}

/// `EVENT_HANDLER(SLS_SPACE_CREATED)`
@WM func slsSpaceCreated(_ sid: SpaceID)
{
    let type = SLSSpaceGetType(connection_global(), sid.rawValue)

    if type == 0 || type == 4 {
        debug("EVENT_HANDLER_SLS_SPACE_CREATED: \(Int64(bitPattern: sid.rawValue)), \(type)\n")
        space_manager_find_view(space_manager_global(), sid)
        eventSignalPush(.spaceCreated, signalContext(sid))
        space_layout_schedule(1.0, false)
    }
}

/// `EVENT_HANDLER(SLS_SPACE_DESTROYED)`
@WM func slsSpaceDestroyed(_ sid: SpaceID)
{
    let sm = space_manager_global()

    if let view = sm.view[sid] {
        debug("EVENT_HANDLER_SLS_SPACE_DESTROYED: \(Int64(bitPattern: sid.rawValue))\n")
        _ = sm.labels.remove(id: sid)
        sm.view.removeValue(forKey: sid)
        view.destroy()
        eventSignalPush(.spaceDestroyed, signalContext(sid))
        space_layout_schedule(1.0, false)
    }
}

//
// NOTE: Brings the menu bar, the windows of the applications and the layout of the current space up to
// date after the active space or display changed.
//

@WM private func refreshCurrentSpace()
{
    let wm = WindowManager.shared
    let sm = space_manager_global()

    if wm.menuBarOpacity != 1.0 {
        let isFullscreen = sm.current_space_id.map { $0.isFullscreen } ?? false
        let alpha: Float = isFullscreen ? 1.0 : wm.menuBarOpacity
        SLSSetMenuBarInsetAndAlpha(connection_global(), 0, 1, alpha)
    }

    let view = sm.current_space_id.map { space_manager_find_view(sm, $0) }

    if space_manager_refresh_application_windows(sm) {
        if let focusedWindow = wm.focusedWindow, wm.hasLostFocusedEvent(for: focusedWindow.id) {
            windowDidReceiveFocus(wm, mouse_state_global(), focusedWindow)
            wm.removeLostFocusedEvent(for: focusedWindow.id)
        }
    }

    if !MissionControl.shared.isActive, let sid = sm.current_space_id, sid.isUser {
        wm.validateAndCheckForWindows(on: sid)

        if let view, view.isInvalid {
            view.update()
        }

        if let view, view.isDirty {
            view.flush()
        }
    }
}

/// `EVENT_HANDLER(SPACE_CHANGED)`
@WM func spaceChanged()
{
    let sm = space_manager_global()

    sm.last_space_id = sm.current_space_id
    sm.current_space_id = SpaceID.active

    debug("EVENT_HANDLER_SPACE_CHANGED: \(Int64(bitPattern: sm.current_space_id?.rawValue ?? 0))\n")
    refreshCurrentSpace()

    eventSignalPush(.spaceChanged, nil)
}

/// `EVENT_HANDLER(DISPLAY_CHANGED)`
@WM func displayChanged()
{
    let dm = DisplayManager.shared
    let sm = space_manager_global()

    let newDid = DisplayID.active
    if dm.currentDisplayID == newDid {
        debug("EVENT_HANDLER_DISPLAY_CHANGED: newly activated display \(dm.currentDisplayID?.rawValue ?? 0) was already active (\(newDid?.rawValue ?? 0))! ignoring event..\n")
        return
    }

    dm.lastDisplayID = dm.currentDisplayID
    dm.currentDisplayID = newDid

    sm.last_space_id = sm.current_space_id
    sm.current_space_id = dm.currentDisplayID.flatMap { $0.currentSpace }

    let expectedDisplayID = sm.current_space_id.flatMap { $0.display }
    if dm.currentDisplayID != expectedDisplayID {
        debug("EVENT_HANDLER_DISPLAY_CHANGED: \(dm.currentDisplayID?.rawValue ?? 0) \(Int64(bitPattern: sm.current_space_id?.rawValue ?? 0)) did not match \(expectedDisplayID?.rawValue ?? 0)! ignoring event..\n")
        return
    }

    debug("EVENT_HANDLER_DISPLAY_CHANGED: \(dm.currentDisplayID?.rawValue ?? 0) \(Int64(bitPattern: sm.current_space_id?.rawValue ?? 0))\n")
    refreshCurrentSpace()

    eventSignalPush(.displayChanged, nil)
}

/// `EVENT_HANDLER(DISPLAY_ADDED)`
@WM func displayAdded(_ did: DisplayID)
{
    debug("EVENT_HANDLER_DISPLAY_ADDED: \(did)\n")
    space_manager_handle_display_add(space_manager_global(), did)
    WindowManager.shared.handleDisplayAddAndRemove(did)
    space_layout_schedule(1.0, true)
    eventSignalPush(.displayAdded, signalContext(did))
}

/// `EVENT_HANDLER(DISPLAY_REMOVED)`
@WM func displayRemoved(_ did: DisplayID)
{
    debug("EVENT_HANDLER_DISPLAY_REMOVED: \(did)\n")
    _ = DisplayManager.shared.labels.remove(id: did)
    WindowManager.shared.handleDisplayAddAndRemove(DisplayID.main)
    space_layout_schedule(1.0, true)
    eventSignalPush(.displayRemoved, signalContext(did))
}

/// `EVENT_HANDLER(DISPLAY_MOVED)`
@WM func displayMoved(_ did: DisplayID)
{
    debug("EVENT_HANDLER_DISPLAY_MOVED: \(did)\n")
    space_manager_mark_spaces_invalid(space_manager_global())
    space_layout_schedule(1.0, true)
    eventSignalPush(.displayMoved, signalContext(did))
}

/// `EVENT_HANDLER(DISPLAY_RESIZED)`
@WM func displayResized(_ did: DisplayID)
{
    debug("EVENT_HANDLER_DISPLAY_RESIZED: \(did)\n")
    space_manager_mark_spaces_invalid_for_display(space_manager_global(), did)
    eventSignalPush(.displayResized, signalContext(did))
}
