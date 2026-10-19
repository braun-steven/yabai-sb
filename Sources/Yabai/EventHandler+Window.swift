import ApplicationServices
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of window events: windows created, destroyed, focused, moved, resized, minimized
// and retitled, from the accessibility observers and the window server.
//

extension EventHandler
{
    /// The element is the retained reference that the AX observer posted.
    func windowCreated(_ element: AXUIElement)
    {
        let wm = WindowManager.shared

        guard let windowID = element.windowID else { return }

        if wm.window(for: windowID) != nil { return }

        let windowPid = element.pid
        if windowPid == 0 { return }

        guard let application = wm.application(for: windowPid) else { return }

        guard let window = wm.createAndAddWindow(application, reference: element, id: windowID, includingOneShotRules: true) else { return }

        // NOTE: Subscribe before tiling. AX can return before the window server publishes the final frame;
        // the border then needs the ensuing move/resize notification to leave the window's creation frame.
        WindowManager.shared.updateWindowNotifications()

        wm.removeOneShotRules()

        if window.shouldBeManaged && wm.managedView(for: window) == nil {
            if let sid = wm.originSpace(for: window) { wm.manageWindow(window, on: sid, inserting: nil) }
        }

        if window.isEligibleForManagement {
            EventSignals.shared.push(.windowCreated, .window(window))
        }

        Border.refreshSpace(of: window)
    }

    func windowDestroyed(_ window: Window?)
    {
        guard let window, !window.isDestroyed else {
            debug("EVENT_HANDLER_WINDOW_DESTROYED: window has already been destroyed, ignoring event..\n")
            return
        }

        let wm = WindowManager.shared
        let ms = MouseState.shared

        debug("EVENT_HANDLER_WINDOW_DESTROYED: \(window.application != nil ? window.application.name : "<unknown>") \(window.id)\n")

        if let view = wm.managedView(for: window) {
            let nextFocus = wm.treeFocusCandidate(in: view, for: window)
            SpaceManager.shared.untile(window, from: view)
            wm.removeManagedWindow(window.id)
            wm.treeFocusAfterClose(in: view, windowID: nextFocus)
        }

        if ms.window == window { ms.window = nil }
        if ms.ffmWindowID == window.id { ms.ffmWindowID = nil }

        if window.isEligible {
            EventSignals.shared.push(.windowDestroyed, .window(window))
        }

        wm.removeScratchpad(from: window, unfloat: false)
        wm.removeWindow(window.id)
        window.unobserve()
        window.destroy()

        if Config.current.border.hideSingle {
            Border.refresh(space: SpaceManager.shared.currentSpaceID)
        }

        WindowManager.shared.updateWindowNotifications()
    }

    func windowFocusDeferred(_ windowID: WindowID)
    {
        guard let window = WindowManager.shared.window(for: windowID), window.application != nil else {
            debug("EVENT_HANDLER_WINDOW_FOCUS_DEFERRED: \(windowID) no longer exists, ignoring event..\n")
            return
        }

        WindowManager.shared.focusWithoutRaiseDeferred(window)
    }

    func windowFocused(_ windowID: WindowID?)
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

        if Config.current.space.skipWindowFocusAnimation {
            if let sid = window.id.space, !sid.isVisible {
                SLS.setFrontProcess(SLS.connection, window.application.psn, forSpace: sid)
                if let did = sid.display {
                    SpaceManager.shared.focusSpaceUsingGesture(sid, on: did)
                }
            }
        }

