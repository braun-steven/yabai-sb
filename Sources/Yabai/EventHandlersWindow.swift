import ApplicationServices
import AppKit
import CPrivate

//
// NOTE: The handlers of window events: windows created, destroyed, focused, moved, resized, minimized
// and retitled, from the accessibility observers and the window server. Ported from src/event_handlers_window.c.
//

/// `EVENT_HANDLER(WINDOW_CREATED)`: the element is the retained reference that the AX observer posted.
@WM func windowCreated(_ element: AXUIElement)
{
    let wm = window_manager_global()

    let windowID = ax_window_id(element)
    if windowID == 0 { return }

    if window_manager_find_window(wm, windowID) != nil { return }

    let windowPid = ax_window_pid(element)
    if windowPid == 0 { return }

    guard let application = window_manager_find_application(wm, windowPid) else { return }

    guard let window = window_manager_create_and_add_window(space_manager_global(), wm, application, element, windowID, true) else { return }

    // NOTE: Subscribe before tiling. AX can return before the window server publishes the final frame;
    // the border then needs the ensuing move/resize notification to leave the window's creation frame.
    update_window_notifications()

    window_manager_remove_one_shot_rules(wm)

    if window_manager_should_manage_window(window) && window_manager_find_managed_window(wm, window) == nil {
        window_manager_manage_window(space_manager_global(), wm, window, window_manager_origin_space(wm, window), 0)
    }

    if window_manager_is_window_eligible(window) {
        eventSignalPush(.windowCreated, signalObject(window))
    }

    border_refresh_window_space(window)
}

/// `EVENT_HANDLER(WINDOW_DESTROYED)`
@WM func windowDestroyed(_ window: Window?)
{
    guard let window, window.id != 0 else {
        debug("EVENT_HANDLER_WINDOW_DESTROYED: window has already been destroyed, ignoring event..\n")
        return
    }

    let wm = window_manager_global()
    let ms = mouse_state_global()

    debug("EVENT_HANDLER_WINDOW_DESTROYED: \(window.application != nil ? window.application.name : "<unknown>") \(window.id)\n")

    if let view = window_manager_find_managed_window(wm, window) {
        let nextFocus = window_manager_tree_focus_candidate(wm, view, window)
        space_manager_untile_window(view, window)
        window_manager_remove_managed_window(wm, window.id)
        window_manager_tree_focus_after_close(wm, view, nextFocus)
    }

    if ms.window == window { ms.window = nil }
    if ms.ffm_window_id == window.id { ms.ffm_window_id = 0 }

    if window.is_eligible {
        eventSignalPush(.windowDestroyed, signalObject(window))
    }

    window_manager_remove_scratchpad_for_window(wm, window, false)
    window_manager_remove_window(wm, window.id)
    window_unobserve(window)
    window_destroy(window)

    if wm.window_border_hide_single {
        border_refresh_space(space_manager_global().current_space_id)
    }

    update_window_notifications()
}

/// `EVENT_HANDLER(WINDOW_FOCUS_DEFERRED)`
@WM func windowFocusDeferred(_ windowID: UInt32)
{
    guard let window = window_manager_find_window(window_manager_global(), windowID), window.application != nil else {
        debug("EVENT_HANDLER_WINDOW_FOCUS_DEFERRED: \(windowID) no longer exists, ignoring event..\n")
        return
    }

    window_manager_focus_window_without_raise_deferred(window)
}

/// `EVENT_HANDLER(WINDOW_FOCUSED)`
@WM func windowFocused(_ windowID: UInt32)
{
    pendingWindowFocus.store(false, ordering: .releasing)
    let wm = window_manager_global()

    guard let window = window_manager_find_window(wm, windowID) else {
        window_manager_add_lost_focused_event(wm, windowID)
        return
    }

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_WINDOW_FOCUSED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window_check_flag(window, WINDOW_MINIMIZE) {
        window_manager_add_lost_focused_event(wm, window.id)
        return
    }

    if !application_is_frontmost(window.application) {
        return
    }

    debug("EVENT_HANDLER_WINDOW_FOCUSED: \(window.application.name) \(window.id)\n")

    if space_manager_global().skip_window_focus_animation {
        let sid = window_space(window.id)
        if sid != 0 && !space_is_visible(sid) {
            SLSSpaceSetFrontPSN(connection_global(), sid, window.application.psn)
            space_manager_focus_space_using_gesture(space_display_id(sid), sid)
        }
    }

    windowDidReceiveFocus(wm, mouse_state_global(), window)
    eventSignalPush(.windowFocused, signalObject(window))
}

