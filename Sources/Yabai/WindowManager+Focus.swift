import AppKit
import ApplicationServices
import CPrivate
import Logging
import YabaiCore

//
// NOTE: Focusing windows through synthesized event records, and the window that commands act on.
//

/// The size of the event records that SLPSPostEventRecordTo sends.
private let eventRecordSize = 0x100

extension WindowManager {
  /// Runs the body with a zeroed event record, which it fills and posts.
  private static func withEventRecord(_ fill: (UnsafeMutablePointer<UInt8>) -> Void) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: eventRecordSize) { buffer in
      let bytes = buffer.baseAddress!
      bytes.initialize(repeating: 0, count: eventRecordSize)
      fill(bytes)
    }
  }

  /// Writes a window id into an event record at the offset; 0 for no window, as the window server reads it.
  private static func storeWindowID(
    _ bytes: UnsafeMutablePointer<UInt8>, at offset: Int, _ windowID: WindowID?
  ) {
    UnsafeMutableRawPointer(bytes + offset).storeBytes(of: windowID?.rawValue ?? 0, as: UInt32.self)
  }

  /// Posts the synthesized events that make an application window key.
  private static func makeKeyWindow(_ process: ProcessSerialNumber, _ windowID: WindowID) {
    //
    // :SynthesizedEvent
    //
    // NOTE: These events are picked up by an event tap at the "Annotated Session" location, so they flow to an
    // application as session events.
    //

    withEventRecord { bytes in
      bytes[0x04] = 0xf8
      bytes[0x3a] = 0x10
      storeWindowID(bytes, at: 0x3c, windowID)
      (bytes + 0x20).update(repeating: 0xff, count: 0x10)

      bytes[0x08] = 0x01
      SLS.postEventRecord(bytes, to: process)

      bytes[0x08] = 0x02
      SLS.postEventRecord(bytes, to: process)
    }
  }

  //
  // NOTE: An event record of type 0x0d tells the application of windowID that the window lost (0x02) or gained
  // (0x01) focus, so focus can move between windows of one application without raising them.
  //
  private static func postFocusRecord(
    to process: ProcessSerialNumber, windowID: WindowID?, state: UInt8
  ) {
    withEventRecord { bytes in
      bytes[0x04] = 0xf8
      bytes[0x08] = 0x0d

      bytes[0x8a] = state
      storeWindowID(bytes, at: 0x3c, windowID)
      SLS.postEventRecord(bytes, to: process)
    }
  }

  func focusWithoutRaise(_ target: Window) {
    if target.application.psn.isSame(as: focus.focusedPSN) {
      Self.postFocusRecord(to: focus.focusedPSN, windowID: focus.focused, state: 0x02)

      //
      // @hack
      // Artificially delay the activation by 40ms. This is necessary
      // because some applications appear to be confused if both of the
      // events appear instantaneously.
      //
      // NOTE: The activation is posted back to the event loop instead of sleeping,
      // so that the event loop keeps handling events in the meantime.
      //

      EventLoop.post(.windowFocusDeferred(windowID: target.id), after: .milliseconds(40))

      return
    }

    SLS.setFrontProcess(target.application.psn, window: target.id, mode: .userGenerated)
    Self.makeKeyWindow(target.application.psn, target.id)
  }

  func focusWithoutRaiseDeferred(_ target: Window) {
    Self.postFocusRecord(to: target.application.psn, windowID: target.id, state: 0x01)

    SLS.setFrontProcess(target.application.psn, window: target.id, mode: .userGenerated)
    Self.makeKeyWindow(target.application.psn, target.id)
  }

  func focusWithRaise(_ target: Window) {
    guard let reference = target.ref else {
      Logger.windows.debug("\(target.id): has no AX element, not raising it")
      return
    }
    focusWithRaise(process: target.application.psn, windowID: target.id, reference: reference)
  }

  /// Focuses a window that is not represented by a managed `Window` model.
  func focusWithRaise(process: ProcessSerialNumber, windowID: WindowID, reference: AXUIElement) {
    SLS.setFrontProcess(process, window: windowID, mode: .userGenerated)
    Self.makeKeyWindow(process, windowID)
    reference.perform(kAXRaiseAction)
  }

  var focusedApplication: Application? {
    let process = SLS.frontProcess()
    return application(for: ProcessGetPIDC(process))
  }

  var focusedWindow: Window? {
    guard let owner = focusedApplication else { return nil }
    guard let windowID = owner.focusedWindowID else { return nil }
    return window(for: windowID)
  }

  //
  // NOTE: A window focused by a command only reports its focus once the application has processed the
  // activation, which can take longer than it takes to send the next command. Until then, the next command
  // acts on the window that was asked to be focused, instead of the one the application still reports.
  //

  func setPendingFocus(_ windowID: WindowID, warpsMouse: Bool = true) {
    focus.setPending(windowID, at: OSTimer.now, warpsMouse: warpsMouse)
  }

  /// The window of the pending focus, when it has not expired and its window exists. Consuming it drops an expired
  /// pending focus, and one whose window is gone.
  func consumePendingFocusWindow(now: UInt64) -> Window? {
    guard let pendingID = focus.consumePending(now: now) else { return nil }

    let target = window(for: pendingID)
    if target == nil { focus.clearPending() }

    return target
  }

  /// Focuses a display, coming from the display in the opposite direction or from no direction (nil): the window of
  /// `displayFocusTarget(on:from:)` on its current space, or the display itself when the space has none.
  func focusDisplay(_ did: DisplayID, from direction: Direction?) {
    did.focus(space: did.currentSpace, from: direction)
  }

  //
  // NOTE: How `window --focus <direction>` moves focus when the acting window is in no tree. With no acting window (an
  // empty space), or one yabai could not manage (a system dialog), focus goes to the display in the direction of the
  // focused display, as sway does from an empty workspace. On a float space it goes to the nearest window in the
  // direction there, and to that display only when there is none: sway has no float layout, and this lets one binding
  // move across the windows and then the displays. A floating window on any other space moves to the nearest floating
  // window in the direction on its space and never to a display, as sway does (`node_get_in_direction_floating`). An
  // eligible window outside a tree on a tree space (not yet tiled) crosses as well.
  //

  enum DirectionalFocus: Equatable {
    /// The nearest window in the direction on the space of the acting window, else the display in the direction.
    case space
    /// The nearest floating window in the direction on the space of the acting window, else nothing.
    case floating
    /// The display in the direction.
    case display
  }

  /// How `window --focus <direction>` moves from an acting window outside a tree: `window` is nil without one,
  /// `layout` the layout of its space.
  nonisolated static func directionalFocus(
    window: (isEligible: Bool, isFloating: Bool)?, layout: ViewType?
  ) -> DirectionalFocus {
    guard let window, window.isEligible else { return .display }
    if layout == .float { return .space }
    return window.isFloating ? .floating : .display
  }

  /// How `window --focus <direction>` moves from an acting window outside a tree (see `directionalFocus(window:layout:)`).
  func directionalFocus(from target: Window?) -> DirectionalFocus {
    let layout = target?.id.space.map { SpaceManager.shared.view(for: $0).layout }
    return Self.directionalFocus(
      window: target.map { ($0.isEligibleForManagement, $0.isFloating) }, layout: layout)
  }

  /// Moves focus in a direction from an acting window outside a tree, as `route` says. Throws when there is no window
  /// and, unless the route is `.floating`, no display in the direction.
  func focus(_ direction: Direction, from target: Window?, by route: DirectionalFocus)
    throws(WindowOperationError)
  {
    switch route {
    case .floating:
      guard let target, let sid = target.id.space,
        let found = closestFloatingWindow(on: sid, to: target, in: direction)
      else { throw .invalidDestinationNode }
      focusWindow(id: found.id)
      return
    case .space:
      if let target, let sid = target.id.space,
        let found = closestWindow(on: sid, to: target, in: direction)
      {
        focusWindow(id: found.id)
        return
      }
    case .display:
      break
    }

    guard let did = DisplayID.active?.crossingDisplay(in: direction) else {
      throw .invalidDestinationNode
    }
    focusDisplay(did, from: direction)
  }

  //
  // NOTE: `window --warp <direction>` of a window outside a tree (floating, not yet tiled, on a float space, or one yabai
  // could not manage) sends it to the current space of the display in the direction of its own display, as
  // `window --display` does, and keeps it focused. There is no wrap, and a display showing a fullscreen space is refused
  // as in the tree (`DisplayID.crossingDisplay(in:)`). sway moves a floating window by pixels instead
  // (`move <direction>`) and gives it to the output under its center; here one binding warps tiled windows in the tree
  // and every other window across displays.
  //

  /// Sends a window outside a tree to the display in a direction from its own display and focuses it. Throws when there
  /// is no display in the direction, or it shows a fullscreen space or no space.
  func warpToDisplay(_ target: Window, in direction: Direction) throws(WindowOperationError) {
    guard let source = target.id.displayID else { throw .invalidSourceView }
    guard let did = source.crossingDisplay(in: direction), let sid = did.currentSpace else {
      throw .invalidDestinationNode
    }
    sendWindow(target, to: sid, movedByRule: false, besideFocus: true, refocusingSource: false)
    focusWithRaise(target)
    setPendingFocus(target.id, warpsMouse: false)
  }

  /// The window that commands act on: the pending focus, or else the focused window.
  func actingWindow() -> Window? {
    consumePendingFocusWindow(now: OSTimer.now) ?? focusedWindow
  }

  //
  // NOTE: Asking the frontmost application for its focused window is an accessibility round trip, which
  // blocks for up to the accessibility timeout when the application does not respond. When the front
  // process still owns the window that last received focus, and no focus change has been reported since,
  // that window is still the focused one and the question can be skipped. The display and space of the
  // window are always looked up again.
  //

  func canUseKnownFocus(front: ProcessSerialNumber, pendingFocus: Bool) -> Bool {
    if pendingFocus { return false }
    if focus.focused == nil { return false }

    return front.isSame(as: focus.focusedPSN)
  }
}
