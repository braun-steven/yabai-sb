//
// NOTE: The pins of labelled spaces. A pinned space returns to its display whenever that display is connected. A pin is
// keyed by the label, so it follows the label when the label moves to another space, and the label removes it. The
// display is kept by its uuid, because the arrangement indices of displays change. This is the pure part; the pins are
// kept by SpaceManager and the reconcile passes are SpaceManager+Pins.swift.
//

/// The pins of the labels: the uuid of the display that each pinned label returns to.
public struct SpacePins: Sendable {
  private var displays: [String: String] = [:]

  public init() {}

  public var isEmpty: Bool { displays.isEmpty }

  /// The pinned labels, in name order.
  public var labels: [String] { displays.keys.sorted() }

  /// The uuid of the display that a label is pinned to.
  public func display(of label: String) -> String? {
    displays[label]
  }

  public mutating func pin(label: String, toDisplay uuid: String) {
    displays[label] = uuid
  }

  /// Removes the pin of a label; false when the label had none.
  @discardableResult public mutating func unpin(label: String) -> Bool {
    displays.removeValue(forKey: label) != nil
  }
}

/// A space that a pin moves to its display.
public struct SpacePinMove: Equatable, Sendable {
  public var sid: SpaceID
  public var did: DisplayID

  public init(sid: SpaceID, did: DisplayID) {
    self.sid = sid
    self.did = did
  }
}

/// The decisions of the pins. `spaceOf` maps a pinned label to the space it labels (a label that names no space is
/// left out), `connected` maps the uuid of each connected display to the display.
public enum SpacePinning {
  /// The moves that bring pinned spaces to their displays, in label order: a pin whose display is connected and
  /// whose space is on another display. `displayOf` gives the display of each labelled space; a space with no known
  /// display is left out.
  public static func moves(
    pins: SpacePins, spaceOf: [String: SpaceID], displayOf: [SpaceID: DisplayID],
    connected: [String: DisplayID]
  ) -> [SpacePinMove] {
    var result: [SpacePinMove] = []

    for label in pins.labels {
      guard let uuid = pins.display(of: label), let target = connected[uuid],
        let sid = spaceOf[label], let current = displayOf[sid], current != target
      else { continue }

      result.append(SpacePinMove(sid: sid, did: target))
    }

    return result
  }

  /// The spaces that the space layout must not move or destroy: the spaces whose pin names a connected display, on
  /// whichever display they are. A layout move of such a space would be undone by its pin.
  public static func pinnedSpaces(
    pins: SpacePins, spaceOf: [String: SpaceID], connected: [String: DisplayID]
  ) -> Set<SpaceID> {
    var result: Set<SpaceID> = []

    for label in pins.labels {
      guard let uuid = pins.display(of: label), connected[uuid] != nil,
        let sid = spaceOf[label]
      else { continue }

      result.insert(sid)
    }

    return result
  }
}
