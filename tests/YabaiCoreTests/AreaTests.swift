import CoreGraphics
import Testing
@testable import YabaiCore

//
// NOTE: Ported from tests/src/area.c. Each test's display name is the C TEST_FUNC it replaces.
//

private struct TestArea
{
    let area: Area
    let max: CGPoint

    init(_ x: Float, _ y: Float, _ w: Float, _ h: Float)
    {
        area = Area(x: x, y: y, w: w, h: h)
        max = area.maxPoint
    }
}

private let displayList = [
    TestArea(0, 0, 2560, 1440),
    TestArea(-1728, 0, 1728, 1117),
    TestArea(2560, 0, 1920, 1080),
]

private func isInDirection(_ a: Int, _ b: Int, _ direction: Direction) -> Bool
{
    Area.isInDirection(displayList[a].area, displayList[a].max, displayList[b].area, displayList[b].max, direction)
}

@Test("display_area_is_in_direction") func displayAreaIsInDirection()
{
    #expect(isInDirection(0, 1, .west) == true)
    #expect(isInDirection(0, 1, .east) == false)
    #expect(isInDirection(0, 2, .west) == false)
    #expect(isInDirection(0, 2, .east) == true)
}

private func closestDisplayInDirection(_ source: Int, _ direction: Direction) -> Int
{
    var bestIndex = -1
    var bestDistance = Int(Int32.max)

    for i in displayList.indices where i != source {
        if isInDirection(source, i, direction) {
            let distance = Area.distanceInDirection(displayList[source].area, displayList[source].max, displayList[i].area, displayList[i].max, direction)
            if distance < bestDistance {
                bestIndex = i
                bestDistance = distance
            }
        }
    }

    return bestIndex
}

@Test("closest_display_in_direction") func closestDisplayInDirection()
{
    #expect(closestDisplayInDirection(0, .west) == 1)
    #expect(closestDisplayInDirection(1, .west) == -1)
    #expect(closestDisplayInDirection(2, .west) == 0)
    #expect(closestDisplayInDirection(0, .east) == 2)
    #expect(closestDisplayInDirection(1, .east) == 0)
    #expect(closestDisplayInDirection(2, .east) == -1)
}
