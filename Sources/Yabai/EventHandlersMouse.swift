import ApplicationServices
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: The handlers of mouse events: moving and resizing windows with the mouse modifier, dropping them on
// other windows, tab bar clicks, and focus follows mouse. Ported from src/event_handlers_mouse.c.
//

//
// NOTE: A resize drags the corner (or edge) of the window that is closest to where the mouse went down.
//

func mouseResizeDirection(_ frame: CGRect, _ point: CGPoint) -> Int32
{
    var direction: Int32 = 0
    let frameMid = CGPoint(x: frame.midX, y: frame.midY)

    if point.x < frameMid.x { direction |= HANDLE_LEFT }
    if point.y < frameMid.y { direction |= HANDLE_TOP }
    if point.x > frameMid.x { direction |= HANDLE_RIGHT }
    if point.y > frameMid.y { direction |= HANDLE_BOTTOM }

    return direction
}

/// `EVENT_HANDLER(MOUSE_DOWN)`
@WM func mouseDown(_ event: CGEvent, _ modifiers: Int32)
{
    let ms = mouse_state_global()

    if mission_control_is_active()                    { return }
    if ms.current_action != MOUSE_MODE_NONE { return }

    let point = event.location
    debug("EVENT_HANDLER_MOUSE_DOWN: \(cFormat("%.2f, %.2f", point.x, point.y))\n")

    guard let window = window_manager_find_window_at_point(window_manager_global(), point), !window_check_flag(window, WINDOW_FULLSCREEN) else { return }

    ms.window = window
    ms.window_frame = window.pointee.frame
    ms.down_location = point
    ms.direction = 0

    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    let mod = UInt8(truncatingIfNeeded: modifiers)

    if button == Int64(CGMouseButton.left.rawValue) && ms.modifier == mod {
        ms.current_action = ms.action1
    } else if button == Int64(CGMouseButton.right.rawValue) && ms.modifier == mod {
        ms.current_action = ms.action2
    }

    if ms.current_action == MOUSE_MODE_RESIZE {
        ms.direction = UInt8(truncatingIfNeeded: mouseResizeDirection(ms.window_frame, point))
    }
}

/// `EVENT_HANDLER(TAB_BAR_CLICKED)`
@WM func tabBarClicked(_ wid: UInt32)
{
    debug("EVENT_HANDLER_TAB_BAR_CLICKED: \(wid)\n")

    guard let window = window_manager_find_window(window_manager_global(), wid) else { return }

    window_manager_focus_window_with_raise(&window.pointee.application.pointee.psn, window.pointee.id, window.pointee.ref)
}

//
// NOTE: The view of the space under the cursor, and the window under the cursor other than the dragged
// window (or nil), that a dragged window is dropped on.
//

@WM private func mouseDropTarget(_ point: CGPoint) -> (view: View?, window: Window?)
{
    let wm = window_manager_global()
    let ms = mouse_state_global()

    let cursorSid = display_space_id(display_manager_point_display_id(point))
    let dstView = space_manager_find_view(space_manager_global(), cursorSid)

    var window = window_manager_find_window_at_point_filtering_window(wm, point, ms.window.pointee.id)
    if window == nil { window = window_manager_find_window_at_point(wm, point) }
    return (dstView, window == ms.window ? nil : window)
}

/// `EVENT_HANDLER(MOUSE_UP)`
@WM func mouseUp(_ event: CGEvent)
{
    let wm = window_manager_global()
    let ms = mouse_state_global()

    if mission_control_is_active() { return }

    guard let window = ms.window else {
        ms.current_action = MOUSE_MODE_NONE
        return
    }

    defer {
        ms.window = nil
        ms.current_action = MOUSE_MODE_NONE
    }

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_MOUSE_UP: \(window.pointee.id) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window_check_flag(window, WINDOW_FULLSCREEN) {
        debug("EVENT_HANDLER_MOUSE_UP: \(window.pointee.id) is transitioning into native-fullscreen mode, ignoring event..\n")
        return
    }

    let point = event.location
    debug("EVENT_HANDLER_MOUSE_UP: \(cFormat("%.2f, %.2f", point.x, point.y))\n")

    guard let srcView = window_manager_find_managed_window(wm, window) else { return }

    var info = mouse_window_info()
    mouse_window_info_populate(ms, &info)

    if info.changed_position && !info.changed_size {
        let target = mouseDropTarget(point)

        mouse_drop(space_manager_global(), wm, ms, srcView, target.view, window, target.window, point)
    } else if info.changed_position || info.changed_size {
        mouse_drop_try_adjust_tree(wm, srcView, window, &info)
    }
}

