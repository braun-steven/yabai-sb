import ApplicationServices
import Carbon
import Foundation
import Synchronization
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the cases of Event, run one at a time on the queue of the @WM actor (see EventLoop.swift).
// Other threads only post events; the state of yabai changes in these handlers. This file has the class, the
// helpers they share and the application handlers; EventHandler+{Window,Space,Mouse,System}.swift have the others.
//

/// Handles the events of the event loop, one at a time on the queue of the @WM actor.
@WM final class EventHandler
{
    static let shared = EventHandler()

    /// The number of open menus.
    var openMenuCount = 0

    //
    // NOTE: Focus follows mouse is off while a menu is open, so that moving the cursor through a menu does not focus
    // the windows below it. This is runtime state: the configured mode in Config stays as it is.
    //

    /// The focus follows mouse mode in effect.
    var focusFollowsMouse: FocusFollowsMouse
    {
        openMenuCount > 0 ? .disabled : Config.current.window.focusFollowsMouse
    }
}

//
// NOTE: Set by producers on other threads and read by the handlers.
//

/// Set when an application reports a focus change that the event loop has not handled yet.
let pendingWindowFocus = Atomic<Bool>(false)

/// Set while a horizontal Dock swipe (a space switch gesture) is in progress.
let pendingGesture = Atomic<Bool>(false)

/// The OSTimer time when the last Dock swipe gesture ended.
let lastGestureTime = Atomic<UInt64>(0)

/// The OSTimer time of the last command-tab notification of the window server.
let lastCmdTabTime = Atomic<UInt64>(0)

/// The number of mouse moved events that the event tap has posted and the event loop has not taken yet.
let pendingMouseMoved = Atomic<UInt32>(0)

/// The number of mouse dragged events that the event tap has posted and the event loop has not taken yet.
let pendingMouseDragged = Atomic<UInt32>(0)

extension EventHandler
{
    //
    // NOTE: Carbon's process handler on the main thread only posts the process key. These handlers update the process
    // table on the event loop and run the application handler in the same event, so it keeps the place in the event
    // order that Carbon gave it.
    //

    func carbonProcessLaunched(_ key: ProcessKey)
    {
        guard let process = ProcessManager.shared.processLaunched(key) else { return }
        applicationLaunched(process)
    }

    func carbonProcessTerminated(_ key: ProcessKey)
    {
        guard let process = ProcessManager.shared.processTerminated(key) else { return }
        applicationTerminated(process)
    }

    func carbonProcessFrontSwitched(_ key: ProcessKey)
    {
        guard let process = ProcessManager.shared.processFrontSwitched(key) else { return }
        applicationFrontSwitched(process)
    }

    //
    // NOTE: The event tap counts the mouse events it posts. A handler that sees a newer event of the same
    // type still queued drops its own, so only the most recent one is handled.
    //
    nonisolated static func isStale(_ pending: borrowing Atomic<UInt32>) -> Bool
    {
        pending.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue > 0
    }

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
    // making sure that each window is only moved and resized a single time, when the final layout has been computed.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    // The handlers collect the views they modified and flush them once with flushDirtyViews.
    //

    private func tileWindowBatched(_ view: View, _ window: Window, _ insertionPoint: WindowID?)
    {
        window.adjustLayer(to: .below)
        view.add(window, insertionPoint: insertionPoint)
        WindowManager.shared.addManagedWindow(window, to: view)
    }

    private func untileWindowBatched(_ view: View, _ window: Window)
    {
        view.remove(window)
        WindowManager.shared.removeManagedWindow(window.id)
    }

    private func flushDirtyViews(_ viewList: [View])
    {
        for view in viewList {
            if !view.sid.isVisible { continue }
            if !view.isDirty                 { continue }

            view.flush()
        }
    }

    //
    // NOTE: Tiles the windows that should be managed and are not yet, each one after the previous one,
    // starting after insertionPoint. New windows go to the space chosen by window_origin_display, other
    // windows stay on their space.
    //

