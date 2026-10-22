import PropertyBased
import Testing
import YabaiTestSupport

@testable import YabaiCore

//
// NOTE: The layout math of a tree (TreeLayout) on flat pre-order arrays of LayoutNode, without a window server. The
// scenarios of tests/YabaiTests/LayoutTests.swift are repeated here on the pure function; the property checks the
// children of every container of random trees.
//

/// A tree of containers and windows, to build the flat arrays of the tests from.
private indirect enum Shape {
  case window(String?)
  case container(ConLayout, [Shape])
}

/// A pseudo-random generator, so that a seed from the property checks gives the same tree every time.
private struct TreeRandom {
  var state: UInt64

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state >> 11
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(next() % UInt64(range.count))
  }

  mutating func unit() -> Float {
    Float(next() % 1_000_000) / 1_000_000
  }
}

/// Appends the nodes of a random subtree: the shares of the children of each container sum to one.
private func randomNodes(
  _ random: inout TreeRandom, depth: Int, percent: Float, into nodes: inout [LayoutNode]
) {
  let layouts: [ConLayout] = [.splitH, .splitV, .tabbed]
  if depth >= 3 || random.int(0...2) == 0 {
    nodes.append(.leaf(percent: percent))
    return
  }

  let count = random.int(1...5)
  let shares = (0..<count).map { _ in random.unit() + 0.05 }
  let total = shares.reduce(0, +)
  nodes.append(LayoutNode(layout: layouts[random.int(0...2)], percent: percent, childCount: count))
  for share in shares {
    randomNodes(&random, depth: depth + 1, percent: share / total, into: &nodes)
  }
}

/// A rectangle of a layout run, with integral values like a display frame.
private struct TreeFrame: Sendable, CustomStringConvertible {
  var area: Area
  var gap: Int

  static var generator: Generator<TreeFrame, some SendableSequenceType> {
    zip(
      Gen.int(in: -2000...2000), Gen.int(in: -500...1000), Gen.int(in: 0...3000),
      Gen.int(in: 0...2000), Gen.int(in: 0...40)
    )
    .map { x, y, w, h, gap in
      TreeFrame(area: Area(x: Float(x), y: Float(y), w: Float(w), h: Float(h)), gap: gap)
    }
  }

  var description: String {
    "\(Int(area.x)),\(Int(area.y)) \(Int(area.w))x\(Int(area.h)) gap \(gap)"
  }
}

/// The bar settings of a layout run.
private struct TreeBar: Sendable, CustomStringConvertible {
  var height: Int
  var offset: Int
  var inset: Int

  static var generator: Generator<TreeBar, some SendableSequenceType> {
    zip(Gen.int(in: 0...40), Gen.int(in: -40...20), Gen.int(in: 0...12))
      .map { height, offset, inset in TreeBar(height: height, offset: offset, inset: inset) }
  }

  var description: String { "bar \(height) offset \(offset) inset \(inset)" }
}

/// The violations of the tiling of the children of the container at index, and of its descendants. Returns the index
/// after the subtree of the node.
///
/// A split is checked for what holds with rounding and gap shrinking: the children have the cross axis of the split,
/// they start at its start, each one starts a gap after the previous one ends (the gap is the window gap, or shorter
/// when the split is too short for it, never longer than an average child), no child has a negative length, the last
/// child ends at the end of the split, and a child but the last gets at most its rounded share. A tabbed container
/// gives its children one identical area inside it.
private func tilingViolations(
  _ nodes: [LayoutNode], _ areas: [Area], _ index: Int, gap: Int, into violations: inout [String]
) -> Int {
  let node = nodes[index]
  let area = areas[index]
  var next = index + 1
  if node.childCount == 0 { return next }

  var children: [Area] = []
  var percents: [Float] = []
  for _ in 0..<node.childCount {
    children.append(areas[next])
    percents.append(nodes[next].percent)
    next = tilingViolations(nodes, areas, next, gap: gap, into: &violations)
  }

  if node.layout == .tabbed {
    for (i, child) in children.enumerated() {
      if child != children[0] { violations.append("tab \(i) \(child) differs from \(children[0])") }
      if child.x < area.x || child.y < area.y || child.x + child.w > area.x + area.w
        || child.y + child.h > area.y + area.h
      {
        violations.append("tab \(i) \(child) leaves \(area)")
      }
    }
    return next
  }

  let horizontal = node.layout == .splitH
  func start(_ a: Area) -> Float { horizontal ? a.x : a.y }
  func size(_ a: Area) -> Float { horizontal ? a.w : a.h }
  func cross(_ a: Area) -> (Float, Float) { horizontal ? (a.y, a.h) : (a.x, a.w) }

  let count = children.count
  let length = size(area)
  let usedGap = count > 1 ? start(children[1]) - (start(children[0]) + size(children[0])) : 0
  if count > 1 {
    if usedGap < 0 || usedGap > Float(gap) {
      violations.append("gap \(usedGap) of \(area) is outside 0...\(gap)")
    }
    if usedGap < Float(gap) && length >= Float(gap * (2 * count - 1)) {
      violations.append("\(area) shrinks its gap to \(usedGap) although it is long enough")
    }
    if usedGap * Float(2 * count - 1) > length {
      violations.append("gap \(usedGap) of \(area) is longer than an average child")
    }
  }

  let total = length - usedGap * Float(count - 1)
  if start(children[0]) != start(area) {
    violations.append("first child \(children[0]) does not start \(area)")
  }
  for (i, child) in children.enumerated() {
    if cross(child) != cross(area) {
      violations.append("child \(i) \(child) leaves the cross axis of \(area)")
    }
    if size(child) < 0 {
      violations.append("child \(i) of \(area) has a negative length \(size(child))")
    }
    if i > 0 && start(child) != start(children[i - 1]) + size(children[i - 1]) + usedGap {
      violations.append(
        "child \(i) \(child) does not follow child \(i - 1) \(children[i - 1]) with gap \(usedGap)")
    }
    if i < count - 1 && size(child) > Float(Int(total * percents[i] + 0.5)) {
      violations.append(
        "child \(i) of \(area) is \(size(child)) long, more than its share of \(total * percents[i])"
      )
    }
  }
  if start(children[count - 1]) + size(children[count - 1]) != start(area) + length {
    violations.append("the last child \(children[count - 1]) does not end with \(area)")
  }

  return next
}