@WM private func mouseDragMoveWindow(_ point: CGPoint)
{
    let ms = mouse_state_global()

    var newPoint = CGPoint(x: ms.window_frame.origin.x + (point.x - ms.down_location.x),
                           y: ms.window_frame.origin.y + (point.y - ms.down_location.y))

    let did = display_manager_point_display_id(newPoint)
    if did != 0 {
        let bounds = display_bounds_constrained(did, false)
        if newPoint.y < bounds.origin.y { newPoint.y = bounds.origin.y }
    }

    if !scripting_addition_move_window(ms.window.pointee.id, Int32(newPoint.x), Int32(newPoint.y)) {
        window_manager_move_window(ms.window, Float(newPoint.x), Float(newPoint.y))
    }
}

//
// NOTE: Resizing through the AX API is slow, so a drag resizes the window at most once per throttle
// interval. Returns false when this event was skipped.
//

private let mouseResizeThrottleMs: Float = 67.67

@WM private func mouseDragResizeWindow(_ point: CGPoint) -> Bool
{
    let ms = mouse_state_global()

    let eventTime = read_os_timer()
    if os_timer_ms_between(ms.last_moved_time, eventTime) < mouseResizeThrottleMs { return false }

    let dx = Int32(point.x - ms.down_location.x)
    let dy = Int32(point.y - ms.down_location.y)

    window_manager_resize_window_relative_internal(ms.window, ms.window.pointee.frame, Int32(ms.direction), Float(dx), Float(dy), false)

    ms.last_moved_time = eventTime
    ms.down_location = point
    return true
}

/// `EVENT_HANDLER(MOUSE_DRAGGED)`
@WM func mouseDragged(_ event: CGEvent)
{
    let ms = mouse_state_global()

    //
    // NOTE: Only the most recent drag event matters, because the new frame is computed from the
    // location where the drag started. Skip this one if a newer one is already queued.
    //

    if mouseEventIsStale(pendingMouseDragged) { return }

    if mission_control_is_active() { return }
    guard let window = ms.window else { return }

    if !window_is_valid(window) {
        debug("EVENT_HANDLER_MOUSE_DRAGGED: \(window.pointee.id) has been marked invalid by the system, ignoring event..\n")
        ms.window = nil
        ms.current_action = MOUSE_MODE_NONE
        return
    }

    let point = event.location
    debug("EVENT_HANDLER_MOUSE_DRAGGED: \(cFormat("%.2f, %.2f", point.x, point.y))\n")

    if ms.current_action == MOUSE_MODE_MOVE {
        mouseDragMoveWindow(point)
    } else if ms.current_action == MOUSE_MODE_RESIZE {
        if !mouseDragResizeWindow(point) { return }
    }

    if window_manager_find_managed_window(window_manager_global(), ms.window) == nil { return }

    var info = mouse_window_info()
    mouse_window_info_populate(ms, &info)

    if info.changed_position && !info.changed_size {
        let target = mouseDropTarget(point)

        mouse_drag(ms, target.view, target.window, point)
    }
}

//
// NOTE(asmvik): Look for a window with role AXSheet or AXDrawer
// and forward focus to it because we are not allowed to focus the main
// window in these cases.
//

