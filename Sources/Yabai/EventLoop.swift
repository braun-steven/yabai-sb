import ApplicationServices
import Dispatch
import YabaiC

//
// NOTE: The event loop. Producers on other threads (AX observers, SkyLight notify procs, the NSWorkspace notifications,
// the mouse event tap, the socket thread) only post events; the handlers run one at a time on the serial queue of the
// @WM actor, in the order the events were posted. After each handler the signals it pushed run, and the temporary
// storage is reset. Events never go through Task {}: a task could run them out of order. Ported from src/event_loop.c
// (a worker thread draining a lock-free queue); the handlers stay C until P8 of the port.
//

/// The actor of the window manager state. Its executor is the serial queue of the event loop.
@globalActor
actor WM
{
    static let shared = WM()

    //
    // NOTE: An autorelease pool around each event, like the pool the C loop drained when the queue was empty. The
    // queue has the default QoS, like the pthread of the C loop.
    //

    nonisolated let queue = DispatchSerialQueue(label: "yabai.wm", qos: .default, autoreleaseFrequency: .workItem)

    nonisolated var unownedExecutor: UnownedSerialExecutor
    {
        queue.asUnownedSerialExecutor()
    }

    //
    // NOTE: Runs code isolated to @WM from a synchronous context that is already on the queue, e.g. a C function
    // that the event loop called. It traps when called from another thread, like MainActor.assumeIsolated, which a
    // custom global actor does not get from the standard library.
    //

    static func assumeIsolated<T>(_ operation: @WM () throws -> T) rethrows -> T
    {
        shared.preconditionIsolated()
        return try withoutActuallyEscaping(operation) { operation in
            try unsafeBitCast(operation, to: (() throws -> T).self)()
        }
    }
}

//
// NOTE: @unchecked Sendable: a producer gives up the object when it posts the event, and from then on only the event
// loop uses it, as with the C queue. The handler owns the object: it releases a retained CF object (the AX element of
// a new window, a mouse event), and the C structs belong to their managers.
//

/// A C object (a process, a window) or a retained CF object that a producer hands to the handler of its event.
struct Handoff<Value>: @unchecked Sendable
{
    let value: Value
}

/// `enum event_type` (src/event_loop.h), with the context and param1 of each event as associated values.
enum Event: Sendable
{
    case applicationLaunched(Handoff<UnsafeMutablePointer<process>>)
    case applicationTerminated(Handoff<UnsafeMutablePointer<process>>)
    case applicationFrontSwitched(Handoff<UnsafeMutablePointer<process>>)
    case applicationVisible(pid: pid_t)
    case applicationHidden(pid: pid_t)
    case windowCreated(Handoff<Unmanaged<AXUIElement>>)
    case windowDestroyed(Handoff<UnsafeMutablePointer<window>>)
    case windowFocused(windowID: UInt32)
    case windowFocusDeferred(windowID: UInt32)
    case windowMoved(windowID: UInt32)
    case windowResized(windowID: UInt32)
    case windowMinimized(Handoff<UnsafeMutablePointer<window>>)
    case windowDeminimized(Handoff<UnsafeMutablePointer<window>>)
    case windowTitleChanged(windowID: UInt32)
    case slsWindowOrdered(windowID: UInt32)
    case slsWindowDestroyed(windowID: UInt32)
    case slsSpaceCreated(spaceID: UInt64)
    case slsSpaceDestroyed(spaceID: UInt64)
    case spaceChanged
    case displayAdded(displayID: UInt32)
    case displayRemoved(displayID: UInt32)
    case displayMoved(displayID: UInt32)
    case displayResized(displayID: UInt32)
    case displayChanged
    case mouseDown(Handoff<Unmanaged<CGEvent>>, modifiers: Int32)
    case mouseUp(Handoff<Unmanaged<CGEvent>>)
    case mouseDragged(Handoff<Unmanaged<CGEvent>>)
    case mouseMoved(Handoff<Unmanaged<CGEvent>>, modifiers: Int32)
    case tabBarClicked(windowID: UInt32)
    case missionControlShowAllWindows
    case missionControlShowFrontWindows
    case missionControlShowDesktop
    case missionControlEnter
    case missionControlCheckForExit
    case missionControlExit
    case dockDidRestart
    case menuOpened(windowID: UInt32)
    case menuClosed
    case menuBarHiddenChanged
    case dockDidChangePref
    case systemWoke
    case spaceLayoutReconcile(generation: Int32)
    case daemonMessage(sockfd: Int32)
}

