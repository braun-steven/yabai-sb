import AppKit
import ApplicationServices
import CPrivate
import Logging
import OrderedCollections
import Synchronization
import YabaiCore

//
// NOTE: The handlers of window events: windows created, destroyed, focused, moved, resized, minimized
// and retitled, from the accessibility observers and the window server.
//

extension EventHandler {
  /// The element is the retained reference that the AX observer posted.
  func windowCreated(_ element: AXUIElement) {
    let wm = WindowManager.shared

    guard let windowID = element.windowID else { return }

    if wm.window(for: windowID) != nil { return }

    guard let windowPid = element.pid, windowPid != 0 else { return }

    guard let application = wm.application(for: windowPid) else { return }

    guard
      let window = wm.createAndAddWindow(
        application, reference: element, id: windowID, includingOneShotRules: true)
    else { return }

    // NOTE: Subscribe before tiling. AX can return before the window server publishes the final frame;
    // the border then needs the ensuing move/resize notification to leave the window's creation frame.
    WindowManager.shared.updateWindowNotifications()

    wm.removeOneShotRules()

    if window.shouldBeManaged && wm.managedView(for: window) == nil {
      if let sid = wm.originSpace(for: window) { wm.manageWindow(window, on: sid, inserting: nil) }
    }

    // NOTE: insert= applies only to the tile made while the window is created. A window that was not tiled here
    // (floating, minimized, on a float view) must not take the placement at a later add, e.g. after a float toggle.
    window.insertionByRule = nil

    if window.isEligibleForManagement {
      EventSignals.shared.push(.windowCreated(window))
    }

    Border.refreshSpace(of: window)
  }

  //
  // NOTE: The destroyed event of a window, handled on @WM. The AX callback marks the id on the main thread (so the
  // window is invalid before this event runs) and the SkyLight callback only posts the id. The handler looks the window
  // up and invalidates it, so the first destroyed event for a window tears it down and any later one finds the window
  // gone (removed by its termination or its first event) or invalid, and returns. A window that is gone also drops
  // the AX mark of its id, which a termination may leave behind when the callback marked the window after its removal.
  //

  func windowDestroyed(windowID: WindowID) {
    guard let window = WindowManager.shared.window(for: windowID) else {
      unmarkAXDestroyed(windowID)
      Logger.events.debug("window destroyed: \(windowID) has already been removed, ignoring event")
      return
    }

    if !window.invalidate() {
      Logger.events.debug(
        "window destroyed: \(windowID) has been marked invalid by the system, ignoring event")
      return
    }

    windowDestroyed(window)
  }

  func windowDestroyed(_ window: Window?) {
    guard let window, !window.isDestroyed else {
      Logger.events.debug("window destroyed: window has already been destroyed, ignoring event")
      return
    }

    Logger.events.debug(
      "window destroyed: \(window.application != nil ? window.application.name : "<unknown>") \(window.id)"
    )

    teardown(window, untile: .immediate)

    if Config.current.border.hideSingle {
      Border.refresh(space: SpaceManager.shared.currentSpaceID)
    }

    WindowManager.shared.updateWindowNotifications()
  }

  func windowFocusDeferred(_ windowID: WindowID) {
    guard let window = WindowManager.shared.window(for: windowID), window.application != nil else {
      Logger.events.debug("window focus deferred: \(windowID) no longer exists, ignoring event")
      return
    }

    WindowManager.shared.focusWithoutRaiseDeferred(window)
  }

  func windowFocused(_ windowID: WindowID?) {
    pendingWindowFocus.store(false, ordering: .releasing)
    let wm = WindowManager.shared

    // NOTE: A focus event without a window id (the element is not a window) only clears the pending focus.
    guard let windowID else { return }

    guard let window = wm.window(for: windowID) else {
      wm.focus.addLostFocusedEvent(for: windowID)
      return
    }

    if !window.isValid {
      Logger.events.debug(
        "window focused: \(windowID) has been marked invalid by the system, ignoring event")
      return
    }

    if window.isMinimized {
      wm.focus.addLostFocusedEvent(for: window.id)
      return
    }

    if !window.application.isFrontmost {
      return
    }

    Logger.events.debug("window focused: \(window.application.name) \(window.id)")

    if Config.current.space.skipWindowFocusAnimation {
      if let sid = window.id.space, !sid.isVisible {
        SLS.setFrontProcess(SLS.connection, window.application.psn, forSpace: sid)
        if let did = sid.display {
          SpaceManager.shared.focusSpaceUsingGesture(sid, on: did)
        }
      }
    }

    windowDidReceiveFocus(window)
    EventSignals.shared.push(.windowFocused(window))
  }

