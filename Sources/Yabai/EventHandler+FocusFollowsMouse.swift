import ApplicationServices
import CoreGraphics
import Logging
import SortedCollections
import Synchronization
import YabaiCore

//
// NOTE: Focus follows mouse ignores moves for this long after a horizontal Dock swipe (a space switch gesture) ends.
// During the swipe the windows of the sliding spaces pass under the pointer, and a move after it would focus one of
// them. The value is the one of #2781 (commit 51393903); it was not derived from the length of the animation.
//

private let ffmGestureSettleInterval: Float = 1250.0

extension EventHandler {
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

  private func ffmRaiseWouldOccludeFloatingWindow(_ window: Window, at point: CGPoint) -> Bool {
    let wm = WindowManager.shared

    // NOTE: Focus may still be on another display. Use the visible space under the pointer, also for sticky windows.
    guard let sid = DisplayID(containing: point)?.currentSpace,
      let windowIDs = sid.windows(includingMinimized: false)
    else { return false }

    let target = FFMOcclusionWindow(
      id: window.id, frame: window.frame, isFloating: window.isFloating,
      level: window.id.level, subLevel: window.id.subLevel)
    let candidates = windowIDs.lazy.compactMap { wid -> FFMOcclusionWindow? in
      if wid == window.id { return target }
      guard let other = wm.window(for: wid), other.isFloating else { return nil }
      let level = wid.level
      guard level == target.level else { return nil }
      return FFMOcclusionWindow(
        id: wid, frame: other.frame, isFloating: true, level: level, subLevel: wid.subLevel)
    }
    return target.wouldOccludeFloatingWindow(among: candidates)
  }

  private func ffmFocusWindow(_ window: Window, at point: CGPoint) {
    let wm = WindowManager.shared

    if window.id == wm.focus.focused { return }
    if !window.isEligibleForManagement { return }
    if ffmMissionControlIsOpen() { return }

    if focusFollowsMouse == .autoraise && ffmRaiseWouldOccludeFloatingWindow(window, at: point) {
      return
    }
    ffmRequestFocus(window)
  }

  /// Sends the focus and records its acknowledgement marker. Display fallback deliberately skips hit-window checks.
  private func ffmRequestFocus(_ window: Window) {
    let wm = WindowManager.shared
    let target: Window
    switch focusFollowsMouse {
    case .disabled: return
    case .autofocus:
      target = ffmWindowToFocus(window)
      wm.focusWithoutRaise(target)
    case .autoraise:
      target = window
      wm.focusWithRaise(target)
    }
    MouseState.shared.ffm.beginRequest(target.id, at: .now)
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
      let did = ms.ffm.displayFocus.decide(
        pointerDisplay: cursorDid, focusedDisplay: DisplayManager.shared.currentDisplayID)
    else { return }
    // NOTE: The attempt is cleared, so the first move after Mission Control closes tries this pair again.
    if ffmMissionControlIsOpen() {
      ms.ffm.displayFocus.reset()
      return
    }

    if let wid = DisplayManager.shared.focusWindow(at: point) {
      Logger.events.debug("focus follows mouse: focusing untracked window \(wid.rawValue)")
      ms.ffm.beginRequest(wid, at: .now)
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
    ffmRequestFocus(window)
    did.activate()
  }

  //
  // NOTE: The front change that reports the opening of Mission Control (missionControlEnter) does not come for every
  // opening. On macOS 27 (2026-10-27, three displays), an opening through the shortcut (`missioncontrol open`) logged no
  // enter while Mission Control stayed open for seconds: the enter came only at its close, with the overlay still on
  // screen. Focus follows mouse then focused the windows and displays under the pointer in the overview. So before a
  // change of focus it looks at the overlay itself (`MissionControl.overlayIsShown`, about 1 ms), and enters Mission
  // Control when it is shown: the guards of every later move and click apply, and the exit check runs as for an enter.
  //

  /// Whether the Mission Control overlay is on screen; enters Mission Control when it is (`overlayIsShown` asks).
  func ffmMissionControlIsOpen(overlayIsShown: () -> Bool = MissionControl.overlayIsShown) -> Bool {
    if !overlayIsShown() { return false }
    Logger.events.debug("focus follows mouse: the Mission Control overlay is on screen")
    missionControlEnter()
    return true
  }

  /// Records the hit window's frame until invalidation, when no other window on a visible space can cover it.
  /// Otherwise the cache is cleared, and every move takes the hit test.
  private func ffmStoreHit(_ window: Window) {
    let ms = MouseState.shared
    guard let visible = ffmVisibleWindowIDs() else {
      ms.ffm.storeHit(nil)
      return
    }

    let otherFrames = WindowManager.shared.window.lazy.compactMap { id, other -> CGRect? in
      id != window.id && visible.contains(id) ? other.frame : nil
    }
    ms.ffm.storeHit(
      FFMState.isCacheable(hitFrame: window.frame, otherFrames: otherFrames) ? window.frame : nil)
  }

  /// The ids of the windows on the visible spaces, minimized ones included. The window server is asked once per
  /// invalidation, not per move; nil when it fails (also memoized).
  private func ffmVisibleWindowIDs() -> Set<WindowID>? {
    let ms = MouseState.shared
    if let memo = ms.ffm.visibleWindows { return memo.ids }

    let spaces = DisplayID.all.compactMap { $0.currentSpace }
    let ids = SpaceID.windowCandidates(on: spaces, connection: nil, includingMinimized: true)
      .map { Set($0) }
    ms.ffm.storeVisibleWindows(ids)
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
  // NOTE: The re-check of a move that a pending focus request held looks at the pointer where it is now,
  // not where the held move was. It takes the guards the event tap applies to a move first: no move reaches yabai
  // while a mouse button is down (it is a drag) or while the mouse modifier alone is held.
  //

  func ffmRecheck() {
    let ms = MouseState.shared
    if !ms.ffm.finishRecheck() { return }

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
    let move = ms.ffm.pointerMoved(to: point, now: .now)
    if case .held(let delay) = move {
      if let delay {
        EventLoop.post(.ffmRecheck, after: delay, key: .ffmRecheck)
      }
      return
    }
    if ms.ffm.finishRecheck() { EventLoop.cancel(key: .ffmRecheck) }
    guard case .hitTest(let expiredRequest) = move else { return }
    if let expiredRequest {
      Logger.events.debug(
        "focus follows mouse: no focus event for window \(expiredRequest.rawValue) before the request timeout, dropping it"
      )
    }

    if pendingGesture.load(ordering: .relaxed) { return }
    let dt = OSTimer.milliseconds(from: lastGestureTime.load(ordering: .relaxed), to: OSTimer.now)
    if dt < ffmGestureSettleInterval { return }

    if let window = wm.window(at: point) {
      Logger.events.debug("focus follows mouse: hit window \(window.id.rawValue)")
      ffmStoreHit(window)
      ffmFocusWindow(window, at: point)
    } else {
      ms.ffm.storeHit(nil)
      ffmFocusDisplayAtPoint(point)
    }
  }
}
