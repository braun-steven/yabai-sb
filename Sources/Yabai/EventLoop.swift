import ApplicationServices
import Dispatch
import Synchronization
import YabaiCore

//
// NOTE: The event loop. Producers on other threads (AX observers, SkyLight notify procs, the NSWorkspace notifications,
// the mouse event tap, the socket thread) only yield events into one AsyncStream; a single long-lived @WM task
// consumes it and runs the handlers one at a time, in the order the events were posted. A handler that waits is
// async: the loop awaits it before it takes the next event, but other @WM code (WM.sync blocks, C callbacks on
// yabai.wm) can run at its await, so the handler re-checks the state it relies on afterwards. After each handler
// the signals it pushed run. Events never get a Task {} of their own: separate tasks could run them out of order.
// Delays post their event later through post(_:after:). The handlers are EventHandler methods, in EventHandler*.swift.
//

/// The actor of the window manager state. Its executor is the serial queue of the event loop.
@globalActor
actor WM
{
    static let shared = WM()

    //
    // NOTE: The queue has the default QoS and drains an autorelease pool after each work item (WM.sync blocks, C
    // callbacks); the event loop drains its own pool per event, since one work item of its task can handle several.
    //

    nonisolated let queue = DispatchSerialQueue(label: "yabai.wm", qos: .default, autoreleaseFrequency: .workItem)

    nonisolated var unownedExecutor: UnownedSerialExecutor
    {
        queue.asUnownedSerialExecutor()
    }

    //
    // NOTE: Runs code isolated to @WM from a synchronous context that is already on the queue but has no static
    // isolation: the block of WM.sync. Code that is @WM itself calls @WM code directly. It traps when called from
    // another thread, like MainActor.assumeIsolated, which a custom global actor does not get from the standard
    // library.
    //

    static func assumeIsolated<T>(_ operation: @WM () throws -> T) rethrows -> T
    {
        shared.preconditionIsolated()
        return try withoutActuallyEscaping(operation) { operation in
            try unsafeBitCast(operation, to: (() throws -> T).self)()
        }
    }

    //
    // NOTE: Runs code isolated to @WM from another thread (the startup on the main thread) and waits until it returns.
    // It deadlocks when called on the queue itself.
    //

    static func sync<T>(_ operation: @WM () throws -> T) rethrows -> T
    {
        try shared.queue.sync { try assumeIsolated(operation) }
    }
}

//
// NOTE: @unchecked Sendable: the retained CF objects that events carry (the AX element of a new window, a mouse event)
// are not Sendable. A producer gives up its +1 reference when it posts the event, and from then on only the event
// loop uses it: handle takes it with takeRetainedValue, so it is released when the handler returns. The models
// (Process, Window) are @WM and therefore Sendable, so events carry them directly.
//

/// A retained CF object that a producer hands to the handler of its event.
struct Handoff<Value>: @unchecked Sendable
{
    let value: Value
}

/// The events of the event loop, with the context and param1 of each event as associated values.
enum Event: Sendable
{
    case carbonProcessLaunched(ProcessKey)
    case carbonProcessTerminated(ProcessKey)
    case carbonProcessFrontSwitched(ProcessKey)
    case applicationLaunchRetry(ProcessKey)
    case applicationLaunched(Process)
    case applicationTerminated(Process)
    case applicationFrontSwitched(Process)
    case applicationVisible(pid: pid_t)
    case applicationHidden(pid: pid_t)
    case windowCreated(Handoff<Unmanaged<AXUIElement>>)
    case windowDestroyed(Window)
    case windowFocused(windowID: WindowID?)
    case windowFocusDeferred(windowID: WindowID)
    case windowMoved(windowID: WindowID)
    case windowResized(windowID: WindowID)
    case windowMinimized(Window)
    case windowDeminimized(Window)
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
    case configChanged(ConfigGroup)
    case spaceLayoutReconcile(generation: UInt32)
    case daemonMessage(DaemonMessage)
}

enum EventLoop
{
    //
    // NOTE: Unbounded, so a producer never blocks or drops an event. Events posted before start() wait in the buffer.
    //

