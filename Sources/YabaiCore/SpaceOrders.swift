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

  /// The recorded arrangement, with the spaces of now put in it.
  public struct Arrangement: Equatable, Sendable {
    /// The index of the display of each space.
    public var home: [String: Int] = [:]
    /// The place of each space on its display.
    public var rank: [String: Int] = [:]
    /// The recorded spaces that are gone, by the spaces that take their places.
    public var replaced: [String: String] = [:]
  }

  //
  // NOTE: macOS can also destroy a space for good when a display returns, and move its windows to a space with another
  // uuid. So a recorded space that is gone leaves its place to a space without a record, the one on its display first,
  // and one with windows before an empty one, which the layout can destroy.
  //

  /// The recorded arrangement of these displays for the spaces of now, nil without a record or when the record does not
  /// have the number of spaces that `target` gives each display: the layout has changed since. `displays` lists the
  /// uuids of the connected displays in arrangement order, `spaces` the uuids of their spaces, and `home` is an index in
  /// `displays`.
  public func arrangement(
    displays: [String], target: [Int], spaces: [[String]], isEmpty: (String) -> Bool
  ) -> Arrangement? {
    guard let recorded = arrangements[Set(displays)],
      displays.map({ recorded[$0]?.count ?? 0 }) == target
    else { return nil }

    var result = Arrangement()
    let current = Set(spaces.joined())
    var missing: [(uuid: String, display: Int, place: Int)] = []

    for (index, display) in displays.enumerated() {
      for (place, space) in (recorded[display] ?? []).enumerated() {
        result.home[space] = index
        result.rank[space] = place
        if !current.contains(space) { missing.append((space, index, place)) }
      }
    }

    var strangers = spaces.enumerated().flatMap { display, list in
      list.filter { result.home[$0] == nil }.map { (uuid: $0, display: display) }
    }
    let occupied = strangers.filter { !isEmpty($0.uuid) }
    let empty = strangers.filter { isEmpty($0.uuid) }
    strangers = occupied + empty

    for gone in missing {
      guard
        let found = strangers.firstIndex(where: { $0.display == gone.display })
          ?? strangers.indices.first
      else { break }

      let stranger = strangers.remove(at: found)
      result.home[stranger.uuid] = gone.display
      result.rank[stranger.uuid] = gone.place
      result.replaced[stranger.uuid] = gone.uuid
    }

    return result
  }
}
