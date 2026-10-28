import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("FocusFollowsMouse")
struct FocusFollowsMouseTests {
  private static let base = ContinuousClock.now
  private static let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
  private static let windowID = WindowID(rawValue: 0xFFFF_0001)

  @Test(
    arguments: [
      (CGPoint(x: 150, y: 150), frame, 0, false, .held(recheckAfter: .milliseconds(500))),
      (CGPoint(x: 50, y: 50), frame, 499, false, .held(recheckAfter: .milliseconds(1))),
      (CGPoint(x: 50, y: 50), nil, 10, false, .held(recheckAfter: .milliseconds(490))),
      (CGPoint(x: 150, y: 150), frame, 10, true, .held(recheckAfter: .milliseconds(490))),
      (CGPoint(x: 50, y: 50), frame, 500, false, .hitTest(expiredRequest: windowID)),
      (CGPoint(x: 150, y: 150), frame, 500, false, .hitTest(expiredRequest: windowID)),
      (CGPoint(x: 150, y: 150), frame, 600, false, .hitTest(expiredRequest: windowID)),
      (CGPoint(x: 50, y: 50), nil, 900, false, .hitTest(expiredRequest: windowID)),
      (CGPoint(x: 150, y: 150), frame, nil, false, .cached),
      (CGPoint(x: 150, y: 150), frame, nil, true, .hitTest(expiredRequest: nil)),
      (CGPoint(x: 50, y: 50), frame, nil, false, .hitTest(expiredRequest: nil)),
      (CGPoint(x: 150, y: 150), nil, nil, false, .hitTest(expiredRequest: nil)),
      (CGPoint(x: 100, y: 100), frame, nil, false, .cached),
      (CGPoint(x: 300, y: 150), frame, nil, false, .hitTest(expiredRequest: nil)),
      (CGPoint(x: 150, y: 300), frame, nil, false, .hitTest(expiredRequest: nil)),
    ] as [(CGPoint, CGRect?, Int?, Bool, FFMState.Move)])
  func decision(
    pointer: CGPoint, cachedFrame: CGRect?, ageMs: Int?, invalidated: Bool,
    expected: FFMState.Move
  ) {
    var state = FFMState()
    state.storeHit(cachedFrame)
    if invalidated { state.invalidateHitCache() }
    if ageMs != nil { state.beginRequest(Self.windowID, at: Self.base) }

    let result = state.pointerMoved(
      to: pointer, now: Self.base.advanced(by: .milliseconds(ageMs ?? 0)))
    #expect(result == expected)
  }

  @Test("an expired request cannot leave a cached hit suppressing later moves")
  func expiredRequestInvalidatesHit() {
    var state = FFMState()
    state.storeHit(Self.frame)
    state.beginRequest(Self.windowID, at: Self.base)

    let expired = state.pointerMoved(
      to: CGPoint(x: 150, y: 150), now: Self.base.advanced(by: .milliseconds(600)))
    #expect(expired == .hitTest(expiredRequest: Self.windowID))
    #expect(state.request == nil)
    #expect(state.hitFrame == nil)
    let next = state.pointerMoved(
      to: CGPoint(x: 160, y: 150), now: Self.base.advanced(by: .milliseconds(610)))
    #expect(next == .hitTest(expiredRequest: nil))
  }

  @Test("held moves coalesce, resolve early, and are consumed once")
  func heldMovesResolve() {
    var state = FFMState()
    state.beginRequest(Self.windowID, at: Self.base)
    let first = state.pointerMoved(to: .zero, now: Self.base.advanced(by: .milliseconds(120)))
    #expect(first == .held(recheckAfter: .milliseconds(380)))
    let second = state.pointerMoved(to: .zero, now: Self.base.advanced(by: .milliseconds(200)))
    #expect(second == .held(recheckAfter: nil))
    let unrelated = state.resolveRequest(ifFor: WindowID(rawValue: 0xFFFF_0002))
    #expect(unrelated == nil)
    #expect(state.request?.windowID == Self.windowID)
    #expect(state.recheckState == .waiting)
    let resolved = state.resolveRequest(ifFor: Self.windowID)
    #expect(resolved == .zero)
    #expect(state.request == nil)
    #expect(state.recheckState == .resolved)
    let again = state.resolveRequest()
    #expect(again == nil)
    let finished = state.finishRecheck()
    #expect(finished)
    let finishedAgain = state.finishRecheck()
    #expect(!finishedAgain)
  }

