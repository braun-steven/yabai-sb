import Testing
import YabaiTestSupport

@testable import YabaiCore

// NOTE: The pins of labelled spaces (SpacePins, SpacePinning) and the space layout move candidate that keeps pinned
// spaces. The rows name the displays by their uuid string ("uuid1", "uuid2", ...) as the daemon does.

/// The connected displays of a row: each uuid maps to a display id, the display ids are 1-based.
private func connectedDisplays(_ count: Int) -> [String: DisplayID] {
  Dictionary(uniqueKeysWithValues: (0..<count).map { ("uuid\($0 + 1)", DisplayID(UInt32($0 + 1))) })
}

private func pinsOf(_ entries: [(label: String, uuid: String)]) -> SpacePins {
  var pins = SpacePins()
  for entry in entries { pins.pin(label: entry.label, toDisplay: entry.uuid) }
  return pins
}

@Test func spacePinsKeepOnePinPerLabel() {
  var pins = SpacePins()
  #expect(pins.isEmpty)

  pins.pin(label: "web", toDisplay: "uuid1")
  pins.pin(label: "web", toDisplay: "uuid2")
  pins.pin(label: "chat", toDisplay: "uuid1")
  #expect(pins.labels == ["chat", "web"])
  #expect(pins.display(of: "web") == "uuid2")

  let removed = pins.unpin(label: "web")
  #expect(removed)
  let removedAgain = pins.unpin(label: "web")
  #expect(!removedAgain)
  #expect(pins.display(of: "web") == nil)
  #expect(pins.labels == ["chat"])
}

private struct PinMoveCase: Sendable, CustomTestStringConvertible {
  let name: String
  /// The pins: each label with the uuid of its display.
  let pins: [(label: String, uuid: String)]
  /// The space that each label names.
  let spaceOf: [String: SpaceID]
  /// The display of each space.
  let displayOf: [SpaceID: DisplayID]
  /// The connected displays, by uuid.
  let connected: [String: DisplayID]
  let moves: [SpacePinMove]

  var testDescription: String { name }
}

private let pinMoveCases: [PinMoveCase] = [
  PinMoveCase(
    name: "a pinned space on another display moves to its display",
    pins: [("web", "uuid2")], spaceOf: ["web": 5], displayOf: [5: 1],
    connected: connectedDisplays(2), moves: [SpacePinMove(sid: 5, did: 2)]),
  PinMoveCase(
    name: "a pinned space already on its display stays",
    pins: [("web", "uuid2")], spaceOf: ["web": 5], displayOf: [5: 2],
    connected: connectedDisplays(2), moves: []),
  PinMoveCase(
    name: "a pin to a disconnected display moves nothing",
    pins: [("web", "uuid3")], spaceOf: ["web": 5], displayOf: [5: 1],
    connected: connectedDisplays(2), moves: []),
  PinMoveCase(
    name: "a label that names no space moves nothing",
    pins: [("web", "uuid2")], spaceOf: [:], displayOf: [5: 1],
    connected: connectedDisplays(2), moves: []),
  PinMoveCase(
    name: "a space with an unknown display moves nothing",
    pins: [("web", "uuid2")], spaceOf: ["web": 5], displayOf: [:],
    connected: connectedDisplays(2), moves: []),
  PinMoveCase(
    name: "an unpinned space is not moved",
    pins: [("web", "uuid2")], spaceOf: ["web": 5, "chat": 6], displayOf: [5: 2, 6: 1],
    connected: connectedDisplays(2), moves: []),
  PinMoveCase(
    name: "moves come in label order, one per pin",
    pins: [("web", "uuid2"), ("chat", "uuid3")], spaceOf: ["web": 5, "chat": 6],
    displayOf: [5: 1, 6: 1], connected: connectedDisplays(3),
    moves: [SpacePinMove(sid: 6, did: 3), SpacePinMove(sid: 5, did: 2)]),
]

@Test(arguments: pinMoveCases)
private func pinMoves(_ row: PinMoveCase) {
  let moves = SpacePinning.moves(
    pins: pinsOf(row.pins), spaceOf: row.spaceOf, displayOf: row.displayOf, connected: row.connected
  )
  #expect(moves == row.moves)
}

@Test func pinnedSpacesAreThoseOfConnectedDisplays() {
  let connected = connectedDisplays(2)
  let spaceOf: [String: SpaceID] = ["web": 5, "chat": 6, "mail": 7]

  // A pin to a connected display protects its space on whichever display it is.
  let pins = pinsOf([("web", "uuid2"), ("chat", "uuid9"), ("mail", "uuid1")])
  #expect(SpacePinning.pinnedSpaces(pins: pins, spaceOf: spaceOf, connected: connected) == [5, 7])

  // A label that names no space protects nothing.
  #expect(
    SpacePinning.pinnedSpaces(
      pins: pinsOf([("gone", "uuid1")]), spaceOf: spaceOf, connected: connected) == [])
  #expect(
    SpacePinning.pinnedSpaces(pins: SpacePins(), spaceOf: spaceOf, connected: connected) == [])
}

