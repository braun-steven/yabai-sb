import CoreGraphics
import Testing

@testable import YabaiCore

//
// NOTE: The arithmetic of a split drag (SplitRatio, shared with Con.resize) and the visible path that the event tap hit-tests
// (SplitLayoutWalk). The rows use a split of 1000 points, so a delta of 100 is a change of 0.1 in percent.
//

@Suite("SplitRatio")
struct SplitRatioTests {
  private static func near(_ actual: Float, _ expected: Float) -> Bool {
    abs(actual - expected) < 1e-5
  }

  /// first, second, delta, size, minPercent, expected first, expected second.
  static let moves: [(Float, Float, Float, Float, Float, Float, Float)] = [
    // a positive delta grows the first child and takes the same share from the second
    (0.5, 0.5, 100, 1000, 0.05, 0.6, 0.4),
    // a negative delta grows the second child
    (0.5, 0.5, -100, 1000, 0.05, 0.4, 0.6),
    // a zero delta keeps both percents
    (0.3, 0.7, 0, 1000, 0.05, 0.3, 0.7),
    // the first child stops at the minimum, the second takes the rest
    (0.5, 0.5, -1000, 1000, 0.05, 0.05, 0.95),
    // the second child stops at the minimum, the first takes the rest
    (0.5, 0.5, 1000, 1000, 0.05, 0.95, 0.05),
    // a move of the first child to exactly the minimum is not clamped
    (0.5, 0.5, -450, 1000, 0.05, 0.05, 0.95),
    // the minimum is a parameter
    (0.5, 0.5, -400, 1000, 0.2, 0.2, 0.8),
    // a move of a child that starts below the minimum is clamped
    (0.02, 0.98, 0, 1000, 0.05, 0.05, 0.95),
  ]

  @Test(arguments: moves)
  func resizedMovesTheBoundary(
    _ first: Float, _ second: Float, _ delta: Float, _ size: Float, _ minPercent: Float,
    _ expectedFirst: Float, _ expectedSecond: Float
  ) throws {
    let result = try #require(
      SplitRatio.resized(
        first: first, second: second, delta: delta, size: size, minPercent: minPercent))
    #expect(Self.near(result.first, expectedFirst))
    #expect(Self.near(result.second, expectedSecond))
  }

  @Test(
    "split_ratio_sum_is_preserved",
    arguments: [-5000, -1200, -1000, -450, -100, 0, 100, 450, 1000, 1200, 5000] as [Float])
  func sumIsPreserved(_ delta: Float) throws {
    let result = try #require(
      SplitRatio.resized(first: 0.4, second: 0.6, delta: delta, size: 1000, minPercent: 0.05))
    #expect(Self.near(result.first + result.second, 1.0))
    #expect(result.first >= 0.05 - 1e-5)
    #expect(result.second >= 0.05 - 1e-5)
  }

  @Test(
    "split_ratio_rejects_bad_input",
    arguments: [
      (Float(0), Float(10)), (Float(-4), Float(10)), (Float(100), Float.nan),
      (Float(100), Float.infinity), (Float(100), -Float.infinity),
    ])
  func rejectsZeroSizeAndNonFiniteDelta(_ size: Float, _ delta: Float) {
    #expect(
      SplitRatio.resized(first: 0.5, second: 0.5, delta: delta, size: size, minPercent: 0.05) == nil
    )
  }
}

@Suite("SplitLayoutWalk")
struct SplitLayoutWalkTests {
  /// A container of the test tree: its info, and the children that are laid out under it (a tabbed container lists only
  /// its visible child, as Con does with focusOrder[0]).
  struct Node {
    var name: String
    var layout: ConLayout
    var isZoomed = false
    var shown: [Node] = []
  }

  private static func area(_ x: Float) -> Area {
    Area(x: x, y: 0, w: 100, h: 100)
  }

  private static func walk(_ root: Node) -> SplitLayoutPath<String>? {
    SplitLayoutWalk.visiblePath(
      root,
      info: { node in
        SplitLayoutInfo(
          layout: node.layout, percent: 0.5, area: area(Float(node.name.count)),
          isZoomed: node.isZoomed)
      },
      children: { $0.shown }
    )
    .map { path in
      SplitLayoutPath(
        nodes: path.nodes, areas: path.areas, elements: path.elements.map { $0.name })
    }
  }

  @Test func leafHasNoChildren() throws {
    let path = try #require(Self.walk(Node(name: "w1", layout: .splitH)))
    #expect(path.nodes == [LayoutNode(layout: .splitH, percent: 0.5, childCount: 0)])
    #expect(path.elements == ["w1"])
  }

  @Test func walksInPreOrder() throws {
    let root = Node(
      name: "root", layout: .splitH,
      shown: [
        Node(
          name: "a", layout: .splitV,
          shown: [Node(name: "a1", layout: .splitH), Node(name: "a2", layout: .splitH)]),
        Node(name: "b", layout: .splitH),
      ])
    let path = try #require(Self.walk(root))
    #expect(path.elements == ["root", "a", "a1", "a2", "b"])
    #expect(
      path.nodes.map(\.childCount) == [2, 2, 0, 0, 0])
    #expect(path.nodes.map(\.layout) == [.splitH, .splitV, .splitH, .splitH, .splitH])
    #expect(path.areas.count == path.nodes.count)
  }

  @Test func tabbedContainerShowsOnlyItsVisibleChild() throws {
    // The hidden tab holds a nested split: it is left out, so its gaps are not hit-tested.
    let root = Node(
      name: "root", layout: .splitH,
      shown: [
        Node(name: "tabs", layout: .tabbed, shown: [Node(name: "visible", layout: .splitH)]),
        Node(name: "side", layout: .splitH),
      ])
    let path = try #require(Self.walk(root))
    #expect(path.elements == ["root", "tabs", "visible", "side"])
    #expect(path.nodes.map(\.childCount) == [2, 1, 0, 0])
  }

  @Test func zoomedContainerOnThePathGivesNil() {
    let root = Node(
      name: "root", layout: .splitH,
      shown: [Node(name: "zoomed", layout: .splitH, isZoomed: true)])
    #expect(Self.walk(root) == nil)
  }
}
