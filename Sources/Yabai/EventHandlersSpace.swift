import CoreGraphics
import YabaiC

//
// NOTE: The handlers of space and display events: spaces created, destroyed and changed, and displays
// added, removed, moved and resized. Ported from src/event_handlers_space.c.
//

//
// NOTE: The signals of these events get the id as their context pointer, as the C producers posted it.
//

private func signalContext(_ id: UInt64) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: UInt(id))
}

private func signalContext(_ id: UInt32) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: Int(id))
}

/// `EVENT_HANDLER(SLS_SPACE_CREATED)`
@WM func slsSpaceCreated(_ sid: UInt64)
{
    let type = SLSSpaceGetType(connection_global(), sid)

    if type == 0 || type == 4 {
        debug("EVENT_HANDLER_SLS_SPACE_CREATED: \(Int64(bitPattern: sid)), \(type)\n")
        space_manager_find_view(space_manager_global(), sid)
        eventSignalPush(.spaceCreated, signalContext(sid))
        space_layout_schedule(1.0, false)
    }
}

/// `EVENT_HANDLER(SLS_SPACE_DESTROYED)`
@WM func slsSpaceDestroyed(_ sid: UInt64)
{
    let sm = space_manager_global()

    if let view = sm.view.find(sid) {
        debug("EVENT_HANDLER_SLS_SPACE_DESTROYED: \(Int64(bitPattern: sid))\n")
        _ = label_remove_id(sm.labels, sid)
        sm.view.remove(sid)
        view_destroy(view)
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
    let wm = window_manager_global()
    let sm = space_manager_global()

    if wm.menubar_opacity != 1.0 {
        let alpha: Float = space_is_fullscreen(sm.current_space_id) ? 1.0 : wm.menubar_opacity
        SLSSetMenuBarInsetAndAlpha(connection_global(), 0, 1, alpha)
    }

    let view = space_manager_find_view(sm, sm.current_space_id)

    if space_manager_refresh_application_windows(sm) {
        if let focusedWindow = window_manager_focused_window(wm), window_manager_find_lost_focused_event(wm, focusedWindow.pointee.id) {
            windowDidReceiveFocus(wm, mouse_state_global(), focusedWindow)
            window_manager_remove_lost_focused_event(wm, focusedWindow.pointee.id)
        }
    }

    if !mission_control_is_active() && space_is_user(sm.current_space_id) {
        window_manager_validate_and_check_for_windows_on_space(sm, wm, sm.current_space_id)

        if view_is_invalid(view) {
            view_update(view)
        }

        if view_is_dirty(view) {
            view_flush(view)
        }
    }
}

/// `EVENT_HANDLER(SPACE_CHANGED)`
@WM func spaceChanged()
{
    let sm = space_manager_global()

    sm.last_space_id = sm.current_space_id
    sm.current_space_id = space_manager_active_space()

    debug("EVENT_HANDLER_SPACE_CHANGED: \(Int64(bitPattern: sm.current_space_id))\n")
    refreshCurrentSpace()

    eventSignalPush(.spaceChanged, nil)
}

/// `EVENT_HANDLER(DISPLAY_CHANGED)`
@WM func displayChanged()
{
    let dm = display_manager_global()
    let sm = space_manager_global()

    let newDid = display_manager_active_display_id()
    if dm.current_display_id == newDid {
        debug("EVENT_HANDLER_DISPLAY_CHANGED: newly activated display \(dm.current_display_id) was already active (\(newDid))! ignoring event..\n")
        return
    }

    dm.last_display_id = dm.current_display_id
    dm.current_display_id = newDid

    sm.last_space_id = sm.current_space_id
    sm.current_space_id = display_space_id(dm.current_display_id)

    let expectedDisplayID = space_display_id(sm.current_space_id)
    if dm.current_display_id != expectedDisplayID {
        debug("EVENT_HANDLER_DISPLAY_CHANGED: \(dm.current_display_id) \(Int64(bitPattern: sm.current_space_id)) did not match \(expectedDisplayID)! ignoring event..\n")
        return
    }

    debug("EVENT_HANDLER_DISPLAY_CHANGED: \(dm.current_display_id) \(Int64(bitPattern: sm.current_space_id))\n")
    refreshCurrentSpace()

    eventSignalPush(.displayChanged, nil)
}

/// `EVENT_HANDLER(DISPLAY_ADDED)`
@WM func displayAdded(_ did: UInt32)
{
    debug("EVENT_HANDLER_DISPLAY_ADDED: \(did)\n")
    space_manager_handle_display_add(space_manager_global(), did)
    window_manager_handle_display_add_and_remove(space_manager_global(), window_manager_global(), did)
    space_layout_schedule(1.0, true)
    eventSignalPush(.displayAdded, signalContext(did))
}

/// `EVENT_HANDLER(DISPLAY_REMOVED)`
@WM func displayRemoved(_ did: UInt32)
{
    debug("EVENT_HANDLER_DISPLAY_REMOVED: \(did)\n")
    _ = label_remove_id(display_manager_global().labels, UInt64(did))
    window_manager_handle_display_add_and_remove(space_manager_global(), window_manager_global(), display_manager_main_display_id())
    space_layout_schedule(1.0, true)
    eventSignalPush(.displayRemoved, signalContext(did))
}

/// `EVENT_HANDLER(DISPLAY_MOVED)`
@WM func displayMoved(_ did: UInt32)
{
    debug("EVENT_HANDLER_DISPLAY_MOVED: \(did)\n")
    space_manager_mark_spaces_invalid(space_manager_global())
    space_layout_schedule(1.0, true)
    eventSignalPush(.displayMoved, signalContext(did))
}

/// `EVENT_HANDLER(DISPLAY_RESIZED)`
@WM func displayResized(_ did: UInt32)
{
    debug("EVENT_HANDLER_DISPLAY_RESIZED: \(did)\n")
    space_manager_mark_spaces_invalid_for_display(space_manager_global(), did)
    eventSignalPush(.displayResized, signalContext(did))
}