  func windowMoved(_ windowID: WindowID) {
    let wm = WindowManager.shared
    let ms = MouseState.shared

    guard let window = wm.window(for: windowID) else { return }

    if !window.isValid {
      Logger.events.debug(
        "window moved: \(windowID) has been marked invalid by the system, ignoring event")
      return
    }

    //
    // NOTE: A window of a hidden application is not in a tree (`applicationHidden` unmanages it), so its move signals
    // and flushes nothing. Its cached frame still follows the move, or `query --windows` keeps reporting the old
    // frame after a `window --move` of a hidden floating dialog. `applyResize` does the same.
    //
    if window.application.isHidden {
      Logger.events.debug(
        "window moved: \(windowID) was moved while the application is hidden, updating its frame only"
      )
      window.frame.origin = window.axOrigin
      window.rememberFloatingFrame()
      return
    }

    let newOrigin = window.axOrigin
    if newOrigin.equalTo(window.frame.origin) {
      Logger.events.debug("window moved (debounced): \(window.application.name) \(window.id)")
      return
    }

    Logger.events.debug("window moved: \(window.application.name) \(window.id)")
    EventSignals.shared.push(.windowMoved(window))
    let windowedFullscreen = window.windowedFrame.equalTo(window.frame)
    window.frame.origin = newOrigin
    window.rememberFloatingFrame()
    wm.followWarp(of: window)

    if !windowedFullscreen {
      window.isWindowed = false

      if ms.window == nil || ms.window != window {
        if let view = wm.managedView(for: window),
          view.needsFlush(windowID: window.id, frame: window.frame)
        {
          wm.retile(window, in: view)
        }
      }
    }
  }

  func windowResized(_ windowID: WindowID) async {
    guard let window = autoreleasepool(invoking: { applyResize(windowID) }) else { return }

    await WindowManager.shared.waitForNativeFullscreenTransition()

    autoreleasepool { manageAfterNativeFullscreen(window) }
  }

  /// Handles the resize up to the wait; returns the window when it has left native fullscreen.
  private func applyResize(_ windowID: WindowID) -> Window? {
    let wm = WindowManager.shared
    let ms = MouseState.shared

    guard let window = wm.window(for: windowID) else { return nil }

    if !window.isValid {
      Logger.events.debug(
        "window resized: \(windowID) has been marked invalid by the system, ignoring event")
      return nil
    }

    if window.application.isHidden {
      Logger.events.debug(
        "window resized: \(windowID) was resized while the application is hidden, updating its frame only"
      )
      window.frame = window.axFrame
      window.rememberFloatingFrame()
      return nil
    }

    let newFrame = window.axFrame
    if newFrame.equalTo(window.frame) {
      Logger.events.debug("window resized (debounced): \(window.application.name) \(window.id)")
      return nil
    }

    Logger.events.debug("window resized: \(window.application.name) \(window.id)")
    EventSignals.shared.push(.windowResized(window))

    let wasFullscreen = window.isFullscreen

    let isFullscreen = window.reportsFullscreen
    window.isFullscreen = isFullscreen

    if wasFullscreen != isFullscreen {
      window.refreshAXState()
    }

    let windowedFullscreen = window.windowedFrame.equalTo(window.frame)
    window.frame = newFrame
    window.rememberFloatingFrame()
    wm.followWarp(of: window)

    if wasFullscreen != isFullscreen { Border.refreshSpace(of: window) }

    if !wasFullscreen && isFullscreen {
      if let view = wm.managedView(for: window) {
        wm.unmanageWindow(window, from: view)
      }
    } else if wasFullscreen && !isFullscreen {
      return window
    } else {
      if ms.currentAction == .move && ms.window == window {
        ms.windowFrame.size = ms.window.frame.size
      }

      if !windowedFullscreen {
        window.isWindowed = false

        if ms.window == nil || ms.window != window {
          if let view = wm.managedView(for: window),
            view.needsFlush(windowID: window.id, frame: newFrame)
          {
            wm.retile(window, in: view)
          }
        }
      }
    }

    return nil
  }

