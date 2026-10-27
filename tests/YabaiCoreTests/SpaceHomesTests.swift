import Testing
import YabaiTestSupport

@testable import YabaiCore

// NOTE: The home displays of the spaces (SpaceHomes) and the space layout passes that send spaces back to them, like
// sway's output priority (tree/output.c, restore_workspaces). The simulation names a space "s<id>" and a display by
// its uuid string, as the daemon does with the uuids of the window server.

@Test func spaceHomesKeepTheDisplayThatWentAway() {
  var homes = SpaceHomes()
  homes.record(["s1": "A", "s2": "B", "s3": "B"], connected: ["A", "B"])
  #expect(homes.display(of: "s2") == "B")

  // B goes away: its spaces are on A now, but keep B. s3 was destroyed with it and keeps B too.
  homes.record(["s1": "A", "s2": "A"], connected: ["A"])
  #expect(homes.display(of: "s1") == "A")
  #expect(homes.display(of: "s2") == "B")
  #expect(homes.display(of: "s3") == "B")
  homes.record(space: "s2", display: "C", connected: ["A", "C"])
  #expect(homes.display(of: "s2") == "B")

  // A move between connected displays changes the home; a space gone from a connected display is dropped.
  homes.record(space: "s1", display: "C", connected: ["A", "C"])
  #expect(homes.display(of: "s1") == "C")
  homes.record(["s2": "A"], connected: ["A", "B", "C"])
  #expect(homes.display(of: "s1") == nil)
  #expect(homes.display(of: "s2") == "A")
  #expect(homes.display(of: "s3") == nil)

  #expect(
    homes.homeIndices(of: [2, 3], spaceUUID: { "s\($0.rawValue)" }, arrangement: ["B", "A"])
      == [2: 1])
}

@Test func spaceLayoutMoveCandidateKeepsSpacesAtHome() {
  let spaces: [SpaceID] = [1, 2, 3, 4]
  let user = [true, true, true, true]
  #expect(
    SpaceLayout.moveCandidate(
      spaces: spaces, user: user, visible: 1, fromEnd: true, atHome: [3, 4]) == 2)
  #expect(
    SpaceLayout.moveCandidate(
      spaces: spaces, user: user, visible: 1, fromEnd: true, atHome: [2, 3, 4]) == 4)
  #expect(
    SpaceLayout.moveCandidate(
      spaces: [1, 2], user: [true, true], visible: 1, fromEnd: true, pinned: [2], atHome: [1])
      == 1)
}

@Test func spaceLayoutReconcileSendsSpacesHomeFirst() {
  let spaces: [[SpaceID]] = [[1, 2, 3], [11], [21, 22, 23]]
  let user = spaces.map { $0.map { _ in true } }
  func step(home: [SpaceID: Int], pinned: Set<SpaceID> = [], visible: [SpaceID] = [1, 11, 21])
    -> SpaceLayoutStep
  {
    SpaceLayout.reconcileStep(
      target: [3, 3, 1], spaces: spaces, user: user, pinned: pinned, home: home,
      visible: { visible[$0] }, isEmpty: { _ in false })
  }

  // Without homes the first display with too many gives its first hidden space.
  #expect(step(home: [:]) == .move(22, from: 2, to: 1))
  // A space whose home is the display with too few goes back, hidden spaces first; a display at its count gives one
  // too.
  #expect(step(home: [23: 1, 22: 1]) == .move(22, from: 2, to: 1))
  #expect(step(home: [2: 1]) == .move(2, from: 0, to: 1))
  #expect(step(home: [21: 1], visible: [1, 11, 21]) == .move(21, from: 2, to: 1))
  // A pin wins over the home, and a display keeps its last user space.
  #expect(step(home: [23: 1], pinned: [23]) == .move(22, from: 2, to: 1))
  // A space at home is only taken when no other hidden space is left.
  #expect(step(home: [22: 2]) == .move(23, from: 2, to: 1))
  #expect(
    SpaceLayout.reconcileStep(
      target: [1, 2], spaces: [[1], [11]], user: [[true], [true]], pinned: [], home: [1: 1],
      visible: { _ in nil }, isEmpty: { _ in false }) == .create(on: 1, pinnedDisplay: nil))
}

