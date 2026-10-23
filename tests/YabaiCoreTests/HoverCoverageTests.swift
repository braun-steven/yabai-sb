import Testing

@testable import YabaiCore

@Suite("HoverCoverage")
struct HoverCoverageTests {
  private static let base = ContinuousClock.now

  private static func stamp(_ wid: UInt32, _ generation: UInt64, at ms: Int) -> HoverCoverageStamp {
    HoverCoverageStamp(
      aboveWid: WindowID(wid), generation: generation, taken: base.advanced(by: .milliseconds(ms)))
  }

  private static func instant(_ ms: Int) -> ContinuousClock.Instant {
    base.advanced(by: .milliseconds(ms))
  }

  // Columns: repeatsLastCheck, last check, cached list, query bar, query generation, now (ms), expected.
  @Test(
    arguments: [
      // same point, same entry, last check fresh: nothing to ask
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 50, HoverCoverageCheck.skip),
      // the lifetime is 100 ms: 99 ms is still fresh, 100 ms is not
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 99, .skip),
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 100, .checkFresh),
      // same point and entry, last check expired while the list is still fresh: reuse the list
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 60), 7, UInt64(1), 120, .checkWithCachedList),
      // same point, but nothing fresh: fetch the list again
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 150, .checkFresh),
      // a different point or entry always asks for the window at the point; a fresh list is reused
      (false, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 50, .checkWithCachedList),
      (false, nil, stamp(7, 1, at: 0), 7, UInt64(1), 50, .checkWithCachedList),
      // a different point with an expired list: fetch the list
      (false, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 100, .checkFresh),
      // the window order generation changed since the stamps: fetch the list
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(2), 50, .checkFresh),
      (false, nil, stamp(7, 1, at: 0), 7, UInt64(2), 50, .checkFresh),
      // another bar (aboveWid) than the stamps: nothing is reusable
      (true, stamp(7, 1, at: 0), stamp(7, 1, at: 0), 8, UInt64(1), 50, .checkFresh),
      (false, nil, stamp(7, 1, at: 0), 8, UInt64(1), 50, .checkFresh),
      // the last check was for another bar: skip is refused, the list of this bar is still reusable
      (true, stamp(8, 1, at: 0), stamp(7, 1, at: 0), 7, UInt64(1), 50, .checkWithCachedList),
      // no cache at all
      (true, nil, nil, 7, UInt64(1), 50, .checkFresh),
      (false, nil, nil, 7, UInt64(1), 50, .checkFresh),
    ] as [(Bool, HoverCoverageStamp?, HoverCoverageStamp?, UInt32, UInt64, Int, HoverCoverageCheck)]
  )
  func decision(
    repeats: Bool, last: HoverCoverageStamp?, list: HoverCoverageStamp?, aboveWid: UInt32,
    generation: UInt64, nowMs: Int, expected: HoverCoverageCheck
  ) {
    let result = HoverCoverageCache.decide(
      repeatsLastCheck: repeats, lastCheck: last, list: list, aboveWid: WindowID(aboveWid),
      generation: generation, now: Self.instant(nowMs))
    #expect(result == expected)
  }

  @Test("the lifetime is 100 ms")
  func lifetime() {
    #expect(hoverCoverageLifetime == .milliseconds(100))
  }
}
