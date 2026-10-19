import ApplicationServices
import Carbon
import Dispatch
import Foundation
import Synchronization
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the events of EVENT_TYPE_LIST, run one at a time on the queue of the @WM actor (see
// EventLoop.swift). Other threads only post events; the state of yabai changes in these handlers. This file has the
// helpers they share and the application handlers; EventHandlers{Window,Space,Mouse,System}.swift have the others.
// Ported from src/event_handlers.c.
//


//
// NOTE: Set by producers on other threads and read by the handlers.
//

/// `__pending_window_focus`
let pendingWindowFocus = Atomic<Bool>(false)

/// `__pending_gesture`
let pendingGesture = Atomic<Bool>(false)

/// `__last_gesture_time`
let lastGestureTime = Atomic<UInt64>(0)

/// `__last_cmd_tab_time`
let lastCmdTabTime = Atomic<UInt64>(0)

/// `__pending_mouse_moved`
let pendingMouseMoved = Atomic<UInt32>(0)

/// `__pending_mouse_dragged`
let pendingMouseDragged = Atomic<UInt32>(0)

func pending_window_focus_set(_ value: Bool)
{
    pendingWindowFocus.store(value, ordering: .releasing)
}

func pending_window_focus() -> Bool
{
    pendingWindowFocus.load(ordering: .acquiring)
}

func pending_gesture_set(_ value: Bool)
{
    pendingGesture.store(value, ordering: .releasing)
}

func last_gesture_time_set(_ time: UInt64)
{
    lastGestureTime.store(time, ordering: .releasing)
}

func pending_mouse_dragged_add()
{
    _ = pendingMouseDragged.wrappingAdd(1, ordering: .acquiringAndReleasing)
}

func pending_mouse_moved_add()
{
    _ = pendingMouseMoved.wrappingAdd(1, ordering: .acquiringAndReleasing)
}

//
// NOTE: The event tap counts the mouse events it posts. A handler that sees a newer event of the same
// type still queued drops its own, so only the most recent one is handled.
//

func mouseEventIsStale(_ pending: borrowing Atomic<UInt32>) -> Bool
{
    pending.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue > 0
}

/// The name and pid of a process, as the debug output prints them (`%s (%d)`).
func describe(_ process: Process) -> String
{
    "\(process.name) (\(process.pid))"
}

/// `update_window_notifications`. yabai_main calls it before the event loop runs, so it is not @WM.
func update_window_notifications()
{
    let wm = window_manager_global()

    // NOTE(asmvik): Subscribe to all windows because of window_destroyed (and ordered) notifications
    var windowIDs = wm.window.values.map { $0.id.rawValue }

    SLSRequestNotificationsForWindows(connection_global(), &windowIDs, Int32(windowIDs.count))
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

@WM private func tileWindowBatched(_ view: View, _ window: Window, _ insertionPoint: WindowID?)
{
    window.adjustLayer(to: .below)
    view.add(window, insertionPoint: insertionPoint)
    WindowManager.shared.addManagedWindow(window, to: view)
}

@WM private func untileWindowBatched(_ view: View, _ window: Window)
{
    view.remove(window)
    WindowManager.shared.removeManagedWindow(window.id)
}

@WM private func flushDirtyViews(_ viewList: [View])
{
    for view in viewList {
        if !space_is_visible(view.sid) { continue }
        if !view.isDirty                 { continue }

        view.flush()
    }
}

//
// NOTE: Tiles the windows that should be managed and are not yet, each one after the previous one,
// starting after insertionPoint. New windows go to the space chosen by window_origin_display, other
// windows stay on their space.
//

@WM private func tileWindowsBatched(_ windows: [Window], _ insertionPoint: WindowID?, _ newWindows: Bool)
{
    let wm = window_manager_global()
    var insertionPoint = insertionPoint
    var viewList: [View] = []

    for window in windows {
        if !window.shouldBeManaged { continue }
        if wm.managedView(for: window) != nil { continue }

        guard let sid = newWindows ? wm.originSpace(for: window) : window.id.space else { continue }
        let view = space_manager_find_view(space_manager_global(), sid)
        if view.layout == .float { continue }

        tileWindowBatched(view, window, insertionPoint)
        viewList.append(view)
        insertionPoint = window.id
    }

    flushDirtyViews(viewList)
}

/// `window_did_receive_focus`
@WM func windowDidReceiveFocus(_ wm: WindowManager, _ ms: MouseState, _ window: Window)
{
    let focusedWindow = wm.focusedWindowID.flatMap { wm.window(for: $0) }
    if let focusedWindow, focusedWindow != window, focusedWindow.id.space == window.id.space {
        wm.setWindowOpacity(focusedWindow, to: wm.normalWindowOpacity)
    }

    wm.setWindowOpacity(window, to: wm.activeWindowOpacity)

    if wm.focusedWindowID != window.id {
        if ms.ffm_window_id != window.id {
            wm.centerMouse(on: window)
        }

        wm.lastWindowID = wm.focusedWindowID
    }

    let prevFocusedWindowID = wm.focusedWindowID
    wm.focusedWindowID = window.id
    wm.focusedWindowPSN = window.application.psn
    ms.ffm_window_id = nil

    //
    // NOTE: Late focus events of windows focused earlier must not end a pending focus, so it is only
    // cleared when the window that was asked to be focused reports it.
    //

    if wm.pendingFocusWindowID == window.id { wm.pendingFocusWindowID = nil }

    if let view = WindowManager.shared.managedView(for: window), view.layout == .tree {
        view.focusWindow(window.id)
    }

    if prevFocusedWindowID != window.id {
        tab_bar_refresh_for_window(prevFocusedWindowID)
    }

    border_begin_batch()
    if prevFocusedWindowID != window.id {
        border_refresh(prevFocusedWindowID.flatMap { wm.window(for: $0) })
    }
    border_refresh_window_space(window)
    border_end_batch()
}

//
// NOTE: An application that cannot be observed yet is tried again with a growing delay. After
// applicationLaunchMaxAttempts attempts (about 36s) it is given up on, until the user
// activates it, so that an application that never responds is not polled forever.
//

let applicationLaunchMaxAttempts = 12

func applicationLaunchRetryDelay(_ attempt: Int) -> Float
{
    min(0.1 * Float(1 << min(attempt, 16)), 5.0)
}

func applicationLaunchCanRetry(_ attempt: Int) -> Bool
{
    attempt < applicationLaunchMaxAttempts
}

@WM private func applicationLaunchRetry(_ process: Process)
{
    if !applicationLaunchCanRetry(process.launch_attempts) {
        process.launch_given_up = true
        debug("application_launch_retry: giving up on \(describe(process)) after \(process.launch_attempts) attempts\n")
        return
    }

    let delay = applicationLaunchRetryDelay(process.launch_attempts)
    process.launch_attempts += 1
    debug("application_launch_retry: retrying \(describe(process)) in \(cFormat("%.1f", Double(delay)))s (attempt \(process.launch_attempts))\n")

    let psn = process.psn
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay * Float(NSEC_PER_SEC)))) {
        var psn = psn
        if let process = process_manager_find_process(process_manager_global(), &psn) {
            EventLoop.post(.applicationLaunched(Handoff(value: process)))
        }
    }
}

