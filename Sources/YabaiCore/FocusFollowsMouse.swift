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
