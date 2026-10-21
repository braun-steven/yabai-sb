import PropertyBased
import YabaiCore

//
// NOTE: Generators of the YabaiCore enums for property tests. They pick a case by index, so a failing input shrinks
// towards the first case.
//

public extension Gen where Value == Direction
{
    static var direction: Generator<Direction, Shrink.Integer<Int>>
    {
        let cases: [Direction] = [.north, .east, .south, .west]
        return Gen<Int>.int(in: 0...3).map { cases[$0] }
    }
}

public extension Gen where Value == InsertDirection
{
    static var insertDirection: Generator<InsertDirection, Shrink.Integer<Int>>
    {
        let cases: [InsertDirection] = [.north, .east, .south, .west, .stack]
        return Gen<Int>.int(in: 0...4).map { cases[$0] }
    }
}

public extension Gen where Value == ConOrientation
{
    static var orientation: Generator<ConOrientation, Shrink.Integer<Int>>
    {
        let cases: [ConOrientation] = [.horizontal, .vertical]
        return Gen<Int>.int(in: 0...1).map { cases[$0] }
    }
}
