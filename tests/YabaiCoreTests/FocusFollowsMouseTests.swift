import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("FocusFollowsMouse")
struct FocusFollowsMouseTests {
  private static let base = ContinuousClock.now
  private static let frame = CGRect(x: 100, y: 100, width: 200, height: 200)

  private static func instant(_ ms: Int) -> ContinuousClock.Instant {
    base.advanced(by: .milliseconds(ms))
  }

  // Columns: pointer, last hit (nil: none), hit generation, current generation, request age (ms; nil: none), expected.
  // The last hit is `frame` (100..300 on both axes) unless a row says otherwise; the current time is the request
  // time plus the age, so the age decides expiry.
  @Test(
    arguments: [
      // a young request holds the move, inside the last hit or not, and clears nothing
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(1), 0,
        FFMDecision(hitTest: false, clearPending: false)
      ),
      (
        CGPoint(x: 50, y: 50), frame, UInt64(1), UInt64(1), 499,
        FFMDecision(hitTest: false, clearPending: false)
      ),
      (
        CGPoint(x: 50, y: 50), nil, UInt64(1), UInt64(1), 10,
        FFMDecision(hitTest: false, clearPending: false)
      ),
      // a young request holds the move even when the generation changed
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(2), 10,
        FFMDecision(hitTest: false, clearPending: false)
      ),
      // the request is dropped at exactly 500 ms, and an expired one moves on
      (
        CGPoint(x: 50, y: 50), frame, UInt64(1), UInt64(1), 500,
        FFMDecision(hitTest: true, clearPending: true)
      ),
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(1), 501,
        FFMDecision(hitTest: false, clearPending: true)
      ),
      (
        CGPoint(x: 50, y: 50), nil, UInt64(1), UInt64(1), 501,
        FFMDecision(hitTest: true, clearPending: true)
      ),
      // an expired request inside the last hit clears and does not hit test
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(1), 900,
        FFMDecision(hitTest: false, clearPending: true)
      ),
      // an expired request while the cache is from another generation: hit test
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(2), 900,
        FFMDecision(hitTest: true, clearPending: true)
      ),
      // no request: inside a valid last hit needs no hit test
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(1), nil,
        FFMDecision(hitTest: false, clearPending: false)
      ),
      // the same frame in another generation: hit test
      (
        CGPoint(x: 150, y: 150), frame, UInt64(1), UInt64(2), nil,
        FFMDecision(hitTest: true, clearPending: false)
      ),
      // outside the last hit: hit test
      (
        CGPoint(x: 50, y: 50), frame, UInt64(1), UInt64(1), nil,
        FFMDecision(hitTest: true, clearPending: false)
      ),
      // no last hit at all: hit test
      (
        CGPoint(x: 150, y: 150), nil, UInt64(1), UInt64(1), nil,
        FFMDecision(hitTest: true, clearPending: false)
      ),
      // the frame edges are the ones of CGRect.contains: the min edge is inside, the max edge is outside
      (
        CGPoint(x: 100, y: 100), frame, UInt64(1), UInt64(1), nil,
        FFMDecision(hitTest: false, clearPending: false)
      ),
      (
        CGPoint(x: 300, y: 150), frame, UInt64(1), UInt64(1), nil,
        FFMDecision(hitTest: true, clearPending: false)
      ),
      (
        CGPoint(x: 150, y: 300), frame, UInt64(1), UInt64(1), nil,
        FFMDecision(hitTest: true, clearPending: false)
      ),
    ] as [(CGPoint, CGRect?, UInt64, UInt64, Int?, FFMDecision)]
  )
  func decision(
    pointer: CGPoint, lastFrame: CGRect?, hitGeneration: UInt64, generation: UInt64,
    ageMs: Int?, expected: FFMDecision
  ) {
    let lastHit = lastFrame.map { FFMHitRecord(frame: $0, generation: hitGeneration) }
    let requestedAt = ageMs.map { _ in Self.instant(0) }
    let now = ageMs.map { Self.instant($0) } ?? Self.instant(0)

    let result = FFMDecision.decide(
      pointer: pointer, lastHit: lastHit, generation: generation,
      requestedAt: requestedAt, now: now)
    #expect(result == expected)
  }

  @Test("the request timeout is 500 ms")
  func requestTimeout() {
    #expect(ffmRequestTimeout == .milliseconds(500))
  }

  // Columns: hit frame, other frames, expected.
  @Test(
    arguments: [
      // nothing else on a visible space: cacheable
      (CGRect(x: 0, y: 0, width: 100, height: 100), [CGRect](), true),
      // another window beside it, sharing an edge only: cacheable
      (
        CGRect(x: 0, y: 0, width: 100, height: 100),
        [CGRect(x: 100, y: 0, width: 100, height: 100)], true
      ),
      // a window that is entirely apart: cacheable
      (
        CGRect(x: 0, y: 0, width: 100, height: 100),
        [CGRect(x: 500, y: 500, width: 10, height: 10)], true
      ),
      // a floating window or dialog over part of the hit window: not cacheable
      (
        CGRect(x: 0, y: 0, width: 100, height: 100),
        [CGRect(x: 50, y: 50, width: 100, height: 100)], false
      ),
      // one covering window among several apart ones: not cacheable
      (
        CGRect(x: 0, y: 0, width: 100, height: 100),
        [CGRect(x: 500, y: 500, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10)],
        false
      ),
      // a window that contains the hit window: not cacheable
      (
        CGRect(x: 10, y: 10, width: 50, height: 50), [CGRect(x: 0, y: 0, width: 200, height: 200)],
        false
      ),
    ] as [(CGRect, [CGRect], Bool)]
  )
  func cacheable(hitFrame: CGRect, otherFrames: [CGRect], expected: Bool) {
    #expect(FFMDecision.isCacheable(hitFrame: hitFrame, otherFrames: otherFrames) == expected)
  }
}

