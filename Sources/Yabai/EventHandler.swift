import ApplicationServices
import CPrivate
import Carbon
import Foundation
import Logging
import OrderedCollections
import Synchronization
import YabaiCore

//
// NOTE: The handlers of the cases of Event, run one at a time on the queue of the @WM actor (see EventLoop.swift).
// Other threads only post events; the state of yabai changes in these handlers. This file has the class, the
// helpers they share and the application handlers; EventHandler+{Window,Space,Mouse,System}.swift have the others.
//

/// Handles the events of the event loop, one at a time on the queue of the @WM actor.
@WM final class EventHandler {
  static let shared = EventHandler()

  /// The number of open menus.
  var openMenuCount = 0

  //
  // NOTE: Focus follows mouse is off while a menu is open, so that moving the cursor through a menu does not focus
  // the windows below it. This is runtime state: the configured mode in Config stays as it is.
  //

  /// The focus follows mouse mode in effect.
  var focusFollowsMouse: FocusFollowsMouse {
    openMenuCount > 0 ? .disabled : Config.current.window.focusFollowsMouse
  }
}

//
// NOTE: Set by producers on other threads and read by the handlers.
//

/// Set when an application reports a focus change that the event loop has not handled yet.
let pendingWindowFocus = Atomic<Bool>(false)

/// Set while a horizontal Dock swipe (a space switch gesture) is in progress.
let pendingGesture = Atomic<Bool>(false)

/// The OSTimer time when the last Dock swipe gesture ended.
let lastGestureTime = Atomic<UInt64>(0)

/// The OSTimer time of the last command-tab notification of the window server.
let lastCmdTabTime = Atomic<UInt64>(0)

/// The number of mouse moved events that the event tap has posted and the event loop has not taken yet.
let pendingMouseMoved = Atomic<UInt32>(0)

/// The number of mouse dragged events that the event tap has posted and the event loop has not taken yet.
let pendingMouseDragged = Atomic<UInt32>(0)

extension EventHandler {
  //
  // NOTE: Carbon's process handler on the main thread only posts the process key. These handlers update the process
  // table on the event loop and run the application handler in the same event, so it keeps the place in the event
  // order that Carbon gave it.
  //

  func carbonProcessLaunched(_ key: ProcessKey) {
    guard let process = ProcessManager.shared.processLaunched(key) else { return }
    applicationLaunched(process)
  }

  func carbonProcessTerminated(_ key: ProcessKey) {
    guard let process = ProcessManager.shared.processTerminated(key) else { return }
    applicationTerminated(process)
  }

  func carbonProcessFrontSwitched(_ key: ProcessKey) {
    guard let process = ProcessManager.shared.processFrontSwitched(key) else { return }
    applicationFrontSwitched(process)
  }

