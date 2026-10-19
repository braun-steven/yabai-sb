import ApplicationServices
import CPrivate
import Synchronization
import YabaiCore

// Ported from src/mouse_handler.c. The event tap runs on the main run loop and only posts events.

/// What a mouse drag does (`config mouse_action1`, `mouse_action2`, `mouse_drop_action`), named by its config value.
enum MouseAction: String, Sendable
{
    case none
    case move
    case resize
    case swap
    case stack
}

/// Where a dragged window is dropped on a managed window: nowhere, its center (stack or swap) or one of its edges.
enum MouseDropAction: Sendable
{
    case none
    case stack
    case swap
    case warpTop
    case warpRight
    case warpBottom
    case warpLeft
}

/// The modifier keys held during a mouse event, as far as mouse actions tell them apart.
struct MouseModifiers: OptionSet, Sendable
{
    let rawValue: UInt8

    static let alt   = MouseModifiers(rawValue: 0x02)
    static let shift = MouseModifiers(rawValue: 0x04)
    static let cmd   = MouseModifiers(rawValue: 0x08)
    static let ctrl  = MouseModifiers(rawValue: 0x10)
    static let fn    = MouseModifiers(rawValue: 0x20)
}

/// The key that has to be held, alone, for the mouse actions (`config mouse_modifier`).
enum MouseModifierKey: String, CaseIterable, Sendable
{
    case alt
    case shift
    case cmd
    case ctrl
    case fn

    var modifiers: MouseModifiers
    {
        switch self {
        case .alt:   .alt
        case .shift: .shift
        case .cmd:   .cmd
        case .ctrl:  .ctrl
        case .fn:    .fn
        }
    }
}

//
// NOTE: The private event type, fields and values of the Dock swipe gesture that switches spaces (an anonymous C enum
// in the C version, which Swift imported as Int).
//

enum DockSwipe
{
    static let eventType: UInt32 = 30                        // kCGSEventDockControl
    static let typeField = CGEventField(rawValue: 55)!       // kCGSEventTypeField
    static let hidTypeField = CGEventField(rawValue: 110)!   // kCGEventGestureHIDType
    static let motionField = CGEventField(rawValue: 123)!    // kCGEventGestureSwipeMotion
    static let progressField = CGEventField(rawValue: 124)!  // kCGEventGestureSwipeProgress
    static let velocityXField = CGEventField(rawValue: 129)! // kCGEventGestureSwipeVelocityX
    static let phaseField = CGEventField(rawValue: 132)!     // kCGEventGesturePhase
    static let hidType: Int64 = 23                           // kIOHIDEventTypeDockSwipe
    static let motionHorizontal: Int64 = 1                   // kCGGestureMotionHorizontal
    static let phaseBegan: Int64 = 1                         // kCGSGesturePhaseBegan
    static let phaseEnded: Int64 = 4                         // kCGSGesturePhaseEnded
    static let phaseCancelled: Int64 = 8                     // kCGSGesturePhaseCancelled
}

/// `struct mouse_window_info`: how a dragged window changed.
struct MouseWindowChange: Sendable
{
    var dx: Float = 0, dy: Float = 0, dw: Float = 0, dh: Float = 0
    var changed_x = false, changed_y = false
    var changed_w = false, changed_h = false
    var changed_position = false
    var changed_size = false
}

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
    var action1 = MouseAction.none
    var action2 = MouseAction.none
    var modifier = MouseModifierKey.fn
    var drop_action = MouseAction.none
    var current_action = MouseAction.none
    var down_location = CGPoint.zero
    var last_moved_time: UInt64 = 0
    var window: Window!
    var window_frame = CGRect.zero
    var ffm_window_id: WindowID?
    var direction: ResizeHandle = []
    var feedback_wid: WindowID?
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

private func mouseModFromCGFlags(_ flags: CGEventFlags) -> MouseModifiers
{
    var result: MouseModifiers = []
    if flags.contains(.maskAlternate) { result.insert(.alt) }
    if flags.contains(.maskShift) { result.insert(.shift) }
    if flags.contains(.maskCommand) { result.insert(.cmd) }
    if flags.contains(.maskControl) { result.insert(.ctrl) }
    if flags.contains(.maskSecondaryFn) { result.insert(.fn) }
    return result
}

//
// NOTE: Focus follows mouse is paused while a horizontal swipe switches spaces, and for a moment after it.
//

