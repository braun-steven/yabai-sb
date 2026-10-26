import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The pending focus of `space --focus` on the same display: it waits for the space change event of its space,
// survives a change to another space (the gesture fallback passes the spaces on the way) and expires. The clock is
// passed in, so nothing reads OSTimer or the window server. The pending focus of `space --display` waits until the
// window server has the space on its new display, then focuses it there or, while it is hidden, switches to it.
//

extension DaemonState {
  @Suite struct PendingSpaceFocusTests {
    private let start: UInt64 = 5_000_000_000_000
    private let sid = SpaceID(rawValue: 0xFFFF_0101)
    private let other = SpaceID(rawValue: 0xFFFF_0102)
    private let did = DisplayID(rawValue: 0xFFFF_0201)
    private let source = DisplayID(rawValue: 0xFFFF_0202)

    @Test @WM func nothingPendingResolvesNothing() {
      let sm = SpaceManager.shared
      #expect(sm.pendingSpaceFocus == nil)
      #expect(sm.consumePendingSpaceFocus(active: sid, now: start) == nil)
    }

    @Test @WM func changeToItsSpaceResolvesOnce() {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, at: start)

      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + 1_999_000_000) == sid)
      #expect(sm.pendingSpaceFocus == nil)
      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + 1_999_000_000) == nil)
    }

    @Test @WM func changeToAnotherSpaceKeepsIt() {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, at: start)

      #expect(sm.consumePendingSpaceFocus(active: other, now: start + 100_000_000) == nil)
      #expect(sm.consumePendingSpaceFocus(active: nil, now: start + 200_000_000) == nil)
      #expect(sm.pendingSpaceFocus?.sid == sid)
      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + 300_000_000) == sid)
    }

    @Test(arguments: [2_000_000_000, 5_000_000_000] as [UInt64])
    @WM func expiredIsDropped(after elapsed: UInt64) {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, at: start)

      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + elapsed) == nil)
      #expect(sm.pendingSpaceFocus == nil)
    }

    @Test @WM func newerRequestReplacesOlder() {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, at: start)
      sm.setPendingSpaceFocus(other, at: start + 100_000_000)

      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + 200_000_000) == nil)
      #expect(sm.consumePendingSpaceFocus(active: other, now: start + 200_000_000) == other)
    }

    @Test @WM func moveWaitsForItsDisplay() {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, on: did, at: start)

      #expect(sm.consumePendingSpaceMove(display: source, current: other, now: start) == .wait)
      #expect(
        sm.consumePendingSpaceMove(display: nil, current: nil, now: start + 100_000_000) == .wait)
      #expect(sm.pendingSpaceFocus?.display == did)
    }

    @Test(arguments: [true, false])
    @WM func moveReportedFocusesOrShows(shown: Bool) {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, on: did, at: start)

      let step = sm.consumePendingSpaceMove(
        display: did, current: shown ? sid : other, now: start + 1_999_000_000)
      #expect(step == (shown ? .focus(sid, on: did) : .show(sid, on: did)))
      #expect(sm.pendingSpaceFocus == nil)
      #expect(
        sm.consumePendingSpaceMove(display: did, current: sid, now: start + 1_999_000_000) == .none)
    }

    @Test(arguments: [2_000_000_000, 5_000_000_000] as [UInt64])
    @WM func expiredMoveIsDropped(after elapsed: UInt64) {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, on: did, at: start)

      #expect(sm.consumePendingSpaceMove(display: did, current: sid, now: start + elapsed) == .none)
      #expect(sm.pendingSpaceFocus == nil)
    }

    @Test @WM func switchAndMoveIgnoreEachOther() {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, on: did, at: start)
      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + 100_000_000) == nil)
      #expect(sm.pendingSpaceFocus?.display == did)

      sm.setPendingSpaceFocus(sid, at: start)
      #expect(
        sm.consumePendingSpaceMove(display: did, current: sid, now: start + 100_000_000) == .none)
      #expect(sm.consumePendingSpaceFocus(active: sid, now: start + 100_000_000) == sid)
    }

    @Test @WM func switchReplacesMove() {
      let sm = SpaceManager.shared
      sm.setPendingSpaceFocus(sid, on: did, at: start)
      sm.setPendingSpaceFocus(other, at: start + 100_000_000)

      #expect(
        sm.consumePendingSpaceMove(display: did, current: sid, now: start + 200_000_000) == .none)
      #expect(sm.consumePendingSpaceFocus(active: other, now: start + 200_000_000) == other)
    }
  }
}
