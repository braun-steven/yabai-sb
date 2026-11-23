import CoreGraphics
import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: The geometry of the strip of a scroll space (ScrollStrip) without a window server: the widths of the columns,
// the offset that shows the focused column, and where a window scrolled out of view is parked.
//

/// The spans of columns of the given widths and gap, starting at 0.
private func spans(_ widths: [Float], gap: Float = 0) -> [ColumnSpan] {
  var start: Float = 0
  return widths.map { width in
    defer { start += width + gap }
    return ColumnSpan(start: start, width: width)
  }
}

@Suite struct ScrollStripTests {
  // MARK: - Columns

  @Test func aLoneColumnFillsTheView() {
    #expect(ScrollStrip.spans(shares: [0.5], length: 1000, gap: 10) == [ColumnSpan(start: 0, width: 1000)])
  }

  @Test func sharesThatSumToOneFillTheViewExactly() {
    let result = ScrollStrip.spans(shares: [0.5, 0.5], length: 1000, gap: 10)
    #expect(result == [ColumnSpan(start: 0, width: 495), ColumnSpan(start: 505, width: 495)])
    #expect(ScrollStrip.length(of: result) == 1000)
  }

  @Test func columnsRunPastTheView() {
    let result = ScrollStrip.spans(shares: [0.5, 0.5, 0.5], length: 1000, gap: 0)
    #expect(result.map(\.start) == [0, 500, 1000])
    #expect(ScrollStrip.length(of: result) == 1500)
  }

  @Test(arguments: [(Float(0), Float(0.1)), (0.05, 0.1), (0.4, 0.4), (1.5, 1)])
  func sharesStayBetweenTheNarrowestAndTheWholeView(share: Float, expected: Float) {
    #expect(ScrollStrip.clampedShare(share) == expected)
  }

  @Test func columnsTileTheStripWithOneGapBetweenNeighbours() async {
    let shares = Gen.int(in: 0...100).map { Float($0) / 100 }.array(of: 2...8)
    await propertyCheck(input: shares, Gen.int(in: 100...4000), Gen.int(in: 0...40)) {
      shares, length, gap in
      let result = ScrollStrip.spans(shares: shares, length: Float(length), gap: gap)
      #expect(result.count == shares.count)
      #expect(result.first?.start == 0)
      for (a, b) in zip(result, result.dropFirst()) { #expect(b.start == a.end + Float(gap)) }
      #expect(result.allSatisfy { $0.width >= 1 })
    }
  }

  // MARK: - Offset

  @Test(arguments: ScrollCenter.allCases)
  func aStripThatFitsIsCentered(center: ScrollCenter) {
    let strip = spans([300, 300], gap: 0)
    #expect(
      ScrollStrip.offset(revealing: 1, current: 0, spans: strip, length: 1000, center: center)
        == -200)
  }