private func mouseHandleDockGesture(_ event: CGEvent)
{
    guard event.getIntegerValueField(DockSwipe.hidTypeField) == DockSwipe.hidType,
          event.getIntegerValueField(DockSwipe.motionField) == DockSwipe.motionHorizontal else { return }
    let phase = event.getIntegerValueField(DockSwipe.phaseField)
    if phase == DockSwipe.phaseBegan {
        pending_gesture_set(true)
    } else if phase == DockSwipe.phaseEnded || phase == DockSwipe.phaseCancelled {
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
        var tabWid: WindowID?
        if type == .leftMouseDown && mod != ms.modifier.modifiers && tab_bar_hit_test(event.location, &tabWid) {
            tab_bar_pointer_update(event.location, pressed: true)
            ms.consume_tab_click = true
            if let tabWid { EventLoop.post(.tabBarClicked(windowID: tabWid)) }
            return nil
        }
        EventLoop.post(.mouseDown(Handoff(value: .passRetained(event)), modifiers: mod))
        if mod == ms.modifier.modifiers {
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
        if mod == ms.modifier.modifiers { return .passUnretained(event) }
        pending_mouse_moved_add()
        EventLoop.post(.mouseMoved(Handoff(value: .passRetained(event)), modifiers: mod))
    default:
        if type.rawValue == DockSwipe.eventType { mouseHandleDockGesture(event) }
    }
    return .passUnretained(event)
}

@WM func mouse_window_info_populate(_ ms: MouseState, _ info: UnsafeMutablePointer<MouseWindowChange>)
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

func mouse_determine_drop_action(_ ms: MouseState, _ target: Window, _ point: CGPoint) -> MouseDropAction
{
    let f = target.frame
    let wp = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
    let center = CGRect(x: 0.25 * f.width, y: 0.25 * f.height, width: 0.5 * f.width, height: 0.5 * f.height)
    let mid = CGPoint(x: 0.5 * f.width, y: 0.5 * f.height)
    var top = [CGPoint.zero, mid, CGPoint(x: f.width, y: 0)]
    var right = [CGPoint(x: f.width, y: 0), mid, CGPoint(x: f.width, y: f.height)]
    var bottom = [CGPoint(x: f.width, y: f.height), mid, CGPoint(x: 0, y: f.height)]
    var left = [CGPoint(x: 0, y: f.height), mid, CGPoint.zero]
    if center.contains(wp) { return ms.drop_action == .stack ? .stack : .swap }
    if triangle_contains_point(&top, wp) { return .warpTop }
    if triangle_contains_point(&right, wp) { return .warpRight }
    if triangle_contains_point(&bottom, wp) { return .warpBottom }
    if triangle_contains_point(&left, wp) { return .warpLeft }
    return .none
}

@WM func mouse_drop_try_adjust_tree(_ wm: WindowManager, _ targetView: View, _ target: Window, _ info: UnsafeMutablePointer<MouseWindowChange>)
{
    var success = true
    if info.pointee.changed_position {
        var direction: ResizeHandle = []
        if info.pointee.changed_x { direction.insert(.left) }
        if info.pointee.changed_y { direction.insert(.top) }
        if window_manager_resize_window_relative(wm, target, direction, info.pointee.dx, info.pointee.dy, true) == .invalidDestinationNode { success = false }
    }
    if info.pointee.changed_size {
        var direction: ResizeHandle = []
        if info.pointee.changed_w && !info.pointee.changed_x { direction.insert(.right) }
        if info.pointee.changed_h && !info.pointee.changed_y { direction.insert(.bottom) }
        if window_manager_resize_window_relative(wm, target, direction, info.pointee.dw, info.pointee.dh, true) == .invalidDestinationNode { success = false }
    }
    if !success { view_flush(targetView) }
}

private func mouseDropActionDirection(_ action: MouseDropAction) -> InsertDirection?
{
    switch action {
    case .stack, .swap: .stack
    case .warpTop:      .north
    case .warpRight:    .east
    case .warpBottom:   .south
    case .warpLeft:     .west
    case .none:         nil
    }
}

@WM private func mouseFindCon(_ targetView: View?, _ target: Window?) -> Con?
{
    guard let targetView, let target else { return nil }
    return tree_view_find_window(targetView, target.id)
}

@WM func mouse_feedback_clear(_ ms: MouseState)
{
    guard let feedbackWid = ms.feedback_wid else { return }
    let wm = window_manager_global()
    let target = window_manager_find_window(wm, feedbackWid)
    let targetView = target.flatMap { window_manager_find_managed_window(wm, $0) }
    if let container = mouseFindCon(targetView, target), container.insertDirection == nil { tree_feedback_hide(container) }
    ms.feedback_wid = nil
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
    window_manager_manage_window(sm, wm, target, dstView.sid, nil)
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
    if action == .none {
        view_flush(srcView)
    } else if action == .swap {
        _ = window_manager_swap_window(wm, srcWindow, dstWindow)
    } else if direction == .stack {
        _ = window_manager_stack_window(sm!, wm, dstWindow, srcWindow)
        if srcView != dstView { view_flush(srcView) }
    } else if srcView == dstView {
        // NOTE: every action other than none, swap and stack is a warp to a side, so direction is set
        guard let container = srcView.tree?.find(srcWindow.id), let direction else { return }
        container.detach()
        dstCon.insert(container, toward: direction)
        container.focus()
        srcView.tree!.flatten()
        if !view_update_auto_padding(srcView) { tree_view_update(srcView) }
        view_flush(srcView)
    } else {
        dstCon.insertDirection = direction
        dstView.insertion_point = dstWindow.id
        window_manager_unmanage_window(wm, srcView, srcWindow)
        window_manager_manage_window(sm!, wm, srcWindow, dstView.sid, nil)
    }
}

/// `mouse_state_init`
func mouse_state_init(_ state: MouseState)
{
    state.modifier = .fn
    state.action1 = .move
    state.action2 = .resize
    state.drop_action = .swap
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
