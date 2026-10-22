import CoreGraphics
import Testing
@testable import YabaiCore

@Suite("DisplayArrangement")
struct DisplayArrangementTests
{
    private static func place(_ uuid: String, _ x: CGFloat, _ y: CGFloat) -> DisplayArrangement.Placement
    {
        DisplayArrangement.Placement(uuid: uuid, center: CGPoint(x: x, y: y))
    }

    @Test func horizontalSortsByXThenY()
    {
        let placements = [
            Self.place("b", 200, 0),
            Self.place("a", 0, 100),
            Self.place("c", 0, 0),
        ]
        #expect(DisplayArrangement.sorted(placements, vertical: false) == ["c", "a", "b"])
    }

    @Test func verticalSortsByYThenX()
    {
        let placements = [
            Self.place("b", 200, 0),
            Self.place("a", 0, 100),
            Self.place("c", 0, 0),
        ]
        #expect(DisplayArrangement.sorted(placements, vertical: true) == ["c", "b", "a"])
    }

    // Displays with the same center keep the order of the window server, on both axes.
    @Test(arguments: [false, true])
    func ties(vertical: Bool)
    {
        let placements = [
            Self.place("x", 10, 10),
            Self.place("y", 10, 10),
            Self.place("z", 0, 0),
        ]
        #expect(DisplayArrangement.sorted(placements, vertical: vertical) == ["z", "x", "y"])
    }

    // The window server's comparator compared the centers as Float: a difference below the precision of Float at that
    // magnitude is a tie on the axis, so the other axis decides.
    @Test func comparesCentersAsFloat()
    {
        let placements = [
            Self.place("a", 1_000_000_001, 0),
            Self.place("b", 1_000_000_000, 100),
        ]
        #expect(DisplayArrangement.sorted(placements, vertical: false) == ["a", "b"])
    }

    @Test(arguments: [false, true])
    func emptyAndSingle(vertical: Bool)
    {
        #expect(DisplayArrangement.sorted([], vertical: vertical) == [])
        #expect(DisplayArrangement.sorted([Self.place("only", 5, 5)], vertical: vertical) == ["only"])
    }
}
