import ApplicationServices
import Carbon
import Dispatch
import Foundation
import Synchronization
import YabaiC
import YabaiCore

//
// NOTE: The handlers of the events of EVENT_TYPE_LIST, run one at a time on the queue of the @WM actor (see
// EventLoop.swift). Other threads only post events; the state of yabai changes in these handlers. This file has the
// helpers they share and the application handlers; EventHandlers{Window,Space,Mouse,System}.swift have the others.
// Ported from src/event_handlers.c.
//

typealias View = UnsafeMutablePointer<view>
typealias Application = UnsafeMutablePointer<application>

//
// NOTE: Set by producers on other threads and read by the handlers. The C code that sets or reads them goes through the
// @_cdecl functions below until it is Swift.
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

@_cdecl("pending_window_focus_set")
func pending_window_focus_set(_ value: Bool)
{
    pendingWindowFocus.store(value, ordering: .releasing)
}

@_cdecl("pending_window_focus")
func pending_window_focus() -> Bool
{
    pendingWindowFocus.load(ordering: .acquiring)
}

@_cdecl("pending_gesture_set")
func pending_gesture_set(_ value: Bool)
{
    pendingGesture.store(value, ordering: .releasing)
}

@_cdecl("last_gesture_time_set")
func last_gesture_time_set(_ time: UInt64)
{
    lastGestureTime.store(time, ordering: .releasing)
}

@_cdecl("pending_mouse_dragged_add")
func pending_mouse_dragged_add()
{
    _ = pendingMouseDragged.wrappingAdd(1, ordering: .acquiringAndReleasing)
}

@_cdecl("pending_mouse_moved_add")
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

/// A C string as printf's `%s` prints it.
func cName(_ string: UnsafeMutablePointer<CChar>?) -> String
{
    string.map { String(cString: $0) } ?? "(null)"
}

/// The name and pid of a process, as the debug output prints them (`%s (%d)`).
func describe(_ process: UnsafeMutablePointer<process>) -> String
{
    "\(cName(process.pointee.name)) (\(process.pointee.pid))"
}

/// `table_for`: the values of a C hash table (src/misc/hashtable.h), in the order of its buckets.
func tableValues<T>(_ hashTable: table, as type: T.Type) -> [UnsafeMutablePointer<T>]
{
    var result: [UnsafeMutablePointer<T>] = []

    for i in 0..<Int(hashTable.capacity) {
        var entry = hashTable.buckets[i]
        while let current = entry {
            if let value = current.pointee.value { result.append(value.assumingMemoryBound(to: T.self)) }
            entry = current.pointee.next
        }
    }

    return result
}

