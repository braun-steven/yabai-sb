import ApplicationServices
import Dispatch
import YabaiCore

//
// NOTE: The event loop. Producers on other threads (AX observers, SkyLight notify procs, the NSWorkspace notifications,
// the mouse event tap, the socket thread) only post events; the handlers run one at a time on the serial queue of the
// @WM actor, in the order the events were posted. After each handler the signals it pushed run. Events never go
// through Task {}: a task could run them out of order. The handlers are EventHandler methods, in EventHandler*.swift.
//

/// The actor of the window manager state. Its executor is the serial queue of the event loop.
@globalActor
actor WM
{
    static let shared = WM()

    //
    // NOTE: An autorelease pool drains after each event (autoreleaseFrequency: .workItem). The queue has the default QoS.
    //

    nonisolated let queue = DispatchSerialQueue(label: "yabai.wm", qos: .default, autoreleaseFrequency: .workItem)

    nonisolated var unownedExecutor: UnownedSerialExecutor
    {
        queue.asUnownedSerialExecutor()
    }

    //
    // NOTE: Runs code isolated to @WM from a synchronous context that is already on the queue, e.g. a callback
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
// loop uses it. The handler owns the object: handle takes the retained CF object (the AX element
// of a new window, a mouse event) with takeRetainedValue, and the models belong to their managers.
//

/// A model object (a process, a window) or a retained CF object that a producer hands to the handler of its event.
struct Handoff<Value>: @unchecked Sendable
{
    let value: Value
}

/// The events of the event loop, with the context and param1 of each event as associated values.
enum Event: Sendable
{
    case applicationLaunched(Handoff<Process>)
    case applicationTerminated(Handoff<Process>)
    case applicationFrontSwitched(Handoff<Process>)
    case applicationVisible(pid: pid_t)
    case applicationHidden(pid: pid_t)
    case windowCreated(Handoff<Unmanaged<AXUIElement>>)
    case windowDestroyed(Handoff<Window>)
    case windowFocused(windowID: WindowID?)
    case windowFocusDeferred(windowID: WindowID)
    case windowMoved(windowID: WindowID)
    case windowResized(windowID: WindowID)
    case windowMinimized(Handoff<Window>)
    case windowDeminimized(Handoff<Window>)
    case windowTitleChanged(windowID: WindowID)
    case slsWindowOrdered(windowID: WindowID)
    case slsWindowDestroyed(windowID: WindowID)
    case slsSpaceCreated(spaceID: SpaceID)
    case slsSpaceDestroyed(spaceID: SpaceID)
    case spaceChanged
    case displayAdded(displayID: DisplayID)
    case displayRemoved(displayID: DisplayID)
    case displayMoved(displayID: DisplayID)
    case displayResized(displayID: DisplayID)
    case displayChanged
    case mouseDown(Handoff<Unmanaged<CGEvent>>, modifiers: MouseModifiers)
    case mouseUp(Handoff<Unmanaged<CGEvent>>)
    case mouseDragged(Handoff<Unmanaged<CGEvent>>)
    case mouseMoved(Handoff<Unmanaged<CGEvent>>, modifiers: MouseModifiers)
    case tabBarClicked(windowID: WindowID)
    case tabCardOrdered(windowID: WindowID)
    case missionControlShowAllWindows
    case missionControlShowFrontWindows
    case missionControlShowDesktop
    case missionControlEnter
    case missionControlCheckForExit
    case missionControlExit
    case dockDidRestart
    case menuOpened(windowID: WindowID?)
    case menuClosed
    case menuBarHiddenChanged
    case dockDidChangePref
    case systemWoke
    case spaceLayoutReconcile(generation: UInt32)
    case daemonMessage(sockfd: Int32)
}

enum EventLoop
{
    /// Posts an event. Callable from any thread.
    static func post(_ event: Event)
    {
        WM.shared.queue.async {
            WM.assumeIsolated {
                EventHandler.shared.handle(event)
                EventSignals.shared.flush()
            }
        }
    }
}

extension EventHandler
{
    /// Runs the handler of an event. The retained CF objects are taken here, so they are released when the handler
    /// returns.
    func handle(_ event: Event)
    {
        switch event {
        case .applicationLaunched(let process):          applicationLaunched(process.value)
        case .applicationTerminated(let process):        applicationTerminated(process.value)
        case .applicationFrontSwitched(let process):     applicationFrontSwitched(process.value)
        case .applicationVisible(let pid):               applicationVisible(pid)
        case .applicationHidden(let pid):                applicationHidden(pid)
        case .windowCreated(let element):                windowCreated(element.value.takeRetainedValue())
        case .windowDestroyed(let window):               windowDestroyed(window.value)
        case .windowFocused(let wid):                    windowFocused(wid)
        case .windowFocusDeferred(let wid):              windowFocusDeferred(wid)
        case .windowMoved(let wid):                      windowMoved(wid)
        case .windowResized(let wid):                    windowResized(wid)
        case .windowMinimized(let window):               windowMinimized(window.value)
        case .windowDeminimized(let window):             windowDeminimized(window.value)
        case .windowTitleChanged(let wid):               windowTitleChanged(wid)
        case .slsWindowOrdered(let wid):                 slsWindowOrdered(wid)
        case .slsWindowDestroyed(let wid):               slsWindowDestroyed(wid)
        case .slsSpaceCreated(let sid):                  slsSpaceCreated(sid)
        case .slsSpaceDestroyed(let sid):                slsSpaceDestroyed(sid)
        case .spaceChanged:                              spaceChanged()
        case .displayAdded(let did):                     displayAdded(did)
        case .displayRemoved(let did):                   displayRemoved(did)
        case .displayMoved(let did):                     displayMoved(did)
        case .displayResized(let did):                   displayResized(did)
        case .displayChanged:                            displayChanged()
        case .mouseDown(let event, let modifiers):       mouseDown(event.value.takeRetainedValue(), modifiers)
        case .mouseUp(let event):                        mouseUp(event.value.takeRetainedValue())
        case .mouseDragged(let event):                   mouseDragged(event.value.takeRetainedValue())
        case .mouseMoved(let event, _):                  mouseMoved(event.value.takeRetainedValue())
        case .tabBarClicked(let wid):                    tabBarClicked(wid)
        case .tabCardOrdered(let wid):                   tabCardOrdered(wid)
        case .missionControlShowAllWindows:              missionControlShowAllWindows()
        case .missionControlShowFrontWindows:            missionControlShowFrontWindows()
        case .missionControlShowDesktop:                 missionControlShowDesktop()
        case .missionControlEnter:                       missionControlEnter()
        case .missionControlCheckForExit:                missionControlCheckForExit()
        case .missionControlExit:                        missionControlExit()
        case .dockDidRestart:                            dockDidRestart()
        case .menuOpened:                                menuOpened()
        case .menuClosed:                                menuClosed()
        case .menuBarHiddenChanged:                      menuBarHiddenChanged()
        case .dockDidChangePref:                         dockDidChangePref()
        case .systemWoke:                                systemWoke()
        case .spaceLayoutReconcile(let generation):      spaceLayoutReconcile(generation)
        case .daemonMessage(let sockfd):                 daemon_message_handle(sockfd)
        }
    }
}