  @Test("a move after timeout cancels the held recheck without scheduling a resolved one")
  func timeoutCancelsHeldMove() {
    var state = FFMState()
    state.beginRequest(Self.windowID, at: Self.base)
    _ = state.pointerMoved(to: .zero, now: Self.base)
    let move = state.pointerMoved(to: .zero, now: Self.base.advanced(by: .milliseconds(500)))
    #expect(move == .hitTest(expiredRequest: Self.windowID))
    let finished = state.finishRecheck()
    #expect(finished)
    #expect(state.recheckState == .idle)
    let resolved = state.resolveRequest()
    #expect(resolved == nil)
  }

  @Test(arguments: [false, true])
  func visibilityMemoIsInvalidated(querySucceeded: Bool) {
    var state = FFMState()
    #expect(state.visibleWindows == nil)
    let ids: Set<WindowID>? = querySucceeded ? [Self.windowID] : nil
    state.storeVisibleWindows(ids)
    state.storeHit(Self.frame)
    #expect(state.visibleWindows != nil)
    #expect(state.visibleWindows?.ids == ids)
    state.invalidateHitCache()
    #expect(state.visibleWindows == nil)
    #expect(state.hitFrame == nil)
  }

  @Test(arguments: [false, true])
  func modeChangeResetsDecisionsAndPreservesAcknowledgement(isEnabled: Bool) {
    var state = FFMState()
    let left = DisplayID(rawValue: 0xFFFF_0001)
    let right = DisplayID(rawValue: 0xFFFF_0002)
    _ = state.displayFocus.decide(pointerDisplay: right, focusedDisplay: left)
    state.storeHit(Self.frame)
    state.storeVisibleWindows([Self.windowID])
    state.beginRequest(Self.windowID, at: Self.base)
    _ = state.pointerMoved(to: .zero, now: Self.base)
    let cancel = state.modeChanged(isEnabled: isEnabled)
    #expect(cancel == !isEnabled)
    #expect(state.hitFrame == nil)
    #expect(state.visibleWindows == nil)
    #expect(state.displayFocus.attempt == nil)
    #expect(state.request?.windowID == Self.windowID)
    #expect(state.recheckState == (isEnabled ? .waiting : .idle))
    let delay = state.resolveRequest()
    #expect(delay == (isEnabled ? .zero : nil))
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
    #expect(FFMState.isCacheable(hitFrame: hitFrame, otherFrames: otherFrames) == expected)
  }
}

@Suite("FFMOcclusion")
struct FFMOcclusionTests {
  private static let target = FFMOcclusionWindow(
    id: WindowID(rawValue: 0xFFFF_0001), frame: CGRect(x: 0, y: 0, width: 200, height: 200),
    isFloating: false, level: 0, subLevel: 0)

  @Test(arguments: [
    (true, Int32(0), Int32(0), CGRect(x: 50, y: 50, width: 50, height: 50), true, true),
    (true, Int32(0), Int32(0), CGRect(x: 50, y: 50, width: 50, height: 50), false, false),
    (false, Int32(0), Int32(0), CGRect(x: 50, y: 50, width: 50, height: 50), true, false),
    (true, Int32(1), Int32(0), CGRect(x: 50, y: 50, width: 50, height: 50), true, false),
    (true, Int32(0), Int32(1), CGRect(x: 50, y: 50, width: 50, height: 50), true, false),
    (true, Int32(0), Int32(0), CGRect(x: 150, y: 50, width: 100, height: 50), true, false),
    (true, Int32(0), Int32(0), CGRect(x: 300, y: 50, width: 50, height: 50), true, false),
  ])
  func protectsOnlyCoveredFloatingWindowsAboveTarget(
    floating: Bool, level: Int32, subLevel: Int32, frame: CGRect, above: Bool, expected: Bool
  ) {
    let other = FFMOcclusionWindow(
      id: WindowID(rawValue: 0xFFFF_0002), frame: frame, isFloating: floating,
      level: level, subLevel: subLevel)
    let windows = above ? [other, Self.target] : [Self.target, other]
    #expect(Self.target.wouldOccludeFloatingWindow(among: windows) == expected)
  }

  @Test("candidates below the target are not inspected")
  func stopsAtTarget() {
    let floating = FFMOcclusionWindow(
      id: WindowID(rawValue: 0xFFFF_0002), frame: CGRect(x: 50, y: 50, width: 50, height: 50),
      isFloating: true, level: 0, subLevel: 0)
    var inspected: [WindowID] = []
    let windows = [Self.target, floating].lazy.map { window in
      inspected.append(window.id)
      return window
    }
    #expect(!Self.target.wouldOccludeFloatingWindow(among: windows))
    #expect(inspected == [Self.target.id])
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
