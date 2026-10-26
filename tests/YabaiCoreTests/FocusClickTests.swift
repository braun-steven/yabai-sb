import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("FocusClick")
struct FocusClickTests {
  private static let bounds = CGRect(x: 1920, y: 0, width: 1800, height: 1200)
  private static let center = CGPoint(x: 2820, y: 600)
  private static let cursor = CGPoint(x: 100, y: 200)

  @Test func candidatesStartAtTheCenterAndCoverTheGrid() {
    let points = FocusClick.candidates(in: Self.bounds)
    #expect(points.count == 9)
    #expect(points.first == Self.center)
    #expect(Set(points.map { "\($0.x),\($0.y)" }).count == 9)
    #expect(points.dropFirst().first == CGPoint(x: 2220, y: 200))
    #expect(points.last == CGPoint(x: 3420, y: 1000))
    #expect(points.allSatisfy { Self.bounds.contains($0) })
  }

  // Columns: needs a click, mouse_follows_focus, the points covered by a window, expected plan.
  @Test(
    arguments: [
      // the desktop at the centre: click there; the cursor goes back, or stays at the centre with mouse_follows_focus
      (
        true, false, [CGPoint](),
        FocusClickPlan(warp: center, click: center, restore: cursor)
      ),
      (
        true, true, [CGPoint](),
        FocusClickPlan(warp: center, click: center, restore: nil)
      ),
      // a window over the centre: the first uncovered grid point takes the click
      (
        true, false, [center],
        FocusClickPlan(
          warp: CGPoint(x: 2220, y: 200), click: CGPoint(x: 2220, y: 200), restore: cursor)
      ),
      (
        true, true, [center],
        FocusClickPlan(
          warp: CGPoint(x: 2220, y: 200), click: CGPoint(x: 2220, y: 200), restore: center)
      ),
      // every point covered: no click, and the cursor only moves with mouse_follows_focus
      (
        true, false, FocusClick.candidates(in: bounds),
        FocusClickPlan(warp: nil, click: nil, restore: nil)
      ),
      (
        true, true, FocusClick.candidates(in: bounds),
        FocusClickPlan(warp: center, click: nil, restore: nil)
      ),
      // the space is already the active one: no click
      (
        false, false, [CGPoint](),
        FocusClickPlan(warp: nil, click: nil, restore: nil)
      ),
      (
        false, true, [CGPoint](),
        FocusClickPlan(warp: center, click: nil, restore: nil)
      ),
    ])
  func plan(
    needsClick: Bool, mouseFollowsFocus: Bool, covered: [CGPoint], expected: FocusClickPlan
  ) {
    let plan = FocusClick.plan(
      bounds: Self.bounds, cursor: Self.cursor, needsClick: needsClick,
      mouseFollowsFocus: mouseFollowsFocus, isDesktop: { !covered.contains($0) })
    #expect(plan == expected)
  }

  @Test func noClickAsksNothingOfTheWindowServer() {
    var asked = false
    _ = FocusClick.plan(
      bounds: Self.bounds, cursor: Self.cursor, needsClick: false, mouseFollowsFocus: false,
      isDesktop: { _ in
        asked = true
        return true
      })
    #expect(!asked)
  }

  @Test func noWarpWhenTheCursorIsAlreadyThere() {
    let atCenter = FocusClick.plan(
      bounds: Self.bounds, cursor: Self.center, needsClick: false, mouseFollowsFocus: true,
      isDesktop: { _ in true })
    #expect(atCenter == FocusClickPlan(warp: nil, click: nil, restore: nil))

    let atClick = FocusClick.plan(
      bounds: Self.bounds, cursor: Self.center, needsClick: true, mouseFollowsFocus: false,
      isDesktop: { _ in true })
    #expect(atClick == FocusClickPlan(warp: Self.center, click: Self.center, restore: nil))
  }

  // Columns: needs a click, the desktop is under the cursor, expected plan.
  @Test(
    "focus follows mouse clicks at the cursor on the desktop and never moves it",
    arguments: [
      (true, true, FocusClickPlan(warp: nil, click: cursor, restore: nil)),
      (true, false, FocusClickPlan(warp: nil, click: nil, restore: nil)),
      (false, true, FocusClickPlan(warp: nil, click: nil, restore: nil)),
    ])
  func planAtCursor(needsClick: Bool, desktop: Bool, expected: FocusClickPlan) {
    var asked: [CGPoint] = []
    let plan = FocusClick.planAtCursor(
      cursor: Self.cursor, needsClick: needsClick,
      isDesktop: { point in
        asked.append(point)
        return desktop
      })
    #expect(plan == expected)
    #expect(asked == (needsClick ? [Self.cursor] : []))
  }
}