    private static let events = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)

    /// Posts an event. Callable from any thread.
    static func post(_ event: Event)
    {
        events.continuation.yield(event)
    }

    //
    // NOTE: A delayed event waits in delayedEvents until its deadline, so the loop keeps handling the events posted
    // meanwhile; handlers never await a delay themselves. A task sleeps until the deadline and then posts every due
    // event, in deadline order and in posting order for equal deadlines: two sleeping tasks can wake in either
    // order, but the delayed events keep the order of their deadlines (two deferred focus activations must not
    // swap). The tasks only sleep and post, they never run a handler. Posting under the lock keeps two waking tasks
    // from interleaving their events.
    //

    private struct DelayedEvent: Sendable
    {
        let deadline: ContinuousClock.Instant
        let event: Event
    }

    private static let delayedEvents = Mutex<[DelayedEvent]>([])

    /// Posts an event after a delay. Callable from any thread.
    static func post(_ event: Event, after delay: Duration)
    {
        let deadline = ContinuousClock.now + delay
        delayedEvents.withLock { pending in
            let index = pending.firstIndex { $0.deadline > deadline } ?? pending.endIndex
            pending.insert(DelayedEvent(deadline: deadline, event: event), at: index)
        }

        Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            postDueEvents()
        }
    }

    /// Posts the delayed events whose deadline has passed.
    private static func postDueEvents()
    {
        let now = ContinuousClock.now
        delayedEvents.withLock { pending in
            let count = pending.prefix { $0.deadline <= now }.count
            for delayed in pending.prefix(count) { post(delayed.event) }
            pending.removeFirst(count)
        }
    }

    //
    // NOTE: Starts the one consumer of the events; call it once, at startup. Priority .medium keeps the default QoS
    // of the yabai.wm queue.
    //

    static func start()
    {
        Task(priority: .medium) { @WM in
            for await event in events.stream {
                await EventHandler.shared.handle(event)
                autoreleasepool { EventSignals.shared.flush() }
            }
        }
    }
}

extension EventHandler
{
    //
    // NOTE: An autorelease pool cannot span an await. Handlers that wait drain their own pools around their
    // synchronous parts; the others run in one pool per event.
    //

    /// Runs the handler of an event.
    func handle(_ event: Event) async
    {
        switch event {
        case .windowResized(let wid):                    await windowResized(wid)
        default:                                         autoreleasepool { handleSynchronously(event) }
        }
    }

    /// Runs the handler of an event that does not wait. The retained CF objects are taken here, so they are released
    /// when the handler returns.
    private func handleSynchronously(_ event: Event)
    {
        switch event {
        case .carbonProcessLaunched(let key):           carbonProcessLaunched(key)
        case .carbonProcessTerminated(let key):         carbonProcessTerminated(key)
        case .carbonProcessFrontSwitched(let key):      carbonProcessFrontSwitched(key)
        case .applicationLaunchRetry(let key):          applicationLaunchRetry(key)
        case .applicationLaunched(let process):          applicationLaunched(process)
        case .applicationTerminated(let process):        applicationTerminated(process)
        case .applicationFrontSwitched(let process):     applicationFrontSwitched(process)
        case .applicationVisible(let pid):               applicationVisible(pid)
        case .applicationHidden(let pid):                applicationHidden(pid)
        case .windowCreated(let element):                windowCreated(element.value.takeRetainedValue())
        case .windowDestroyed(let window):               windowDestroyed(window)
        case .windowFocused(let wid):                    windowFocused(wid)
        case .windowFocusDeferred(let wid):              windowFocusDeferred(wid)
        case .windowMoved(let wid):                      windowMoved(wid)
        case .windowResized:                             break // async, run by handle(_:)
        case .windowMinimized(let window):               windowMinimized(window)
        case .windowDeminimized(let window):             windowDeminimized(window)
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
        case .configChanged(let group):                  configChanged(group)
        case .spaceLayoutReconcile(let generation):      spaceLayoutReconcile(generation)
        case .daemonMessage(let message):                MessageLoop.handle(message)
        }
    }
}
