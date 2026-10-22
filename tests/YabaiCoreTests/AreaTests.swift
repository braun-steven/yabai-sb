import CoreGraphics
import Testing
import YabaiTestSupport

@testable import YabaiCore

//
// NOTE: Ported from tests/src/area.c. Each test's display name is the C TEST_FUNC it replaces.
//

private struct TestArea {
  let area: Area
  let max: CGPoint

  init(_ x: Float, _ y: Float, _ w: Float, _ h: Float) {
    area = Area(x: x, y: y, w: w, h: h)
    max = area.maxPoint
  }
}

private let displayList = [
  TestArea(0, 0, 2560, 1440),
  TestArea(-1728, 0, 1728, 1117),
  TestArea(2560, 0, 1920, 1080),
]

private func isInDirection(_ a: Int, _ b: Int, _ direction: Direction) -> Bool {
  Area.isInDirection(
    displayList[a].area, displayList[a].max, displayList[b].area, displayList[b].max, direction)
}

@Test("display_area_is_in_direction") func displayAreaIsInDirection() {
  #expect(isInDirection(0, 1, .west) == true)
  #expect(isInDirection(0, 1, .east) == false)
  #expect(isInDirection(0, 2, .west) == false)
  #expect(isInDirection(0, 2, .east) == true)
}

/// The index of the display of displayList closest to source in a direction, -1 when there is none.
private func closestDisplayInDirection(_ source: Int, _ direction: Direction) -> Int {
  let others = displayList.indices.filter { $0 != source }
  return displayList[source].area.closest(in: direction, among: others.map { displayList[$0].area })
    .map { others[$0] } ?? -1
}

@Test("closest_display_in_direction") func closestDisplayInDirection() {
  #expect(closestDisplayInDirection(0, .west) == 1)
  #expect(closestDisplayInDirection(1, .west) == -1)
  #expect(closestDisplayInDirection(2, .west) == 0)
  #expect(closestDisplayInDirection(0, .east) == 2)
  #expect(closestDisplayInDirection(1, .east) == 0)
  #expect(closestDisplayInDirection(2, .east) == -1)
}

@Test func closestAreaInEveryDirection() {
  // candidates 0 to 3 touch the center at its north, east, west and south side; 4 lies far below 3
  let center = Area(x: 0, y: 0, w: 100, h: 100)
  let candidates = [
    Area(x: 0, y: -100, w: 100, h: 100),
    Area(x: 100, y: 0, w: 100, h: 100),
    Area(x: -100, y: 0, w: 100, h: 100),
    Area(x: 0, y: 100, w: 100, h: 100),
    Area(x: 20, y: 500, w: 50, h: 50),
  ]
  #expect(center.closest(in: .north, among: candidates) == 0)
  #expect(center.closest(in: .east, among: candidates) == 1)
  #expect(center.closest(in: .west, among: candidates) == 2)
  #expect(center.closest(in: .south, among: candidates) == 3)
  #expect(center.closest(in: .south, among: [candidates[4], candidates[3]]) == 1)
  #expect(center.closest(in: .north, among: [candidates[3], candidates[4]]) == nil)
  #expect(center.closest(in: .east, among: []) == nil)
}

@Test func closestAreaPrefersTheFirstOfEqualDistances() {
  let center = Area(x: 0, y: 0, w: 100, h: 100)
  let upper = Area(x: 100, y: -50, w: 100, h: 100)
  let lower = Area(x: 100, y: 50, w: 100, h: 100)
  #expect(center.closest(in: .east, among: [upper, lower]) == 0)
  #expect(center.closest(in: .east, among: [lower, upper]) == 0)
  // an area that only touches the edge of the source does not lie in its direction
  #expect(center.closest(in: .east, among: [Area(x: 100, y: 100, w: 100, h: 100)]) == nil)
}
