import AppKit
import ApplicationServices
import CPrivate
import Foundation
import Logging
import SortedCollections
import Synchronization
import YabaiCore

//
// NOTE: The handlers of mouse events: moving and resizing windows with the mouse modifier, dropping them on
// other windows, tab bar clicks, and focus follows mouse.
//

//
// NOTE: A resize drags the corner (or edge) of the window that is closest to where the mouse went down.
//

extension ResizeHandle {
  /// The edges that a resize from point drags: the ones on the side of the frame's center where point is.
  init(at point: CGPoint, in frame: CGRect) {
    self.init(rawValue: 0)
    let frameMid = CGPoint(x: frame.midX, y: frame.midY)

    if point.x < frameMid.x { insert(.left) }
    if point.y < frameMid.y { insert(.top) }
    if point.x > frameMid.x { insert(.right) }
    if point.y > frameMid.y { insert(.bottom) }
  }
}

//
// NOTE: Resizing through the AX API is slow, so a drag resizes the window at most once per `dragResizeInterval`
// (67.67 ms, about 15 Hz). Returns false when this event was skipped. The interval is fixed rather than adapted to the
// measured latency of the AX writes: that latency differs per application, and nothing here measures it.
//

// NOTE: The split drag (EventHandler+SplitDrag.swift) writes its frames at the same rate.
let dragResizeInterval: Float = 67.67

//
// NOTE: Focus follows mouse ignores moves for this long after a horizontal Dock swipe (a space switch gesture) ends.
// During the swipe the windows of the sliding spaces pass under the pointer, and a move after it would focus one of
// them. The value is the one of #2781 (commit 51393903); it was not derived from the length of the animation.
//

private let ffmGestureSettleInterval: Float = 1250.0

extension EventHandler {
  func mouseDown(_ event: CGEvent, _ modifiers: MouseModifiers) {
    let ms = MouseState.shared

    //
    // NOTE: A mouse down while a resize drag holds an EUI scope means that the mouse up of the drag was lost (the
    // event tap was disabled), or a second button was pressed during it. The next frame of a drag opens the scope again.
    //
    ms.endFrameScope()
    // NOTE: The drop preview of a drag whose mouse up was lost ends here too, with its ghost images.
    ms.releaseDropGhosts()

    if MissionControl.shared.isActive { return }

    //
    // NOTE: A mouse down of the button that holds a drag means that the mouse up of the drag was lost (the event tap was
    // disabled, or Mission Control was open at the mouse up). The drag ends where it was last dragged to, as the mouse
    // up would have ended it, so a later plain drag does not move its window. A mouse down of another button during the
    // drag is ignored.
    //
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    if ms.isLostDrag(button: button) {
      Logger.events.debug("mouse down: the mouse up of the drag was lost, ending the drag")
      endDrag(at: ms.dragLocation)
    }
    if ms.currentAction != .none { return }

    let point = event.location
    Logger.events.debug("mouse down: \(point.x), \(point.y)")

    guard let window = WindowManager.shared.window(at: point), !window.isFullscreen else { return }

    ms.window = window
    ms.windowFrame = window.frame
    ms.downLocation = point
    ms.dragLocation = point
    ms.actionButton = button
    ms.direction = []

    let config = Config.current.mouse
    if button == Int64(CGMouseButton.left.rawValue) && config.modifier.modifiers == modifiers {
      ms.currentAction = config.action1
    } else if button == Int64(CGMouseButton.right.rawValue)
      && config.modifier.modifiers == modifiers
    {
      ms.currentAction = config.action2
    }

    if ms.currentAction == .resize {
      ms.direction = ResizeHandle(at: point, in: ms.windowFrame)
    }
  }

  func tabBarClicked(_ wid: WindowID) {
    Logger.events.debug("tab bar clicked: \(wid)")

    guard let window = WindowManager.shared.window(for: wid) else { return }

    WindowManager.shared.focusWithRaise(window)
  }

  func tabCardOrdered(_ wid: WindowID) {
    Logger.events.debug("tab card ordered: \(wid)")
    WindowManager.shared.cardDidOrder(wid)
  }

  //
  // NOTE: The view of the space under the cursor, and the window under the cursor other than the dragged
  // window (or nil), that a dragged window is dropped on.
  //

