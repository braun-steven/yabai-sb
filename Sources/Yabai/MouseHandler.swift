import ApplicationServices
import YabaiC

// Ported from src/mouse_handler.c. The event tap runs on the main run loop and only posts events.

private func mouseModFromCGFlags(_ flags: CGEventFlags) -> UInt8
{
    var result: UInt8 = 0
    if flags.contains(.maskAlternate) { result |= UInt8(MOUSE_MOD_ALT.rawValue) }
    if flags.contains(.maskShift) { result |= UInt8(MOUSE_MOD_SHIFT.rawValue) }
    if flags.contains(.maskCommand) { result |= UInt8(MOUSE_MOD_CMD.rawValue) }
    if flags.contains(.maskControl) { result |= UInt8(MOUSE_MOD_CTRL.rawValue) }
    if flags.contains(.maskSecondaryFn) { result |= UInt8(MOUSE_MOD_FN.rawValue) }
    return result
}

//
// NOTE: Focus follows mouse is paused while a horizontal swipe switches spaces, and for a moment after it.
//

private func mouseHandleDockGesture(_ event: CGEvent)
{
    guard event.getIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGestureHIDType))!) == kIOHIDEventTypeDockSwipe,
          event.getIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGestureSwipeMotion))!) == kCGGestureMotionHorizontal else { return }
    let phase = event.getIntegerValueField(CGEventField(rawValue: UInt32(kCGEventGesturePhase))!)
    if phase == kCGSGesturePhaseBegan {
        pending_gesture_set(true)
    } else if phase == kCGSGesturePhaseEnded || phase == kCGSGesturePhaseCancelled {
        pending_gesture_set(false)
        last_gesture_time_set(read_os_timer())
    }
}

private func mouseHandler(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?
{
    let ms = context!.assumingMemoryBound(to: mouse_state.self)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let handle = mouse_handle_load(ms)?.takeUnretainedValue() { CGEvent.tapEnable(tap: handle, enable: true) }
    case .leftMouseDown, .rightMouseDown:
        let mod = mouseModFromCGFlags(event.flags)
        var tabWid: UInt32 = 0
        if type == .leftMouseDown && mod != ms.pointee.modifier && tab_bar_hit_test(event.location, &tabWid) {
            ms.pointee.consume_tab_click = true
            EventLoop.post(.tabBarClicked(windowID: tabWid))
            return nil
        }
        EventLoop.post(.mouseDown(Handoff(value: .passRetained(event)), modifiers: Int32(mod)))
        if mod == ms.pointee.modifier {
            ms.pointee.consume_mouse_click = true
            ms.pointee.consumed_event = .passRetained(event)
            return nil
        }
    case .leftMouseUp, .rightMouseUp:
        if type == .leftMouseUp && ms.pointee.consume_tab_click {
            ms.pointee.consume_tab_click = false
            return nil
        }
        EventLoop.post(.mouseUp(Handoff(value: .passRetained(event))))
        if ms.pointee.consume_mouse_click {
            if !ms.pointee.drag_detected {
                ms.pointee.consumed_event.takeUnretainedValue().tapPostEvent(proxy)
                event.tapPostEvent(proxy)
            }
            ms.pointee.drag_detected = false
            ms.pointee.consume_mouse_click = false
            ms.pointee.consumed_event.release()
            return nil
        }
    case .leftMouseDragged, .rightMouseDragged:
        if type == .leftMouseDragged && ms.pointee.consume_tab_click { return nil }
        ms.pointee.drag_detected = true
        pending_mouse_dragged_add()
        EventLoop.post(.mouseDragged(Handoff(value: .passRetained(event))))
    case .mouseMoved:
        let mod = mouseModFromCGFlags(event.flags)
        if mod == ms.pointee.modifier { return .passUnretained(event) }
        pending_mouse_moved_add()
        EventLoop.post(.mouseMoved(Handoff(value: .passRetained(event)), modifiers: Int32(mod)))
    default:
        if type.rawValue == UInt32(kCGSEventDockControl) { mouseHandleDockGesture(event) }
    }
    return .passUnretained(event)
}

@WM func mouse_window_info_populate(_ ms: UnsafeMutablePointer<mouse_state>, _ info: UnsafeMutablePointer<mouse_window_info>)
{
    let frame = ms.pointee.window.pointee.frame
    info.pointee.dx = Float(frame.origin.x - ms.pointee.window_frame.origin.x)
    info.pointee.dy = Float(frame.origin.y - ms.pointee.window_frame.origin.y)
    info.pointee.dw = Float(frame.width - ms.pointee.window_frame.width)
    info.pointee.dh = Float(frame.height - ms.pointee.window_frame.height)
    info.pointee.changed_x = info.pointee.dx != 0
    info.pointee.changed_y = info.pointee.dy != 0
    info.pointee.changed_w = info.pointee.dw != 0
    info.pointee.changed_h = info.pointee.dh != 0
    info.pointee.changed_position = info.pointee.changed_x || info.pointee.changed_y
    info.pointee.changed_size = info.pointee.changed_w || info.pointee.changed_h
}

