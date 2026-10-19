import ApplicationServices
import Foundation
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of mouse events: moving and resizing windows with the mouse modifier, dropping them on
// other windows, tab bar clicks, and focus follows mouse. Ported from src/event_handlers_mouse.c.
//

//
// NOTE: A resize drags the corner (or edge) of the window that is closest to where the mouse went down.
//

func mouseResizeDirection(_ frame: CGRect, _ point: CGPoint) -> ResizeHandle
{
    var direction: ResizeHandle = []
    let frameMid = CGPoint(x: frame.midX, y: frame.midY)

    if point.x < frameMid.x { direction.insert(.left) }
    if point.y < frameMid.y { direction.insert(.top) }
    if point.x > frameMid.x { direction.insert(.right) }
    if point.y > frameMid.y { direction.insert(.bottom) }

    return direction
}

/// `EVENT_HANDLER(MOUSE_DOWN)`
@WM func mouseDown(_ event: CGEvent, _ modifiers: MouseModifiers)
{
    let ms = mouse_state_global()

    if MissionControl.shared.isActive                 { return }
    if ms.current_action != .none { return }

    let point = event.location
    debug("EVENT_HANDLER_MOUSE_DOWN: \(cFormat("%.2f, %.2f", point.x, point.y))\n")

    guard let window = WindowManager.shared.window(at: point), !window.isFullscreen else { return }

    ms.window = window
    ms.window_frame = window.frame
    ms.down_location = point
    ms.direction = []

    let button = event.getIntegerValueField(.mouseEventButtonNumber)

    if button == Int64(CGMouseButton.left.rawValue) && ms.modifier.modifiers == modifiers {
        ms.current_action = ms.action1
    } else if button == Int64(CGMouseButton.right.rawValue) && ms.modifier.modifiers == modifiers {
        ms.current_action = ms.action2
    }

    if ms.current_action == .resize {
        ms.direction = mouseResizeDirection(ms.window_frame, point)
    }
}

/// `EVENT_HANDLER(TAB_BAR_CLICKED)`
@WM func tabBarClicked(_ wid: WindowID)
{
    debug("EVENT_HANDLER_TAB_BAR_CLICKED: \(wid)\n")

    guard let window = WindowManager.shared.window(for: wid) else { return }

    WindowManager.shared.focusWithRaise(window)
}

/// `EVENT_HANDLER(TAB_CARD_ORDERED)`
@WM func tabCardOrdered(_ wid: WindowID)
{
    debug("EVENT_HANDLER_TAB_CARD_ORDERED: \(wid)\n")
    WindowManager.shared.cardDidOrder(wid)
}

//
// NOTE: The view of the space under the cursor, and the window under the cursor other than the dragged
// window (or nil), that a dragged window is dropped on.
//

@WM private func mouseDropTarget(_ point: CGPoint) -> (view: View?, window: Window?)
{
    let wm = WindowManager.shared
    let ms = mouse_state_global()

    let cursorSid = DisplayID(containing: point).flatMap { $0.currentSpace }
    let dstView = cursorSid.map { SpaceManager.shared.view(for: $0) }

    var window = wm.window(at: point, excluding: ms.window.id)
    if window == nil { window = wm.window(at: point) }
    return (dstView, window == ms.window ? nil : window)
}

/// `EVENT_HANDLER(MOUSE_UP)`
@WM func mouseUp(_ event: CGEvent)
{
    let wm = WindowManager.shared
    let ms = mouse_state_global()

    if MissionControl.shared.isActive { return }

    guard let window = ms.window else {
        ms.current_action = .none
        return
    }

    defer {
        ms.window = nil
        ms.current_action = .none
    }

    if !window.isValid {
        debug("EVENT_HANDLER_MOUSE_UP: \(window.id) has been marked invalid by the system, ignoring event..\n")
        return
    }

    if window.isFullscreen {
        debug("EVENT_HANDLER_MOUSE_UP: \(window.id) is transitioning into native-fullscreen mode, ignoring event..\n")
        return
    }

    let point = event.location
    debug("EVENT_HANDLER_MOUSE_UP: \(cFormat("%.2f, %.2f", point.x, point.y))\n")

    guard let srcView = wm.managedView(for: window) else { return }

    var info = MouseWindowChange()
    mouse_window_info_populate(ms, &info)

    if info.changed_position && !info.changed_size {
        let target = mouseDropTarget(point)

        mouse_drop(SpaceManager.shared, wm, ms, srcView, target.view, window, target.window, point)
    } else if info.changed_position || info.changed_size {
        mouse_drop_try_adjust_tree(wm, srcView, window, &info)
    }
}

