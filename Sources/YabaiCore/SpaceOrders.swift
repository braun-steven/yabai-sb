//
// NOTE: How the spaces were arranged on each set of connected displays, for the space layout. Spaces and displays are kept
// by uuid, like SpaceHomes, and each set of displays has its own record: the arrangement of the docked displays stays
// while the laptop is undocked, so it can be put back when they return. A space that macOS recreated keeps its uuid and
// finds its place again. The records are kept in memory, like the homes and the pins.
// This is the pure part; SpaceManager keeps the records and SpaceManager+SpaceLayout.swift uses them.
//

/// The spaces (uuids) of each display (uuid), for each set of connected displays.
public struct SpaceOrders: Equatable, Sendable {
  private var arrangements: [Set<String>: [String: [String]]] = [:]

  public init() {}

  /// Records the spaces of the displays. `displays` lists the uuids of the connected displays in arrangement order, and
  /// `spaces` the space uuids of each of them.
  public mutating func record(_ spaces: [[String]], displays: [String]) {
    arrangements[Set(displays)] = Dictionary(
      zip(displays, spaces).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
  }

  /// The recorded display and place of each space on these displays, nil without a record or when the record does not
  /// have the number of spaces that `target` gives each display: the layout has changed since. `displays` lists the
  /// uuids of the connected displays in arrangement order, and `home` is an index in it.
  public func arrangement(displays: [String], target: [Int]) -> (
    home: [String: Int], rank: [String: Int]
  )? {
    guard let recorded = arrangements[Set(displays)],
      displays.map({ recorded[$0]?.count ?? 0 }) == target
    else { return nil }

    var home: [String: Int] = [:]
    var rank: [String: Int] = [:]
    for (index, display) in displays.enumerated() {
      for (place, space) in (recorded[display] ?? []).enumerated() {
        home[space] = index
        rank[space] = place
      }
    }
    return (home, rank)
  }
}
