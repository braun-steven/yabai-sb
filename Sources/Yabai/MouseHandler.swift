import ApplicationServices
import CPrivate
import Synchronization
import YabaiCore

// Ported from src/mouse_handler.c. The event tap runs on the main run loop and only posts events.

/// `struct mouse_state`
final class MouseState
{
    // NOTE: The event tap reads the handle (a +1 CFMachPort) while the event loop tears it down (mouse_handler_end).
    let handle = Atomic<UnsafeMutableRawPointer?>(nil)
    // NOTE: The tap receives moves for glass hover even when focus-follows-mouse is disabled.
    let tracks_focus = Atomic(false)
    var runloop_source: CFRunLoopSource?
    var consume_mouse_click = false
    var consume_tab_click = false
    var drag_detected = false
    var consumed_event: CGEvent?
    var action1 = MOUSE_MODE_NONE
    var action2 = MOUSE_MODE_NONE
    var modifier: UInt8 = 0
    var drop_action = MOUSE_MODE_NONE
    var current_action = MOUSE_MODE_NONE
    var down_location = CGPoint.zero
    var last_moved_time: UInt64 = 0
    var window: Window!
    var window_frame = CGRect.zero
    var ffm_window_id: UInt32 = 0
    var direction: UInt8 = 0
    var feedback_wid: UInt32 = 0
    var feedback_dir: InsertDirection?