/// The displays and spaces of a session, the way the window server changes them, with the space layout passes, the pin
/// passes and the homes of the daemon.
private struct Session {
  var displays: [(uuid: String, spaces: [SpaceID], visible: SpaceID)]
  var layouts: [[Int]]
  var builtin: String?
  var homes = SpaceHomes()
  /// The pins: the space and the uuid of its display.
  var pins: [SpaceID: String] = [:]
  /// The spaces the window server destroyed with their display, and creates again when it is back.
  var away: [String: SpaceID] = [:]
  var nextSpace: SpaceID = 100

  init(_ displays: [(String, [SpaceID])], layouts: [[Int]], builtin: String? = nil) {
    self.displays = displays.map { ($0.0, $0.1, $0.1[0]) }
    self.layouts = layouts
    self.builtin = builtin
    settle()
  }

  var connected: Set<String> { Set(displays.map(\.uuid)) }

  func spaces(on uuid: String) -> Set<SpaceID> {
    Set(displays.first { $0.uuid == uuid }?.spaces ?? [])
  }

  mutating func move(_ sid: SpaceID, from: Int, to: Int) {
    displays[from].spaces.removeAll { $0 == sid }
    if displays[from].visible == sid { displays[from].visible = displays[from].spaces[0] }
    displays[to].spaces.append(sid)
    homes.record(space: "s\(sid.rawValue)", display: displays[to].uuid, connected: connected)
  }

  /// The window server takes the display away: its visible space is destroyed, the others go to the first display.
  mutating func unplug(_ uuid: String) {
    let i = displays.firstIndex { $0.uuid == uuid }!
    let removed = displays.remove(at: i)
    away[uuid] = removed.visible
    displays[0].spaces += removed.spaces.filter { $0 != removed.visible }
    settle()
  }

  /// The window server brings the display back at its index with the space it destroyed, and moves `taking` hidden
  /// spaces of the first display onto it.
  mutating func replug(_ uuid: String, at index: Int, taking: Int = 0) {
    let sid = away.removeValue(forKey: uuid)!
    displays.insert((uuid, [sid], sid), at: index)
    for _ in 0..<taking {
      let first = displays[0].spaces.last!
      displays[0].spaces.removeLast()
      displays[index].spaces.append(first)
    }
    settle()
  }

  /// Runs the pin and layout passes until both are done.
  mutating func settle() {
    for _ in 0..<40 {
      if let pin = pins.first(where: {
        connected.contains($0.value) && !spaces(on: $0.value).contains($0.key)
      }),
        let from = displays.firstIndex(where: { $0.spaces.contains(pin.key) }),
        let to = displays.firstIndex(where: { $0.uuid == pin.value })
      {
        move(pin.key, from: from, to: to)
        continue
      }

      let layout = SpaceLayout(target: layouts[displays.count - 1])
      let target = layout.targets(builtin: displays.firstIndex { $0.uuid == builtin })
      let spaces = displays.map(\.spaces)
      let pinned = Set(pins.filter { connected.contains($0.value) }.keys)
      let home = homes.homeIndices(
        of: spaces.flatMap { $0 }, spaceUUID: { "s\($0.rawValue)" },
        arrangement: displays.map(\.uuid))
      let visible = displays.map(\.visible)

      switch SpaceLayout.reconcileStep(
        target: target, spaces: spaces, user: spaces.map { $0.map { _ in true } }, pinned: pinned,
        home: home, visible: { visible[$0] }, isEmpty: { $0.rawValue >= 100 })
      {
      case .done, .keep:
        var located: [String: String] = [:]
        for display in displays {
          for sid in display.spaces { located["s\(sid.rawValue)"] = display.uuid }
        }
        homes.record(located, connected: connected)
        return
      case .move(let sid, let from, let to):
        move(sid, from: from, to: to)
      case .create(let i, _):
        displays[i].spaces.append(nextSpace)
        nextSpace = SpaceID(nextSpace.rawValue + 1)
      case .destroy(let sid, let i):
        displays[i].spaces.removeAll { $0 == sid }
      }
    }
    Issue.record("the passes did not converge")
  }
}