        windowDidReceiveFocus(window)
        EventSignals.shared.push(.windowFocused, .window(window))
    }

    func windowMoved(_ windowID: WindowID)
    {
        let wm = WindowManager.shared
        let ms = MouseState.shared

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
        EventSignals.shared.push(.windowMoved, .window(window))
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

    func windowResized(_ windowID: WindowID) async
    {
        guard let window = autoreleasepool(invoking: { applyResize(windowID) }) else { return }

        await WindowManager.shared.waitForNativeFullscreenTransition()

        autoreleasepool { manageAfterNativeFullscreen(window) }
    }

    /// Handles the resize up to the wait; returns the window when it has left native fullscreen.
    private func applyResize(_ windowID: WindowID) -> Window?
    {
        let wm = WindowManager.shared
        let ms = MouseState.shared

        guard let window = wm.window(for: windowID) else { return nil }

        if !window.isValid {
            debug("EVENT_HANDLER_WINDOW_RESIZED: \(windowID) has been marked invalid by the system, ignoring event..\n")
            return nil
        }

        if window.application.isHidden {
            debug("EVENT_HANDLER_WINDOW_RESIZED: \(windowID) was resized while the application is hidden, ignoring event..\n")
            return nil
        }

        let newFrame = window.axFrame
        if newFrame.equalTo(window.frame) {
            debug("EVENT_HANDLER_WINDOW_RESIZED:DEBOUNCED \(window.application.name) \(window.id)\n")
            return nil
        }

        debug("EVENT_HANDLER_WINDOW_RESIZED: \(window.application.name) \(window.id)\n")
        EventSignals.shared.push(.windowResized, .window(window))

        let wasFullscreen = window.isFullscreen

        let isFullscreen = window.reportsFullscreen
        window.isFullscreen = isFullscreen

        if wasFullscreen != isFullscreen {
            window.refreshAXProperties()
        }

        let windowedFullscreen = window.windowedFrame.equalTo(window.frame)
        window.frame = newFrame

        if wasFullscreen != isFullscreen { Border.refreshSpace(of: window) }

        if !wasFullscreen && isFullscreen {
            if let view = wm.managedView(for: window) {
                wm.unmanageWindow(window, from: view)
            }
        } else if wasFullscreen && !isFullscreen {
            return window
        } else {
            if ms.currentAction == .move && ms.window == window {
                ms.windowFrame.size = ms.window.frame.size
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

        return nil
    }

    //
    // NOTE: Other @WM code may have run during the wait: the window may have been destroyed or managed meanwhile.
    //

    private func manageAfterNativeFullscreen(_ window: Window)
    {
        let wm = WindowManager.shared

        guard !window.isDestroyed, window.isValid, wm.window(for: window.id) == window else { return }

        if window.shouldBeManaged && wm.managedView(for: window) == nil {
            if let sid = window.id.space { wm.manageWindow(window, on: sid, inserting: nil) }
        }
    }

    func windowMinimized(_ window: Window)
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

        Border.refreshSpace(of: window)
        EventSignals.shared.push(.windowMinimized, .window(window))
    }

    func windowDeminimized(_ window: Window)
    {
        let wm = WindowManager.shared

        if !window.isValid {
            debug("EVENT_HANDLER_WINDOW_DEMINIMIZED: \(window.id) has been marked invalid by the system, ignoring event..\n")
            wm.removeLostFocusedEvent(for: window.id)
            return
        }

        window.isMinimized = false

        window.refreshAXProperties()

        let sid = SpaceID.active
        if let sid, window.id.spaces.contains(sid) {
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

        Border.refreshSpace(of: window)
        EventSignals.shared.push(.windowDeminimized, .window(window))
    }

    func windowTitleChanged(_ windowID: WindowID)
    {
        guard let window = WindowManager.shared.window(for: windowID) else { return }

        if !window.isValid {
            debug("EVENT_HANDLER_WINDOW_TITLE_CHANGED: \(windowID) has been marked invalid by the system, ignoring event..\n")
            return
        }

        debug("EVENT_HANDLER_WINDOW_TITLE_CHANGED: \(window.application.name) \(window.id)\n")

        window.title = window.currentTitle()
        TabBar.refresh(for: window.id)

        EventSignals.shared.push(.windowTitleChanged, .window(window))
    }

    func slsWindowOrdered(_ wid: WindowID)
    {
        debug("EVENT_HANDLER_SLS_WINDOW_ORDERED: \(wid)\n")
        TabBar.orderBars(above: wid)
    }

    func slsWindowDestroyed(_ wid: WindowID)
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
}