enum EventLoop
{
    /// `event_loop_post`: callable from any thread.
    static func post(_ event: Event)
    {
        WM.shared.queue.async {
            WM.assumeIsolated {
                handle(event)
                eventSignalFlush()
                ts_reset_storage()
            }
        }
    }
}

//
// NOTE: The C producers pass an id as the context pointer ((void *)(intptr_t) wid) and the handlers convert it back
// the same way, so these conversions only have to round-trip.
//

private func id32(_ context: UnsafeMutableRawPointer?) -> UInt32
{
    UInt32(truncatingIfNeeded: Int(bitPattern: context))
}

private func id64(_ context: UnsafeMutableRawPointer?) -> UInt64
{
    UInt64(UInt(bitPattern: context))
}

private func context(_ id: UInt32) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: Int(id))
}

private func context(_ id: UInt64) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: UInt(id))
}

private func context(_ pid: pid_t) -> UnsafeMutableRawPointer?
{
    UnsafeMutableRawPointer(bitPattern: Int(pid))
}

private func handoff<T>(_ context: UnsafeMutableRawPointer?, _ type: T.Type) -> Handoff<UnsafeMutablePointer<T>>
{
    Handoff(value: context!.assumingMemoryBound(to: T.self))
}

private func handoff<T: AnyObject>(_ context: UnsafeMutableRawPointer?, _ type: T.Type) -> Handoff<Unmanaged<T>>
{
    Handoff(value: Unmanaged<T>.fromOpaque(context!))
}