private func ids(_ range: ClosedRange<UInt64>) -> [SpaceID] { range.map { SpaceID($0) } }

private let threeDisplays: [(String, [SpaceID])] = [
  ("D1", ids(1...10)), ("D2", ids(11...15)), ("B", [16]),
]

@Test(arguments: [0, 2]) func spaceLayoutUnplugAndReplugOfThreeDisplays(taking: Int) {
  var session = Session(threeDisplays, layouts: [[15], [10, 5], [10, 5, 1]], builtin: "B")

  // With display 2 away the builtin display is the second one and takes 5 spaces: the ones of display 2.
  session.unplug("D2")
  #expect(session.spaces(on: "D1") == Set(ids(1...10)))
  #expect(session.spaces(on: "B") == [16, 12, 13, 14, 15])

  session.replug("D2", at: 1, taking: taking)
  #expect(session.spaces(on: "D1") == Set(ids(1...10)))
  #expect(session.spaces(on: "D2") == Set(ids(11...15)))
  #expect(session.spaces(on: "B") == [16])
}

@Test func spaceLayoutUnplugAndReplugOfTwoDisplays() {
  var session = Session(
    [("D1", ids(1...10)), ("D2", ids(11...15))], layouts: [[15], [10, 5]])

  session.unplug("D2")
  #expect(session.spaces(on: "D1") == Set(ids(1...10) + [12, 13, 14, 15, 100]))

  // The spaces of display 2 go back; the space created for the count is empty and destroyed.
  session.replug("D2", at: 1)
  #expect(session.spaces(on: "D1") == Set(ids(1...10)))
  #expect(session.spaces(on: "D2") == Set(ids(11...15)))

  // A second round trip gives the same result.
  session.unplug("D2")
  session.replug("D2", at: 1)
  #expect(session.spaces(on: "D1") == Set(ids(1...10)))
  #expect(session.spaces(on: "D2") == Set(ids(11...15)))
}

@Test func spaceLayoutPinWinsOverHome() {
  var session = Session(threeDisplays, layouts: [[15], [10, 5], [10, 5, 1]], builtin: "B")
  session.pins = [12: "D1", 13: "D2"]
  session.settle()

  session.unplug("D2")
  #expect(session.spaces(on: "D1").contains(12))

  // 12 stays on its pinned display, 13 goes back with its pin, the other spaces of display 2 by their home.
  session.replug("D2", at: 1)
  #expect(session.spaces(on: "D1").contains(12))
  #expect(session.spaces(on: "D2").isSuperset(of: [11, 13, 14, 15]))
  #expect(session.spaces(on: "B") == [16])
}

@Test func spaceLayoutPinToAFullDisplayMovesItsVisibleSpace() {
  // NOTE: The builtin display takes 1 space. A pin brings 7 there, so its other space has to leave, and the visible
  // 16 is the only one (P4.3f). The pin takes the slot of the display; 16 goes to the display that lost 7.
  var session = Session(threeDisplays, layouts: [[15], [10, 5], [10, 5, 1]], builtin: "B")
  session.pins = [7: "B"]
  session.settle()

  #expect(session.spaces(on: "B") == [7])
  #expect(session.spaces(on: "D1") == Set(ids(1...6) + [8, 9, 10, 16]))
  #expect(session.spaces(on: "D2") == Set(ids(11...15)))
}
