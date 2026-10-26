import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The pending focus of `space --focus` on the same display: it waits for the space change event of its space,
// survives a change to another space (the gesture fallback passes the spaces on the way) and expires. The clock is
// passed in, so nothing reads OSTimer or the window server.
//

extension DaemonState {
  @Suite struct PendingSpaceFocusTests {
    private let start: UInt64 = 5_000_000_000_000
    private let sid = SpaceID(rawValue: 0xFFFF_0101)
    private let other = SpaceID(rawValue: 0xFFFF_0102)

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
  }
}