@Suite struct TreeLayoutTests {
  // MARK: - Properties

  @Test func childrenTileTheirParentMinusTheGaps() async {
    await propertyCheck(
      count: 1000, input: Gen.int(in: 1...1_000_000), TreeFrame.generator, TreeBar.generator
    ) { seed, frame, bar in
      var random = TreeRandom(state: UInt64(seed))
      var nodes: [LayoutNode] = []
      randomNodes(&random, depth: 0, percent: 1, into: &nodes)

      let params = LayoutParams(
        gap: frame.gap, barHeight: bar.height, barOffset: bar.offset, barInset: bar.inset)
      let areas = TreeLayout.layOut(nodes, in: frame.area, params: params)

      #expect(areas.count == nodes.count)
      #expect(areas[0] == frame.area)
      var violations: [String] = []
      _ = tilingViolations(nodes, areas, 0, gap: frame.gap, into: &violations)
      try #require(violations.isEmpty, "\(violations)\n\(nodes)\n\(areas)")
    }
  }

  @Test func tinyFramesTileToo() async {
    let tiny = zip(Gen.int(in: 0...200), Gen.int(in: 0...200), Gen.int(in: 0...60))
      .map { w, h, gap in TreeFrame(area: Area(x: 0, y: 0, w: Float(w), h: Float(h)), gap: gap) }
    await propertyCheck(count: 1000, input: Gen.int(in: 1...1_000_000), tiny, TreeBar.generator) {
      seed, frame, bar in
      var random = TreeRandom(state: UInt64(seed))
      var nodes: [LayoutNode] = []
      randomNodes(&random, depth: 0, percent: 1, into: &nodes)

      let params = LayoutParams(
        gap: frame.gap, barHeight: bar.height, barOffset: bar.offset, barInset: bar.inset)
      let areas = TreeLayout.layOut(nodes, in: frame.area, params: params)

      var violations: [String] = []
      _ = tilingViolations(nodes, areas, 0, gap: frame.gap, into: &violations)
      try #require(violations.isEmpty, "\(violations)\n\(nodes)\n\(areas)")
    }
  }

  // MARK: - Examples

  @Test func tabbedChildrenShareTheCardBelowTheBar() {
    let root = Area(x: 0, y: 0, w: 1000, h: 800)
    let tabs = [
      LayoutNode(layout: .tabbed, percent: 1, childCount: 2), .leaf(percent: 0.5),
      .leaf(percent: 0.5),
    ]

    var params = LayoutParams(gap: 10, barHeight: 24, barOffset: 0, barInset: 6)
    #expect(
      TreeLayout.layOut(tabs, in: root, params: params) == [
        root, Area(x: 6, y: 30, w: 988, h: 764), Area(x: 6, y: 30, w: 988, h: 764),
      ])

