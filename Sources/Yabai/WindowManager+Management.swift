import AppKit
import CPrivate
import CoreGraphics
import YabaiCore

/// The variable parts of unmanaging a window (`WindowManager.unmanage`).
struct UnmanageOptions: OptionSet {
  let rawValue: Int

  /// Flush the view when the window was in its tree. Without it, the caller flushes the dirty view later.
  static let flush = UnmanageOptions(rawValue: 1 << 0)
  /// Restore the shadow of an unmanaged window once the window has left its view.
  static let purify = UnmanageOptions(rawValue: 1 << 1)
}

extension WindowManager {
  func setFocusFollowsMouse(_ mode: FocusFollowsMouse) {
    MouseState.shared.ffmHit = nil

    // NOTE: In headless mode the test process must not install an event tap on the user's mouse.
    if Headless.isEnabled {
      Config.current.window.focusFollowsMouse = mode
      return
    }

    MouseState.shared.endEventTap()

    if mode == .disabled {
      MouseState.shared.beginEventTap(mask: mouseEventMask)
    } else {
      MouseState.shared.beginEventTap(mask: mouseEventMaskFFM)
    }

    Config.current.window.focusFollowsMouse = mode
  }

  //
  // NOTE: The cached frame of a window follows its AX moved and resized events, which come after the window server has
  // moved the space of the window to another display (`space --display`). A caller that knows the display the window
  // is on now (`display`, `DisplayID.focus(space:from:)`) gets the frame there from `MouseFollowsFocus.focusFrame`: the
  // window's tile while its tree is laid out (`tileFrame(of:)`), else the window server's frame. Without one, a cursor
  // inside the cached frame stays without asking the window server for the display.
  //

  /// Moves the cursor to the center of a window that takes focus, as `mouse_follows_focus` says (`MouseFollowsFocus`).
  func centerMouse(on target: Window, display: DisplayID? = nil) {
    if !(target.mouseFollowsFocusByRule ?? Config.current.window.mouseFollowsFocus) { return }

    let cursor = SLS.cursorLocation(SLS.connection)
    if display == nil, target.frame.contains(cursor) { return }

    guard let did = display ?? target.id.displayID else { return }
    let bounds = CGDisplayBounds(did.rawValue)

    let frame =
      display == nil
      ? target.frame
      : MouseFollowsFocus.focusFrame(
        cached: target.frame, tile: tileFrame(of: target), displayBounds: bounds,
        live: { SLS.windowBounds(SLS.connection, target.id) })
    if let center = MouseFollowsFocus.warpPoint(cursor: cursor, frame: frame, displayBounds: bounds)
    {
      CGWarpMouseCursorPosition(center)
    }
  }

  /// The frame of a tiled window in its tree, while the tree is laid out (its view is valid); nil otherwise.
  func tileFrame(of target: Window) -> CGRect? {
    guard let owner = treeView(for: target), owner.isValid, let node = owner.findWindow(target.id)
    else { return nil }
    let area = owner.frame(for: node)
    return CGRect(
      x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
  }

  func managedView(for target: Window) -> View? {
    managedWindows[target.id]
  }

  func removeManagedWindow(_ windowID: WindowID) {
    managedWindows.removeValue(forKey: windowID)
  }

  func addManagedWindow(_ target: Window, to owner: View) {
    if owner.layout == .float { return }

    if managedWindows[target.id] == nil { managedWindows[target.id] = owner }
    purifyWindow(target)
  }

  //
  // NOTE: These operations on tree spaces act on the container selected with
  // 'window --focus parent' when there is one, and on the window otherwise.
  //

  //
  // NOTE: Unmanaging a window removes it from its view's tree and gives it the shadow and layer of an unmanaged window.
  //

  func unmanageWindow(_ target: Window, from owner: View) {
    unmanage(target, from: owner, options: [.flush, .purify])
  }

  /// Takes a window out of its view and out of the managed windows: for a tiled view, the layer is restored and the
  /// window is removed from the tree (flushing the view with `.flush` when it was in the tree); then the window leaves
  /// the managed windows and `.purify` restores its shadow. A float view has no tree to leave. Without `.flush` the
  /// caller flushes the dirty view later.
  func unmanage(_ target: Window, from owner: View, options: UnmanageOptions) {
    if owner.layout != .float {
      target.adjustLayer(to: .normal)
      if owner.remove(target), options.contains(.flush) { owner.flush() }
    }
    removeManagedWindow(target.id)
    if options.contains(.purify) { purifyWindow(target) }
  }

  func manageWindow(
    _ target: Window, on spaceID: SpaceID, inserting insertionPoint: WindowID?,
    besideFocus: Bool = false, arrivingFrom direction: Direction? = nil
  ) {
    let owner = SpaceManager.shared.tile(
      target, on: spaceID, insertionPoint: insertionPoint, besideFocus: besideFocus,
      arrivingFrom: direction)
    addManagedWindow(target, to: owner)
  }

  func treeView(for target: Window?) -> View? {
    guard let target, let owner = managedView(for: target) else { return nil }
    return owner.tree != nil ? owner : nil
  }

  /// Focuses and raises a window, as the pending focus. With `warpsMouse` false its focus event does not move the
  /// cursor (`MouseFollowsFocus`).
  func focusWindow(id windowID: WindowID?, warpsMouse: Bool = true) {
    guard let windowID else { return }
    if let target = window(for: windowID) {
      focusWithRaise(target)
      setPendingFocus(target.id, warpsMouse: warpsMouse)
    }
  }
}