  /// Checks the tiled windows that something else moved or resized off their tile again, now that their frame changes
  /// have settled (`WindowManager.retile(_:in:)`), and flushes the views of the ones that are still off their tile.
  func windowFrameRecheck() {
    let wm = WindowManager.shared
    let ids = wm.frameRecheckWindows
    wm.frameRecheckWindows = []
    if MissionControl.shared.isActive { return }

    let observed = ids.compactMap { id -> (window: Window, frame: CGRect)? in
      guard let window = wm.window(for: id), window.isValid, !window.application.isHidden else {
        return nil
      }
      return (window, window.axFrame)
    }
    wm.retileWindowsOffTile(observed)
  }

  //
  // NOTE: Other @WM code may have run during the wait: the window may have been destroyed or managed meanwhile.
  //

  private func manageAfterNativeFullscreen(_ window: Window) {
    let wm = WindowManager.shared

    guard !window.isDestroyed, window.isValid, wm.window(for: window.id) == window else { return }

    if window.shouldBeManaged && wm.managedView(for: window) == nil {
      if let sid = window.id.space { wm.manageWindow(window, on: sid, inserting: nil) }
    }
  }

  // NOTE: A window that is gone (removed, so it was invalidated first) has nothing left to minimize.
  func windowMinimized(windowID: WindowID) {
    guard let window = WindowManager.shared.window(for: windowID) else {
      Logger.events.debug("window minimized: \(windowID) has already been removed, ignoring event")
      return
    }

    windowMinimized(window)
  }

  func windowMinimized(_ window: Window) {
    let wm = WindowManager.shared

    if !window.isValid {
      Logger.events.debug(
        "window minimized: \(window.id) has been marked invalid by the system, ignoring event")
      return
    }

    Logger.events.debug("window minimized: \(window.application.name) \(window.id)")
    window.isMinimized = true

    window.refreshAXState()

    let view = wm.managedView(for: window)
    let nextFocus = view.flatMap { wm.treeFocusCandidate(in: $0, for: window) }

    if window.id == wm.focus.last {
      wm.focus.markFocusedAsLast()
    }

    if let view {
      wm.unmanageWindow(window, from: view)
      wm.treeFocusAfterClose(in: view, windowID: nextFocus)
    }

    Border.refreshSpace(of: window)
    EventSignals.shared.push(.windowMinimized(window))
  }

  // NOTE: A window that is gone (removed, so it was invalidated first) is ignored like an invalid one, and its lost
  // focus event is dropped the same way.
  func windowDeminimized(windowID: WindowID) {
    guard let window = WindowManager.shared.window(for: windowID) else {
      Logger.events.debug(
        "window deminimized: \(windowID) has already been removed, ignoring event")
      WindowManager.shared.focus.removeLostFocusedEvent(for: windowID)
      return
    }

    windowDeminimized(window)
  }

  func windowDeminimized(_ window: Window) {
    let wm = WindowManager.shared

    if !window.isValid {
      Logger.events.debug(
        "window deminimized: \(window.id) has been marked invalid by the system, ignoring event")
      wm.focus.removeLostFocusedEvent(for: window.id)
      return
    }

    window.isMinimized = false

    window.refreshAXState()

    let sid = SpaceID.active
    if let sid, window.id.spaces.contains(sid) {
      Logger.events.debug(
        "window deminimized: window \(window.application.name) \(window.id) is deminimized on active space"
      )
      if window.shouldBeManaged && wm.managedView(for: window) == nil {
        let lastWindow = wm.focus.last.flatMap { wm.window(for: $0) }
        let insertionPoint: WindowID? =
          if let lastWindow, lastWindow.application.pid != window.application.pid {
            lastWindow.id
          } else { nil }
        wm.manageWindow(window, on: sid, inserting: insertionPoint)
      }
    } else {
      Logger.events.debug(
        "window deminimized: window \(window.application.name) \(window.id) is deminimized on inactive space"
      )
    }

    if wm.focus.hasLostFocusedEvent(for: window.id) {
      EventLoop.post(.windowFocused(windowID: window.id))
      wm.focus.removeLostFocusedEvent(for: window.id)
    }

    Border.refreshSpace(of: window)
    EventSignals.shared.push(.windowDeminimized(window))
  }