/// The C entry point of `EventLoop.post`: maps the type, context and param1 of a C producer to an Event.
@_cdecl("event_loop_post")
func event_loop_post(_ type: event_type, _ context: UnsafeMutableRawPointer?, _ param1: Int32)
{
    let event: Event = switch type {
    case APPLICATION_LAUNCHED:               .applicationLaunched(handoff(context, process.self))
    case APPLICATION_TERMINATED:             .applicationTerminated(handoff(context, process.self))
    case APPLICATION_FRONT_SWITCHED:         .applicationFrontSwitched(handoff(context, process.self))
    case APPLICATION_VISIBLE:                .applicationVisible(pid: pid_t(truncatingIfNeeded: Int(bitPattern: context)))
    case APPLICATION_HIDDEN:                 .applicationHidden(pid: pid_t(truncatingIfNeeded: Int(bitPattern: context)))
    case WINDOW_CREATED:                     .windowCreated(handoff(context, AXUIElement.self))
    case WINDOW_DESTROYED:                   .windowDestroyed(handoff(context, window.self))
    case WINDOW_FOCUSED:                     .windowFocused(windowID: id32(context))
    case WINDOW_FOCUS_DEFERRED:              .windowFocusDeferred(windowID: id32(context))
    case WINDOW_MOVED:                       .windowMoved(windowID: id32(context))
    case WINDOW_RESIZED:                     .windowResized(windowID: id32(context))
    case WINDOW_MINIMIZED:                   .windowMinimized(handoff(context, window.self))
    case WINDOW_DEMINIMIZED:                 .windowDeminimized(handoff(context, window.self))
    case WINDOW_TITLE_CHANGED:               .windowTitleChanged(windowID: id32(context))
    case SLS_WINDOW_ORDERED:                 .slsWindowOrdered(windowID: id32(context))
    case SLS_WINDOW_DESTROYED:               .slsWindowDestroyed(windowID: id32(context))
    case SLS_SPACE_CREATED:                  .slsSpaceCreated(spaceID: id64(context))
    case SLS_SPACE_DESTROYED:                .slsSpaceDestroyed(spaceID: id64(context))
    case SPACE_CHANGED:                      .spaceChanged
    case DISPLAY_ADDED:                      .displayAdded(displayID: id32(context))
    case DISPLAY_REMOVED:                    .displayRemoved(displayID: id32(context))
    case DISPLAY_MOVED:                      .displayMoved(displayID: id32(context))
    case DISPLAY_RESIZED:                    .displayResized(displayID: id32(context))
    case DISPLAY_CHANGED:                    .displayChanged
    case MOUSE_DOWN:                         .mouseDown(handoff(context, CGEvent.self), modifiers: param1)
    case MOUSE_UP:                           .mouseUp(handoff(context, CGEvent.self))
    case MOUSE_DRAGGED:                      .mouseDragged(handoff(context, CGEvent.self))
    case MOUSE_MOVED:                        .mouseMoved(handoff(context, CGEvent.self), modifiers: param1)
    case TAB_BAR_CLICKED:                    .tabBarClicked(windowID: id32(context))
    case MISSION_CONTROL_SHOW_ALL_WINDOWS:   .missionControlShowAllWindows
    case MISSION_CONTROL_SHOW_FRONT_WINDOWS: .missionControlShowFrontWindows
    case MISSION_CONTROL_SHOW_DESKTOP:       .missionControlShowDesktop
    case MISSION_CONTROL_ENTER:              .missionControlEnter
    case MISSION_CONTROL_CHECK_FOR_EXIT:     .missionControlCheckForExit
    case MISSION_CONTROL_EXIT:               .missionControlExit
    case DOCK_DID_RESTART:                   .dockDidRestart
    case MENU_OPENED:                        .menuOpened(windowID: id32(context))
    case MENU_CLOSED:                        .menuClosed
    case MENU_BAR_HIDDEN_CHANGED:            .menuBarHiddenChanged
    case DOCK_DID_CHANGE_PREF:               .dockDidChangePref
    case SYSTEM_WOKE:                        .systemWoke
    case SPACE_LAYOUT_RECONCILE:             .spaceLayoutReconcile(generation: param1)
    case DAEMON_MESSAGE:                     .daemonMessage(sockfd: param1)
    default:                                 preconditionFailure("unknown event type \(type.rawValue)")
    }

    EventLoop.post(event)
}