@Suite("FFMRecheck")
struct FFMRecheckTests {
  private static let base = ContinuousClock.now

  private static func instant(_ ms: Int) -> ContinuousClock.Instant {
    base.advanced(by: .milliseconds(ms))
  }

  // NOTE: #expect cannot call a mutating method, so every result is taken first.

  @Test("the first held move schedules the re-check for the rest of the request timeout")
  func firstHoldSchedules() {
    var recheck = FFMRecheck()
    let first = recheck.hold(requestedAt: Self.base, now: Self.instant(120))
    #expect(first == .milliseconds(380))
    #expect(recheck.state == .waiting)
    let second = recheck.hold(requestedAt: Self.base, now: Self.instant(200))
    #expect(second == nil)
    #expect(recheck.state == .waiting)
  }

  @Test("a hold past the timeout schedules at once")
  func holdPastTimeout() {
    var recheck = FFMRecheck()
    let delay = recheck.hold(requestedAt: Self.base, now: Self.instant(700))
    #expect(delay == .zero)
  }

  @Test("the resolved request brings the re-check forward once")
  func resolveOnce() {
    var recheck = FFMRecheck()
    let unheld = recheck.resolve()
    #expect(unheld == nil)
    #expect(recheck.state == .idle)

    _ = recheck.hold(requestedAt: Self.base, now: Self.base)
    let resolved = recheck.resolve()
    #expect(resolved == .zero)
    #expect(recheck.state == .resolved)
    let again = recheck.resolve()
    #expect(again == nil)
    let held = recheck.hold(requestedAt: Self.base, now: Self.base)
    #expect(held == nil)
  }

  // Columns: a move was held, the request resolved, expected result of finish.
  @Test(
    "finish reports a scheduled re-check and goes idle",
    arguments: [(false, false, false), (true, false, true), (true, true, true)]
  )
  func finish(held: Bool, resolved: Bool, expected: Bool) {
    var recheck = FFMRecheck()
    if held { _ = recheck.hold(requestedAt: Self.base, now: Self.base) }
    if resolved { _ = recheck.resolve() }
    let first = recheck.finish()
    #expect(first == expected)
    #expect(recheck.state == .idle)
    let second = recheck.finish()
    #expect(!second)
  }
}

@Suite("FFMDisplayFocus")
struct FFMDisplayFocusTests {
  private static let left = DisplayID(rawValue: 0xFFFF_0001)
  private static let right = DisplayID(rawValue: 0xFFFF_0002)
  private static let third = DisplayID(rawValue: 0xFFFF_0003)

  // Columns: display under the pointer (nil: off its usable area), focused display, expected display to focus.
  @Test(
    "a move over the desktop focuses the pointer's display only when focus is on another one",
    arguments: [
      (Optional(right), Optional(left), Optional(right)),
      (Optional(left), Optional(left), nil),
      (nil, Optional(left), nil),
      (Optional(right), nil, nil),
    ] as [(DisplayID?, DisplayID?, DisplayID?)]
  )
  func decide(pointer: DisplayID?, focused: DisplayID?, expected: DisplayID?) {
    var focus = FFMDisplayFocus()
    #expect(focus.decide(pointerDisplay: pointer, focusedDisplay: focused) == expected)
    #expect(focus.attempt?.target == expected)
  }

  @Test("a pair is tried once, until a display change resets it")
  func onceUntilReset() {
    var focus = FFMDisplayFocus()
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left) == Self.right)
    // later moves on the same desktop, the focus not yet (or never) moved
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left) == nil)
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left) == nil)
    // the focus moved there: nothing to do
    focus.reset()
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.right) == nil)
    // keyboard focus went back to the left display: the next move focuses the right one again
    focus.reset()
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left) == Self.right)
  }

  @Test("another pair is tried without a reset")
  func otherPair() {
    var focus = FFMDisplayFocus()
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left) == Self.right)
    // the pointer goes on to a third display before the focus of the first attempt arrived
    #expect(focus.decide(pointerDisplay: Self.third, focusedDisplay: Self.left) == Self.third)
    // and back: the right display is tried again
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left) == Self.right)
    // focus moved to the third display without a reset: the right display is tried from there
    #expect(focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.third) == Self.right)
  }

  @Test("a move over the focused display keeps the attempt")
  func focusedDisplayKeepsAttempt() {
    var focus = FFMDisplayFocus()
    _ = focus.decide(pointerDisplay: Self.right, focusedDisplay: Self.left)
    #expect(focus.decide(pointerDisplay: Self.left, focusedDisplay: Self.left) == nil)
    #expect(focus.attempt == FFMDisplayFocus.Attempt(target: Self.right, from: Self.left))
  }
}
