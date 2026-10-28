import CoreGraphics

//
// NOTE: Focus follows mouse asks the window server which window is under the pointer on every move. Moves inside the
// frame of the window that the last hit found answer the same question, so they skip the hit test while nothing else
// changed: every event but a mouse move clears the cache, and no other window on a visible space intersects that
// frame. A focus request that no focus event answers is dropped after ffmRequestTimeout, along with its cached hit,
// so the pointer can reach the window again.
//

/// How long a focus follows mouse request waits for its focus event. At exactly this age the request is dropped.
public let ffmRequestTimeout: ContinuousClock.Duration = .milliseconds(500)

//
// NOTE: A move that a pending request holds is not looked at again by itself: when the pointer stops during a fast
// sweep, its last move can be one of them, and focus stays on a window it only passed over. The first held move of a
// request schedules one re-check of the pointer for the request timeout; when the request resolves first (its focus
// event, or it is cleared), the re-check moves to at once. A move that goes on to its own checks makes the re-check
// unnecessary. So a pending request causes at most one re-check, which looks at where the pointer is then.
//

/// Focus follows mouse state. Transitions return scheduling decisions; the caller owns the event loop and clock.
public struct FFMState: Sendable {
  public struct Request: Sendable, Equatable {
    public let windowID: WindowID
    public let requestedAt: ContinuousClock.Instant
  }

  /// A nil memo has not been loaded; a memo whose ids are nil remembers a failed query.
  public struct VisibleWindows: Sendable {
    public let ids: Set<WindowID>?
  }

  public enum Move: Sendable, Equatable {
    case held(recheckAfter: ContinuousClock.Duration?)
    case cached
    case hitTest(expiredRequest: WindowID?)
  }

  public enum RecheckState: Sendable {
    case idle
    case waiting
    case resolved
  }

  public private(set) var request: Request?
  public private(set) var hitFrame: CGRect?
  public private(set) var visibleWindows: VisibleWindows?
  public var displayFocus = FFMDisplayFocus()
  public private(set) var recheckState = RecheckState.idle

  public init() {}

  public mutating func beginRequest(_ windowID: WindowID, at now: ContinuousClock.Instant) {
    request = Request(windowID: windowID, requestedAt: now)
  }

  /// Ends the request, optionally only for a removed window. Returns a delay when a held move needs rechecking.
  public mutating func resolveRequest(ifFor windowID: WindowID? = nil) -> ContinuousClock.Duration?
  {
    if let windowID, request?.windowID != windowID { return nil }
    request = nil
    guard recheckState == .waiting else { return nil }
    recheckState = .resolved
    return .zero
  }

  public mutating func pointerMoved(to point: CGPoint, now: ContinuousClock.Instant) -> Move {
    if let request {
      let deadline = request.requestedAt.advanced(by: ffmRequestTimeout)
      if now < deadline {
        guard recheckState == .idle else { return .held(recheckAfter: nil) }
        recheckState = .waiting
        return .held(recheckAfter: now.duration(to: deadline))
      }
      self.request = nil
      hitFrame = nil
      return .hitTest(expiredRequest: request.windowID)
    }
    return hitFrame?.contains(point) == true ? .cached : .hitTest(expiredRequest: nil)
  }

  /// A move continues, or its scheduled re-check runs. The caller cancels a scheduled delivery when continuing.
  public mutating func finishRecheck() -> Bool {
    defer { recheckState = .idle }
    return recheckState != .idle
  }

  public mutating func storeHit(_ frame: CGRect?) {
    hitFrame = frame
  }

  public mutating func storeVisibleWindows(_ ids: Set<WindowID>?) {
    visibleWindows = VisibleWindows(ids: ids)
  }

  public mutating func invalidateHitCache() {
    hitFrame = nil
    visibleWindows = nil
  }

  /// Changing mode forgets old hit/display decisions. Disabling also cancels held moves, but keeps the request's
  /// acknowledgement marker so a focus already sent does not warp the cursor with mouse_follows_focus.
  public mutating func modeChanged(isEnabled: Bool) -> Bool {
    invalidateHitCache()
    displayFocus.reset()
    return !isEnabled && finishRecheck()
  }

  /// Whether a hit window may be remembered: no other window on a visible space may intersect its frame, since such a
  /// window could take the pointer inside it. `otherFrames` are the frames of those windows.
  public static func isCacheable(hitFrame: CGRect, otherFrames: some Sequence<CGRect>) -> Bool {
    !otherFrames.contains { $0.intersects(hitFrame) }
  }
}

/// A window in stacking order, with only the properties needed to protect floating windows during autoraise.
public struct FFMOcclusionWindow: Sendable {
  public let id: WindowID
  public let frame: CGRect
  public let isFloating: Bool
  public let level: Int32
  public let subLevel: Int32

  public init(id: WindowID, frame: CGRect, isFloating: Bool, level: Int32, subLevel: Int32) {
    self.id = id
    self.frame = frame
    self.isFloating = isFloating
    self.level = level
    self.subLevel = subLevel
  }

  /// Windows are ordered front to back on the visible space under the pointer. Only windows above this one count.
  public func wouldOccludeFloatingWindow(among windows: some Sequence<FFMOcclusionWindow>) -> Bool {
    for other in windows {
      if other.id == id { break }
      if other.isFloating && other.level == level && other.subLevel == subLevel
        && frame.contains(other.frame)
      {
        return true
      }
    }
    return false
  }
}

//
// NOTE: Over no window (the desktop or a gap), focus follows mouse focuses the display under the pointer when focus
// is on another display, as sway does over a workspace (`check_focus_follows_mouse`): the focus target of its space
// (`WindowManager.displayFocusTarget(on:from:)`, sway's focus-inactive window), or the display itself when the space
// has none. Over the desktop of the focused display nothing happens. sway asks again on every move while the two
// displays differ; here a pair of pointer display and focused display is tried once, so a focus the window server does
// not carry out (no display change follows) is not tried again on every move. A display change ends the attempt
// (`reset()`), so the desktop of a display that keyboard focus left later focuses it again, as in sway.
//

/// The display focus follows mouse focuses for the desktop under the pointer, tried once per pair of displays.
public struct FFMDisplayFocus: Sendable, Equatable {
  /// The last attempt: the display under the pointer, and the focused display it was made from.
  public struct Attempt: Sendable, Equatable {
    public let target: DisplayID
    public let from: DisplayID

    public init(target: DisplayID, from: DisplayID) {
      self.target = target
      self.from = from
    }
  }

  public private(set) var attempt: Attempt?

  public init() {}

  /// Decides a move over no window. `pointerDisplay` is the display under the pointer, nil when the pointer is off its
  /// usable area (the menu bar or the Dock); `focusedDisplay` the display that has focus. Returns the display to focus
  /// and records the attempt; nil when the pointer is on the focused display, or this pair was tried already.
  public mutating func decide(pointerDisplay: DisplayID?, focusedDisplay: DisplayID?) -> DisplayID?
  {
    guard let pointerDisplay, let focusedDisplay, pointerDisplay != focusedDisplay else {
      return nil
    }
    let next = Attempt(target: pointerDisplay, from: focusedDisplay)
    if attempt == next { return nil }
    attempt = next
    return pointerDisplay
  }

  /// The focused display changed: the next move over the desktop of another display tries again.
  public mutating func reset() {
    attempt = nil
  }
}
