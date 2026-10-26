import CoreGraphics

//
// NOTE: Focus follows mouse asks the window server which window is under the pointer on every move. Moves inside the
// frame of the window that the last hit found answer the same question, so they skip the hit test while nothing else
// changed: the event generation (every event but a mouse move) is the same as at the hit, and no other window on a
// visible space intersects that frame. A focus request that no focus event answers is dropped after
// ffmRequestTimeout, so the pointer can reach the window again.
//

/// How long a focus follows mouse request waits for its focus event. At exactly this age the request is dropped.
public let ffmRequestTimeout: ContinuousClock.Duration = .milliseconds(500)

/// The frame of the window of the last hit test, and the event generation it was taken in.
public struct FFMHitRecord: Sendable, Equatable {
  public let frame: CGRect
  public let generation: UInt64

  public init(frame: CGRect, generation: UInt64) {
    self.frame = frame
    self.generation = generation
  }
}

/// What focus follows mouse does for one pointer move, before its gesture and focus checks.
public struct FFMDecision: Sendable, Equatable {
  /// Ask the window server which window is under the pointer.
  public let hitTest: Bool
  /// Drop the pending focus request: it is older than ffmRequestTimeout.
  public let clearPending: Bool

  public init(hitTest: Bool, clearPending: Bool) {
    self.hitTest = hitTest
    self.clearPending = clearPending
  }

  /// Decides one move.
  ///
  /// A request younger than ffmRequestTimeout holds the move: nothing is asked and nothing is cleared. An older one is
  /// dropped, and the move goes on as if none was pending. A move inside the frame of the last hit, taken in the
  /// current generation, needs no hit test. `requestedAt` is nil when no focus request is pending.
  public static func decide(
    pointer: CGPoint,
    lastHit: FFMHitRecord?,
    generation: UInt64,
    requestedAt: ContinuousClock.Instant?,
    now: ContinuousClock.Instant
  ) -> FFMDecision {
    let insideLastHit =
      lastHit.map { $0.generation == generation && $0.frame.contains(pointer) } ?? false

    guard let requestedAt else {
      return FFMDecision(hitTest: !insideLastHit, clearPending: false)
    }
    if now < requestedAt.advanced(by: ffmRequestTimeout) {
      return FFMDecision(hitTest: false, clearPending: false)
    }
    return FFMDecision(hitTest: !insideLastHit, clearPending: true)
  }

  /// Whether a hit window may be remembered: no other window on a visible space may intersect its frame, since such a
  /// window could take the pointer inside it. `otherFrames` are the frames of those windows.
  public static func isCacheable(hitFrame: CGRect, otherFrames: [CGRect]) -> Bool {
    !otherFrames.contains { $0.intersects(hitFrame) }
  }
}

//
// NOTE: A move that a pending request holds is not looked at again by itself: when the pointer stops during a fast
// sweep, its last move can be one of them, and focus stays on a window it only passed over. The first held move of a
// request schedules one re-check of the pointer for the request timeout; when the request resolves first (its focus
// event, or it is cleared), the re-check moves to at once. A move that goes on to its own checks makes the re-check
// unnecessary. So a pending request causes at most one re-check, which looks at where the pointer is then.
//

/// The re-check of the pointer after a pending focus follows mouse request held a move.
public struct FFMRecheck: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    /// No held move waits for a re-check.
    case idle
    /// A held move waits; the re-check is scheduled for the request timeout.
    case waiting
    /// The request resolved; the re-check is scheduled at once.
    case resolved
  }

  public private(set) var state = State.idle

  public init() {}

  /// A move is held by the request made at `requestedAt`. Returns the delay to schedule the re-check after for the
  /// first held move of the request, nil when one is already scheduled.
  public mutating func hold(
    requestedAt: ContinuousClock.Instant, now: ContinuousClock.Instant
  ) -> ContinuousClock.Duration? {
    guard state == .idle else { return nil }
    state = .waiting
    return max(.zero, now.duration(to: requestedAt.advanced(by: ffmRequestTimeout)))
  }

  /// The pending request resolved. Returns the delay to schedule the re-check after (at once) when a held move waits
  /// for it, nil otherwise.
  public mutating func resolve() -> ContinuousClock.Duration? {
    guard state == .waiting else { return nil }
    state = .resolved
    return .zero
  }

  /// A move went on to its own checks, or the re-check runs. Returns whether a re-check was scheduled: the move
  /// cancels it, the re-check runs only then.
  public mutating func finish() -> Bool {
    defer { state = .idle }
    return state != .idle
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