/// `EVENT_HANDLER(APPLICATION_LAUNCHED)`
@WM func applicationLaunched(_ process: Process)
{
    let wm = window_manager_global()

    if process_is_terminated(process) {
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process)) terminated during launch\n")
        wm.removeLostFrontSwitchedEvent(for: process.pid)
        return
    }

    if process_ns_application(process) == nil {
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process)) missing ns_application. fetching..\n")
        process_set_ns_application(process, workspace_application_create_running_ns_application(process))

        if process_ns_application(process) == nil {
            debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process)) unable to fetch ns_application..\n")
            applicationLaunchRetry(process)
            return
        }
    }

    if !workspace_application_is_finished_launching(process) {
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process)) is not finished launching, subscribing to finishedLaunching changes\n")
        workspace_application_observe_finished_launching(process)

        //
        // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
        // Not actually sure if this can happen in practice..
        //

        if !workspace_application_is_finished_launching(process) { return }
        workspace_application_unobserve_finished_launching(process)
    }

    if !workspace_application_is_observable(process) {
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process)) is not observable, subscribing to activationPolicy changes\n")
        workspace_application_observe_activation_policy(process)

        //
        // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
        // Not actually sure if this can happen in practice..
        //

        if !workspace_application_is_observable(process) { return }
        workspace_application_unobserve_activation_policy(process)
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
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: could not observe notifications for \(describe(process)) (\(axRetry ? 1 : 0))\n")

        if axRetry { applicationLaunchRetry(process) }
        return
    }

    if wm.hasLostFrontSwitchedEvent(for: process.pid) {
        EventLoop.post(.applicationFrontSwitched(Handoff(value: process)))
        wm.removeLostFrontSwitchedEvent(for: process.pid)
    }

    debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process))\n")
    wm.addApplication(application)
    eventSignalPush(.applicationLaunched, signalObject(application))
    process.launch_attempts = 0
    process.launch_given_up = false

    let windows = wm.addApplicationWindows(application)
    update_window_notifications()
    tileWindowsBatched(windows, wm.focusedWindowID, true)

    for window in windows where window.isEligibleForManagement {
        eventSignalPush(.windowCreated, signalObject(window))
    }
}