func mouse_determine_drop_action(_ ms: UnsafeMutablePointer<mouse_state>, _ target: Window, _ point: CGPoint) -> mouse_drop_action
{
    let f = target.pointee.frame
    let wp = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
    let center = CGRect(x: 0.25 * f.width, y: 0.25 * f.height, width: 0.5 * f.width, height: 0.5 * f.height)
    let mid = CGPoint(x: 0.5 * f.width, y: 0.5 * f.height)
    var top = [CGPoint.zero, mid, CGPoint(x: f.width, y: 0)]
    var right = [CGPoint(x: f.width, y: 0), mid, CGPoint(x: f.width, y: f.height)]
    var bottom = [CGPoint(x: f.width, y: f.height), mid, CGPoint(x: 0, y: f.height)]
    var left = [CGPoint(x: 0, y: f.height), mid, CGPoint.zero]
    if center.contains(wp) { return ms.pointee.drop_action == MOUSE_MODE_STACK ? MOUSE_DROP_ACTION_STACK : MOUSE_DROP_ACTION_SWAP }
    if triangle_contains_point(&top, wp) { return MOUSE_DROP_ACTION_WARP_TOP }
    if triangle_contains_point(&right, wp) { return MOUSE_DROP_ACTION_WARP_RIGHT }
    if triangle_contains_point(&bottom, wp) { return MOUSE_DROP_ACTION_WARP_BOTTOM }
    if triangle_contains_point(&left, wp) { return MOUSE_DROP_ACTION_WARP_LEFT }
    return MOUSE_DROP_ACTION_NONE
}

@WM func mouse_drop_try_adjust_tree(_ wm: UnsafeMutablePointer<window_manager>, _ targetView: View, _ target: Window, _ info: UnsafeMutablePointer<mouse_window_info>)
{
    var success = true
    if info.pointee.changed_position {
        var direction: Int32 = 0
        if info.pointee.changed_x { direction |= HANDLE_LEFT }
        if info.pointee.changed_y { direction |= HANDLE_TOP }
        if window_manager_resize_window_relative(wm, target, direction, info.pointee.dx, info.pointee.dy, true) == WINDOW_OP_ERROR_INVALID_DST_NODE { success = false }
    }
    if info.pointee.changed_size {
        var direction: Int32 = 0
        if info.pointee.changed_w && !info.pointee.changed_x { direction |= HANDLE_RIGHT }
        if info.pointee.changed_h && !info.pointee.changed_y { direction |= HANDLE_BOTTOM }
        if window_manager_resize_window_relative(wm, target, direction, info.pointee.dw, info.pointee.dh, true) == WINDOW_OP_ERROR_INVALID_DST_NODE { success = false }
    }
    if !success { view_flush(targetView) }
}

private func mouseDropActionDirection(_ action: mouse_drop_action) -> Int32
{
    switch action {
    case MOUSE_DROP_ACTION_STACK, MOUSE_DROP_ACTION_SWAP: return STACK
    case MOUSE_DROP_ACTION_WARP_TOP: return DIR_NORTH
    case MOUSE_DROP_ACTION_WARP_RIGHT: return DIR_EAST
    case MOUSE_DROP_ACTION_WARP_BOTTOM: return DIR_SOUTH
    case MOUSE_DROP_ACTION_WARP_LEFT: return DIR_WEST
    default: return 0
    }
}

@WM private func mouseFindCon(_ targetView: View?, _ target: Window?) -> UnsafeMutablePointer<con>?
{
    guard let targetView, let target else { return nil }
    return tree_view_find_window(targetView, target.pointee.id)
}

@WM func mouse_feedback_clear(_ ms: UnsafeMutablePointer<mouse_state>)
{
    if ms.pointee.feedback_wid == 0 { return }
    let wm = window_manager_global()!
    let target = window_manager_find_window(wm, ms.pointee.feedback_wid)
    let targetView = target.flatMap { window_manager_find_managed_window(wm, $0) }
    if let container = mouseFindCon(targetView, target), container.pointee.insert_dir == 0 { tree_feedback_hide(container) }
    ms.pointee.feedback_wid = 0
    ms.pointee.feedback_dir = 0
}

//
// NOTE: While a window is dragged over a managed window, the half where it would be placed
// is outlined, or the whole window when dropping would swap or stack them.
//