  func windowTitleChanged(_ windowID: WindowID) {
    guard let window = WindowManager.shared.window(for: windowID) else { return }

    if !window.isValid {
      Logger.events.debug(
        "window title changed: \(windowID) has been marked invalid by the system, ignoring event")
      return
    }

    Logger.events.debug("window title changed: \(window.application.name) \(window.id)")

    // Non-essential: the title refresh is skipped while the application's breaker is open; the cached title stays
    // until its next change event.
    if let title = WindowManager.shared.ifResponsive(
      pid: window.application.pid, { window.readTitle() })
    {
      window.ax.title = title
    } else {
      Logger.events.debug(
        "window title changed: \(window.application.name) \(window.id) is unresponsive, keeping its title"
      )
    }
    TabBar.refresh(for: window.id)

    EventSignals.shared.push(.windowTitleChanged(window))
  }

  func slsWindowOrdered(_ wid: WindowID) {
    Logger.events.debug("SkyLight window ordered: \(wid)")
    TabBar.orderBars(above: wid)
  }

  func slsWindowDestroyed(_ wid: WindowID) {
    Logger.events.debug("SkyLight window destroyed: \(wid)")

    // NOTE: The AX destroyed notification of the same window may be queued too. The handler invalidates the window,
    // so whichever arrives second finds it gone and does nothing.
    windowDestroyed(windowID: wid)
  }
}

//
// NOTE: A tiled window that something else moves or resizes off its tile is put back by a flush of its view (the window
// moved and resized handlers). That flush can lose: macOS tiles a window in several steps over about 400 ms (seen on
// a plain click on a window after an alt-drag of the focused window was released outside every display, P5.7), a step
// after the flush puts the window back on macOS's frame, and its notification is read when the window has the frame
// the handler last saw, so it is dropped as debounced and the window stays off its tile. The handler therefore checks
// the window again once its changes have settled: `frameRecheckDelay` after the last of them (a newer change replaces
// the pending check), the AX frame is read, and a window still off its tile gets one more flush of its view. The check
// writes the frame even when the request and the window server's bounds look current (`frameNeedsUpdate`), and it
// schedules no further check, so an application that keeps its own size (a minimum size) gets one more write, not a loop.
// During macOS's tile steps the flushes have no effect (the AX reads right after them still return macOS's frame); the
// check after the last step is the write that sticks (about 0.3 s after the last step, about 0.9 s after the
// click). The handler and the check log the observed frame, and the check logs a window it finds back on its tile.
//

extension WindowManager {
  /// How long after the last foreign move or resize of a tiled window it is checked again (`windowFrameRecheck`).
  static let frameRecheckDelay: Duration = .milliseconds(300)

  /// Flushes the view of a tiled window that something else moved or resized off its tile, and schedules the check of
  /// the window once its frame changes have settled.
  func retile(_ window: Window, in view: View) {
    Logger.windows.debug(
      "\(window.id): moved off its tile by something else to \(window.frame), flushing")
    view.flushAfterWindowChange()
    frameRecheckWindows.append(window.id)
    EventLoop.post(.windowFrameRecheck, after: Self.frameRecheckDelay, key: .windowFrameRecheck)
  }

  /// Flushes, once each, the views of the observed windows that are off their tile, and returns those views. Each such
  /// window takes the observed frame as its frame and its request, so the flush writes its tile. The window of a drag
  /// or click in progress (`MouseState.window`) and windows outside a tree are left alone.
  @discardableResult
  func retileWindowsOffTile(_ observed: [(window: Window, frame: CGRect)]) -> [View] {
    let ms = MouseState.shared
    var views: [View] = []
    for (window, frame) in observed where ms.window != window {
      guard let view = managedView(for: window) else { continue }
      guard view.needsFlush(windowID: window.id, frame: frame) else {
        Logger.windows.debug("\(window.id): back on its tile after a foreign frame change")
        continue
      }
      Logger.windows.debug(
        "\(window.id): still off its tile after a foreign frame change at \(frame), flushing")
      window.frame = frame
      window.frameRequest = frame
      if !views.contains(where: { $0 === view }) { views.append(view) }
    }
    for view in views { view.flushAfterWindowChange() }
    return views
  }
}
