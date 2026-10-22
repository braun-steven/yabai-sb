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

  func centerMouse(on target: Window) {
    if !(target.mouseFollowsFocusByRule ?? Config.current.window.mouseFollowsFocus) { return }

    let cursor = SLS.cursorLocation(SLS.connection)
    if target.frame.contains(cursor) { return }

    guard let did = target.id.displayID else { return }

    let center = CGPoint(
      x: target.frame.origin.x + target.frame.size.width / 2,
      y: target.frame.origin.y + target.frame.size.height / 2)

    let bounds = CGDisplayBounds(did.rawValue)
    if !bounds.contains(center) { return }

    CGWarpMouseCursorPosition(center)
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

  func manageWindow(_ target: Window, on spaceID: SpaceID, inserting insertionPoint: WindowID?) {
    let owner = SpaceManager.shared.tile(target, on: spaceID, insertionPoint: insertionPoint)
    addManagedWindow(target, to: owner)
  }

  func treeView(for target: Window?) -> View? {
    guard let target, let owner = managedView(for: target) else { return nil }
    return owner.tree != nil ? owner : nil
  }

  func focusWindow(id windowID: WindowID?) {
    guard let windowID else { return }
    if let target = window(for: windowID) {
      focusWithRaise(target)
      setPendingFocus(target.id)
    }
  }
}
