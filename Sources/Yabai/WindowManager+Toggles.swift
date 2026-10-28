import AppKit
import ApplicationServices
import CPrivate
import CoreFoundation
import CoreGraphics
import YabaiCore

extension WindowManager {
  private static var nativeFullscreenWaitIterations: Int { 30 }

  //
  // NOTE: A window has left native fullscreen, but its display may still be animating. Keep waiting before
  // interacting with the window, until the active space is a user space. The display manager API does not work for
  // this on macOS Monterey. The wait is bounded because the destination space may never become active, such as
  // after a cancelled transition.
  //

  private var isNativeFullscreenTransitionDone: Bool {
    SpaceID.active.map { $0.isUser } ?? false
  }

  /// Waits for the display animation after a window left native fullscreen. The event loop takes no other event
  /// meanwhile, but other @WM code can run at each await.
  func waitForNativeFullscreenTransition() async {
    var iteration = 0
    while iteration < Self.nativeFullscreenWaitIterations && !isNativeFullscreenTransitionDone {
      try? await Task.sleep(for: .milliseconds(100))
      iteration += 1
    }
  }

  //
  // NOTE: toggleNativeFullscreen, a window command, waits synchronously. Commands do not await: the event loop
  // takes no other event before the response anyway, the commands after it in the message rely on its wait, and
  // the autorelease pool of the message cannot span an await (MessageLoop.handle).
  //

  private func blockUntilNativeFullscreenTransitionIsDone() {
    var iteration = 0
    while iteration < Self.nativeFullscreenWaitIterations && !isNativeFullscreenTransitionDone {
      usleep(100000)
      iteration += 1
    }
  }

  func toggleNativeFullscreen(_ target: Window) {
    let spaceID = target.id.space

    // NOTE: The window must be focused before its fullscreen attribute changes. Focus it and wait for a possible
    // space animation to finish before setting the attribute.
    focusWithRaise(target)
    var iteration = 0
    while iteration < Self.nativeFullscreenWaitIterations && spaceID != SpaceID.active {
      usleep(100000)
      iteration += 1
    }

    _ = target.ref?.setAttribute(Window.fullscreenAttribute, to: !target.reportsFullscreen)

    // NOTE: After changing fullscreen, wait for the display animation to finish.
    blockUntilNativeFullscreenTransitionIsDone()
  }

  private func toggleZoom(for target: Window, to zoom: ConZoom) {
    guard let owner = treeView(for: target) else { return }
    guard let node = owner.tree?.find(target.id), node != owner.tree else { return }

    var zoom = zoom
    if zoom == .parent && node.parent == owner.tree { zoom = .fullscreen }

    node.zoom = node.zoom == zoom ? .none : zoom
    treeApply(owner)
  }

  func toggleParentZoom(_ target: Window) {
    toggleZoom(for: target, to: .parent)
  }

  func toggleFullscreenZoom(_ target: Window) {
    toggleZoom(for: target, to: .fullscreen)
  }

  func toggleWindowedFullscreen(_ target: Window) {
    guard let displayID = target.id.displayID else { return }

    if target.isWindowed {
      target.isWindowed = false
      let frame = target.windowedFrame
      placeWindow(
        WindowPlacement(
          window: target,
          x: Float(frame.origin.x),
          y: Float(frame.origin.y),
          w: Float(frame.size.width),
          h: Float(frame.size.height)
        ))
    } else {
      target.isWindowed = true
      target.windowedFrame = target.frame
      let bounds = displayID.constrainedBounds(ignoringExternalBar: true)
      placeWindow(
        WindowPlacement(
          window: target,
          x: Float(bounds.origin.x),
          y: Float(bounds.origin.y),
          w: Float(bounds.size.width),
          h: Float(bounds.size.height)
        ))
    }
  }

  func toggleExpose(_ target: Window) {
    focusWithRaise(target)
    CoreDock.sendNotification("com.apple.expose.front.awake")
  }

  func togglePictureInPicture(_ target: Window) {
    guard let displayID = target.id.displayID else { return }

    // NOTE: Without a space on the display, its bounds are not reduced by padding because the space's view has none.
    let view = displayID.currentSpace.map { SpaceManager.shared.view(for: $0) }

    var bounds = displayID.constrainedBounds(ignoringExternalBar: false)
    if let view, view.isPaddingEnabled {
      bounds.origin.x += CGFloat(view.leftPadding)
      bounds.size.width -= CGFloat(view.leftPadding + view.rightPadding)
      bounds.origin.y += CGFloat(view.topPadding)
      bounds.size.height -= CGFloat(view.topPadding + view.bottomPadding)
    }

    ScriptingAddition.shared.scaleWindow(
      target.id,
      x: Float(bounds.origin.x),
      y: Float(bounds.origin.y),
      width: Float(bounds.size.width),
      height: Float(bounds.size.height)
    )
  }
}