/// `update_window_notifications`. yabai_main calls it before the event loop runs, so it is not @WM.
@_cdecl("update_window_notifications")
func update_window_notifications()
{
    let wm = window_manager_global()!

    // NOTE(asmvik): Subscribe to all windows because of window_destroyed (and ordered) notifications
    var windowIDs = tableValues(wm.pointee.window, as: window.self).map { $0.pointee.id }

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

@WM private func tileWindowBatched(_ view: View, _ window: Window, _ insertionPoint: UInt32)
{
    window_manager_adjust_layer(window, layerValue(.below))
    view_add_window(view, window, insertionPoint)
    window_manager_add_managed_window(window_manager_global(), window, view)
}

@WM private func untileWindowBatched(_ view: View, _ window: Window)
{
    view_remove_window(view, window)
    window_manager_remove_managed_window(window_manager_global(), window.pointee.id)
}

@WM private func flushDirtyViews(_ viewList: [View])
{
    for view in viewList {
        if !space_is_visible(view.pointee.sid) { continue }
        if !view_is_dirty(view)                 { continue }

        view_flush(view)
    }
}

//
// NOTE: Tiles the windows that should be managed and are not yet, each one after the previous one,
// starting after insertionPoint. New windows go to the space chosen by window_origin_display, other
// windows stay on their space.
//

@WM private func tileWindowsBatched(_ windows: [Window], _ insertionPoint: UInt32, _ newWindows: Bool)
{
    let wm = window_manager_global()!
    var insertionPoint = insertionPoint
    var viewList: [View] = []

    for window in windows {
        if !window_manager_should_manage_window(window)            { continue }
        if window_manager_find_managed_window(wm, window) != nil { continue }

        let sid = newWindows ? window_manager_origin_space(wm, window) : window_space(window.pointee.id)
        let view = space_manager_find_view(space_manager_global(), sid)
        if view.pointee.layout == VIEW_FLOAT { continue }

        tileWindowBatched(view, window, insertionPoint)
        viewList.append(view)
        insertionPoint = window.pointee.id
    }

    flushDirtyViews(viewList)
}

/// `window_did_receive_focus`
@WM func windowDidReceiveFocus(_ wm: UnsafeMutablePointer<window_manager>, _ ms: MouseState, _ window: Window)
{
    let focusedWindow = window_manager_find_window(wm, wm.pointee.focused_window_id)
    if let focusedWindow, focusedWindow != window, window_space(focusedWindow.pointee.id) == window_space(window.pointee.id) {
        window_manager_set_window_opacity(wm, focusedWindow, window_manager_global()!.pointee.normal_window_opacity)
    }

    window_manager_set_window_opacity(wm, window, wm.pointee.active_window_opacity)

    if wm.pointee.focused_window_id != window.pointee.id {
        if ms.ffm_window_id != window.pointee.id {
            window_manager_center_mouse(wm, window)
        }

        wm.pointee.last_window_id = wm.pointee.focused_window_id
    }

    let prevFocusedWindowID = wm.pointee.focused_window_id
    wm.pointee.focused_window_id = window.pointee.id
    wm.pointee.focused_window_psn = window.pointee.application.pointee.psn
    ms.ffm_window_id = 0

    //
    // NOTE: Late focus events of windows focused earlier must not end a pending focus, so it is only
    // cleared when the window that was asked to be focused reports it.
    //

    if wm.pointee.pending_focus_window_id == window.pointee.id { wm.pointee.pending_focus_window_id = 0 }

    if let view = window_manager_find_managed_window(window_manager_global(), window), view.pointee.layout == VIEW_TREE {
        tree_window_did_receive_focus(view, window.pointee.id)
    }

    if prevFocusedWindowID != window.pointee.id {
        tab_bar_refresh_for_window(prevFocusedWindowID)
    }

    border_begin_batch()
    if prevFocusedWindowID != window.pointee.id {
        border_refresh(window_manager_find_window(wm, prevFocusedWindowID))
    }
    border_refresh(window)
    border_end_batch()
}

//
// NOTE: An application that cannot be observed yet is tried again with a growing delay. After
// applicationLaunchMaxAttempts attempts (about 36s) it is given up on, until the user
// activates it, so that an application that never responds is not polled forever.
//

let applicationLaunchMaxAttempts: Int32 = 12

func applicationLaunchRetryDelay(_ attempt: Int32) -> Float
{
    min(0.1 * Float(1 << min(attempt, 16)), 5.0)
}

func applicationLaunchCanRetry(_ attempt: Int32) -> Bool
{
    attempt < applicationLaunchMaxAttempts
}

@WM private func applicationLaunchRetry(_ process: UnsafeMutablePointer<process>)
{
    if !applicationLaunchCanRetry(process.pointee.launch_attempts) {
        process.pointee.launch_given_up = true
        debug("application_launch_retry: giving up on \(describe(process)) after \(process.pointee.launch_attempts) attempts\n")
        return
    }

    let delay = applicationLaunchRetryDelay(process.pointee.launch_attempts)
    process.pointee.launch_attempts += 1
    debug("application_launch_retry: retrying \(describe(process)) in \(cFormat("%.1f", Double(delay)))s (attempt \(process.pointee.launch_attempts))\n")

    let psn = process.pointee.psn
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay * Float(NSEC_PER_SEC)))) {
        var psn = psn
        if let process = process_manager_find_process(process_manager_global(), &psn) {
            EventLoop.post(.applicationLaunched(Handoff(value: process)))
        }
    }
}