    /// `mouse_handle_load`
    var handlePort: CFMachPort?
    {
        handle.load(ordering: .relaxed).map { Unmanaged<CFMachPort>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// `g_mouse_state`: the event tap reads the fields it read in C, on the main thread (see the NOTE of g_display_manager).
nonisolated(unsafe) let g_mouse_state = MouseState()

func mouse_state_global() -> MouseState
{
    g_mouse_state
}

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
    let ms = Unmanaged<MouseState>.fromOpaque(context!).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let handle = ms.handlePort { CGEvent.tapEnable(tap: handle, enable: true) }
    case .leftMouseDown, .rightMouseDown:
        let mod = mouseModFromCGFlags(event.flags)
        var tabWid: UInt32 = 0
        if type == .leftMouseDown && mod != ms.modifier && tab_bar_hit_test(event.location, &tabWid) {
            tab_bar_pointer_update(event.location, pressed: true)
            ms.consume_tab_click = true
            EventLoop.post(.tabBarClicked(windowID: tabWid))
            return nil
        }
        EventLoop.post(.mouseDown(Handoff(value: .passRetained(event)), modifiers: Int32(mod)))
        if mod == ms.modifier {
            ms.consume_mouse_click = true
            ms.consumed_event = event
            return nil
        }
    case .leftMouseUp, .rightMouseUp:
        if type == .leftMouseUp && ms.consume_tab_click {
            tab_bar_pointer_update(event.location, pressed: false)
            ms.consume_tab_click = false
            return nil
        }
        EventLoop.post(.mouseUp(Handoff(value: .passRetained(event))))
        if ms.consume_mouse_click {
            if !ms.drag_detected {
                ms.consumed_event!.tapPostEvent(proxy)
                event.tapPostEvent(proxy)
            }
            ms.drag_detected = false
            ms.consume_mouse_click = false
            ms.consumed_event = nil
            return nil
        }
    case .leftMouseDragged, .rightMouseDragged:
        if type == .leftMouseDragged && ms.consume_tab_click {
            tab_bar_pointer_update(event.location, pressed: true)
            return nil
        }
        ms.drag_detected = true
        pending_mouse_dragged_add()
        EventLoop.post(.mouseDragged(Handoff(value: .passRetained(event))))
    case .mouseMoved:
        tab_bar_pointer_update(event.location, pressed: false)
        if !ms.tracks_focus.load(ordering: .relaxed) { return .passUnretained(event) }
        let mod = mouseModFromCGFlags(event.flags)
        if mod == ms.modifier { return .passUnretained(event) }
        pending_mouse_moved_add()
        EventLoop.post(.mouseMoved(Handoff(value: .passRetained(event)), modifiers: Int32(mod)))
    default:
        if type.rawValue == UInt32(kCGSEventDockControl) { mouseHandleDockGesture(event) }
    }
    return .passUnretained(event)
}

@WM func mouse_window_info_populate(_ ms: MouseState, _ info: UnsafeMutablePointer<mouse_window_info>)
{
    let frame = ms.window.frame
    info.pointee.dx = Float(frame.origin.x - ms.window_frame.origin.x)
    info.pointee.dy = Float(frame.origin.y - ms.window_frame.origin.y)
    info.pointee.dw = Float(frame.width - ms.window_frame.width)
    info.pointee.dh = Float(frame.height - ms.window_frame.height)
    info.pointee.changed_x = info.pointee.dx != 0
    info.pointee.changed_y = info.pointee.dy != 0
    info.pointee.changed_w = info.pointee.dw != 0
    info.pointee.changed_h = info.pointee.dh != 0
    info.pointee.changed_position = info.pointee.changed_x || info.pointee.changed_y
    info.pointee.changed_size = info.pointee.changed_w || info.pointee.changed_h
}

func mouse_determine_drop_action(_ ms: MouseState, _ target: Window, _ point: CGPoint) -> mouse_drop_action
{
    let f = target.frame
    let wp = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
    let center = CGRect(x: 0.25 * f.width, y: 0.25 * f.height, width: 0.5 * f.width, height: 0.5 * f.height)
    let mid = CGPoint(x: 0.5 * f.width, y: 0.5 * f.height)
    var top = [CGPoint.zero, mid, CGPoint(x: f.width, y: 0)]
    var right = [CGPoint(x: f.width, y: 0), mid, CGPoint(x: f.width, y: f.height)]
    var bottom = [CGPoint(x: f.width, y: f.height), mid, CGPoint(x: 0, y: f.height)]
    var left = [CGPoint(x: 0, y: f.height), mid, CGPoint.zero]
    if center.contains(wp) { return ms.drop_action == MOUSE_MODE_STACK ? MOUSE_DROP_ACTION_STACK : MOUSE_DROP_ACTION_SWAP }
    if triangle_contains_point(&top, wp) { return MOUSE_DROP_ACTION_WARP_TOP }
    if triangle_contains_point(&right, wp) { return MOUSE_DROP_ACTION_WARP_RIGHT }
    if triangle_contains_point(&bottom, wp) { return MOUSE_DROP_ACTION_WARP_BOTTOM }
    if triangle_contains_point(&left, wp) { return MOUSE_DROP_ACTION_WARP_LEFT }
    return MOUSE_DROP_ACTION_NONE
}

@WM func mouse_drop_try_adjust_tree(_ wm: WindowManager, _ targetView: View, _ target: Window, _ info: UnsafeMutablePointer<mouse_window_info>)
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

private func mouseDropActionDirection(_ action: mouse_drop_action) -> InsertDirection?
{
    switch action {
    case MOUSE_DROP_ACTION_STACK, MOUSE_DROP_ACTION_SWAP: return .stack
    case MOUSE_DROP_ACTION_WARP_TOP: return .north
    case MOUSE_DROP_ACTION_WARP_RIGHT: return .east
    case MOUSE_DROP_ACTION_WARP_BOTTOM: return .south
    case MOUSE_DROP_ACTION_WARP_LEFT: return .west
    default: return nil
    }
}

@WM private func mouseFindCon(_ targetView: View?, _ target: Window?) -> Con?
{
    guard let targetView, let target else { return nil }
    return tree_view_find_window(targetView, target.id)
}

@WM func mouse_feedback_clear(_ ms: MouseState)
{
    if ms.feedback_wid == 0 { return }
    let wm = window_manager_global()
    let target = window_manager_find_window(wm, ms.feedback_wid)
    let targetView = target.flatMap { window_manager_find_managed_window(wm, $0) }
    if let container = mouseFindCon(targetView, target), container.insert_dir == nil { tree_feedback_hide(container) }
    ms.feedback_wid = 0
    ms.feedback_dir = nil
}

//
// NOTE: While a window is dragged over a managed window, the half where it would be placed
// is outlined, or the whole window when dropping would swap or stack them.
//

@WM func mouse_drag(_ ms: MouseState, _ dstView: View?, _ dstWindow: Window?, _ point: CGPoint)
{
    guard let container = mouseFindCon(dstView, dstWindow), let dstWindow else { mouse_feedback_clear(ms); return }
    let direction = mouseDropActionDirection(mouse_determine_drop_action(ms, dstWindow, point))
    if ms.feedback_wid == dstWindow.id && ms.feedback_dir == direction { return }
    mouse_feedback_clear(ms)
    guard let direction else { return }
    tree_feedback_show(container, direction)
    ms.feedback_wid = dstWindow.id
    ms.feedback_dir = direction
}

@WM private func mouseDropNoTarget(_ sm: SpaceManager, _ wm: WindowManager, _ srcView: View, _ dstView: View, _ target: Window)
{
    if srcView.sid == dstView.sid || dstView.layout == .float { view_flush(srcView); return }
    window_manager_unmanage_window(wm, srcView, target)
    window_manager_manage_window(sm, wm, target, dstView.sid, 0)
}

//
// NOTE: Dropping a window on a managed window: the center swaps the two windows, or makes
// the dropped window a tab of the other one with mouse_drop_action stack. The edges place the dropped
// window on that side of the other window.
//

@WM func mouse_drop(_ sm: SpaceManager?, _ wm: WindowManager, _ ms: MouseState, _ srcView: View, _ dstView: View?, _ srcWindow: Window, _ dstWindow: Window?, _ point: CGPoint)
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
    } else if direction == .stack {
        _ = window_manager_stack_window(sm!, wm, dstWindow, srcWindow)
        if srcView != dstView { view_flush(srcView) }
    } else if srcView == dstView {
        // NOTE: every action other than none, swap and stack is a warp to a side, so direction is set
        guard let container = tree_find_window(srcView.tree, srcWindow.id), let direction else { return }
        tree_detach(container)
        tree_insert_relative(dstCon, container, direction)
        tree_focus(container)
        tree_flatten(srcView.tree)
        if !view_update_auto_padding(srcView) { tree_view_update(srcView) }
        view_flush(srcView)
    } else {
        dstCon.insert_dir = direction
        dstView.insertion_point = dstWindow.id
        window_manager_unmanage_window(wm, srcView, srcWindow)
        window_manager_manage_window(sm!, wm, srcWindow, dstView.sid, 0)
    }
}