  private func mouseDropTarget(_ point: CGPoint) -> (view: View?, window: Window?) {
    let wm = WindowManager.shared
    let ms = MouseState.shared

    let cursorSid = DisplayID(containing: point).flatMap { $0.currentSpace }
    let dstView = cursorSid.map { SpaceManager.shared.view(for: $0) }

    var window = wm.window(at: point, excluding: ms.window.id)
    if window == nil { window = wm.window(at: point) }
    return (dstView, window == ms.window ? nil : window)
  }

  func mouseUp(_ event: CGEvent) {
    // NOTE: The drag ends here on every path below, including the ones that ignore the event.
    MouseState.shared.endFrameScope()

    if MissionControl.shared.isActive { return }

    let point = event.location
    Logger.events.debug("mouse up: \(point.x), \(point.y)")
    endDrag(at: point)
  }

  /// Ends the drag at point: drops a moved window there, or applies the resize. Clears the window and the action of the
  /// drag on every path.
  private func endDrag(at point: CGPoint) {
    let wm = WindowManager.shared
    let ms = MouseState.shared

    guard let window = ms.window else {
      ms.currentAction = .none
      return
    }

    defer {
      ms.clearWindow()
      ms.currentAction = .none
    }

    if !window.isValid {
      Logger.events.debug(
        "mouse up: \(window.id) has been marked invalid by the system, ignoring event")
      return
    }

    if window.isFullscreen {
      Logger.events.debug(
        "mouse up: \(window.id) is transitioning into native-fullscreen mode, ignoring event")
      return
    }

    guard let srcView = wm.managedView(for: window) else { return }

    let info = ms.windowChange

    if info.changedPosition && !info.changedSize {
      let target = mouseDropTarget(point)

      ms.drop(window, from: srcView, onto: target.window, in: target.view, at: point)
    } else if info.changedPosition || info.changedSize {
      wm.resizeAfterDrag(window, in: srcView, by: info)
    }
  }

  private func mouseDragMoveWindow(_ point: CGPoint) {
    let ms = MouseState.shared

    var newPoint = CGPoint(
      x: ms.windowFrame.origin.x + (point.x - ms.downLocation.x),
      y: ms.windowFrame.origin.y + (point.y - ms.downLocation.y))

    let did = DisplayID(containing: newPoint)
    if let did {
      let bounds = did.constrainedBounds(ignoringExternalBar: false)
      if newPoint.y < bounds.origin.y { newPoint.y = bounds.origin.y }
    }

    if !ScriptingAddition.shared.moveWindow(
      ms.window.id, x: Int32(newPoint.x), y: Int32(newPoint.y))
    {
      ms.window.move(to: newPoint)
    }
  }

  private func mouseDragResizeWindow(_ point: CGPoint) -> Bool {
    let ms = MouseState.shared

    let eventTime = OSTimer.now
    if OSTimer.milliseconds(from: ms.lastMovedTime, to: eventTime) < dragResizeInterval {
      return false
    }

    let dx = Int(point.x - ms.downLocation.x)
    let dy = Int(point.y - ms.downLocation.y)

    // NOTE: The first frame of the drag turns EUI off for the application; the frames after it write inside that scope.
    ms.beginFrameScope(of: ms.window)
    ms.window.resizeRelative(
      frame: ms.window.frame, direction: ms.direction, dx: Float(dx), dy: Float(dy), animate: false,
      euiScope: .drag)

    ms.lastMovedTime = eventTime
    ms.downLocation = point
    return true
  }

  func mouseDragged(_ event: CGEvent) {
    let ms = MouseState.shared

    //
    // NOTE: Only the most recent drag event matters, because the new frame is computed from the
    // location where the drag started. Skip this one if a newer one is already queued.
    //

    if EventHandler.isStale(pendingMouseDragged) { return }

    if MissionControl.shared.isActive { return }
    guard let window = ms.window else { return }

    if !window.isValid {
      Logger.events.debug(
        "mouse dragged: \(window.id) has been marked invalid by the system, ignoring event")
      ms.clearWindow()
      ms.currentAction = .none
      return
    }

    let point = event.location
    Logger.events.debug("mouse dragged: \(point.x), \(point.y)")
    ms.dragLocation = point

    if ms.currentAction == .move {
      mouseDragMoveWindow(point)
    } else if ms.currentAction == .resize {
      if !mouseDragResizeWindow(point) { return }
    }

    if WindowManager.shared.managedView(for: ms.window) == nil { return }

    let info = ms.windowChange

    if info.changedPosition && !info.changedSize {
      let target = mouseDropTarget(point)

      ms.showDropFeedback(view: target.view, window: target.window, at: point)
    }
  }