/// `EVENT_HANDLER(APPLICATION_LAUNCHED)`
@WM func applicationLaunched(_ process: UnsafeMutablePointer<process>)
{
    let wm = window_manager_global()!

    if process_is_terminated(process) {
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process)) terminated during launch\n")
        window_manager_remove_lost_front_switched_event(wm, process.pointee.pid)
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

    if window_manager_find_application(wm, process.pointee.pid) != nil { return }
    let application = application_create(process)

    if !application_observe(application) {
        let axRetry = application.pointee.ax_retry

        application_unobserve(application)
        application_destroy(application)
        debug("EVENT_HANDLER_APPLICATION_LAUNCHED: could not observe notifications for \(describe(process)) (\(axRetry ? 1 : 0))\n")

        if axRetry { applicationLaunchRetry(process) }
        return
    }

    if window_manager_find_lost_front_switched_event(wm, process.pointee.pid) {
        EventLoop.post(.applicationFrontSwitched(Handoff(value: process)))
        window_manager_remove_lost_front_switched_event(wm, process.pointee.pid)
    }

    debug("EVENT_HANDLER_APPLICATION_LAUNCHED: \(describe(process))\n")
    window_manager_add_application(wm, application)
    eventSignalPush(.applicationLaunched, UnsafeMutableRawPointer(application))
    process.pointee.launch_attempts = 0
    process.pointee.launch_given_up = false

    let windows = window_manager_add_application_windows(space_manager_global(), wm, application)
    tileWindowsBatched(windows, wm.pointee.focused_window_id, true)

    for window in windows where window_manager_is_window_eligible(window) {
        eventSignalPush(.windowCreated, UnsafeMutableRawPointer(window))
    }

    update_window_notifications()
}

/// `EVENT_HANDLER(APPLICATION_TERMINATED)`
@WM func applicationTerminated(_ process: UnsafeMutablePointer<process>)
{
    defer { process_destroy(process) }

    let wm = window_manager_global()!
    let ms = mouse_state_global()

    guard let application = window_manager_find_application(wm, process.pointee.pid) else {
        debug("EVENT_HANDLER_APPLICATION_TERMINATED: \(describe(process)) (not observed)\n")
        return
    }

    debug("EVENT_HANDLER_APPLICATION_TERMINATED: \(describe(process))\n")
    eventSignalPush(.applicationTerminated, UnsafeMutableRawPointer(application))
    window_manager_remove_application(wm, application.pointee.pid)

    let refreshIndex = window_manager_application_refresh_index(wm, application)
    if refreshIndex >= 0 { window_manager_remove_application_refresh(wm, refreshIndex) }

    let windows = window_manager_find_application_windows(wm, application)
    var viewList: [View] = []

    for window in windows {
        if !window_invalidate(window) {
            window.pointee.application = nil
            continue
        }

        if let view = window_manager_find_managed_window(wm, window) {
            untileWindowBatched(view, window)
            viewList.append(view)
        }

        if ms.window == window { ms.window = nil }
        if ms.ffm_window_id == window.pointee.id { ms.ffm_window_id = 0 }

        if window.pointee.is_eligible {
            eventSignalPush(.windowDestroyed, UnsafeMutableRawPointer(window))
        }

        window_manager_remove_scratchpad_for_window(wm, window, false)
        window_manager_remove_window(wm, window.pointee.id)
        window_unobserve(window)
        window_destroy(window)
    }

    application_unobserve(application)
    application_destroy(application)

    flushDirtyViews(viewList)

    update_window_notifications()
}

//
// NOTE: With skip_window_focus_animation, an application activated on a space that is not visible
// (e.g. by cmd-tab) brings that space to front without the space switch animation.
//

@WM private func applicationFrontSwitchedFocusSpace(_ application: Application, _ process: UnsafeMutablePointer<process>)
{
    let psnSid = process_manager_active_space_for_psn(application.pointee.connection)

    let dt = os_timer_ms_between(lastCmdTabTime.load(ordering: .relaxed), read_os_timer())
    if dt > 1500.0 {
        var dummy: CFTypeRef?
        AXUIElementCopyAttributeValue(application.pointee.ref.takeUnretainedValue(), "__fence" as CFString, &dummy)
    }

    if pendingWindowFocus.load(ordering: .relaxed) == false {
        if psnSid != 0 && !space_is_visible(psnSid) {
            SLSSpaceSetFrontPSN(connection_global(), psnSid, process.pointee.psn)
            space_manager_focus_space_using_gesture(space_display_id(psnSid), psnSid)
        }
    }
}

@WM @discardableResult private func dimFocusedWindow() -> Window?
{
    let wm = window_manager_global()!

    let focusedWindow = window_manager_find_window(wm, wm.pointee.focused_window_id)
    if let focusedWindow {
        window_manager_set_window_opacity(wm, focusedWindow, wm.pointee.normal_window_opacity)
    }

    return focusedWindow
}

//
// NOTE: The activated application has no focused window (e.g. Finder with only the desktop), so no window
// has focus until one of its windows is focused.
//

