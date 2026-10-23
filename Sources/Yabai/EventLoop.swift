import Algorithms
import ApplicationServices
import DequeModule
import Dispatch
import Synchronization
import YabaiCore
import os

//
// NOTE: The event loop. Producers on other threads (AX observers, SkyLight notify procs, the NSWorkspace notifications,
// the mouse event tap, the socket thread) only yield events into one AsyncStream; a single long-lived @WM task
// consumes it and runs the handlers one at a time, in the order the events were posted. A handler that waits is
// async: the loop awaits it before it takes the next event, but other @WM code (WM.sync blocks, C callbacks on
// yabai.wm) can run at its await, so the handler re-checks the state it relies on afterwards. After each handler
// the signals it pushed run. Events never get a Task {} of their own: separate tasks could run them out of order.
// Delays post their event later through post(_:after:key:). The handlers are EventHandler methods, in EventHandler*.swift.
//

/// The actor of the window manager state. Its executor is the serial queue of the event loop.
@globalActor
actor WM {
  static let shared = WM()

  //
  // NOTE: The queue has the default QoS and drains an autorelease pool after each work item (WM.sync blocks, C
  // callbacks); the event loop drains its own pool per event, since one work item of its task can handle several.
  //

  nonisolated let queue = DispatchSerialQueue(
    label: "yabai.wm", qos: .default, autoreleaseFrequency: .workItem)

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  //
  // NOTE: Runs code isolated to @WM from a synchronous context that is already on the queue but has no static
  // isolation: the block of WM.sync. Code that is @WM itself calls @WM code directly. It traps when called from
  // another thread, like MainActor.assumeIsolated, which a custom global actor does not get from the standard
  // library.
  //

  static func assumeIsolated<T>(_ operation: @WM () throws -> T) rethrows -> T {
    shared.preconditionIsolated()
    return try withoutActuallyEscaping(operation) { operation in
      try unsafeBitCast(operation, to: (() throws -> T).self)()
    }
  }

  //
  // NOTE: Runs code isolated to @WM from another thread (the startup on the main thread) and waits until it returns.
  // It deadlocks when called on the queue itself.
  //

  static func sync<T>(_ operation: @WM () throws -> T) rethrows -> T {
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
struct Handoff<Value>: @unchecked Sendable {
  let value: Value
}

/// The events of the event loop, with the context and param1 of each event as associated values.
enum Event: Sendable {
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
  case windowDestroyed(windowID: WindowID)
  case windowFocused(windowID: WindowID?)
  case windowFocusDeferred(windowID: WindowID)
  case windowMoved(windowID: WindowID)
  case windowResized(windowID: WindowID)
  case windowMinimized(windowID: WindowID)
  case windowDeminimized(windowID: WindowID)
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
  // NOTE: Only post with `key: .missionControlCheck` (`EventLoop.post(_:after:key:)`); a stale one is dropped.
  case missionControlCheckForExit
  case missionControlExit
  case dockDidRestart
  case menuOpened(windowID: WindowID?)
  case menuClosed
  case menuBarHiddenChanged
  case dockDidChangePref
  case systemWoke
  case configChanged(ConfigGroup)
  // NOTE: Only post with `key: .spaceLayoutReconcile` (`EventLoop.post(_:after:key:)`); a stale one is dropped.
  case spaceLayoutReconcile
  // NOTE: Only post with `key: .spacePinReconcile` (`EventLoop.post(_:after:key:)`); a stale one is dropped.
  case spacePinReconcile
  case daemonMessage(DaemonMessage)
  // NOTE: Posted by an EventSubscriber when it ends (a closed peer, a failed write or a full backlog). It only removes
  // the subscriber from EventSubscribers, which runs on @WM.
  case eventSubscriberRemoved(id: Int)
}

extension Event {
  var isMouseMoved: Bool {
    if case .mouseMoved = self { return true }
    return false
  }
}

enum EventLoop {
  //
  // NOTE: Unbounded, so a producer never blocks or drops an event. Events posted before start() wait in the buffer.
  //

  private static let events = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)

  /// Posts an event. Callable from any thread.
  static func post(_ event: Event) {
    events.continuation.yield(event)
  }

  //
  // NOTE: A delayed event waits in one DelayedQueue until its deadline, so the loop keeps handling the events posted
  // meanwhile; handlers never await a delay themselves. One DispatchSourceTimer, on a private serial queue, is armed
  // for the earliest deadline. Its handler only posts the due events, in deadline order, and then arms the timer for
  // the next deadline. The queue and the armed deadline share one Mutex, and an insert that moves the earliest
  // deadline earlier re-arms the timer under that lock, so a deadline is never left without a timer. The timer
  // sleeps on the monotonic uptime clock; deadlines and the due check use ContinuousClock. After a system sleep, a
  // delay can end later than with ContinuousClock.
  //
  // NOTE: An event with a DelayedEventKey supersedes the pending event with that key: the insert removes it. A
  // keyed event that is already due and posted (waiting in the event stream) is superseded too: the insert marks it
  // stale, and claimDelivery drops it when the handler takes it. The unkeyed events are never superseded. cancel(key:)
  // removes the pending event of a key and marks the delivered ones stale, without a replacement.
  //

  /// The delayed events that supersede each other: an insert with a key replaces the pending event with that key.
  /// Only post the events `.spaceLayoutReconcile`, `.spacePinReconcile` and `.missionControlCheckForExit` with their key.
  enum DelayedEventKey: Hashable, Sendable {
    case spaceLayoutReconcile
    case spacePinReconcile
    case missionControlCheck
  }

  private struct DelayedState: Sendable {
    /// The pending events, and the keyed events delivered and not yet handled (see DelayedQueue).
    var queue = DelayedQueue<Event, DelayedEventKey>()
    /// The deadline the timer is set for, nil when it is not armed. It is never later than the next deadline.
    var armed: ContinuousClock.Instant?
  }

  private static let delayed = Mutex(DelayedState())

  private static let delayedTimerQueue = DispatchQueue(label: "yabai.events.delayed")

  private static let delayedTimer: any DispatchSourceTimer =
    {
      let timer = DispatchSource.makeTimerSource(queue: delayedTimerQueue)
      timer.setEventHandler { postDueEvents() }
      timer.resume()
      return timer
    }()

  /// Posts an event after a delay. A key supersedes the pending event with the same key. Callable from any thread.
  static func post(_ event: Event, after delay: Duration, key: DelayedEventKey? = nil) {
    let deadline = ContinuousClock.now + delay
    delayed.withLock { state in
      state.queue.insert(event, at: deadline, key: key)
      if let next = state.queue.nextDeadline, state.armed.map({ next < $0 }) ?? true {
        arm(&state, for: next)
      }
    }
  }

  /// Cancels the pending delayed event with this key, and drops a delivered one that is not yet handled, without a
  /// replacement. Callable from any thread. The armed timer may fire once more for the cancelled deadline; it posts
  /// nothing then and re-arms for the next one.
  static func cancel(key: DelayedEventKey) {
    delayed.withLock { state in state.queue.cancel(key: key) }
  }

  /// Called on @WM when a keyed delayed event is handled. Returns false when the event was superseded after its
  /// delivery, so the handler must drop it.
  static func claimDelivery(of key: DelayedEventKey) -> Bool {
    delayed.withLock { state in state.queue.claim(key: key) }
  }

  /// Posts the due events, then arms the timer for the next deadline. Runs on the timer queue.
  private static func postDueEvents() {
    delayed.withLock { state in
      for due in state.queue.removeDue(at: ContinuousClock.now) { post(due.element) }

      state.armed = nil
      if let next = state.queue.nextDeadline { arm(&state, for: next) }
    }
  }

  /// Sets the timer to fire at the deadline. Called under the lock of `delayed`.
  private static func arm(_ state: inout DelayedState, for deadline: ContinuousClock.Instant) {
    state.armed = deadline

    let remaining = max(Duration.zero, deadline - ContinuousClock.now).components
    let (scaled, overflow) = remaining.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let nanoseconds = overflow ? Int.max : Int(scaled) + Int(remaining.attoseconds / 1_000_000_000)
    delayedTimer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .never)
  }

  //
  // NOTE: Starts the one consumer of the events; call it once, at startup. Priority .medium keeps the default QoS
  // of the yabai.wm queue.
  //

  static func start() {
    Task(priority: .medium) { @WM in
      for await event in events.stream {
        await EventHandler.shared.handle(event)
        autoreleasepool { EventSignals.shared.flush() }
      }
    }
  }
}

