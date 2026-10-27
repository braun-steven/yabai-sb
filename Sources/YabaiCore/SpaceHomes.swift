//
// NOTE: The home displays of the spaces, for the space layout (sway's output priority, tree/output.c: a workspace
// remembers the output it came from and returns to it when that output is back). Spaces and displays are kept by uuid,
// because the window server can destroy a space when its display goes away and create it again with the same uuid,
// and the arrangement indices of displays change. A space keeps the display it was recorded on while that display is
// not connected; on a connected display the record follows the space. The homes are kept in memory, like the pins.
// This is the pure part; SpaceManager keeps the homes and SpaceManager+SpaceLayout.swift records them.
//

/// The display (uuid) that each space (uuid) was last seen on.
public struct SpaceHomes: Equatable, Sendable {
  private var displays: [String: String] = [:]

  public init() {}

  public var isEmpty: Bool { displays.isEmpty }

  /// The uuid of the display that the space was last seen on.
  public func display(of space: String) -> String? {
    displays[space]
  }

  /// Records the display of every space on the connected displays (`located`: space uuid to display uuid). A space whose
  /// recorded display is not connected keeps it, wherever it is now: that display is its home. The records of the
  /// other spaces that are not located any more are dropped.
  public mutating func record(_ located: [String: String], connected: Set<String>) {
    var result = displays.filter { !connected.contains($0.value) }

    for (space, display) in located where result[space] == nil {
      result[space] = display
    }

    displays = result
  }

  /// Records that one space moved to a display, unless its recorded display is not connected (its home stays).
  public mutating func record(space: String, display: String, connected: Set<String>) {
    if let home = displays[space], !connected.contains(home) { return }
    displays[space] = display
  }

  /// The arrangement index of the home display of each space (`spaceUUID` names them), for the spaces whose recorded
  /// display is connected; `arrangement` lists the uuids of the connected displays in arrangement order.
  public func homeIndices(
    of spaces: [SpaceID], spaceUUID: (SpaceID) -> String?, arrangement: [String]
  ) -> [SpaceID: Int] {
    if displays.isEmpty { return [:] }

    var result: [SpaceID: Int] = [:]
    for sid in spaces {
      guard let uuid = spaceUUID(sid), let display = displays[uuid],
        let index = arrangement.firstIndex(of: display)
      else { continue }

      result[sid] = index
    }

    return result
  }
}
