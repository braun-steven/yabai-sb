import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("DisplayArrangement")
struct DisplayArrangementTests {
  private static func place(_ uuid: String, _ x: CGFloat, _ y: CGFloat)
    -> DisplayArrangement.Placement
  {
    DisplayArrangement.Placement(uuid: uuid, center: CGPoint(x: x, y: y))
  }

  @Test func horizontalSortsByXThenY() {
    let placements = [
      Self.place("b", 200, 0),
      Self.place("a", 0, 100),
      Self.place("c", 0, 0),
    ]
    #expect(DisplayArrangement.sorted(placements, vertical: false) == ["c", "a", "b"])
  }

  @Test func verticalSortsByYThenX() {
    let placements = [
      Self.place("b", 200, 0),
      Self.place("a", 0, 100),
      Self.place("c", 0, 0),
    ]
    #expect(DisplayArrangement.sorted(placements, vertical: true) == ["c", "b", "a"])
  }

  // Displays with the same center keep the order of the window server, on both axes.
  @Test(arguments: [false, true])
  func ties(vertical: Bool) {
    let placements = [
      Self.place("x", 10, 10),
      Self.place("y", 10, 10),
      Self.place("z", 0, 0),
    ]
    #expect(DisplayArrangement.sorted(placements, vertical: vertical) == ["z", "x", "y"])
  }

  // The window server's comparator compared the centers as Float: a difference below the precision of Float at that
  // magnitude is a tie on the axis, so the other axis decides.
  @Test func comparesCentersAsFloat() {
    let placements = [
      Self.place("a", 1_000_000_001, 0),
      Self.place("b", 1_000_000_000, 100),
    ]
    #expect(DisplayArrangement.sorted(placements, vertical: false) == ["a", "b"])
  }

  @Test(arguments: [false, true])
  func emptyAndSingle(vertical: Bool) {
    #expect(DisplayArrangement.sorted([], vertical: vertical) == [])
    #expect(DisplayArrangement.sorted([Self.place("only", 5, 5)], vertical: vertical) == ["only"])
  }

  // The built-in display west of two 2560x1440 displays, 314 points lower: from the east display, east wraps past the
  // middle one to the built-in display, and from the built-in display, west wraps to the east display. The middle
  // display has displays both ways, so its selectors never wrap, but the helper still names the farthest one.
  private static let row = [
    CGRect(x: 0, y: 0, width: 2560, height: 1440),
    CGRect(x: -1512, y: 314, width: 1512, height: 982),
    CGRect(x: 2560, y: 0, width: 2560, height: 1440),
  ]

  private static func wrapped(_ source: Int, _ direction: Direction, _ frames: [CGRect]) -> Int? {
    let others = frames.indices.filter { $0 != source }
    return DisplayArrangement.wrapped(
      in: direction, from: frames[source], among: others.map { frames[$0] }
    ).map { others[$0] }
  }

  @Test(arguments: [
    (2, Direction.east, 1), (1, .west, 2), (0, .east, 1), (0, .west, 2),
  ])
  func wrapsToTheFarthestDisplayTheOtherWay(source: Int, direction: Direction, expected: Int) {
    #expect(Self.wrapped(source, direction, Self.row) == expected)
  }

  // A display overlapping the reference on the axis of the direction does not lie wholly the other way.
  @Test(arguments: [Direction.north, .south])
  func rowHasNoWrapAcrossIt(direction: Direction) {
    for source in Self.row.indices {
      #expect(Self.wrapped(source, direction, Self.row) == nil)
    }
  }

  // Three displays stacked top to bottom: north from the top wraps to the bottom one, south from the bottom to the top.
  @Test(arguments: [(0, Direction.north, 2), (2, .south, 0), (1, .north, 2), (1, .south, 0)])
  func wrapsVertically(source: Int, direction: Direction, expected: Int) {
    let column = [
      CGRect(x: 0, y: -1440, width: 2560, height: 1440),
      CGRect(x: 0, y: 0, width: 2560, height: 1440),
      CGRect(x: 300, y: 1440, width: 1920, height: 1080),
    ]
    #expect(Self.wrapped(source, direction, column) == expected)
  }

  // The distance counts both axes: of two displays at the same x to the west, the one farther off to the side wins.
  @Test func farthestMeasuresBothAxes() {
    let reference = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let candidates = [
      CGRect(x: -1000, y: 0, width: 1000, height: 1000),
      CGRect(x: -1000, y: 3000, width: 1000, height: 1000),
    ]
    #expect(DisplayArrangement.wrapped(in: .east, from: reference, among: candidates) == 1)
  }

  // A single display has no display to wrap to, so the selector keeps failing.
  @Test(arguments: [Direction.north, .east, .south, .west])
  func singleDisplayHasNoWrap(direction: Direction) {
    #expect(Self.wrapped(0, direction, [Self.row[0]]) == nil)
  }
}