@WM private func mouseDragMoveWindow(_ point: CGPoint)
{
    let ms = mouse_state_global()

    var newPoint = CGPoint(x: ms.window_frame.origin.x + (point.x - ms.down_location.x),
                           y: ms.window_frame.origin.y + (point.y - ms.down_location.y))

    let did = DisplayID(containing: newPoint)
    if let did {
        let bounds = did.constrainedBounds(ignoringExternalBar: false)
        if newPoint.y < bounds.origin.y { newPoint.y = bounds.origin.y }
    }

    if !scripting_addition_move_window(ms.window.id, Int32(newPoint.x), Int32(newPoint.y)) {
        ms.window.move(to: newPoint)
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

    let eventTime = OSTimer.now
    if OSTimer.milliseconds(from: ms.last_moved_time, to: eventTime) < mouseResizeThrottleMs { return false }

    let dx = Int(point.x - ms.down_location.x)
    let dy = Int(point.y - ms.down_location.y)

    ms.window.resizeRelative(frame: ms.window.frame, direction: ms.direction, dx: Float(dx), dy: Float(dy), animate: false)

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

    if MissionControl.shared.isActive { return }
    guard let window = ms.window else { return }

    if !window.isValid {
        debug("EVENT_HANDLER_MOUSE_DRAGGED: \(window.id) has been marked invalid by the system, ignoring event..\n")
        ms.window = nil
        ms.current_action = .none
        return
    }

    let point = event.location
    debug("EVENT_HANDLER_MOUSE_DRAGGED: \(cFormat("%.2f, %.2f", point.x, point.y))\n")

    if ms.current_action == .move {
        mouseDragMoveWindow(point)
    } else if ms.current_action == .resize {
        if !mouseDragResizeWindow(point) { return }
    }

    if WindowManager.shared.managedView(for: ms.window) == nil { return }

    var info = MouseWindowChange()
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
    guard let associatedWindows = SLSCopyAssociatedWindows(SLS.connection, window.id.rawValue) else { return window }

    let wm = WindowManager.shared

    for i in 0..<CFArrayGetCount(associatedWindows) {
        let number = unsafeBitCast(CFArrayGetValueAtIndex(associatedWindows, i), to: CFNumber.self)
        var childRawWid: UInt32 = 0
        CFNumberGetValue(number, .sInt32Type, &childRawWid)
        guard let childWid = WindowID(nonzero: childRawWid), let child = wm.window(for: childWid) else { continue }

        // NOTE: `Window.role` owns its reference; reading it here does not transfer ownership.

        guard let role = child.role else { continue }

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
    let wm = WindowManager.shared

    guard let sid = SpaceManager.shared.currentSpaceID, let windowIDs = sid.windows(includingMinimized: false) else { return false }

    let level = window.id.level
    let subLevel = window.id.subLevel

    for wid in windowIDs {
        if wid == window.id { break }

        guard let subWindow = wm.window(for: wid) else { continue }

        if !subWindow.isFloating                      { continue }
        if level != subWindow.id.level        { continue }
        if subLevel != subWindow.id.subLevel { continue }

        if window.frame.contains(subWindow.frame) { return true }
    }

    return false
}

@WM private func ffmFocusWindow(_ window: Window)
{
    let wm = WindowManager.shared
    let ms = mouse_state_global()

    if window.id == wm.focusedWindowID { return }
    if !window.isEligibleForManagement { return }

    if wm.focusFollowsMouseMode == .autofocus {
        let target = ffmWindowToFocus(window)
        WindowManager.shared.focusWithoutRaise(target)
        ms.ffm_window_id = target.id
    } else if wm.focusFollowsMouseMode == .autoraise {
        if ffmRaiseWouldOccludeFloatingWindow(window) { return }

        WindowManager.shared.focusWithRaise(window)
        ms.ffm_window_id = window.id
    }
}

@WM private func ffmFocusDisplayAtPoint(_ point: CGPoint)
{
    let cursorDid = DisplayID(containing: point)
    if DisplayManager.shared.currentDisplayID == cursorDid { return }
    guard let did = cursorDid else { return }

    let bounds = did.constrainedBounds(ignoringExternalBar: false)
    if !bounds.containsIncludingEdges(point) { return }

    let wid = DisplayManager.shared.focusWindow(at: point)
    if wid == nil { did.activate() }
    mouse_state_global().ffm_window_id = wid
}

/// `EVENT_HANDLER(MOUSE_MOVED)`
@WM func mouseMoved(_ event: CGEvent)
{
    let wm = WindowManager.shared

    if mouseEventIsStale(pendingMouseMoved) { return }

    if wm.focusFollowsMouseMode == .disabled                { return }
    if MissionControl.shared.isActive                     { return }
    if mouse_state_global().ffm_window_id != nil { return }

    if pendingGesture.load(ordering: .relaxed) { return }
    let dt = OSTimer.milliseconds(from: lastGestureTime.load(ordering: .relaxed), to: OSTimer.now)
    if dt < 1250.0 { return }

    let point = event.location

    if let window = wm.window(at: point) {
        ffmFocusWindow(window)
    } else {
        ffmFocusDisplayAtPoint(point)
    }
}
