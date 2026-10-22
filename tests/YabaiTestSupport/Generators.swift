import PropertyBased
import YabaiCore

//
// NOTE: Generators of the YabaiCore enums for property tests. They pick a case by index, so a failing input shrinks
// towards the first case.
//

extension Gen where Value == Direction {
  public static var direction: Generator<Direction, Shrink.Integer<Int>> {
    let cases: [Direction] = [.north, .east, .south, .west]
    return Gen<Int>.int(in: 0...3).map { cases[$0] }
  }
}

extension Gen where Value == InsertDirection {
  public static var insertDirection: Generator<InsertDirection, Shrink.Integer<Int>> {
    let cases: [InsertDirection] = [.north, .east, .south, .west, .stack]
    return Gen<Int>.int(in: 0...4).map { cases[$0] }
  }
}

extension Gen where Value == ConOrientation {
  public static var orientation: Generator<ConOrientation, Shrink.Integer<Int>> {
    let cases: [ConOrientation] = [.horizontal, .vertical]
    return Gen<Int>.int(in: 0...1).map { cases[$0] }
  }
}
