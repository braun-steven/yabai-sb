import CoreGraphics
import Testing

@testable import YabaiCore

//
// NOTE: The split gaps under a point (SplitHitTest) on the areas that TreeLayout lays out for the same tree. The root is
// 1000 by 500 points. With a window gap of 10, two equal children of a split are 495 points long and the gap lies from
// 495 to 505. Gaps of 0 leave children of 500 points and a boundary at 500.
//

@Suite("SplitHandle")
struct SplitHandleTests {
  private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
  }

  private static func handle(_ container: Int, _ boundary: Int, _ orientation: ConLayout)
    -> SplitHandle
  {
    SplitHandle(container: container, boundary: boundary, orientation: orientation)
  }

  /// Two side-by-side windows in one split.
  private static let halves: [LayoutNode] = [
    LayoutNode(layout: .splitH, percent: 1, childCount: 2),
    .leaf(percent: 0.5),
    .leaf(percent: 0.5),
  ]

  /// Two stacked windows in one split.
  private static let stacked: [LayoutNode] = [
    LayoutNode(layout: .splitV, percent: 1, childCount: 2),
    .leaf(percent: 0.5),
    .leaf(percent: 0.5),
  ]

  /// A side-by-side split whose right child is a stacked split: 0 is the outer split, 2 the inner one.
  private static let nested: [LayoutNode] = [
    LayoutNode(layout: .splitH, percent: 1, childCount: 2),
    .leaf(percent: 0.5),
    LayoutNode(layout: .splitV, percent: 0.5, childCount: 2),
    .leaf(percent: 0.5),
    .leaf(percent: 0.5),
  ]

  /// A tabbed container of two windows.
  private static let tabWindows: [LayoutNode] = [
    LayoutNode(layout: .tabbed, percent: 1, childCount: 2),
    .leaf(percent: 0.5),
    .leaf(percent: 0.5),
  ]

  /// A tabbed container of a side-by-side split and a window: 1 is the split inside the tab.
  private static let tabbed: [LayoutNode] = [
    LayoutNode(layout: .tabbed, percent: 1, childCount: 2),
    LayoutNode(layout: .splitH, percent: 0.5, childCount: 2),
    .leaf(percent: 0.5),
    .leaf(percent: 0.5),
    .leaf(percent: 0.5),
  ]

  /// Lays out the tree in the root and returns the handle under the point.
  private static func hit(_ nodes: [LayoutNode], gap: Int, at point: CGPoint) -> SplitHandle? {
    let root = Area(x: 0, y: 0, w: 1000, h: 500)
    let params = LayoutParams(gap: gap, barHeight: 0, barOffset: 0, barInset: 0)
    let areas = TreeLayout.layOut(nodes, in: root, params: params)
    return SplitHitTest.handle(nodes: nodes, areas: areas, gap: gap, at: point)
  }

  @Test(
    arguments: [
      // the gap at 495 to 505, widened by 2 on each side (493 to 507)
      (halves, 10, point(493, 100), handle(0, 0, .splitH)),
      (halves, 10, point(500, 250), handle(0, 0, .splitH)),
      (halves, 10, point(507, 100), handle(0, 0, .splitH)),
      // just outside the widened gap
      (halves, 10, point(492, 100), nil),
      (halves, 10, point(508, 100), nil),
      // the strip covers the full height of the split: its top edge hits, its bottom edge (500) does not
      (halves, 10, point(500, 0), handle(0, 0, .splitH)),
      (halves, 10, point(500, 500), nil),
      // inside a window
      (halves, 10, point(100, 250), nil),
      (halves, 10, point(800, 250), nil),
    ] as [([LayoutNode], Int, CGPoint, SplitHandle?)])
  func sideBySideGap(_ nodes: [LayoutNode], _ gap: Int, _ point: CGPoint, _ expected: SplitHandle?)
  {
    #expect(Self.hit(nodes, gap: gap, at: point) == expected)
  }

  @Test(
    arguments: [
      // the gap at 245 to 255 of the 500 points height, widened to 243 to 257
      (stacked, 10, point(5, 250), handle(0, 0, .splitV)),
      (stacked, 10, point(999, 250), handle(0, 0, .splitV)),
      (stacked, 10, point(100, 243), handle(0, 0, .splitV)),
      (stacked, 10, point(100, 257), handle(0, 0, .splitV)),
      (stacked, 10, point(100, 242), nil),
      (stacked, 10, point(100, 258), nil),
      // inside a window
      (stacked, 10, point(100, 100), nil),
      (stacked, 10, point(100, 400), nil),
    ] as [([LayoutNode], Int, CGPoint, SplitHandle?)])
  func stackedGap(_ nodes: [LayoutNode], _ gap: Int, _ point: CGPoint, _ expected: SplitHandle?) {
    #expect(Self.hit(nodes, gap: gap, at: point) == expected)
  }

  @Test(
    arguments: [
      // a gap of 0 leaves a boundary at 500: only the 2 points on each side hit it
      (halves, 0, point(497, 100), nil),
      (halves, 0, point(498, 100), handle(0, 0, .splitH)),
      (halves, 0, point(500, 100), handle(0, 0, .splitH)),
      (halves, 0, point(502, 100), handle(0, 0, .splitH)),
      (halves, 0, point(503, 100), nil),
      // windows on both sides of the boundary
      (halves, 0, point(250, 100), nil),
      (halves, 0, point(750, 100), nil),
      // stacked splits with a gap of 0: the boundary at 250 of 500 points
      (stacked, 0, point(100, 248), handle(0, 0, .splitV)),
      (stacked, 0, point(100, 252), handle(0, 0, .splitV)),
      (stacked, 0, point(100, 247), nil),
      (stacked, 0, point(100, 253), nil),
    ] as [([LayoutNode], Int, CGPoint, SplitHandle?)])
  func zeroGapOnlyHitsNearTheBoundary(
    _ nodes: [LayoutNode], _ gap: Int, _ point: CGPoint, _ expected: SplitHandle?
  ) {
    #expect(Self.hit(nodes, gap: gap, at: point) == expected)
  }

  @Test(
    arguments: [
      // inside the right child, on the gap of the inner split only
      (nested, 10, point(700, 250), handle(2, 0, .splitV)),
      // inside the windows of the inner split
      (nested, 10, point(700, 100), nil),
      (nested, 10, point(600, 400), nil),
      // the outer gap alone, above the inner split's gap
      (nested, 10, point(500, 100), handle(0, 0, .splitH)),
      (nested, 10, point(506, 100), handle(0, 0, .splitH)),
      // both gaps match at (506, 250): the innermost split wins
      (nested, 10, point(506, 250), handle(2, 0, .splitV)),
      (nested, 10, point(500, 250), handle(0, 0, .splitH)),
    ] as [([LayoutNode], Int, CGPoint, SplitHandle?)])
  func nestedSplitsPreferTheInnermost(
    _ nodes: [LayoutNode], _ gap: Int, _ point: CGPoint, _ expected: SplitHandle?
  ) {
    #expect(Self.hit(nodes, gap: gap, at: point) == expected)
  }

  @Test(
    arguments: [
      // a tabbed container has no gap: its two children share the whole area
      (tabWindows, 10, point(500, 250), nil),
      (tabWindows, 0, point(500, 250), nil),
      // a split inside a tab still has its own gap
      (tabbed, 10, point(500, 250), handle(1, 0, .splitH)),
      (tabbed, 10, point(100, 100), nil),
    ] as [([LayoutNode], Int, CGPoint, SplitHandle?)])
  func tabbedContainersHaveNoGap(
    _ nodes: [LayoutNode], _ gap: Int, _ point: CGPoint, _ expected: SplitHandle?
  ) {
    #expect(Self.hit(nodes, gap: gap, at: point) == expected)
  }

  @Test(
    arguments: [
      (halves, 10, point(-5, 250), nil),
      (halves, 10, point(1005, 250), nil),
      (halves, 10, point(500, -5), nil),
      (halves, 10, point(500, 505), nil),
      (stacked, 0, point(1005, 250), nil),
    ] as [([LayoutNode], Int, CGPoint, SplitHandle?)])
  func pointsOutsideTheRootGiveNil(
    _ nodes: [LayoutNode], _ gap: Int, _ point: CGPoint, _ expected: SplitHandle?
  ) {
    #expect(Self.hit(nodes, gap: gap, at: point) == expected)
  }

  @Test func emptyOrMismatchedTreesGiveNil() {
    #expect(SplitHitTest.handle(nodes: [], areas: [], gap: 10, at: Self.point(500, 250)) == nil)
    #expect(
      SplitHitTest.handle(nodes: Self.halves, areas: [], gap: 10, at: Self.point(500, 250)) == nil)
  }
}