@WM private func applicationFrontSwitchedWithoutWindow(_ application: Application)
{
    let wm = window_manager_global()!
    let focusedWindow = dimFocusedWindow()

    let prevFocusedWindowID = wm.pointee.focused_window_id
    wm.pointee.last_window_id = prevFocusedWindowID
    wm.pointee.focused_window_id = 0
    wm.pointee.focused_window_psn = application.pointee.psn
    mouse_state_global().ffm_window_id = 0

    if prevFocusedWindowID != 0 {
        tab_bar_refresh_for_window(prevFocusedWindowID)
        border_refresh(focusedWindow)
    }
}

/// `EVENT_HANDLER(APPLICATION_FRONT_SWITCHED)`
@WM func applicationFrontSwitched(_ process: UnsafeMutablePointer<process>)
{
    let wm = window_manager_global()!
    let pm = process_manager_global()

    guard let application = window_manager_find_application(wm, process.pointee.pid) else {
        window_manager_add_lost_front_switched_event(wm, process.pointee.pid)

        if process.pointee.launch_given_up {
            debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(describe(process)) was activated, trying to observe it again\n")
            process.pointee.launch_attempts = 0
            process.pointee.launch_given_up = false
            EventLoop.post(.applicationLaunched(Handoff(value: process)))
        }

        return
    }

    if space_manager_global().skip_window_focus_animation {
        applicationFrontSwitchedFocusSpace(application, process)
    }

    if let deactivatedApplication = window_manager_find_application(wm, pm.front_pid) {
        eventSignalPush(.applicationDeactivated, UnsafeMutableRawPointer(deactivatedApplication))
    }

    debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(describe(process))\n")
    eventSignalPush(.applicationActivated, UnsafeMutableRawPointer(application))
    pm.switch_event_time = GetCurrentEventTime()
    pm.last_front_pid = pm.front_pid
    pm.front_pid = process.pointee.pid
    eventSignalPush(.applicationFrontSwitched, nil)

    let refreshIndex = window_manager_application_refresh_index(wm, application)
    if refreshIndex >= 0 {
        debug("EVENT_HANDLER_APPLICATION_FRONT_SWITCHED: \(cName(application.pointee.name)) has windows that are not yet resolved\n")
        _ = window_manager_add_existing_application_windows(space_manager_global(), wm, application, refreshIndex)
    }

    let applicationFocusedWindowID = application_focused_window(application)
    if applicationFocusedWindowID == 0 {
        applicationFrontSwitchedWithoutWindow(application)
        return
    }

    guard let window = window_manager_find_window(wm, applicationFocusedWindowID) else {
        dimFocusedWindow()
        window_manager_add_lost_focused_event(wm, applicationFocusedWindowID)
        return
    }

    windowDidReceiveFocus(wm, mouse_state_global(), window)
    eventSignalPush(.windowFocused, UnsafeMutableRawPointer(window))
    pendingWindowFocus.store(false, ordering: .releasing)
}

/// `EVENT_HANDLER(APPLICATION_VISIBLE)`
@WM func applicationVisible(_ pid: pid_t)
{
    let wm = window_manager_global()!
    guard let application = window_manager_find_application(wm, pid) else { return }

    debug("EVENT_HANDLER_APPLICATION_VISIBLE: \(cName(application.pointee.name))\n")
    application.pointee.is_hidden = false

    let windows = window_manager_find_application_windows(wm, application)
    tileWindowsBatched(windows, wm.pointee.last_window_id, false)

    for window in windows {
        border_refresh_window_space(window)
    }

    eventSignalPush(.applicationVisible, UnsafeMutableRawPointer(application))
}

/// `EVENT_HANDLER(APPLICATION_HIDDEN)`
@WM func applicationHidden(_ pid: pid_t)
{
    let wm = window_manager_global()!
    guard let application = window_manager_find_application(wm, pid) else { return }

    debug("EVENT_HANDLER_APPLICATION_HIDDEN: \(cName(application.pointee.name))\n")
    application.pointee.is_hidden = true

    let windows = window_manager_find_application_windows(wm, application)
    var viewList: [View] = []

    for window in windows {
        if let view = window_manager_find_managed_window(wm, window) {
            window_manager_adjust_layer(window, layerValue(.normal))
            untileWindowBatched(view, window)
            window_manager_purify_window(wm, window)
            viewList.append(view)
        }
    }

    flushDirtyViews(viewList)

    for window in windows {
        border_refresh_window_space(window)
    }

    eventSignalPush(.applicationHidden, UnsafeMutableRawPointer(application))
}