    private func tileWindowsBatched(_ windows: [Window], _ insertionPoint: WindowID?, _ newWindows: Bool)
    {
        let wm = WindowManager.shared
        var insertionPoint = insertionPoint
        var viewList: [View] = []

        for window in windows {
            if !window.shouldBeManaged { continue }
            if wm.managedView(for: window) != nil { continue }

            guard let sid = newWindows ? wm.originSpace(for: window) : window.id.space else { continue }
            let view = SpaceManager.shared.view(for: sid)
            if view.layout == .float { continue }

            tileWindowBatched(view, window, insertionPoint)
            viewList.append(view)
            insertionPoint = window.id
        }

        flushDirtyViews(viewList)
    }

    func windowDidReceiveFocus(_ window: Window)
    {
        let wm = WindowManager.shared
        let ms = MouseState.shared

        let focusedWindow = wm.focusedWindowID.flatMap { wm.window(for: $0) }
        if let focusedWindow, focusedWindow != window, focusedWindow.id.space == window.id.space {
            wm.setWindowOpacity(focusedWindow, to: Config.current.window.normalOpacity)
        }

        wm.setWindowOpacity(window, to: Config.current.window.activeOpacity)

        if wm.focusedWindowID != window.id {
            if ms.ffmWindowID != window.id {
                wm.centerMouse(on: window)
            }

            wm.lastWindowID = wm.focusedWindowID
        }

        let prevFocusedWindowID = wm.focusedWindowID
        wm.focusedWindowID = window.id
        wm.focusedWindowPSN = window.application.psn
        ms.ffmWindowID = nil

        //
        // NOTE: Late focus events of windows focused earlier must not end a pending focus, so it is only
        // cleared when the window that was asked to be focused reports it.
        //

        if wm.pendingFocusWindowID == window.id { wm.pendingFocusWindowID = nil }

        if let view = WindowManager.shared.managedView(for: window), view.layout == .tree {
            view.focusWindow(window.id)
        }

        //
        // NOTE: The focus hand-over updates opacity, tab bars and borders explicitly in this event, with the focus
        // change: the previous window loses the active style as the new one gets it. Focus is not observed.
        //

        if prevFocusedWindowID != window.id {
            TabBar.refresh(for: prevFocusedWindowID)
        }

        Border.beginBatch()
        if prevFocusedWindowID != window.id {
            Border.refresh(prevFocusedWindowID.flatMap { wm.window(for: $0) })
        }
        Border.refreshSpace(of: window)
        Border.endBatch()
    }

    private func applicationLaunchRetry(_ process: Process)
    {
        if !Process.canRetryLaunch(process.launchAttempts) {
            process.launchGivenUp = true
            debug("EventHandler.applicationLaunchRetry: giving up on \(process.nameAndPID) after \(process.launchAttempts) attempts\n")
            return
        }

        let delay = Process.launchRetryDelay(process.launchAttempts)
        process.launchAttempts += 1
        debug("EventHandler.applicationLaunchRetry: retrying \(process.nameAndPID) in \(cFormat("%.1f", delay / .seconds(1)))s (attempt \(process.launchAttempts))\n")

        let key = ProcessKey(process.psn)
        EventLoop.post(.applicationLaunchRetry(key), after: delay)
    }

    /// The delayed retry of a launch: the process is looked up again, since it can terminate during the delay.
    func applicationLaunchRetry(_ key: ProcessKey)
    {
        guard let process = ProcessManager.shared.process(for: key) else { return }
        applicationLaunched(process)
    }

