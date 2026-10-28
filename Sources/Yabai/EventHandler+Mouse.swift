import CoreGraphics
import Logging
import YabaiCore

//
// NOTE: The handlers of mouse events: moving and resizing windows with the mouse modifier, dropping them on
// other windows, and tab bar clicks. Focus follows mouse lives in EventHandler+FocusFollowsMouse.swift.
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

extension EventHandler {
  func mouseDown(_ event: CGEvent, _ modifiers: MouseModifiers) {
    let ms = MouseState.shared

    //
    // NOTE: A mouse down while a resize drag holds an EUI scope means that the mouse up of the drag was lost (the
    // event tap was disabled), or a second button was pressed during it. The next frame of a drag opens the scope again.
    //
    ms.endFrameScope()
    // NOTE: The drop feedback of a drag whose mouse up was lost ends here too.
    ms.clearFeedback()

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
      frame: ms.window.frame, direction: ms.direction, dx: Float(dx), dy: Float(dy),
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
}