/// `mouse_state_init`
func mouse_state_init(_ state: MouseState)
{
    state.modifier = UInt8(MOUSE_MOD_FN.rawValue)
    state.action1 = MOUSE_MODE_MOVE
    state.action2 = MOUSE_MODE_RESIZE
    state.drop_action = MOUSE_MODE_SWAP
}

//
// NOTE: The tap gets the state as its context, unretained: the state is a global that lives as long as the daemon.
//

/// `mouse_handler_begin`
@discardableResult
func mouse_handler_begin(_ state: MouseState, _ mask: UInt32) -> Bool
{
    if state.handle.load(ordering: .relaxed) != nil { return true }
    let moveMask = UInt32(1 << CGEventType.mouseMoved.rawValue)
    guard let handle = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask | moveMask), callback: mouseHandler, userInfo: Unmanaged.passUnretained(state).toOpaque()) else { return false }
    state.tracks_focus.store(mask & moveMask != 0, ordering: .relaxed)
    state.handle.store(Unmanaged.passRetained(handle).toOpaque(), ordering: .relaxed)
    if !CGEvent.tapIsEnabled(tap: handle) {
        CFMachPortInvalidate(handle)
        Unmanaged<CFMachPort>.passUnretained(handle).release()
        state.handle.store(nil, ordering: .releasing)
        return false
    }
    let source = CFMachPortCreateRunLoopSource(nil, handle, 0)!
    state.runloop_source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return true
}

/// `mouse_handler_end`
func mouse_handler_end(_ state: MouseState)
{
    guard let handle = state.handlePort else { return }
    CGEvent.tapEnable(tap: handle, enable: false)
    CFMachPortInvalidate(handle)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), state.runloop_source!, .commonModes)
    state.runloop_source = nil
    Unmanaged<CFMachPort>.passUnretained(handle).release()
    state.handle.store(nil, ordering: .releasing)
}