/// `EVENT_HANDLER(WINDOW_MOVED)`
@WM func windowMoved(_ windowID: UInt32)
{
    let wm = window_manager_global()
    let ms = mouse_state_global()

    guard let window = window_manager_find_window(wm, windowID) else { return }

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_WINDOW_MOVED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window.application.is_hidden {
        debug("EVENT_HANDLER_WINDOW_MOVED: \(windowID) was moved while the application is hidden, ignoring event..\n")
        return
    }

    let newOrigin = window_ax_origin(window)
    if newOrigin.equalTo(window.frame.origin) {
        debug("EVENT_HANDLER_WINDOW_MOVED:DEBOUNCED \(window.application.name) \(window.id)\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_MOVED: \(window.application.name) \(window.id)\n")
    eventSignalPush(.windowMoved, signalObject(window))
    let windowedFullscreen = window.windowed_frame.equalTo(window.frame)
    window.frame.origin = newOrigin

    if !windowedFullscreen {
        window_clear_flag(window, WINDOW_WINDOWED)

        if ms.window == nil || ms.window != window {
            if let view = window_manager_find_managed_window(wm, window), tree_window_needs_flush(view, window.id, window.frame) {
                view_flush(view)
            }
        }
    }
}

/// `EVENT_HANDLER(WINDOW_RESIZED)`
@WM func windowResized(_ windowID: UInt32)
{
    let wm = window_manager_global()
    let ms = mouse_state_global()

    guard let window = window_manager_find_window(wm, windowID) else { return }

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_WINDOW_RESIZED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window.application.is_hidden {
        debug("EVENT_HANDLER_WINDOW_RESIZED: \(windowID) was resized while the application is hidden, ignoring event..\n")
        return
    }

    let newFrame = window_ax_frame(window)
    if newFrame.equalTo(window.frame) {
        debug("EVENT_HANDLER_WINDOW_RESIZED:DEBOUNCED \(window.application.name) \(window.id)\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_RESIZED: \(window.application.name) \(window.id)\n")
    eventSignalPush(.windowResized, signalObject(window))

    let wasFullscreen = window_check_flag(window, WINDOW_FULLSCREEN)

    let isFullscreen = window_is_fullscreen(window)
    if isFullscreen {
        window_set_flag(window, WINDOW_FULLSCREEN)
    } else {
        window_clear_flag(window, WINDOW_FULLSCREEN)
    }

    if wasFullscreen != isFullscreen {
        window_refresh_ax_properties(window)
    }

    let windowedFullscreen = window.windowed_frame.equalTo(window.frame)
    window.frame = newFrame

    if wasFullscreen != isFullscreen { border_refresh_window_space(window) }

    if !wasFullscreen && isFullscreen {
        if let view = window_manager_find_managed_window(wm, window) {
            window_manager_unmanage_window(wm, view, window)
        }
    } else if wasFullscreen && !isFullscreen {
        window_manager_wait_for_native_fullscreen_transition()

        if window_manager_should_manage_window(window) && window_manager_find_managed_window(wm, window) == nil {
            window_manager_manage_window(space_manager_global(), wm, window, window_space(window.id), 0)
        }
    } else {
        if ms.current_action == MOUSE_MODE_MOVE && ms.window == window {
            ms.window_frame.size = ms.window.frame.size
        }

        if !windowedFullscreen {
            window_clear_flag(window, WINDOW_WINDOWED)

            if ms.window == nil || ms.window != window {
                if let view = window_manager_find_managed_window(wm, window), tree_window_needs_flush(view, window.id, newFrame) {
                    view_flush(view)
                }
            }
        }
    }
}

/// `EVENT_HANDLER(WINDOW_MINIMIZED)`
@WM func windowMinimized(_ window: Window)
{
    let wm = window_manager_global()

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_WINDOW_MINIMIZED: \(window.id) has been marked invalid by the system, ignoring event..\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_MINIMIZED: \(window.application.name) \(window.id)\n")
    window_set_flag(window, WINDOW_MINIMIZE)

    window_refresh_ax_properties(window)

    let view = window_manager_find_managed_window(wm, window)
    let nextFocus = view.map { window_manager_tree_focus_candidate(wm, $0, window) } ?? 0

    if window.id == wm.last_window_id {
        wm.last_window_id = wm.focused_window_id
    }

    if let view {
        window_manager_unmanage_window(wm, view, window)
        window_manager_tree_focus_after_close(wm, view, nextFocus)
    }

    border_refresh_window_space(window)
    eventSignalPush(.windowMinimized, signalObject(window))
}

/// `EVENT_HANDLER(WINDOW_DEMINIMIZED)`
@WM func windowDeminimized(_ window: Window)
{
    let wm = window_manager_global()

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: \(window.id) has been marked invalid by the system, ignoring event..\n")
        window_manager_remove_lost_focused_event(wm, window.id)
        return
    }

    window_clear_flag(window, WINDOW_MINIMIZE)

    window_refresh_ax_properties(window)

    let sid = space_manager_active_space()
    if space_manager_is_window_on_space(sid, window) {
        debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: window \(window.application.name) \(window.id) is deminimized on active space\n")
        if window_manager_should_manage_window(window) && window_manager_find_managed_window(wm, window) == nil {
            let lastWindow = window_manager_find_window(wm, wm.last_window_id)
            let insertionPoint = if let lastWindow, lastWindow.application.pid != window.application.pid { lastWindow.id } else { UInt32(0) }
            window_manager_manage_window(space_manager_global(), wm, window, sid, insertionPoint)
        }
    } else {
        debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: window \(window.application.name) \(window.id) is deminimized on inactive space\n")
    }

    if window_manager_find_lost_focused_event(wm, window.id) {
        EventLoop.post(.windowFocused(windowID: window.id))
        window_manager_remove_lost_focused_event(wm, window.id)
    }

    border_refresh_window_space(window)
    eventSignalPush(.windowDeminimized, signalObject(window))
}

/// `EVENT_HANDLER(WINDOW_TITLE_CHANGED)`
@WM func windowTitleChanged(_ windowID: UInt32)
{
    guard let window = window_manager_find_window(window_manager_global(), windowID) else { return }

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_WINDOW_TITLE_CHANGED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_TITLE_CHANGED: \(window.application.name) \(window.id)\n")

    window.title = window_title(window)
    tab_bar_refresh_for_window(window.id)

    eventSignalPush(.windowTitleChanged, signalObject(window))
}

/// `EVENT_HANDLER(SLS_WINDOW_ORDERED)`
@WM func slsWindowOrdered(_ wid: UInt32)
{
    debug("EVENT_HANDLER_SLS_WINDOW_ORDERED: \(wid)\n")
    tab_bar_order(wid)
}

/// `EVENT_HANDLER(SLS_WINDOW_DESTROYED)`
@WM func slsWindowDestroyed(_ wid: UInt32)
{
    debug("EVENT_HANDLER_SLS_WINDOW_DESTROYED: \(wid)\n")

    guard let window = window_manager_find_window(window_manager_global(), wid) else { return }

    //
    // NOTE: The AX destroyed notification for the same window can arrive on the main thread at any
    // time. Claim the window like that callback does, so that it bails out instead of posting a second
    // WINDOW_DESTROYED event for memory that we are about to free.
    //

    if !window_invalidate(window) {
        debug("EVENT_HANDLER_SLS_WINDOW_DESTROYED: \(wid) has been marked invalid by the system, ignoring event..\n")
        return
    }

    windowDestroyed(window)
}