@WM private func ffmWindowToFocus(_ window: Window) -> Window
{
    guard let associatedWindows = SLSCopyAssociatedWindows(connection_global(), window.pointee.id) else { return window }

    let wm = window_manager_global()

    for i in 0..<CFArrayGetCount(associatedWindows) {
        let number = unsafeBitCast(CFArrayGetValueAtIndex(associatedWindows, i), to: CFNumber.self)
        var childWid: UInt32 = 0
        CFNumberGetValue(number, .sInt32Type, &childWid)
        guard let child = window_manager_find_window(wm, childWid) else { continue }

        //
        // NOTE: window_role returns the role that the window keeps (not a +1 reference); the C version
        // released it here, one release too many.
        //

        guard let role = window_role(child) else { continue }

        if CFEqual(role, kAXSheetRole as CFString) || CFEqual(role, kAXDrawerRole as CFString) {
            return child
        }
    }

    return window
}

//
// NOTE(asmvik): If any **floating** window would be fully occluded by
// autoraising the window below the cursor we do not actually perform the
// focus change, as it is likely that the user is trying to reach for the
// smaller window that sits on top of the window we would otherwise raise.
//

@WM private func ffmRaiseWouldOccludeFloatingWindow(_ window: Window) -> Bool
{
    let wm = window_manager_global()

    var windowCount: Int32 = 0
    guard let windowIDs = space_window_list(space_manager_global().current_space_id, &windowCount, false) else { return false }

    let level = window_level(window.pointee.id)
    let subLevel = window_sub_level(window.pointee.id)

    for i in 0..<Int(windowCount) {
        let wid = windowIDs[i]
        if wid == window.pointee.id { break }

        guard let subWindow = window_manager_find_window(wm, wid) else { continue }

        if !window_check_flag(subWindow, WINDOW_FLOAT)       { continue }
        if level != window_level(subWindow.pointee.id)        { continue }
        if subLevel != window_sub_level(subWindow.pointee.id) { continue }

        if window.pointee.frame.contains(subWindow.pointee.frame) { return true }
    }

    return false
}

@WM private func ffmFocusWindow(_ window: Window)
{
    let wm = window_manager_global()
    let ms = mouse_state_global()

    if window.pointee.id == wm.focused_window_id { return }
    if !window_manager_is_window_eligible(window)       { return }

    if wm.ffm_mode == FFM_AUTOFOCUS {
        let target = ffmWindowToFocus(window)
        window_manager_focus_window_without_raise(&target.pointee.application.pointee.psn, target.pointee.id)
        ms.ffm_window_id = target.pointee.id
    } else if wm.ffm_mode == FFM_AUTORAISE {
        if ffmRaiseWouldOccludeFloatingWindow(window) { return }

        window_manager_focus_window_with_raise(&window.pointee.application.pointee.psn, window.pointee.id, window.pointee.ref)
        ms.ffm_window_id = window.pointee.id
    }
}

@WM private func ffmFocusDisplayAtPoint(_ point: CGPoint)
{
    let cursorDid = display_manager_point_display_id(point)
    if display_manager_global().current_display_id == cursorDid { return }

    let bounds = display_bounds_constrained(cursorDid, false)
    if !cgrect_contains_point(bounds, point) { return }

    let wid = display_manager_focus_display_with_window_at_point(point)
    if wid == 0 { display_manager_set_active_display_id(cursorDid) }
    mouse_state_global().ffm_window_id = wid
}

/// `EVENT_HANDLER(MOUSE_MOVED)`
@WM func mouseMoved(_ event: CGEvent)
{
    let wm = window_manager_global()

    if mouseEventIsStale(pendingMouseMoved) { return }

    if wm.ffm_mode == FFM_DISABLED                { return }
    if mission_control_is_active()                        { return }
    if mouse_state_global().ffm_window_id != 0 { return }

    if pendingGesture.load(ordering: .relaxed) { return }
    let dt = os_timer_ms_between(lastGestureTime.load(ordering: .relaxed), read_os_timer())
    if dt < 1250.0 { return }

    let point = event.location

    if let window = window_manager_find_window_at_point(wm, point) {
        ffmFocusWindow(window)
    } else {
        ffmFocusDisplayAtPoint(point)
    }
}