    func applicationLaunched(_ process: Process)
    {
        let wm = WindowManager.shared

        if process.isTerminated {
            debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(process.nameAndPID) terminated during launch\n")
            wm.removeLostFrontSwitchedEvent(for: process.pid)
            return
        }

        if !process.hasRunningApplication {
            debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(process.nameAndPID) missing ns_application. fetching..\n")
            process.attachRunningApplication()

            if !process.hasRunningApplication {
                debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(process.nameAndPID) unable to fetch ns_application..\n")
                applicationLaunchRetry(process)
                return
            }
        }

        if !process.isFinishedLaunching {
            debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(process.nameAndPID) is not finished launching, subscribing to finishedLaunching changes\n")
            process.observeFinishedLaunching()

            //
            // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
            // Not actually sure if this can happen in practice..
            //

            if !process.isFinishedLaunching { return }
            process.unobserveFinishedLaunching()
        }

        if !process.isObservable() {
            debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(process.nameAndPID) is not observable, subscribing to activationPolicy changes\n")
            process.observeActivationPolicy()

            //
            // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
            // Not actually sure if this can happen in practice..
            //

            if !process.isObservable() { return }
            process.unobserveActivationPolicy()
        }

        //
        // NOTE(asmvik): If we somehow receive a duplicate launched event due to the subscription-timing-mess above,
        // simply ignore the event..
        //

        if wm.application(for: process.pid) != nil { return }
        let application = Application(process: process)

        if !application.observe() {
            let axRetry = application.axRetry

            application.unobserve()
            application.destroy()
            debug("EVENT_HANDLER_APPLICATION_LAUNCHED: could not observe notifications for \(process.nameAndPID) (\(axRetry ? 1 : 0))\n")

            if axRetry { applicationLaunchRetry(process) }
            return
        }

        if wm.hasLostFrontSwitchedEvent(for: process.pid) {
            EventLoop.post(.applicationFrontSwitched(process))
            wm.removeLostFrontSwitchedEvent(for: process.pid)
        }

        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(process.nameAndPID)\n")
        wm.addApplication(application)
        EventSignals.shared.push(.applicationLaunched, .application(application))
        process.launchAttempts = 0
        process.launchGivenUp = false

        let windows = wm.addApplicationWindows(application)
        WindowManager.shared.updateWindowNotifications()
        tileWindowsBatched(windows, wm.focusedWindowID, true)

        for window in windows where window.isEligibleForManagement {
            EventSignals.shared.push(.windowCreated, .window(window))
        }
    }