    // a negative offset reaches under the bar, but no higher than the card
    params.barOffset = -40
    #expect(
      TreeLayout.layOut(tabs, in: root, params: params)[1] == Area(x: 6, y: 6, w: 988, h: 788))

    // a large offset leaves the tabs the height of the bar
    params.barOffset = 200
    let short = Area(x: 0, y: 0, w: 1000, h: 100)
    #expect(
      TreeLayout.layOut(tabs, in: short, params: params)[1] == Area(x: 6, y: 70, w: 988, h: 24))

    // no room for the card: the bar sits on the edge of the container
    #expect(TreeLayout.cardInset(Area(x: 0, y: 0, w: 1000, h: 60), barHeight: 24, barInset: 6) == 0)
    #expect(TreeLayout.cardInset(Area(x: 0, y: 0, w: 24, h: 800), barHeight: 24, barInset: 6) == 0)
    #expect(
      TreeLayout.cardInset(Area(x: 0, y: 0, w: 1000, h: 800), barHeight: 24, barInset: 0) == 0)
    #expect(
      TreeLayout.cardInset(Area(x: 0, y: 0, w: 1000, h: 800), barHeight: 24, barInset: 6) == 6)

    // a container no higher than two bars gives its tabs all of its area
    params.barOffset = 0
    let low = Area(x: 0, y: 0, w: 1000, h: 48)
    #expect(TreeLayout.layOut(tabs, in: low, params: params)[1] == low)
  }

  @Test func lastChildTakesTheRemainder() {
    let thirds = Float(1) / 3
    let split = [
      LayoutNode(layout: .splitH, percent: 1, childCount: 3), .leaf(percent: thirds),
      .leaf(percent: thirds), .leaf(percent: thirds),
    ]

    let flat = TreeLayout.layOut(
      split, in: Area(x: 0, y: 0, w: 1001, h: 500),
      params: LayoutParams(gap: 0, barHeight: 0, barOffset: 0, barInset: 0))
    #expect(flat.dropFirst().map(\.w) == [334, 334, 333])

    let gapped = TreeLayout.layOut(
      split, in: Area(x: 10, y: 0, w: 1000, h: 500),
      params: LayoutParams(gap: 7, barHeight: 0, barOffset: 0, barInset: 0))
    #expect(gapped.dropFirst().map(\.x) == [10, 346, 682])
    #expect(gapped.dropFirst().map(\.w) == [329, 329, 328])
  }

  @Test func negativeLengthInASplitShorterThanItsGaps() {
    let thirds = Float(1) / 3
    let split = [
      LayoutNode(layout: .splitV, percent: 1, childCount: 3), .leaf(percent: thirds),
      .leaf(percent: thirds), .leaf(percent: thirds),
    ]

    // the gaps shrink to 22 / 5 = 4 pixels, which leaves each window its share of 14
    let areas = TreeLayout.layOut(
      split, in: Area(x: 0, y: 0, w: 300, h: 22),
      params: LayoutParams(gap: 12, barHeight: 0, barOffset: 0, barInset: 0))
    #expect(areas.dropFirst().map(\.y) == [0, 9, 18])
    #expect(areas.dropFirst().map(\.h) == [5, 5, 4])
  }

  @Test func roundingLeavesTheLastChildNoNegativeLength() {
    // four quarters of 2 pixels round up to 1, 1 and 0 left for the last two
    let quarters =
      [LayoutNode(layout: .splitH, percent: 1, childCount: 4)]
      + Array(repeating: LayoutNode.leaf(percent: 0.25), count: 4)
    let areas = TreeLayout.layOut(
      quarters, in: Area(x: 0, y: 0, w: 2, h: 100),
      params: LayoutParams(gap: 0, barHeight: 0, barOffset: 0, barInset: 0))
    #expect(areas.dropFirst().map(\.w) == [1, 1, 0, 0])
    #expect(areas.dropFirst().map(\.x) == [0, 1, 2, 2])
  }

  @Test(arguments: [
    // length, gap, children: the gap stays as long as an average child is at least as long
    (100, 10, 3, 10),
    (50, 10, 3, 10),
    (49, 10, 3, 9),
    (4, 10, 3, 0),
    (0, 10, 3, 0),
    (10, 10, 1, 10),
    (100, -5, 3, -5),
  ])
  func splitGapIsAtMostAnAverageChild(length: Int, gap: Int, count: Int, expected: Int) {
    #expect(TreeLayout.splitGap(gap, length: Float(length), count: count) == expected)
  }

  @Test func aNodeWithoutChildrenKeepsItsAreaAlone() {
    let area = Area(x: 3, y: 4, w: 5, h: 6)
    #expect(
      TreeLayout.layOut(
        [.leaf(percent: 1)], in: area,
        params: LayoutParams(gap: 10, barHeight: 24, barOffset: 0, barInset: 6)) == [area])
    #expect(
      TreeLayout.layOut(
        [], in: area, params: LayoutParams(gap: 10, barHeight: 24, barOffset: 0, barInset: 6)
      ).isEmpty)
  }

  // MARK: - Titles

  private func title(_ shape: Shape) -> String {
    TreeTitle.title(
      of: shape,
      container: { node in
        if case .container(let layout, let children) = node {
          return (layout: layout, children: children)
        }
        return nil
      },
      leafName: { node in
        if case .window(let name) = node { return name }
        return nil
      })
  }

  @Test func titlesNameTheWindowsInTheirBrackets() {
    #expect(title(.window("Safari")) == "Safari")
    #expect(title(.window(nil)) == "")
    #expect(
      title(.container(.splitH, [.window("iTerm2"), .window("Safari")])) == "H[iTerm2 Safari]")
    #expect(title(.container(.tabbed, [])) == "T[]")

    // a window without a name keeps its separator, as the old title did
    let nested = Shape.container(
      .splitH,
      [
        .window("iTerm2"), .container(.splitV, [.window("Safari"), .window(nil)]),
        .container(.tabbed, []),
      ])
    #expect(title(nested) == "H[iTerm2 V[Safari ] T[]]")
  }
}