// NOTE: The display holds the spaces 1..n, one per character of the mask, and 'u' marks a user space.
private func pinnedMoveCandidate(
  _ mask: String, visible: SpaceID, fromEnd: Bool, pinned: Set<SpaceID>
)
  -> SpaceID?
{
  let spaces = (0..<mask.count).map { SpaceID(UInt64($0 + 1)) }
  let user = mask.map { $0 == "u" }
  return SpaceLayout.moveCandidate(
    spaces: spaces, user: user, visible: visible, fromEnd: fromEnd, pinned: pinned)
}

@Test func spaceLayoutMoveCandidateSkipsPinnedSpaces() {
  // The first candidate from the edge is pinned, so the next unpinned one is taken.
  #expect(pinnedMoveCandidate("uuuu", visible: 4, fromEnd: false, pinned: [1]) == 2)
  #expect(pinnedMoveCandidate("uuuu", visible: 4, fromEnd: true, pinned: [4]) == 3)
  #expect(pinnedMoveCandidate("uuuu", visible: 4, fromEnd: false, pinned: [1, 2]) == 3)

  // A pinned visible space is not moved, even when it is the only user space.
  #expect(pinnedMoveCandidate("-u--", visible: 2, fromEnd: false, pinned: [2]) == nil)

  // Every user space pinned: nothing can be moved.
  #expect(pinnedMoveCandidate("uu", visible: 1, fromEnd: false, pinned: [1, 2]) == nil)

  // Without pins the candidates are the ones of spaceLayoutMoveCandidate.
  #expect(pinnedMoveCandidate("uuuu", visible: 3, fromEnd: false, pinned: []) == 1)
}

/// The placement of the spaces of each display (in arrangement order) after the reconcile steps have run, and the
/// spaces that they moved.
private struct Settled: Equatable {
  var placement: [[SpaceID]]
  var moved: [SpaceID]
}

/// Runs the reconcile steps as the daemon does: a pin move first, then one space layout move, until neither moves.
/// A moved space joins the end of the list of its new display. The visible space of each display does not change.
private func settle(
  _ placement: [[SpaceID]], visible: [SpaceID], targets: [Int], pins: SpacePins,
  spaceOf: [String: SpaceID], protecting: Bool
) -> Settled {
  var placement = placement
  var moved: [SpaceID] = []
  let connected = connectedDisplays(placement.count)

  for _ in 0..<20 {
    var displayOf: [SpaceID: DisplayID] = [:]
    for (index, list) in placement.enumerated() {
      for sid in list { displayOf[sid] = DisplayID(UInt32(index + 1)) }
    }

    if let move = SpacePinning.moves(
      pins: pins, spaceOf: spaceOf, displayOf: displayOf, connected: connected
    ).first {
      let from = Int(move.did.rawValue) - 1
      let source = placement.firstIndex { $0.contains(move.sid) }!
      placement[source].removeAll { $0 == move.sid }
      placement[from].append(move.sid)
      moved.append(move.sid)
      continue
    }

    let counts = placement.map { $0.count }
    guard let source = counts.indices.first(where: { counts[$0] > targets[$0] }),
      let target = counts.indices.first(where: { counts[$0] < targets[$0] })
    else { break }

    let pinned =
      protecting
      ? SpacePinning.pinnedSpaces(pins: pins, spaceOf: spaceOf, connected: connected) : []
    guard
      let sid = SpaceLayout.moveCandidate(
        spaces: placement[source], user: placement[source].map { _ in true },
        visible: visible[source], fromEnd: target > source, pinned: pinned)
    else { break }

    placement[source].removeAll { $0 == sid }
    placement[target].append(sid)
    moved.append(sid)
  }

  return Settled(placement: placement, moved: moved)
}

// NOTE: Space 3 is pinned to display 2, where it is. Display 1 needs a third space, and the layout step would take the
// first space that is not visible, which is space 3 unless the pin keeps it.
private let webOnDisplayTwo = pinsOf([("web", "uuid2")])
private let webSpace: [String: SpaceID] = ["web": 3]

@Test func pinnedSpaceStaysAndTheLayoutSettlesWithOtherSpaces() {
  let result = settle(
    [[1, 2], [3, 4, 5]], visible: [1, 5], targets: [3, 2], pins: webOnDisplayTwo, spaceOf: webSpace,
    protecting: true)

  #expect(result.placement == [[1, 2, 4], [3, 5]])
  #expect(result.moved == [4])
}

@Test func withoutTheProtectionThePinnedSpaceMovesBackAndForth() {
  // The control row: the layout moves the pinned space away, and its pin moves it back, more than once.
  let result = settle(
    [[1, 2], [3, 4, 5]], visible: [1, 5], targets: [3, 2], pins: webOnDisplayTwo, spaceOf: webSpace,
    protecting: false)

  #expect(result.moved.filter { $0 == 3 }.count > 1)
}

@Test func pinMovesItsSpaceAndTheCountsMatch() {
  // Space 1 is pinned to display 2 but sits on display 1: the pin moves it and no layout step is needed.
  let result = settle(
    [[1, 2, 3], [4, 5]], visible: [2, 4], targets: [2, 3], pins: pinsOf([("web", "uuid2")]),
    spaceOf: ["web": 1], protecting: true)

  #expect(result.placement == [[2, 3], [4, 5, 1]])
  #expect(result.moved == [1])
}