  @Test func neverScrollsAsLittleAsShowsTheColumn() {
    let strip = spans([500, 500, 500, 500])
    // Already in view: unchanged.
    #expect(
      ScrollStrip.offset(revealing: 1, current: 0, spans: strip, length: 1000, center: .never) == 0)
    // To the right: its end at the right edge.
    #expect(
      ScrollStrip.offset(revealing: 2, current: 0, spans: strip, length: 1000, center: .never)
        == 500)
    // To the left: its start at the left edge.
    #expect(
      ScrollStrip.offset(revealing: 0, current: 1000, spans: strip, length: 1000, center: .never)
        == 0)
  }

  @Test func neverStopsAtTheEndsOfTheStrip() {
    let strip = spans([500, 500, 500])
    #expect(
      ScrollStrip.offset(revealing: nil, current: 2000, spans: strip, length: 1000, center: .never)
        == 500)
    #expect(
      ScrollStrip.offset(revealing: nil, current: -300, spans: strip, length: 1000, center: .never)
        == 0)
  }

  @Test func aColumnWiderThanTheViewIsCentered() {
    let strip = spans([500, 1400, 500])
    #expect(
      ScrollStrip.offset(revealing: 1, current: 0, spans: strip, length: 1000, center: .never)
        == 700)
  }

  @Test func alwaysCentersTheColumnEvenAtTheEnds() {
    let strip = spans([400, 400, 400])
    #expect(
      ScrollStrip.offset(revealing: 1, current: 0, spans: strip, length: 1000, center: .always)
        == 100)
    #expect(
      ScrollStrip.offset(revealing: 0, current: 0, spans: strip, length: 1000, center: .always)
        == -300)
  }

  @Test func overflowCentersOnlyWhenTheColumnDoesNotFitWithThePreviousOne() {
    let strip = spans([400, 400, 400, 400])
    // 0 and 1 fit together: minimal scroll.
    #expect(
      ScrollStrip.offset(
        revealing: 1, previous: 0, current: 0, spans: strip, length: 1000, center: .overflow) == 0)
    // 0 and 2 do not: centered on 2.
    #expect(
      ScrollStrip.offset(
        revealing: 2, previous: 0, current: 0, spans: strip, length: 1000, center: .overflow)
        == 500)
    // Without a previous column it scrolls as little as never does.
    #expect(
      ScrollStrip.offset(revealing: 2, current: 0, spans: strip, length: 1000, center: .overflow)
        == 200)
  }

  @Test func theRevealedColumnIsWhollyInViewUnlessWiderThanTheView() async {
    let widths = Gen.int(in: 50...1500).map { Float($0) }.array(of: 1...8)
    await propertyCheck(input: widths, Gen.int(in: 0...7), Gen.int(in: -2000...6000)) {
      widths, index, current in
      let strip = spans(widths, gap: 10)
      let index = index % strip.count
      for center in [ScrollCenter.never, .overflow] {
        let offset = ScrollStrip.offset(
          revealing: index, current: Float(current), spans: strip, length: 1000, center: center)
        let column = strip[index]
        if column.width <= 1000 {
          #expect(column.start - offset >= 0)
          #expect(column.end - offset <= 1000)
        }
      }
    }
  }

  // MARK: - Peek

  @Test func theStripKeepsRoomForThePeekLessThePadding() {
    let view = Area(x: 10, y: 0, w: 980, h: 800)
    #expect(
      ScrollStrip.insets(peek: 24, gap: 10, view: view, display: Self.display)
        == ScrollInsets(left: 24, right: 24))
    #expect(
      ScrollStrip.insets(peek: 24, gap: 10, view: Area(x: 50, y: 0, w: 900, h: 800), display: Self.display)
        == ScrollInsets(left: 0, right: 0))
  }

  @Test func columnsShareTheViewLessTheRoomAtOneEdge() {
    let insets = ScrollInsets(left: 24, right: 24)
    let result = ScrollStrip.spans(shares: [0.5, 0.5, 0.5], length: 1000, gap: 10, insets: insets)
    #expect(result.map(\.width) == [483, 483, 483])
    // Two of them leave the room for one strip.
    #expect(result[1].end == 976)
  }

  @Test func noColumnCoversTheViewFromEdgeToEdge() {
    let insets = ScrollInsets(left: 24, right: 24)
    let result = ScrollStrip.spans(shares: [1, 1, 1], length: 1000, gap: 10, insets: insets)
    // The ends of the strip have columns beyond them on one side, the column in between on both.
    #expect(result.map(\.width) == [976, 952, 976])
    // A lone column still fills the whole view.
    #expect(
      ScrollStrip.spans(shares: [0.5], length: 1000, gap: 10, insets: insets)
        == [ColumnSpan(start: 0, width: 1000)])
  }

  @Test func theRevealedColumnStaysClearOfTheInsetsWithColumnsBeyond() {
    let insets = ScrollInsets(left: 24, right: 24)
    let strip = spans([500, 500, 500, 500], gap: 10)
    // Going right: its end the inset short of the right edge.
    #expect(
      ScrollStrip.offset(
        revealing: 2, current: 0, spans: strip, length: 1000, insets: insets, center: .never)
        == 544)
    // Going left: its start the inset past the left edge.
    #expect(
      ScrollStrip.offset(
        revealing: 1, current: 1000, spans: strip, length: 1000, insets: insets, center: .never)
        == 486)
    // The first and last columns have nothing beyond them on the outer side.
    #expect(
      ScrollStrip.offset(
        revealing: 0, current: 500, spans: strip, length: 1000, insets: insets, center: .never)
        == 0)
    #expect(
      ScrollStrip.offset(
        revealing: 3, current: 0, spans: strip, length: 1000, insets: insets, center: .never)
        == 1030)
  }

  @Test func theRevealedColumnIsClearOfTheInsetsUnlessWiderThanTheRoom() async {
    let widths = Gen.int(in: 50...1500).map { Float($0) }.array(of: 2...8)
    await propertyCheck(
      input: widths, Gen.int(in: 0...7), Gen.int(in: -2000...6000), Gen.int(in: 0...60)
    ) { widths, index, current, inset in
      let strip = spans(widths, gap: 10)
      let index = index % strip.count
      let insets = ScrollInsets(left: Float(inset), right: Float(inset))
      let left = index > 0 ? insets.left : 0
      let right = index < strip.count - 1 ? insets.right : 0
      let offset = ScrollStrip.offset(
        revealing: index, current: Float(current), spans: strip, length: 1000, insets: insets,
        center: .never)
      let column = strip[index]
      if ScrollStrip.length(of: strip) > 1000, column.width <= 1000 - left - right {
        #expect(column.start - offset >= left)
        #expect(column.end - offset <= 1000 - right)
      }
    }
  }

  // MARK: - Parking

  private static let display = Area(x: 0, y: 0, w: 1000, h: 800)

  /// The edges for a peek of 24 with nothing in view near them.
  private static let edges = ScrollEdges(left: 24, right: 976)

  @Test func aWindowOnScreenStaysWhereTheStripPutsIt() {
    let frame = Area(x: 800, y: 10, w: 500, h: 700)
    #expect(ScrollStrip.park(frame, display: Self.display, walls: [], edges: Self.edges) == frame)
  }

  @Test func aWindowScrolledOutHangsOffTheEdgeWithThePeekShowing() {
    let right = ScrollStrip.park(
      Area(x: 1500, y: 10, w: 500, h: 700), display: Self.display, walls: [], edges: Self.edges)
    #expect(right == Area(x: 976, y: 10, w: 500, h: 700))
    let left = ScrollStrip.park(
      Area(x: -900, y: 10, w: 500, h: 700), display: Self.display, walls: [], edges: Self.edges)
    #expect(left == Area(x: -476, y: 10, w: 500, h: 700))
  }

  @Test func atAWallAWindowStaysWhollyOnTheDisplay() {
    let right = ScrollStrip.park(
      Area(x: 800, y: 10, w: 500, h: 700), display: Self.display, walls: [.right],
      edges: Self.edges)
    #expect(right.x == 500)
    let left = ScrollStrip.park(
      Area(x: -900, y: 10, w: 500, h: 700), display: Self.display, walls: [.left],
      edges: Self.edges)
    #expect(left.x == 0)
  }

  @Test func windowsOutOfViewShowThePeekBesideTheColumnsInView() {
    let columns = [
      Area(x: -1000, y: 0, w: 450, h: 800), Area(x: -476, y: 0, w: 500, h: 800),
      Area(x: 34, y: 0, w: 932, h: 800), Area(x: 976, y: 0, w: 500, h: 800),
      Area(x: 1486, y: 0, w: 500, h: 800),
    ]
    #expect(
      ScrollStrip.edges(of: columns, display: Self.display, peek: 24, gap: 10)
        == ScrollEdges(left: 24, right: 976))
  }

  @Test func aParkedWindowDoesNotCoverAColumnThatReachesTheEdge() {
    // The second column ends 5 points short of the edge: the third shows the 5 points left past the gap.
    let columns = [
      Area(x: 0, y: 0, w: 490, h: 800), Area(x: 500, y: 0, w: 495, h: 800),
      Area(x: 1005, y: 0, w: 500, h: 800),
    ]
    #expect(ScrollStrip.edges(of: columns, display: Self.display, peek: 24, gap: 10).right == 999)
    // A column that runs past the edge leaves the sliver.
    let past = [Area(x: 0, y: 0, w: 1200, h: 800), Area(x: 1210, y: 0, w: 500, h: 800)]
    #expect(ScrollStrip.edges(of: past, display: Self.display, peek: 24, gap: 10).right == 999)
  }

  @Test func displaysBesideADisplayAreItsWalls() {
    let left = Area(x: -1920, y: 0, w: 1920, h: 1080)
    let right = Area(x: 1000, y: 200, w: 1000, h: 800)
    let above = Area(x: 0, y: -1080, w: 1920, h: 1080)
    #expect(ScrollStrip.walls(of: Self.display, among: [Self.display]) == [])
    #expect(ScrollStrip.walls(of: Self.display, among: [Self.display, left]) == [.left])
    #expect(ScrollStrip.walls(of: Self.display, among: [Self.display, right]) == [.right])
    #expect(ScrollStrip.walls(of: Self.display, among: [Self.display, above]) == [])
    #expect(
      ScrollStrip.walls(of: Self.display, among: [left, Self.display, right, above])
        == [.left, .right])
  }

  @Test func aParkedWindowKeepsPartOfItselfOnTheDisplay() async {
    let columns = Gen.int(in: 50...1500).map { Float($0) }.array(of: 1...8)
    await propertyCheck(
      input: columns, Gen.int(in: -5000...5000), Gen.int(in: 1...200), Gen.int(in: 1...3000)
    ) { widths, start, peek, w in
      var x = Float(start)
      let frames = widths.map { width in
        defer { x += width + 10 }
        return Area(x: x, y: 0, w: width, h: 100)
      }
      let edges = ScrollStrip.edges(
        of: frames, display: Self.display, peek: Float(peek), gap: 10)
      for walls in [ScrollWalls(), [.left], [.right]] {
        for frame in frames + [Area(x: Float(start), y: 0, w: Float(w), h: 100)] {
          let parked = ScrollStrip.park(frame, display: Self.display, walls: walls, edges: edges)
          #expect(parked.x + parked.w >= Self.display.x + ScrollStrip.sliver)
          #expect(parked.x <= Self.display.x + Self.display.w - ScrollStrip.sliver)
        }
      }
    }
  }
}

