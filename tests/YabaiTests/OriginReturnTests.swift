import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: A created window that yabai moved from the space macOS showed it on to its origin space is focused again when
// macOS reports the switch to the space it came from. The first space change after the move consumes the request,
// whether it is that switch or not, and it expires. The clock is passed in, so nothing reads OSTimer or the window
// server.
//

extension DaemonState {
  @Suite struct OriginReturnTests {
    private let start: UInt64 = 5_000_000_000_000
    private let wid = WindowID(rawValue: 0xFFFF_0001)
    private let source = SpaceID(rawValue: 0xFFFF_0101)

    @Test @WM func nothingPendingResolvesNothing() {
      let wm = WindowManager.shared
      #expect(wm.originReturn == nil)
      #expect(wm.consumeOriginReturn(active: source, now: start) == nil)
    }

    @Test @WM func switchToTheSourceResolvesOnce() {
      let wm = WindowManager.shared
      wm.originReturn = OriginReturn(windowID: wid, source: source, time: start)

      #expect(wm.consumeOriginReturn(active: source, now: start + 999_000_000) == wid)
      #expect(wm.originReturn == nil)
      #expect(wm.consumeOriginReturn(active: source, now: start + 999_000_000) == nil)
    }

    @Test(arguments: [SpaceID(rawValue: 0xFFFF_0102), nil] as [SpaceID?])
    @WM func changeToAnotherSpaceDropsIt(active: SpaceID?) {
      let wm = WindowManager.shared
      wm.originReturn = OriginReturn(windowID: wid, source: source, time: start)

      #expect(wm.consumeOriginReturn(active: active, now: start + 100_000_000) == nil)
      #expect(wm.originReturn == nil)
      #expect(wm.consumeOriginReturn(active: source, now: start + 200_000_000) == nil)
    }

    @Test(arguments: [1_000_000_000, 5_000_000_000] as [UInt64])
    @WM func expiredIsDropped(after elapsed: UInt64) {
      let wm = WindowManager.shared
      wm.originReturn = OriginReturn(windowID: wid, source: source, time: start)

      #expect(wm.consumeOriginReturn(active: source, now: start + elapsed) == nil)
      #expect(wm.originReturn == nil)
    }
  }
}