    func applicationTerminated(_ process: Process)
    {
        defer { process.releaseRunningApplication() }

        let wm = WindowManager.shared
        let ms = MouseState.shared

        guard let application = wm.application(for: process.pid) else {
            debug("EVENT_HANDLER_APPLICATION_TERMINATED: \(process.nameAndPID) (not observed)\n")
            return
        }

        debug("EVENT_HANDLER_APPLICATION_TERMINATED: \(process.nameAndPID)\n")
        EventSignals.shared.push(.applicationTerminated, .application(application))
        wm.removeApplication(pid: application.pid)

        let refreshIndex = wm.applicationRefreshIndex(of: application)
        if let refreshIndex { wm.removeApplicationRefresh(at: refreshIndex) }

        let windows = wm.windows(for: application)
        var viewList: [View] = []

        for window in windows {
            if !window.invalidate() {
                window.application = nil
                continue
            }

            if let view = wm.managedView(for: window) {
                untileWindowBatched(view, window)
                viewList.append(view)
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
        }

        application.unobserve()
        application.destroy()

        flushDirtyViews(viewList)

        WindowManager.shared.updateWindowNotifications()
    }

    //
    // NOTE: With skip_window_focus_animation, an application activated on a space that is not visible
    // (e.g. by cmd-tab) brings that space to front without the space switch animation.
    //

    private func applicationFrontSwitchedFocusSpace(_ application: Application, _ process: Process)
    {
        let psnSid = ProcessManager.shared.activeSpace(forConnection: application.connection)

        let dt = OSTimer.milliseconds(from: lastCmdTabTime.load(ordering: .relaxed), to: OSTimer.now)
        if dt > 1500.0 {
            _ = application.ref.attribute("__fence")
        }

        if pendingWindowFocus.load(ordering: .relaxed) == false {
            if let psnSid, !psnSid.isVisible {
                SLS.setFrontProcess(SLS.connection, process.psn, forSpace: psnSid)
                if let psnDid = psnSid.display {
                    SpaceManager.shared.focusSpaceUsingGesture(psnSid, on: psnDid)
                }
            }
        }
    }

    @discardableResult private func dimFocusedWindow() -> Window?
    {
        let wm = WindowManager.shared

        let focusedWindow = wm.focusedWindowID.flatMap { wm.window(for: $0) }
        if let focusedWindow {
            wm.setWindowOpacity(focusedWindow, to: Config.current.window.normalOpacity)
        }

        return focusedWindow
    }

    //
    // NOTE: The activated application has no focused window (e.g. Finder with only the desktop), so no window
    // has focus until one of its windows is focused.
    //

    private func applicationFrontSwitchedWithoutWindow(_ application: Application)
    {
        let wm = WindowManager.shared
        let focusedWindow = dimFocusedWindow()

        let prevFocusedWindowID = wm.focusedWindowID
        wm.lastWindowID = prevFocusedWindowID
        wm.focusedWindowID = nil
        wm.focusedWindowPSN = application.psn
        MouseState.shared.ffmWindowID = nil

        if let prevFocusedWindowID {
            TabBar.refresh(for: prevFocusedWindowID)
            Border.refresh(focusedWindow)
        }
    }

    func applicationFrontSwitched(_ process: Process)
    {
        let wm = WindowManager.shared
        let pm = ProcessManager.shared

        guard let application = wm.application(for: process.pid) else {
            wm.addLostFrontSwitchedEvent(for: process.pid)

            if process.launchGivenUp {
                debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(process.nameAndPID) was activated, trying to observe it again\n")
                process.launchAttempts = 0
                process.launchGivenUp = false
                EventLoop.post(.applicationLaunched(process))
            }

            return
        }

        if Config.current.space.skipWindowFocusAnimation {
            applicationFrontSwitchedFocusSpace(application, process)
        }

        if let deactivatedApplication = wm.application(for: pm.frontPID) {
            EventSignals.shared.push(.applicationDeactivated, .application(deactivatedApplication))
        }

        debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(process.nameAndPID)\n")
        EventSignals.shared.push(.applicationActivated, .application(application))
        pm.switchEventTime = GetCurrentEventTime()
        pm.lastFrontPID = pm.frontPID
        pm.frontPID = process.pid
        EventSignals.shared.push(.applicationFrontSwitched)

        let refreshIndex = wm.applicationRefreshIndex(of: application)
        if let refreshIndex {
            debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(application.name) has windows that are not yet resolved\n")
            _ = wm.addExistingApplicationWindows(application, refreshIndex: refreshIndex)
        }

        guard let applicationFocusedWindowID = application.focusedWindowID else {
            applicationFrontSwitchedWithoutWindow(application)
            return
        }

        guard let window = wm.window(for: applicationFocusedWindowID) else {
            dimFocusedWindow()
            wm.addLostFocusedEvent(for: applicationFocusedWindowID)
            return
        }

        windowDidReceiveFocus(window)
        EventSignals.shared.push(.windowFocused, .window(window))
        pendingWindowFocus.store(false, ordering: .releasing)
    }

    func applicationVisible(_ pid: pid_t)
    {
        let wm = WindowManager.shared
        guard let application = wm.application(for: pid) else { return }

        debug("EVENT_HANDLER_APPLICATION_VISIBLE: \(application.name)\n")
        application.isHidden = false

        let windows = wm.windows(for: application)
        tileWindowsBatched(windows, wm.lastWindowID, false)

        for window in windows {
            Border.refreshSpace(of: window)
        }

        EventSignals.shared.push(.applicationVisible, .application(application))
    }

    func applicationHidden(_ pid: pid_t)
    {
        let wm = WindowManager.shared
        guard let application = wm.application(for: pid) else { return }

        debug("EVENT_HANDLER_APPLICATION_HIDDEN: \(application.name)\n")
        application.isHidden = true

        let windows = wm.windows(for: application)
        var viewList: [View] = []

        for window in windows {
            if let view = wm.managedView(for: window) {
                window.adjustLayer(to: .normal)
                untileWindowBatched(view, window)
                wm.purifyWindow(window)
                viewList.append(view)
            }
        }

        flushDirtyViews(viewList)

        for window in windows {
            Border.refreshSpace(of: window)
        }

        EventSignals.shared.push(.applicationHidden, .application(application))
    }
}