/// `EVENT_HANDLER(APPLICATION_TERMINATED)`
@WM func applicationTerminated(_ process: Process)
{
    defer { process_destroy(process) }

    let wm = window_manager_global()
    let ms = mouse_state_global()

    guard let application = wm.application(for: process.pid) else {
        debug("EVENT_HANDLER_APPLICATION_TERMINATED: \(describe(process)) (not observed)\n")
        return
    }

    debug("EVENT_HANDLER_APPLICATION_TERMINATED: \(describe(process))\n")
    eventSignalPush(.applicationTerminated, signalObject(application))
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
        if ms.ffm_window_id == window.id { ms.ffm_window_id = nil }

        if window.isEligible {
            eventSignalPush(.windowDestroyed, signalObject(window))
        }

        wm.removeScratchpad(from: window, unfloat: false)
        wm.removeWindow(window.id)
        window.unobserve()
        window.destroy()
    }

    application.unobserve()
    application.destroy()

    flushDirtyViews(viewList)

    update_window_notifications()
}

//
// NOTE: With skip_window_focus_animation, an application activated on a space that is not visible
// (e.g. by cmd-tab) brings that space to front without the space switch animation.
//

@WM private func applicationFrontSwitchedFocusSpace(_ application: Application, _ process: Process)
{
    let psnSid = process_manager_active_space_for_psn(application.connection)

    let dt = os_timer_ms_between(lastCmdTabTime.load(ordering: .relaxed), read_os_timer())
    if dt > 1500.0 {
        var dummy: CFTypeRef?
        AXUIElementCopyAttributeValue(application.ref, "__fence" as CFString, &dummy)
    }

    if pendingWindowFocus.load(ordering: .relaxed) == false {
        if let psnSid, !space_is_visible(psnSid) {
            SLSSpaceSetFrontPSN(connection_global(), psnSid.rawValue, process.psn)
            if let psnDid = space_display_id(psnSid) {
                space_manager_focus_space_using_gesture(psnDid, psnSid)
            }
        }
    }
}

@WM @discardableResult private func dimFocusedWindow() -> Window?
{
    let wm = window_manager_global()

    let focusedWindow = wm.focusedWindowID.flatMap { wm.window(for: $0) }
    if let focusedWindow {
        wm.setWindowOpacity(focusedWindow, to: wm.normalWindowOpacity)
    }

    return focusedWindow
}

//
// NOTE: The activated application has no focused window (e.g. Finder with only the desktop), so no window
// has focus until one of its windows is focused.
//

@WM private func applicationFrontSwitchedWithoutWindow(_ application: Application)
{
    let wm = window_manager_global()
    let focusedWindow = dimFocusedWindow()

    let prevFocusedWindowID = wm.focusedWindowID
    wm.lastWindowID = prevFocusedWindowID
    wm.focusedWindowID = nil
    wm.focusedWindowPSN = application.psn
    mouse_state_global().ffm_window_id = nil

    if let prevFocusedWindowID {
        tab_bar_refresh_for_window(prevFocusedWindowID)
        border_refresh(focusedWindow)
    }
}

/// `EVENT_HANDLER(APPLICATION_FRONT_SWITCHED)`
@WM func applicationFrontSwitched(_ process: Process)
{
    let wm = window_manager_global()
    let pm = process_manager_global()

    guard let application = wm.application(for: process.pid) else {
        wm.addLostFrontSwitchedEvent(for: process.pid)

        if process.launch_given_up {
            debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(describe(process)) was activated, trying to observe it again\n")
            process.launch_attempts = 0
            process.launch_given_up = false
            EventLoop.post(.applicationLaunched(Handoff(value: process)))
        }

        return
    }

    if space_manager_global().skip_window_focus_animation {
        applicationFrontSwitchedFocusSpace(application, process)
    }

    if let deactivatedApplication = wm.application(for: pm.front_pid) {
        eventSignalPush(.applicationDeactivated, signalObject(deactivatedApplication))
    }

    debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(describe(process))\n")
    eventSignalPush(.applicationActivated, signalObject(application))
    pm.switch_event_time = GetCurrentEventTime()
    pm.last_front_pid = pm.front_pid
    pm.front_pid = process.pid
    eventSignalPush(.applicationFrontSwitched, nil)

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

    windowDidReceiveFocus(wm, mouse_state_global(), window)
    eventSignalPush(.windowFocused, signalObject(window))
    pendingWindowFocus.store(false, ordering: .releasing)
}

/// `EVENT_HANDLER(APPLICATION_VISIBLE)`
@WM func applicationVisible(_ pid: pid_t)
{
    let wm = window_manager_global()
    guard let application = wm.application(for: pid) else { return }

    debug("EVENT_HANDLER_APPLICATION_VISIBLE: \(application.name)\n")
    application.isHidden = false

    let windows = wm.windows(for: application)
    tileWindowsBatched(windows, wm.lastWindowID, false)

    for window in windows {
        border_refresh_window_space(window)
    }

    eventSignalPush(.applicationVisible, signalObject(application))
}

/// `EVENT_HANDLER(APPLICATION_HIDDEN)`
@WM func applicationHidden(_ pid: pid_t)
{
    let wm = window_manager_global()
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
        border_refresh_window_space(window)
    }

    eventSignalPush(.applicationHidden, signalObject(application))
}