  //
  // NOTE(asmvik): Look for a window with role AXSheet or AXDrawer
  // and forward focus to it because we are not allowed to focus the main
  // window in these cases.
  //

  private func ffmWindowToFocus(_ window: Window) -> Window {
    guard let associatedWindows = SLS.associatedWindows(SLS.connection, window.id) else {
      return window
    }

    let wm = WindowManager.shared

    for childWid in associatedWindows {
      guard let child = wm.window(for: childWid) else { continue }

      guard let role = child.ax.role else { continue }

      if role == kAXSheetRole as String || role == kAXDrawerRole as String {
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

  private func ffmRaiseWouldOccludeFloatingWindow(_ window: Window) -> Bool {
    let wm = WindowManager.shared

    guard let sid = SpaceManager.shared.currentSpaceID,
      let windowIDs = sid.windows(includingMinimized: false)
    else { return false }

    let level = window.id.level
    let subLevel = window.id.subLevel

    for wid in windowIDs {
      if wid == window.id { break }

      guard let subWindow = wm.window(for: wid) else { continue }

      if !subWindow.isFloating { continue }
      if level != subWindow.id.level { continue }
      if subLevel != subWindow.id.subLevel { continue }

      if window.frame.contains(subWindow.frame) { return true }
    }

    return false
  }

  private func ffmFocusWindow(_ window: Window) {
    let wm = WindowManager.shared
    let ms = MouseState.shared

    if window.id == wm.focus.focused { return }
    if !window.isEligibleForManagement { return }

    if focusFollowsMouse == .autofocus {
      let target = ffmWindowToFocus(window)
      WindowManager.shared.focusWithoutRaise(target)
      ms.ffmWindowID = target.id
    } else if focusFollowsMouse == .autoraise {
      if ffmRaiseWouldOccludeFloatingWindow(window) { return }

      WindowManager.shared.focusWithRaise(window)
      ms.ffmWindowID = window.id
    }
  }

  //
  // NOTE: Over no window yabai knows, focus goes to the display under the pointer when focus is on another display, once
  // per pair of displays (`FFMDisplayFocus`). A window under the pointer that yabai does not track is focused as
  // before. Otherwise the focus target of the display's space takes focus like a hit window: without a raise for
  // autofocus, with one for autoraise (the floating occlusion check is skipped, since the pointer is not over it), and
  // as the request in flight, so its focus event does not warp the cursor with mouse_follows_focus. An empty space
  // gets the focus click at the pointer (`DisplayID.focusDesktop(at:)`), which never warps the cursor; while the cursor
  // restore of an earlier focus click is pending, nothing is tried, since the cursor is not where the user put it.
  //

  private func ffmFocusDisplayAtPoint(_ point: CGPoint) {
    let ms = MouseState.shared
    if ms.focusClickRestorePoint != nil { return }

    let cursorDid = DisplayID(containing: point).flatMap { did in
      did.constrainedBounds(ignoringExternalBar: false).containsIncludingEdges(point) ? did : nil
    }
    guard
      let did = ms.ffmDisplayFocus.decide(
        pointerDisplay: cursorDid, focusedDisplay: DisplayManager.shared.currentDisplayID)
    else { return }

    if let wid = DisplayManager.shared.focusWindow(at: point) {
      Logger.events.debug("focus follows mouse: focusing untracked window \(wid.rawValue)")
      ms.ffmWindowID = wid
      return
    }

    let wm = WindowManager.shared
    DisplayManager.shared.invalidateSpaceCaches()
    guard let sid = did.currentSpace, let window = wm.displayFocusTarget(on: sid, from: nil) else {
      Logger.events.debug("focus follows mouse: focusing empty display \(did.rawValue)")
      did.focusDesktop(at: point)
      return
    }

    Logger.events.debug(
      "focus follows mouse: focusing display \(did.rawValue) through window \(window.id.rawValue)")
    if focusFollowsMouse == .autofocus {
      let target = ffmWindowToFocus(window)
      wm.focusWithoutRaise(target)
      ms.ffmWindowID = target.id
    } else {
      wm.focusWithRaise(window)
      ms.ffmWindowID = window.id
    }
    did.activate()
  }

  /// Records the hit window's frame for the current generation, when no other window on a visible space can cover it.
  /// Otherwise the cache is cleared, and every move takes the hit test.
  private func ffmStoreHit(_ window: Window) {
    let ms = MouseState.shared
    guard let visible = ffmVisibleWindowIDs() else {
      ms.ffmHit = nil
      return
    }

    var otherFrames: [CGRect] = []
    for (id, other) in WindowManager.shared.window where id != window.id {
      if visible.contains(id) { otherFrames.append(other.frame) }
    }

    if FFMDecision.isCacheable(hitFrame: window.frame, otherFrames: otherFrames) {
      ms.ffmHit = FFMHitRecord(frame: window.frame, generation: ms.ffmGeneration)
    } else {
      ms.ffmHit = nil
    }
  }

  /// The ids of the windows on the visible spaces, minimized ones included. The window server is asked once per
  /// generation, not per move; nil when it fails.
  private func ffmVisibleWindowIDs() -> Set<WindowID>? {
    let ms = MouseState.shared
    if let memo = ms.ffmVisible, memo.generation == ms.ffmGeneration { return memo.windowIDs }

    let spaces = DisplayID.all.compactMap { $0.currentSpace }
    let ids = SpaceID.windowCandidates(on: spaces, connection: nil, includingMinimized: true)
      .map { Set($0) }
    ms.ffmVisible = (ms.ffmGeneration, ids)
    return ids
  }

  /// Warps the cursor back to where it was before the focus click of an empty display (`DisplayID.focusDesktop`).
  func focusClickCursorRestore() {
    let ms = MouseState.shared
    guard let point = ms.focusClickRestorePoint else { return }
    ms.focusClickRestorePoint = nil
    CGWarpMouseCursorPosition(point)
  }

  func mouseMoved(_ event: CGEvent) {
    if EventHandler.isStale(pendingMouseMoved) { return }

    ffmPointerMoved(to: event.location)
  }

  //
  // NOTE: The re-check of a move that a pending focus request held (FFMRecheck) looks at the pointer where it is now,
  // not where the held move was. It takes the guards the event tap applies to a move first: no move reaches yabai
  // while a mouse button is down (it is a drag) or while the mouse modifier alone is held.
  //

  func ffmRecheck() {
    let ms = MouseState.shared
    if !ms.ffmRecheck.finish() { return }

    if !ms.tap.tracksFocus.load(ordering: .relaxed) { return }
    if ms.currentAction != .none { return }
    let buttons: [CGMouseButton] = [.left, .right, .center]
    if buttons.contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }) {
      return
    }
    let modifiers = MouseModifiers(CGEventSource.flagsState(.combinedSessionState))
    if modifiers == ms.tap.modifier.modifiers { return }

    let point = SLS.cursorLocation(SLS.connection)
    Logger.events.debug("focus follows mouse: re-check at \(point.x), \(point.y)")
    ffmPointerMoved(to: point)
  }

  func ffmPointerMoved(to point: CGPoint) {
    let wm = WindowManager.shared

    if focusFollowsMouse == .disabled { return }
    if MissionControl.shared.isActive { return }

    let ms = MouseState.shared
    let now = ContinuousClock.now

    let decision = FFMDecision.decide(
      pointer: point, lastHit: ms.ffmHit, generation: ms.ffmGeneration,
      requestedAt: ms.ffmRequestTime, now: now)
    if ms.ffmWindowID != nil, !decision.clearPending, let requestedAt = ms.ffmRequestTime {
      if let delay = ms.ffmRecheck.hold(requestedAt: requestedAt, now: now) {
        EventLoop.post(.ffmRecheck, after: delay, key: .ffmRecheck)
      }
      return
    }
    if ms.ffmRecheck.finish() { EventLoop.cancel(key: .ffmRecheck) }
    if decision.clearPending {
      Logger.events.debug(
        "focus follows mouse: no focus event for window \(ms.ffmWindowID?.rawValue ?? 0) before the request timeout, dropping it"
      )
      ms.ffmWindowID = nil
    }
    if !decision.hitTest { return }

    if pendingGesture.load(ordering: .relaxed) { return }
    let dt = OSTimer.milliseconds(from: lastGestureTime.load(ordering: .relaxed), to: OSTimer.now)
    if dt < ffmGestureSettleInterval { return }

    if let window = wm.window(at: point) {
      Logger.events.debug("focus follows mouse: hit window \(window.id.rawValue)")
      ffmStoreHit(window)
      ffmFocusWindow(window)
    } else {
      ms.ffmHit = nil
      ffmFocusDisplayAtPoint(point)
    }
  }
}