  //
  // NOTE: The event tap counts the mouse events it posts. A handler that sees a newer event of the same
  // type still queued drops its own, so only the most recent one is handled.
  //
  nonisolated static func isStale(_ pending: borrowing Atomic<UInt32>) -> Bool {
    pending.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue > 0
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

  private func tileWindowBatched(_ view: View, _ window: Window, _ insertionPoint: WindowID?) {
    window.adjustLayer(to: .below)
    view.add(window, insertionPoint: insertionPoint)
    WindowManager.shared.addManagedWindow(window, to: view)
  }

  /// How teardown takes a window out of its view. `immediate` untiles it now, hands the focus to the next window of the
  /// tree and flushes the view. `batched` only removes it from the tree; the caller flushes the view it gets back.
  enum TeardownUntile {
    case immediate
    case batched
  }

  //
  // NOTE: The one teardown of a window that is gone, from its destroyed event or its application's termination. The
  // caller has invalidated the window. The order is the behavior: the untile (if the window is tiled), the mouse state,
  // the destroyed signal, the scratchpad, the window table, the AX notifications, then destroy(). Returns the view that
  // a batched untile left dirty.
  //

  @discardableResult
  func teardown(_ window: Window, untile: TeardownUntile) -> View? {
    let wm = WindowManager.shared
    let ms = MouseState.shared
    var dirtyView: View?

    if let view = wm.managedView(for: window) {
      switch untile {
      case .immediate:
        let nextFocus = wm.treeFocusCandidate(in: view, for: window)
        wm.unmanage(window, from: view, options: .flush)
        wm.treeFocusAfterClose(in: view, windowID: nextFocus)
      case .batched:
        // NOTE: This path does not adjust the layer, unlike unmanage: it only removes the window from the tree and
        // the managed windows, and the caller flushes the view it returns.
        untileWindowBatched(view, window)
        dirtyView = view
      }
    }

    if ms.window == window { ms.clearWindow() }
    if ms.ffmWindowID == window.id { ms.ffmWindowID = nil }

    if window.isEligible {
      EventSignals.shared.push(.windowDestroyed, .window(window))
    }

    wm.removeScratchpad(from: window, unfloat: false)
    wm.removeWindow(window.id)
    window.unobserve()
    window.destroy()

    return dirtyView
  }

  private func untileWindowBatched(_ view: View, _ window: Window) {
    view.remove(window)
    WindowManager.shared.removeManagedWindow(window.id)
  }

  private func flushDirtyViews(_ viewList: [View]) {
    for view in viewList {
      if !view.sid.isVisible { continue }
      if !view.isDirty { continue }

      view.flush()
    }
  }

  //
  // NOTE: Tiles the windows that should be managed and are not yet, each one after the previous one,
  // starting after insertionPoint. New windows go to the space chosen by window_origin_display, other
  // windows stay on their space.
  //

  private func tileWindowsBatched(
    _ windows: [Window], _ insertionPoint: WindowID?, _ newWindows: Bool
  ) {
    let wm = WindowManager.shared
    var insertionPoint = insertionPoint
    var viewList: [View] = []

    for window in windows {
      if !window.shouldBeManaged { continue }
      if wm.managedView(for: window) != nil { continue }

      guard let sid = newWindows ? wm.originSpace(for: window) : window.id.space else { continue }
      let view = SpaceManager.shared.view(for: sid)
      if view.layout == .float { continue }

      tileWindowBatched(view, window, insertionPoint)
      viewList.append(view)
      insertionPoint = window.id
    }

    flushDirtyViews(viewList)
  }

  func windowDidReceiveFocus(_ window: Window) {
    let wm = WindowManager.shared
    let ms = MouseState.shared

    let focusedWindow = wm.focus.focused.flatMap { wm.window(for: $0) }
    if let focusedWindow, focusedWindow != window, focusedWindow.id.space == window.id.space {
      wm.setWindowOpacity(focusedWindow, to: Config.current.windowOpacity.normal)
    }

    wm.setWindowOpacity(window, to: Config.current.windowOpacity.active)

    if wm.focus.focused != window.id {
      if ms.ffmWindowID != window.id {
        wm.centerMouse(on: window)
      }

      wm.focus.markFocusedAsLast()
    }

    let prevFocusedWindowID = wm.focus.focused
    wm.focus.focusChanged(to: window.id, psn: window.application.psn)
    ms.ffmWindowID = nil

    //
    // NOTE: Late focus events of windows focused earlier must not end a pending focus, so it is only
    // cleared when the window that was asked to be focused reports it.
    //

    wm.focus.clearPending(ifFor: window.id)

    if let view = WindowManager.shared.managedView(for: window), view.layout == .tree {
      view.focusWindow(window.id)
    }

    //
    // NOTE: The focus hand-over updates opacity, tab bars and borders explicitly in this event, with the focus
    // change: the previous window loses the active style as the new one gets it. Focus is not observed.
    //

    if prevFocusedWindowID != window.id {
      TabBar.refresh(for: prevFocusedWindowID)
    }

    Border.beginBatch()
    if prevFocusedWindowID != window.id {
      Border.refresh(prevFocusedWindowID.flatMap { wm.window(for: $0) })
    }
    Border.refreshSpace(of: window)
    Border.endBatch()
  }

  private func applicationLaunchRetry(_ process: Process) {
    if !Process.canRetryLaunch(process.launchAttempts) {
      process.launchGivenUp = true
      Logger.processes.notice(
        "giving up on launching \(process.nameAndPID) after \(process.launchAttempts) attempts")
      return
    }

    let delay = Process.launchRetryDelay(process.launchAttempts)
    process.launchAttempts += 1
    Logger.events.debug(
      "retrying the launch of \(process.nameAndPID) in \(cFormat("%.1f", delay / .seconds(1)))s (attempt \(process.launchAttempts))"
    )

    let key = ProcessKey(process.psn)
    EventLoop.post(.applicationLaunchRetry(key), after: delay)
  }

  /// The delayed retry of a launch: the process is looked up again, since it can terminate during the delay.
  func applicationLaunchRetry(_ key: ProcessKey) {
    guard let process = ProcessManager.shared.process(for: key) else { return }
    applicationLaunched(process)
  }

  func applicationLaunched(_ process: Process) {
    let wm = WindowManager.shared

    if process.isTerminated {
      Logger.events.debug("application launched: \(process.nameAndPID) terminated during launch")
      wm.focus.removeLostFrontSwitchedEvent(for: process.pid)
      return
    }

    if !process.hasRunningApplication {
      Logger.events.debug(
        "application launched: \(process.nameAndPID) has no NSRunningApplication yet, fetching it")
      process.attachRunningApplication()

      if !process.hasRunningApplication {
        Logger.events.debug(
          "application launched: \(process.nameAndPID) could not fetch its NSRunningApplication")
        applicationLaunchRetry(process)
        return
      }
    }

    if !process.isFinishedLaunching {
      Logger.events.debug(
        "application launched: \(process.nameAndPID) is not finished launching, subscribing to finishedLaunching changes"
      )
      process.observeFinishedLaunching()

      //
      // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
      // Not actually sure if this can happen in practice..
      //

      if !process.isFinishedLaunching { return }
      process.unobserveFinishedLaunching()
    }

    if !process.isObservable() {
      Logger.events.debug(
        "application launched: \(process.nameAndPID) is not observable, subscribing to activationPolicy changes"
      )
      process.observeActivationPolicy()

      //
      // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
      // Not actually sure if this can happen in practice..
      //

      if !process.isObservable() { return }
      process.unobserveActivationPolicy()
    }

    //
    // NOTE(asmvik): If we somehow receive a duplicate launched event due to the subscription-timing-mess above,
    // simply ignore the event..
    //

    if wm.application(for: process.pid) != nil { return }
    let application = Application(process: process)

    if !application.observe() {
      let axRetry = application.axRetry

      application.unobserve()
      application.destroy()
      Logger.events.debug(
        "application launched: could not observe notifications for \(process.nameAndPID) (\(axRetry ? 1 : 0))"
      )

      if axRetry { applicationLaunchRetry(process) }
      return
    }

    if wm.focus.hasLostFrontSwitchedEvent(for: process.pid) {
      EventLoop.post(.applicationFrontSwitched(process))
      wm.focus.removeLostFrontSwitchedEvent(for: process.pid)
    }

    Logger.events.debug("application launched: \(process.nameAndPID)")
    wm.addApplication(application)
    EventSignals.shared.push(.applicationLaunched, .application(application))
    process.launchAttempts = 0
    process.launchGivenUp = false

    let windows = wm.addApplicationWindows(application)
    WindowManager.shared.updateWindowNotifications()
    tileWindowsBatched(windows, wm.focus.focused, true)

    // NOTE: insert= applies only to the tile made while the window is created (see windowCreated), so a window that
    // was not tiled here does not keep it for a later add.
    for window in windows { window.insertionByRule = nil }

    for window in windows where window.isEligibleForManagement {
      EventSignals.shared.push(.windowCreated, .window(window))
    }
  }

  func applicationTerminated(_ process: Process) {
    defer { process.releaseRunningApplication() }

    let wm = WindowManager.shared

    guard let application = wm.application(for: process.pid) else {
      Logger.events.debug("application terminated: \(process.nameAndPID) (not observed)")
      return
    }

    Logger.events.debug("application terminated: \(process.nameAndPID)")
    EventSignals.shared.push(.applicationTerminated, .application(application))
    wm.removeApplication(pid: application.pid)

    wm.applicationsToRefresh.remove(application)

    let viewList = removeTerminatedWindows(wm.windows(for: application))

    application.unobserve()
    application.destroy()

    flushDirtyViews(viewList)

    WindowManager.shared.updateWindowNotifications()
  }

  //
  // NOTE: Removes the windows of a terminated application and returns the views to flush. This includes windows
  // that their AX destroyed callback already invalidated: the windowDestroyed event it queued runs after this
  // handler, and until then the window would stay in the tree and the registry without an application, so the
  // flush below would lay it out (and trap building its frame group). The queued event then ignores the destroyed
  // window, so each window is still untiled, signalled and destroyed exactly once.
  //

  func removeTerminatedWindows(_ windows: [Window]) -> [View] {
    var viewList: [View] = []

    for window in windows {
      _ = window.invalidate()

      if let view = teardown(window, untile: .batched) { viewList.append(view) }
    }

    return viewList
  }

  //
  // NOTE: With skip_window_focus_animation, an application activated on a space that is not visible
  // (e.g. by cmd-tab) brings that space to front without the space switch animation.
  //

  private func applicationFrontSwitchedFocusSpace(_ application: Application, _ process: Process) {
    let psnSid = ProcessManager.shared.activeSpace(forConnection: application.connection)

    let dt = OSTimer.milliseconds(from: lastCmdTabTime.load(ordering: .relaxed), to: OSTimer.now)
    if dt > 1500.0 {
      _ = application.ref.attribute("__fence")
    }

    if pendingWindowFocus.load(ordering: .relaxed) == false {
      if let psnSid, !psnSid.isVisible {
        SLS.setFrontProcess(SLS.connection, process.psn, forSpace: psnSid)
        if let psnDid = psnSid.display {
          SpaceManager.shared.focusSpaceUsingGesture(psnSid, on: psnDid)
        }
      }
    }
  }

  @discardableResult private func dimFocusedWindow() -> Window? {
    let wm = WindowManager.shared

    let focusedWindow = wm.focus.focused.flatMap { wm.window(for: $0) }
    if let focusedWindow {
      wm.setWindowOpacity(focusedWindow, to: Config.current.windowOpacity.normal)
    }

    return focusedWindow
  }

  //
  // NOTE: The activated application has no focused window (e.g. Finder with only the desktop), so no window
  // has focus until one of its windows is focused.
  //

  private func applicationFrontSwitchedWithoutWindow(_ application: Application) {
    let wm = WindowManager.shared
    let focusedWindow = dimFocusedWindow()

    let prevFocusedWindowID = wm.focus.focused
    wm.focus.markFocusedAsLast()
    wm.focus.focusChanged(to: nil, psn: application.psn)
    MouseState.shared.ffmWindowID = nil

    if let prevFocusedWindowID {
      TabBar.refresh(for: prevFocusedWindowID)
      Border.refresh(focusedWindow)
    }
  }

  func applicationFrontSwitched(_ process: Process) {
    let wm = WindowManager.shared
    let pm = ProcessManager.shared

    guard let application = wm.application(for: process.pid) else {
      wm.focus.addLostFrontSwitchedEvent(for: process.pid)

      if process.launchGivenUp {
        Logger.events.debug(
          "application front switched: \(process.nameAndPID) was activated, trying to observe it again"
        )
        process.launchAttempts = 0
        process.launchGivenUp = false
        EventLoop.post(.applicationLaunched(process))
      }

      return
    }

    if Config.current.space.skipWindowFocusAnimation {
      applicationFrontSwitchedFocusSpace(application, process)
    }

    if let deactivatedApplication = wm.application(for: pm.frontPID) {
      EventSignals.shared.push(.applicationDeactivated, .application(deactivatedApplication))
    }

    Logger.events.debug("application front switched: \(process.nameAndPID)")
    EventSignals.shared.push(.applicationActivated, .application(application))
    pm.switchEventTime = GetCurrentEventTime()
    pm.lastFrontPID = pm.frontPID
    pm.frontPID = process.pid
    EventSignals.shared.push(.applicationFrontSwitched)

    if wm.applicationsToRefresh.contains(application) {
      Logger.events.debug(
        "application front switched: \(application.name) has windows that are not yet resolved")
      wm.addExistingApplicationWindows(application, isRefreshing: true)
    }

    guard let applicationFocusedWindowID = application.focusedWindowID else {
      applicationFrontSwitchedWithoutWindow(application)
      return
    }

    guard let window = wm.window(for: applicationFocusedWindowID) else {
      dimFocusedWindow()
      wm.focus.addLostFocusedEvent(for: applicationFocusedWindowID)
      return
    }

    windowDidReceiveFocus(window)
    EventSignals.shared.push(.windowFocused, .window(window))
    pendingWindowFocus.store(false, ordering: .releasing)
  }

  func applicationVisible(_ pid: pid_t) {
    let wm = WindowManager.shared
    guard let application = wm.application(for: pid) else { return }

    Logger.events.debug("application visible: \(application.name)")
    application.isHidden = false

    let windows = wm.windows(for: application)
    tileWindowsBatched(windows, wm.focus.last, false)

    for window in windows {
      Border.refreshSpace(of: window)
    }

    EventSignals.shared.push(.applicationVisible, .application(application))
  }

  func applicationHidden(_ pid: pid_t) {
    let wm = WindowManager.shared
    guard let application = wm.application(for: pid) else { return }

    Logger.events.debug("application hidden: \(application.name)")
    application.isHidden = true

    let windows = wm.windows(for: application)
    var viewList: [View] = []

    for window in windows {
      if let view = wm.managedView(for: window) {
        wm.unmanage(window, from: view, options: .purify)
        viewList.append(view)
      }
    }

    flushDirtyViews(viewList)

    for window in windows {
      Border.refreshSpace(of: window)
    }

    EventSignals.shared.push(.applicationHidden, .application(application))
  }
}
