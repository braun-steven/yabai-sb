import ApplicationServices
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of window events: windows created, destroyed, focused, moved, resized, minimized
// and retitled, from the accessibility observers and the window server. Ported from src/event_handlers_window.c.
//

/// `EVENT_HANDLER(WINDOW_CREATED)`: the element is the retained reference that the AX observer posted.
@WM func windowCreated(_ element: AXUIElement)
{
    let wm = WindowManager.shared

    guard let windowID = ax_window_id(element) else { return }

    if wm.window(for: windowID) != nil { return }

    let windowPid = ax_window_pid(element)
    if windowPid == 0 { return }

    guard let application = wm.application(for: windowPid) else { return }

    guard let window = wm.createAndAddWindow(application, reference: element, id: windowID, includingOneShotRules: true) else { return }

    // NOTE: Subscribe before tiling. AX can return before the window server publishes the final frame;
    // the border then needs the ensuing move/resize notification to leave the window's creation frame.
    update_window_notifications()

    wm.removeOneShotRules()

    if window.shouldBeManaged && wm.managedView(for: window) == nil {
        if let sid = wm.originSpace(for: window) { wm.manageWindow(window, on: sid, inserting: nil) }
    }

    if window.isEligibleForManagement {
        eventSignalPush(.windowCreated, signalObject(window))
    }

    border_refresh_window_space(window)
}

/// `EVENT_HANDLER(WINDOW_DESTROYED)`
@WM func windowDestroyed(_ window: Window?)
{
    guard let window, !window.isDestroyed else {
        debug("EVENT_HANDLER_WINDOW_DESTROYED: window has already been destroyed, ignoring event..\n")
        return
    }

    let wm = WindowManager.shared
    let ms = mouse_state_global()

    debug("EVENT_HANDLER_WINDOW_DESTROYED: \(window.application != nil ? window.application.name : "<unknown>") \(window.id)\n")

    if let view = wm.managedView(for: window) {
        let nextFocus = wm.treeFocusCandidate(in: view, for: window)
        space_manager_untile_window(view, window)
        wm.removeManagedWindow(window.id)
        wm.treeFocusAfterClose(in: view, windowID: nextFocus)
    }

    if ms.window == window { ms.window = nil }
    if ms.ffm_window_id == window.id { ms.ffm_window_id = nil }

    if window.isEligible {
        eventSignalPush(.windowDestroyed, signalObject(window))
    }

    wm.removeScratchpad(from: window, unfloat: false)
    wm.removeWindow(window.id)
    window.unobserve()
    window.destroy()

    if wm.windowBorderHideSingle {
        border_refresh_space(space_manager_global().current_space_id)
    }

    update_window_notifications()
}

/// `EVENT_HANDLER(WINDOW_FOCUS_DEFERRED)`
@WM func windowFocusDeferred(_ windowID: WindowID)
{
    guard let window = WindowManager.shared.window(for: windowID), window.application != nil else {
        debug("EVENT_HANDLER_WINDOW_FOCUS_DEFERRED: \(windowID) no longer exists, ignoring event..\n")
        return
    }

    WindowManager.shared.focusWithoutRaiseDeferred(window)
}