/// Runs the C handler of an event with the context and param1 it was posted with.
@WM private func handle(_ event: Event)
{
    switch event {
    case .applicationLaunched(let process):          EVENT_HANDLER_APPLICATION_LAUNCHED(UnsafeMutableRawPointer(process.value), 0)
    case .applicationTerminated(let process):        EVENT_HANDLER_APPLICATION_TERMINATED(UnsafeMutableRawPointer(process.value), 0)
    case .applicationFrontSwitched(let process):     EVENT_HANDLER_APPLICATION_FRONT_SWITCHED(UnsafeMutableRawPointer(process.value), 0)
    case .applicationVisible(let pid):               EVENT_HANDLER_APPLICATION_VISIBLE(context(pid), 0)
    case .applicationHidden(let pid):                EVENT_HANDLER_APPLICATION_HIDDEN(context(pid), 0)
    case .windowCreated(let element):                EVENT_HANDLER_WINDOW_CREATED(element.value.toOpaque(), 0)
    case .windowDestroyed(let window):               EVENT_HANDLER_WINDOW_DESTROYED(UnsafeMutableRawPointer(window.value), 0)
    case .windowFocused(let wid):                    EVENT_HANDLER_WINDOW_FOCUSED(context(wid), 0)
    case .windowFocusDeferred(let wid):              EVENT_HANDLER_WINDOW_FOCUS_DEFERRED(context(wid), 0)
    case .windowMoved(let wid):                      EVENT_HANDLER_WINDOW_MOVED(context(wid), 0)
    case .windowResized(let wid):                    EVENT_HANDLER_WINDOW_RESIZED(context(wid), 0)
    case .windowMinimized(let window):               EVENT_HANDLER_WINDOW_MINIMIZED(UnsafeMutableRawPointer(window.value), 0)
    case .windowDeminimized(let window):             EVENT_HANDLER_WINDOW_DEMINIMIZED(UnsafeMutableRawPointer(window.value), 0)
    case .windowTitleChanged(let wid):               EVENT_HANDLER_WINDOW_TITLE_CHANGED(context(wid), 0)
    case .slsWindowOrdered(let wid):                 EVENT_HANDLER_SLS_WINDOW_ORDERED(context(wid), 0)
    case .slsWindowDestroyed(let wid):               EVENT_HANDLER_SLS_WINDOW_DESTROYED(context(wid), 0)
    case .slsSpaceCreated(let sid):                  EVENT_HANDLER_SLS_SPACE_CREATED(context(sid), 0)
    case .slsSpaceDestroyed(let sid):                EVENT_HANDLER_SLS_SPACE_DESTROYED(context(sid), 0)
    case .spaceChanged:                              EVENT_HANDLER_SPACE_CHANGED(nil, 0)
    case .displayAdded(let did):                     EVENT_HANDLER_DISPLAY_ADDED(context(did), 0)
    case .displayRemoved(let did):                   EVENT_HANDLER_DISPLAY_REMOVED(context(did), 0)
    case .displayMoved(let did):                     EVENT_HANDLER_DISPLAY_MOVED(context(did), 0)
    case .displayResized(let did):                   EVENT_HANDLER_DISPLAY_RESIZED(context(did), 0)
    case .displayChanged:                            EVENT_HANDLER_DISPLAY_CHANGED(nil, 0)
    case .mouseDown(let event, let modifiers):       EVENT_HANDLER_MOUSE_DOWN(event.value.toOpaque(), modifiers)
    case .mouseUp(let event):                        EVENT_HANDLER_MOUSE_UP(event.value.toOpaque(), 0)
    case .mouseDragged(let event):                   EVENT_HANDLER_MOUSE_DRAGGED(event.value.toOpaque(), 0)
    case .mouseMoved(let event, let modifiers):      EVENT_HANDLER_MOUSE_MOVED(event.value.toOpaque(), modifiers)
    case .tabBarClicked(let wid):                    EVENT_HANDLER_TAB_BAR_CLICKED(context(wid), 0)
    case .missionControlShowAllWindows:              EVENT_HANDLER_MISSION_CONTROL_SHOW_ALL_WINDOWS(nil, 0)
    case .missionControlShowFrontWindows:            EVENT_HANDLER_MISSION_CONTROL_SHOW_FRONT_WINDOWS(nil, 0)
    case .missionControlShowDesktop:                 EVENT_HANDLER_MISSION_CONTROL_SHOW_DESKTOP(nil, 0)
    case .missionControlEnter:                       EVENT_HANDLER_MISSION_CONTROL_ENTER(nil, 0)
    case .missionControlCheckForExit:                EVENT_HANDLER_MISSION_CONTROL_CHECK_FOR_EXIT(nil, 0)
    case .missionControlExit:                        EVENT_HANDLER_MISSION_CONTROL_EXIT(nil, 0)
    case .dockDidRestart:                            EVENT_HANDLER_DOCK_DID_RESTART(nil, 0)
    case .menuOpened(let wid):                       EVENT_HANDLER_MENU_OPENED(context(wid), 0)
    case .menuClosed:                                EVENT_HANDLER_MENU_CLOSED(nil, 0)
    case .menuBarHiddenChanged:                      EVENT_HANDLER_MENU_BAR_HIDDEN_CHANGED(nil, 0)
    case .dockDidChangePref:                         EVENT_HANDLER_DOCK_DID_CHANGE_PREF(nil, 0)
    case .systemWoke:                                EVENT_HANDLER_SYSTEM_WOKE(nil, 0)
    case .spaceLayoutReconcile(let generation):      EVENT_HANDLER_SPACE_LAYOUT_RECONCILE(nil, generation)
    case .daemonMessage(let sockfd):                 EVENT_HANDLER_DAEMON_MESSAGE(nil, sockfd)
    }
}