@WM func mouse_drag(_ ms: UnsafeMutablePointer<mouse_state>, _ dstView: View?, _ dstWindow: Window?, _ point: CGPoint)
{
    guard let container = mouseFindCon(dstView, dstWindow), let dstWindow else { mouse_feedback_clear(ms); return }
    let direction = mouseDropActionDirection(mouse_determine_drop_action(ms, dstWindow, point))
    if ms.pointee.feedback_wid == dstWindow.pointee.id && ms.pointee.feedback_dir == direction { return }
    mouse_feedback_clear(ms)
    if direction == 0 { return }
    tree_feedback_show(container, direction)
    ms.pointee.feedback_wid = dstWindow.pointee.id
    ms.pointee.feedback_dir = direction
}

@WM private func mouseDropNoTarget(_ sm: UnsafeMutablePointer<space_manager>, _ wm: UnsafeMutablePointer<window_manager>, _ srcView: View, _ dstView: View, _ target: Window)
{
    if srcView.pointee.sid == dstView.pointee.sid || dstView.pointee.layout == VIEW_FLOAT { view_flush(srcView); return }
    window_manager_unmanage_window(wm, srcView, target)
    window_manager_manage_window(sm, wm, target, dstView.pointee.sid, 0)
}

//
// NOTE: Dropping a window on a managed window: the center swaps the two windows, or makes
// the dropped window a tab of the other one with mouse_drop_action stack. The edges place the dropped
// window on that side of the other window.
//

@WM func mouse_drop(_ sm: UnsafeMutablePointer<space_manager>?, _ wm: UnsafeMutablePointer<window_manager>, _ ms: UnsafeMutablePointer<mouse_state>, _ srcView: View, _ dstView: View?, _ srcWindow: Window, _ dstWindow: Window?, _ point: CGPoint)
{
    mouse_feedback_clear(ms)
    guard let dstView else { view_flush(srcView); return }
    guard let dstCon = mouseFindCon(dstView, dstWindow), let dstWindow else { mouseDropNoTarget(sm!, wm, srcView, dstView, srcWindow); return }
    let action = mouse_determine_drop_action(ms, dstWindow, point)
    let direction = mouseDropActionDirection(action)
    if action == MOUSE_DROP_ACTION_NONE {
        view_flush(srcView)
    } else if action == MOUSE_DROP_ACTION_SWAP {
        _ = window_manager_swap_window(wm, srcWindow, dstWindow)
    } else if direction == STACK {
        _ = window_manager_stack_window(sm!, wm, dstWindow, srcWindow)
        if srcView != dstView { view_flush(srcView) }
    } else if srcView == dstView {
        guard let container = tree_find_window(srcView.pointee.tree, srcWindow.pointee.id) else { return }
        tree_detach(container)
        tree_insert_relative(dstCon, container, direction)
        tree_focus(container)
        tree_flatten(srcView.pointee.tree)
        if !view_update_auto_padding(srcView) { tree_view_update(srcView) }
        view_flush(srcView)
    } else {
        dstCon.pointee.insert_dir = direction
        dstView.pointee.insertion_point = dstWindow.pointee.id
        window_manager_unmanage_window(wm, srcView, srcWindow)
        window_manager_manage_window(sm!, wm, srcWindow, dstView.pointee.sid, 0)
    }
}

@_cdecl("mouse_state_init")
func mouseStateInit(_ state: UnsafeMutablePointer<mouse_state>)
{
    state.pointee.modifier = UInt8(MOUSE_MOD_FN.rawValue)
    state.pointee.action1 = MOUSE_MODE_MOVE
    state.pointee.action2 = MOUSE_MODE_RESIZE
    state.pointee.drop_action = MOUSE_MODE_SWAP
}

@_cdecl("mouse_handler_begin")
@discardableResult
func mouse_handler_begin(_ state: UnsafeMutablePointer<mouse_state>?, _ mask: UInt32) -> Bool
{
    let state = state!
    if state.pointee.handle != nil { return true }
    guard let handle = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: mouseHandler, userInfo: state) else { return false }
    state.pointee.handle = .passRetained(handle)
    if !CGEvent.tapIsEnabled(tap: handle) {
        CFMachPortInvalidate(handle)
        state.pointee.handle.release()
        mouse_handle_clear(state)
        return false
    }
    let source = CFMachPortCreateRunLoopSource(nil, handle, 0)!
    state.pointee.runloop_source = .passRetained(source)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return true
}

@_cdecl("mouse_handler_end")
func mouse_handler_end(_ state: UnsafeMutablePointer<mouse_state>?)
{
    let state = state!
    guard let handle = state.pointee.handle?.takeUnretainedValue() else { return }
    CGEvent.tapEnable(tap: handle, enable: false)
    CFMachPortInvalidate(handle)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), state.pointee.runloop_source.takeUnretainedValue(), .commonModes)
    state.pointee.runloop_source.release()
    state.pointee.handle.release()
    mouse_handle_clear(state)
}