extension EventHandler {
  //
  // NOTE: An autorelease pool cannot span an await. Handlers that wait drain their own pools around their
  // synchronous parts; the others run in one pool per event.
  //

  /// Runs the handler of an event.
  func handle(_ event: Event) async {
    //
    // NOTE: Every event but a mouse move may change what is under the pointer, so it bumps the generation that the
    // focus follows mouse hit cache is kept for (MouseState.ffmGeneration). Mouse moves do not: they are the reason for
    // the cache.
    //
    if !event.isMouseMoved { MouseState.shared.ffmGeneration &+= 1 }

    //
    // NOTE: The loop takes the next event only after this handler returns, even when the handler awaits, so the
    // intervals of the events never overlap and their id is .exclusive.
    //
    let signposter = Signposts.events
    let name = event.signpostName
    let interval = signposter.beginInterval(name, id: .exclusive)
    defer { signposter.endInterval(name, interval) }

    switch event {
    case .windowResized(let wid): await windowResized(wid)
    default: autoreleasepool { handleSynchronously(event) }
    }
  }

  /// Runs the handler of an event that does not wait. The retained CF objects are taken here, so they are released
  /// when the handler returns.
  private func handleSynchronously(_ event: Event) {
    switch event {
    case .carbonProcessLaunched(let key): carbonProcessLaunched(key)
    case .carbonProcessTerminated(let key): carbonProcessTerminated(key)
    case .carbonProcessFrontSwitched(let key): carbonProcessFrontSwitched(key)
    case .applicationLaunchRetry(let key): applicationLaunchRetry(key)
    case .applicationLaunched(let process): applicationLaunched(process)
    case .applicationTerminated(let process): applicationTerminated(process)
    case .applicationFrontSwitched(let process): applicationFrontSwitched(process)
    case .applicationVisible(let pid): applicationVisible(pid)
    case .applicationHidden(let pid): applicationHidden(pid)
    case .windowCreated(let element): windowCreated(element.value.takeRetainedValue())
    case .windowDestroyed(let wid): windowDestroyed(windowID: wid)
    case .windowFocused(let wid): windowFocused(wid)
    case .windowFocusDeferred(let wid): windowFocusDeferred(wid)
    case .windowMoved(let wid): windowMoved(wid)
    case .windowResized: break  // async, run by handle(_:)
    case .windowMinimized(let wid): windowMinimized(windowID: wid)
    case .windowDeminimized(let wid): windowDeminimized(windowID: wid)
    case .windowTitleChanged(let wid): windowTitleChanged(wid)
    case .slsWindowOrdered(let wid): slsWindowOrdered(wid)
    case .slsWindowDestroyed(let wid): slsWindowDestroyed(wid)
    case .slsSpaceCreated(let sid): slsSpaceCreated(sid)
    case .slsSpaceDestroyed(let sid): slsSpaceDestroyed(sid)
    case .spaceChanged: spaceChanged()
    case .displayAdded(let did): displayAdded(did)
    case .displayRemoved(let did): displayRemoved(did)
    case .displayMoved(let did): displayMoved(did)
    case .displayResized(let did): displayResized(did)
    case .displayChanged: displayChanged()
    case .mouseDown(let event, let modifiers): mouseDown(event.value.takeRetainedValue(), modifiers)
    case .mouseUp(let event): mouseUp(event.value.takeRetainedValue())
    case .mouseDragged(let event): mouseDragged(event.value.takeRetainedValue())
    case .mouseMoved(let event, _): mouseMoved(event.value.takeRetainedValue())
    case .tabBarClicked(let wid): tabBarClicked(wid)
    case .tabCardOrdered(let wid): tabCardOrdered(wid)
    case .missionControlShowAllWindows: missionControlShowAllWindows()
    case .missionControlShowFrontWindows: missionControlShowFrontWindows()
    case .missionControlShowDesktop: missionControlShowDesktop()
    case .missionControlEnter: missionControlEnter()
    case .missionControlCheckForExit:
      if EventLoop.claimDelivery(of: .missionControlCheck) { missionControlCheckForExit() }
    case .missionControlExit: missionControlExit()
    case .dockDidRestart: dockDidRestart()
    case .menuOpened: menuOpened()
    case .menuClosed: menuClosed()
    case .menuBarHiddenChanged: menuBarHiddenChanged()
    case .dockDidChangePref: dockDidChangePref()
    case .systemWoke: systemWoke()
    case .configChanged(let group): configChanged(group)
    case .spaceLayoutReconcile:
      if EventLoop.claimDelivery(of: .spaceLayoutReconcile) { spaceLayoutReconcile() }
    case .spacePinReconcile:
      if EventLoop.claimDelivery(of: .spacePinReconcile) { spacePinReconcile() }
    case .daemonMessage(let message): MessageLoop.handle(message)
    case .eventSubscriberRemoved(let id): EventSubscribers.shared.remove(id)
    }
  }
}