/// `EVENT_HANDLER(WINDOW_FOCUSED)`
@WM func windowFocused(_ windowID: WindowID?)
{
    pendingWindowFocus.store(false, ordering: .releasing)
    let wm = WindowManager.shared

    // NOTE: A focus event without a window id (the element is not a window) only clears the pending focus.
    guard let windowID else { return }

    guard let window = wm.window(for: windowID) else {
        wm.addLostFocusedEvent(for: windowID)
        return
    }

    if !window.isValid {
        debug("EVENT_HANDLER_WINDOW_FOCUSED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window.isMinimized {
        wm.addLostFocusedEvent(for: window.id)
        return
    }

    if !window.application.isFrontmost {
        return
    }

    debug("EVENT_HANDLER_WINDOW_FOCUSED: \(window.application.name) \(window.id)\n")

    if space_manager_global().skip_window_focus_animation {
        if let sid = window.id.space, !space_is_visible(sid) {
            SLSSpaceSetFrontPSN(connection_global(), sid.rawValue, window.application.psn)
            if let did = space_display_id(sid) {
                space_manager_focus_space_using_gesture(did, sid)
            }
        }
    }

    windowDidReceiveFocus(wm, mouse_state_global(), window)
    eventSignalPush(.windowFocused, signalObject(window))
}

/// `EVENT_HANDLER(WINDOW_MOVED)`
@WM func windowMoved(_ windowID: WindowID)
{
    let wm = WindowManager.shared
    let ms = mouse_state_global()

    guard let window = wm.window(for: windowID) else { return }

    if !window.isValid {
        debug("EVENT_HANDLER_WINDOW_MOVED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window.application.isHidden {
        debug("EVENT_HANDLER_WINDOW_MOVED: \(windowID) was moved while the application is hidden, ignoring event..\n")
        return
    }

    let newOrigin = window.axOrigin
    if newOrigin.equalTo(window.frame.origin) {
        debug("EVENT_HANDLER_WINDOW_MOVED:DEBOUNCED \(window.application.name) \(window.id)\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_MOVED: \(window.application.name) \(window.id)\n")
    eventSignalPush(.windowMoved, signalObject(window))
    let windowedFullscreen = window.windowedFrame.equalTo(window.frame)
    window.frame.origin = newOrigin

    if !windowedFullscreen {
        window.isWindowed = false

        if ms.window == nil || ms.window != window {
            if let view = wm.managedView(for: window), view.needsFlush(windowID: window.id, frame: window.frame) {
                view.flush()
            }
        }
    }
}

/// `EVENT_HANDLER(WINDOW_RESIZED)`
@WM func windowResized(_ windowID: WindowID)
{
    let wm = WindowManager.shared
    let ms = mouse_state_global()

    guard let window = wm.window(for: windowID) else { return }

    if !window.isValid {
        debug("EVENT_HANDLER_WINDOW_RESIZED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window.application.isHidden {
        debug("EVENT_HANDLER_WINDOW_RESIZED: \(windowID) was resized while the application is hidden, ignoring event..\n")
        return
    }

    let newFrame = window.axFrame
    if newFrame.equalTo(window.frame) {
        debug("EVENT_HANDLER_WINDOW_RESIZED:DEBOUNCED \(window.application.name) \(window.id)\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_RESIZED: \(window.application.name) \(window.id)\n")
    eventSignalPush(.windowResized, signalObject(window))

    let wasFullscreen = window.isFullscreen

    let isFullscreen = window.reportsFullscreen
    window.isFullscreen = isFullscreen

    if wasFullscreen != isFullscreen {
        window.refreshAXProperties()
    }

    let windowedFullscreen = window.windowedFrame.equalTo(window.frame)
    window.frame = newFrame

    if wasFullscreen != isFullscreen { border_refresh_window_space(window) }

    if !wasFullscreen && isFullscreen {
        if let view = wm.managedView(for: window) {
            wm.unmanageWindow(window, from: view)
        }
    } else if wasFullscreen && !isFullscreen {
        wm.waitForNativeFullscreenTransition()

        if window.shouldBeManaged && wm.managedView(for: window) == nil {
            if let sid = window.id.space { wm.manageWindow(window, on: sid, inserting: nil) }
        }
    } else {
        if ms.current_action == .move && ms.window == window {
            ms.window_frame.size = ms.window.frame.size
        }

        if !windowedFullscreen {
            window.isWindowed = false

            if ms.window == nil || ms.window != window {
                if let view = wm.managedView(for: window), view.needsFlush(windowID: window.id, frame: newFrame) {
                    view.flush()
                }
            }
        }
    }
}

/// `EVENT_HANDLER(WINDOW_MINIMIZED)`
@WM func windowMinimized(_ window: Window)
{
    let wm = WindowManager.shared

    if !window.isValid {
        debug("EVENT_HANDLER_WINDOW_MINIMIZED: \(window.id) has been marked invalid by the system, ignoring event..\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_MINIMIZED: \(window.application.name) \(window.id)\n")
    window.isMinimized = true

    window.refreshAXProperties()

    let view = wm.managedView(for: window)
    let nextFocus = view.flatMap { wm.treeFocusCandidate(in: $0, for: window) }

    if window.id == wm.lastWindowID {
        wm.lastWindowID = wm.focusedWindowID
    }

    if let view {
        wm.unmanageWindow(window, from: view)
        wm.treeFocusAfterClose(in: view, windowID: nextFocus)
    }

    border_refresh_window_space(window)
    eventSignalPush(.windowMinimized, signalObject(window))
}

/// `EVENT_HANDLER(WINDOW_DEMINIMIZED)`
@WM func windowDeminimized(_ window: Window)
{
    let wm = WindowManager.shared

    if !window.isValid {
        debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: \(window.id) has been marked invalid by the system, ignoring event..\n")
        wm.removeLostFocusedEvent(for: window.id)
        return
    }

    window.isMinimized = false

    window.refreshAXProperties()

    let sid = space_manager_active_space()
    if let sid, space_manager_is_window_on_space(sid, window) {
        debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: window \(window.application.name) \(window.id) is deminimized on active space\n")
        if window.shouldBeManaged && wm.managedView(for: window) == nil {
            let lastWindow = wm.lastWindowID.flatMap { wm.window(for: $0) }
            let insertionPoint: WindowID? = if let lastWindow, lastWindow.application.pid != window.application.pid { lastWindow.id } else { nil }
            wm.manageWindow(window, on: sid, inserting: insertionPoint)
        }
    } else {
        debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: window \(window.application.name) \(window.id) is deminimized on inactive space\n")
    }

    if wm.hasLostFocusedEvent(for: window.id) {
        EventLoop.post(.windowFocused(windowID: window.id))
        wm.removeLostFocusedEvent(for: window.id)
    }

    border_refresh_window_space(window)
    eventSignalPush(.windowDeminimized, signalObject(window))
}

/// `EVENT_HANDLER(WINDOW_TITLE_CHANGED)`
@WM func windowTitleChanged(_ windowID: WindowID)
{
    guard let window = WindowManager.shared.window(for: windowID) else { return }

    if !window.isValid {
        debug("EVENT_HANDLER_WINDOW_TITLE_CHANGED: \(windowID) has been marked invalid by the system, ignoring event..\n")
        return
    }

    debug("EVENT_HANDLER_WINDOW_TITLE_CHANGED: \(window.application.name) \(window.id)\n")

    window.title = window.currentTitle()
    tab_bar_refresh_for_window(window.id)

    eventSignalPush(.windowTitleChanged, signalObject(window))
}

/// `EVENT_HANDLER(SLS_WINDOW_ORDERED)`
@WM func slsWindowOrdered(_ wid: WindowID)
{
    debug("EVENT_HANDLER_SLS_WINDOW_ORDERED: \(wid)\n")
    tab_bar_order(wid)
}

/// `EVENT_HANDLER(SLS_WINDOW_DESTROYED)`
@WM func slsWindowDestroyed(_ wid: WindowID)
{
    debug("EVENT_HANDLER_SLS_WINDOW_DESTROYED: \(wid)\n")

    guard let window = WindowManager.shared.window(for: wid) else { return }

    //
    // NOTE: The AX destroyed notification for the same window can arrive on the main thread at any
    // time. Claim the window like that callback does, so that it bails out instead of posting a second
    // WINDOW_DESTROYED event for memory that we are about to free.
    //

    if !window.invalidate() {
        debug("EVENT_HANDLER_SLS_WINDOW_DESTROYED: \(wid) has been marked invalid by the system, ignoring event..\n")
        return
    }

    windowDestroyed(window)
}