@Suite struct ScrollEasingTests {
  @Test(arguments: [(-10.0, 0.0), (0.0, 0.0), (100.0, 0.875), (200.0, 1.0), (500.0, 1.0)])
  func progressEasesOutOverTheDuration(elapsed: Double, expected: Double) {
    #expect(ScrollEasing.progress(elapsed: elapsed, duration: 200) == expected)
  }

  @Test func withoutADurationTheWayIsCoveredAtOnce() {
    #expect(ScrollEasing.progress(elapsed: 0, duration: 0) == 1)
  }

  @Test func progressNeverGoesBack() async {
    await propertyCheck(input: Gen.int(in: 0...400), Gen.int(in: 0...400)) { a, b in
      let early = ScrollEasing.progress(elapsed: Double(min(a, b)), duration: 300)
      let late = ScrollEasing.progress(elapsed: Double(max(a, b)), duration: 300)
      #expect(early <= late)
    }
  }

  @Test func onlyAWindowThatMovesWithoutResizingSlides() {
    let target = CGRect(x: 600, y: 0, width: 600, height: 800)
    #expect(ScrollEasing.slides(from: CGRect(x: 0, y: 0, width: 600, height: 800), to: target))
    #expect(!ScrollEasing.slides(from: target, to: target))
    #expect(!ScrollEasing.slides(from: CGRect(x: 600.4, y: 0, width: 600, height: 800), to: target))
    #expect(!ScrollEasing.slides(from: CGRect(x: 0, y: 0, width: 500, height: 800), to: target))
    #expect(!ScrollEasing.slides(from: nil, to: target))
  }

  @Test func positionsRunFromStartToEnd() {
    #expect(ScrollEasing.position(from: 100, to: -500, progress: 0) == 100)
    #expect(ScrollEasing.position(from: 100, to: -500, progress: 0.5) == -200)
    #expect(ScrollEasing.position(from: 100, to: -500, progress: 1) == -500)
  }
}
