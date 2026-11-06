import Testing
import YabaiCore

private func window(_ id: UInt32) -> WindowID { WindowID(rawValue: id) }

private func slot(_ uuid: String, _ windows: [UInt32] = [], display: String = "d1") -> TopologySlot
{
  TopologySlot(uuid: uuid, display: display, windows: windows.map(window), tree: nil)
}

private func commit(_ time: Double, _ slots: [TopologySlot], active: String? = nil)
  -> TopologyCommit
{
  TopologyCommit(time: time, slots: slots, shown: [:], active: active, focused: nil)
}

private func bind(
  _ commit: TopologyCommit, displays: [String] = ["d1"], _ spaces: [[String]],
  windows: [String: [UInt32]] = [:]
) -> TopologyBinding {
  TopologyRestore.bind(
    commit, displays: displays, spaces: spaces,
    windows: { (windows[$0] ?? []).map(window) })
}

// MARK: The ledger

@Test func aRestoreTakesTheNewestCommitFromBeforeTheDisturbance() {
  var ledger = TopologyLedger()
  ledger.add(commit(1, [slot("a")]))
  ledger.add(commit(2, [slot("b")]))
  ledger.add(commit(3, [slot("c")]))

  #expect(ledger.commit(before: 2.5)?.slots.map(\.uuid) == ["b"])
  #expect(ledger.commit(before: 0.5) == nil)
}

@Test func aCommitThatRepeatsTheNewestKeepsItsTime() {
  var ledger = TopologyLedger()
  ledger.add(commit(1, [slot("a", [1])]))
  ledger.add(commit(2, [slot("a", [1])]))

  #expect(ledger.commits.map(\.time) == [1])
  #expect(ledger.commit(before: 1.5) != nil)
}

@Test func theLedgerKeepsALimitedNumberOfCommits() {
  var ledger = TopologyLedger()
  for time in 0..<(TopologyLedger.capacity + 3) {
    ledger.add(commit(Double(time), [slot("\(time)")]))
  }

  #expect(ledger.commits.count == TopologyLedger.capacity)
  #expect(ledger.commits.first?.time == 3)
}

@Test func aCommitRemembersWhatADisplayThatIsGoneShowed() {
  var ledger = TopologyLedger()
  ledger.add(
    TopologyCommit(
      time: 1, slots: [slot("a"), slot("b")], shown: ["d1": "a", "d2": "b"], active: nil,
      focused: nil))
  ledger.add(
    TopologyCommit(
      time: 2, slots: [slot("a"), slot("b")], shown: ["d1": "a"], active: nil, focused: nil))

  #expect(ledger.commits.last?.shown == ["d1": "a", "d2": "b"])
}

@Test func aStandInRemembersTheSpaceItReplaced() throws {
  var ledger = TopologyLedger()
  let first = commit(1, [slot("original")])
  ledger.add(first)
  ledger.adopt(TopologyBinding(spaces: ["stand-in"], extras: []), of: first)
  ledger.add(commit(2, [slot("stand-in")]))

  let newest = try #require(ledger.commits.last)
  #expect(newest.slots[0].formerUUIDs == ["original"])

  ledger.adopt(TopologyBinding(spaces: ["original"], extras: ["stand-in"]), of: newest)
  ledger.add(commit(3, [slot("original")]))
  #expect(ledger.commits.last?.slots[0].formerUUIDs == [])
}

// MARK: Binding

@Test func aSpaceThatIsThereKeepsItsSlot() {
  let binding = bind(commit(1, [slot("a"), slot("b")]), [["b", "a"]])

  #expect(binding.spaces == ["a", "b"])
  #expect(binding.extras.isEmpty)
}

@Test func aSlotWithoutASpaceWaitsForANewOne() {
  let binding = bind(commit(1, [slot("a"), slot("b")]), [["a"]])

  #expect(binding.spaces == ["a", nil])
}

@Test func aReturningOriginalWinsOverItsStandIn() {
  var standIn = slot("stand-in")
  standIn.formerUUIDs = ["newer", "original"]

  let binding = bind(commit(1, [standIn]), [["stand-in", "original", "newer"]])

  #expect(binding.spaces == ["original"])
  #expect(binding.extras == ["stand-in", "newer"])
}

@Test func aFormerSpaceThatStandsOnAnotherSlotStaysThere() {
  var first = slot("a")
  first.formerUUIDs = ["b"]

  let binding = bind(commit(1, [first, slot("b")]), [["a", "b"]])

  #expect(binding.spaces == ["a", "b"])
}

@Test func aSpaceWithoutASlotTakesTheSlotOfTheWindowsItHolds() {
  // macOS destroyed a and moved its windows to x, which it put on another display.
  let binding = bind(
    commit(1, [slot("a", [1]), slot("b"), slot("c", display: "d2")]),
    displays: ["d1", "d2"], [["b", "y"], ["c", "x"]], windows: ["x": [1], "y": [9]])

  #expect(binding.spaces == ["x", "b", "c"])
  #expect(binding.extras == ["y"])
}

@Test func aSpaceWithWindowsTakesASlotBeforeAnEmptySpace() {
  let binding = bind(
    commit(1, [slot("a"), slot("b")]), [["b", "empty", "x"]], windows: ["x": [9]])

  #expect(binding.spaces == ["x", "b"])
  #expect(binding.extras == ["empty"])
}

@Test func aSpaceOnTheDisplayOfTheSlotComesBeforeOneElsewhere() {
  let binding = bind(
    commit(1, [slot("a", display: "d2"), slot("b")]),
    displays: ["d1", "d2"], [["b", "x"], ["y"]])

  #expect(binding.spaces == ["y", "b"])
  #expect(binding.extras == ["x"])
}

@Test func aSlotTakesASpaceOfAnotherDisplayWhenItsOwnHasNone() {
  let binding = bind(
    commit(1, [slot("a"), slot("b"), slot("c", display: "d2")]),
    displays: ["d1", "d2"], [["b"], ["c", "x"]])

  #expect(binding.spaces == ["x", "b", "c"])
}

// MARK: The transaction

@Test func theRestoreWaitsUntilTheChangesAreQuiet() {
  var transaction = TopologyTransaction()
  #expect(!transaction.isFrozen)

  transaction.disturb(at: 10, displays: true)
  transaction.disturb(at: 13, displays: false)
  transaction.touch(at: 14)

  #expect(transaction.phase == .disturbed)
  #expect(transaction.firstChange == 10)
  #expect(transaction.restoreTime == 14 + TopologyTransaction.quiet)
}

@Test func theRestoreDoesNotWaitForever() {
  var transaction = TopologyTransaction()
  transaction.disturb(at: 10, displays: true)
  transaction.disturb(at: 39, displays: true)

  #expect(transaction.restoreTime == 10 + TopologyTransaction.limit)
}

@Test func aChangeOfTheDisplaysIsWatchedAfterTheRestore() {
  var transaction = TopologyTransaction()
  transaction.disturb(at: 10, displays: true)
  transaction.beginRestore()
  #expect(transaction.holdsWindows)

  transaction.finishRestore(at: 20)
  #expect(transaction.phase == .watching)
  #expect(transaction.isFrozen)
  #expect(!transaction.holdsWindows)
  #expect(!transaction.watchHasEnded(at: 20 + TopologyTransaction.watch - 1))
  #expect(transaction.watchHasEnded(at: 20 + TopologyTransaction.watch))

  transaction.finish()
  #expect(transaction.phase == .stable)
}

@Test func aChangeWithoutDisplaysEndsWithTheRestore() {
  var transaction = TopologyTransaction()
  transaction.disturb(at: 10, displays: false)
  transaction.beginRestore()
  transaction.finishRestore(at: 20)

  #expect(transaction.phase == .stable)
}

@Test func aDisturbanceDuringTheWatchWaitsAgainAndKeepsItsStart() {
  var transaction = TopologyTransaction()
  transaction.disturb(at: 10, displays: true)
  transaction.beginRestore()
  transaction.finishRestore(at: 20)
  transaction.disturb(at: 25, displays: false)

  #expect(transaction.phase == .disturbed)
  #expect(transaction.firstChange == 10)
  #expect(transaction.displaysChanged)
  #expect(transaction.restoreTime == 25 + TopologyTransaction.quiet)
}

@Test func aNewTransactionForgetsTheDisplaysOfTheOldOne() {
  var transaction = TopologyTransaction()
  transaction.disturb(at: 10, displays: true)
  transaction.finish()
  transaction.disturb(at: 100, displays: false)

  #expect(!transaction.displaysChanged)
  #expect(transaction.firstChange == 100)
}

// MARK: A desktop that behaves like macOS

/// Three displays with 16 spaces, which collapse and return as measured with a real dock.
private struct Desktop {
  struct Space: Equatable {
    var id: SpaceID
    var uuid: String
    var windows: [WindowID]
  }

  struct Display {
    var uuid: String
    var spaces: [Space]
    var shown: SpaceID
  }

  /// What macOS remembers of a display that is gone.
  struct Lost {
    var display: String
    var first: String
    var windows: [WindowID]
    var others: [String]
  }

  static let order = ["D1", "D2", "B"]
  static let targets: [Int: [Int]] = [1: [16], 2: [10, 6], 3: [10, 5, 1]]

  var displays: [Display] = []
  var lost: [Lost] = []
  var nextID: UInt64 = 1000
  var nextUUID = 0

  init() {
    var index = 0
    for (uuid, count) in zip(Self.order, [10, 5, 1]) {
      var spaces: [Space] = []
      for _ in 0..<count {
        index += 1
        spaces.append(
          Space(
            id: SpaceID(rawValue: UInt64(index)), uuid: "space-\(index)",
            windows: [window(UInt32(index * 10)), window(UInt32(index * 10 + 1))]))
      }
      displays.append(Display(uuid: uuid, spaces: spaces, shown: spaces[0].id))
    }
  }

  var allWindows: [WindowID] { displays.flatMap(\.spaces).flatMap(\.windows) }

  var observed: TopologyObserved {
    let spaces = displays.flatMap(\.spaces)
    return TopologyObserved(
      displays: displays.map(\.uuid), spaces: displays.map { $0.spaces.map(\.id) },
      user: displays.map { $0.spaces.map { _ in true } },
      uuids: Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.uuid) }),
      windows: Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.windows) }))
  }

  var target: [Int] { Self.targets[displays.count] ?? [] }

  func commit(at time: Double) -> TopologyCommit {
    let slots = displays.flatMap { display in
      display.spaces.map {
        TopologySlot(uuid: $0.uuid, display: display.uuid, windows: $0.windows, tree: nil)
      }
    }
    return TopologyCommit(time: time, slots: slots, shown: [:], active: nil, focused: nil)
  }

  mutating func newID() -> SpaceID {
    nextID += 1
    return SpaceID(rawValue: nextID)
  }

  /// The first space of the display is destroyed and its windows pile up on the first remaining display, whose first
  /// space they join; the other spaces are appended to that display.
  mutating func remove(_ uuid: String) {
    guard let index = displays.firstIndex(where: { $0.uuid == uuid }) else { return }

    let gone = displays.remove(at: index)
    let first = gone.spaces[0]
    displays[0].spaces[0].windows += first.windows
    displays[0].spaces += gone.spaces.dropFirst()
    lost.append(
      Lost(
        display: uuid, first: first.uuid, windows: first.windows,
        others: gone.spaces.dropFirst().map(\.uuid)))
  }

  /// macOS creates the destroyed space again with a new id, pulls its windows back from wherever they are, and takes its
  /// other spaces along.
  mutating func restore(_ uuid: String) {
    guard let index = lost.firstIndex(where: { $0.display == uuid }) else { return }

    let back = lost.remove(at: index)
    for d in displays.indices {
      for s in displays[d].spaces.indices {
        displays[d].spaces[s].windows.removeAll { back.windows.contains($0) }
      }
    }

    var spaces = [Space(id: newID(), uuid: back.first, windows: back.windows)]
    for d in displays.indices {
      let shown = displays[d].shown
      let leaving = displays[d].spaces.filter { back.others.contains($0.uuid) && $0.id != shown }
      displays[d].spaces.removeAll { leaving.contains($0) }
      spaces += leaving
    }

    let place = displays.firstIndex { position($0.uuid) > position(uuid) } ?? displays.count
    displays.insert(Display(uuid: uuid, spaces: spaces, shown: spaces[0].id), at: place)
  }

  private func position(_ uuid: String) -> Int { Self.order.firstIndex(of: uuid) ?? 0 }

  /// A display shows its first space when the one it showed went elsewhere.
  mutating func settleShownSpaces() {
    for d in displays.indices
    where !displays[d].spaces.contains(where: { $0.id == displays[d].shown }) {
      displays[d].shown = displays[d].spaces[0].id
    }
  }

  /// macOS drops a window on the space a display shows.
  mutating func stray(_ window: WindowID, display: Int) {
    settleShownSpaces()
    for d in displays.indices {
      for s in displays[d].spaces.indices {
        displays[d].spaces[s].windows.removeAll { $0 == window }
      }
    }
    let shown = displays[display].shown
    if let s = displays[display].spaces.firstIndex(where: { $0.id == shown }) {
      displays[display].spaces[s].windows.append(window)
    }
  }

  private func location(of sid: SpaceID) -> (display: Int, space: Int)? {
    for (d, display) in displays.enumerated() {
      if let s = display.spaces.firstIndex(where: { $0.id == sid }) { return (d, s) }
    }
    return nil
  }

  mutating func perform(_ step: SpaceLayoutStep) {
    switch step {
    case .done, .keep: break
    case .move(let sid, _, let to):
      guard let (d, s) = location(of: sid) else { return }
      let space = displays[d].spaces.remove(at: s)
      // NOTE: A moved space lands next to the visible space of its display.
      let shown = displays[to].spaces.firstIndex { $0.id == displays[to].shown } ?? 0
      displays[to].spaces.insert(space, at: shown + 1)
    case .create(let display, _):
      nextUUID += 1
      displays[display].spaces.append(
        Space(id: newID(), uuid: "stand-in-\(nextUUID)", windows: []))
    case .destroy(let sid, _):
      guard let (d, s) = location(of: sid) else { return }
      displays[d].spaces.remove(at: s)
    case .reorder(let sid, let other, let display):
      guard let (_, s) = location(of: sid), let (_, o) = location(of: other) else { return }
      let space = displays[display].spaces.remove(at: s)
      displays[display].spaces.insert(space, at: o)
    }
  }

  mutating func perform(_ move: TopologyMove) {
    guard let (d, s) = location(of: move.space) else { return }

    for w in move.windows {
      for a in displays.indices {
        for b in displays[a].spaces.indices { displays[a].spaces[b].windows.removeAll { $0 == w } }
      }
    }
    displays[d].spaces[s].windows += move.windows
  }

  /// Runs the passes of a restore until nothing is left to do; the number of passes, nil when it never ends.
  mutating func restore(to commit: TopologyCommit) -> (TopologyBinding, Int)? {
    for pass in 1...200 {
      settleShownSpaces()
      let shown = displays.map(\.shown)
      guard
        let plan = TopologyRestore.plan(
          commit, observed: observed, target: target, pinned: [], visible: { shown[$0] })
      else { return nil }

      if !plan.spacesAreDone {
        perform(plan.step)
      } else if !plan.moves.isEmpty {
        for move in plan.moves { perform(move) }
      } else {
        return (plan.binding, pass)
      }
    }
    return nil
  }

  /// The windows of each slot.
  var slots: [Set<WindowID>] { displays.flatMap(\.spaces).map { Set($0.windows) } }
}

/// A small generator, so a failure repeats.
private struct Numbers {
  var state: UInt64

  mutating func next(_ bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(bound))
  }
}

private func expectBack(_ desktop: Desktop, slots: [Set<WindowID>]) {
  #expect(desktop.displays.map { $0.spaces.count } == desktop.target)
  #expect(desktop.slots == slots)
}

@Test func anUndockKeepsEverySlotAndAReplugBringsTheOriginalsBack() throws {
  var desktop = Desktop()
  var ledger = TopologyLedger()
  let slots = desktop.slots
  ledger.add(desktop.commit(at: 1))

  desktop.remove("D1")
  desktop.remove("D2")
  let docked = try #require(ledger.commit(before: 2))
  let first = desktop.restore(to: docked)
  let (binding, _) = try #require(first)
  expectBack(desktop, slots: slots)

  ledger.adopt(binding, of: docked)
  ledger.add(desktop.commit(at: 3))

  desktop.restore("D2")
  desktop.restore("D1")
  let undocked = try #require(ledger.commit(before: 4))
  #expect(desktop.restore(to: undocked) != nil)
  expectBack(desktop, slots: slots)

  #expect(desktop.displays[1].spaces[0].uuid == "space-11")
}

@Test func windowsThatStrayedGoBack() throws {
  var desktop = Desktop()
  let slots = desktop.slots
  let commit = desktop.commit(at: 1)

  desktop.stray(window(110), display: 0)
  desktop.stray(window(10), display: 2)

  #expect(desktop.restore(to: commit) != nil)
  expectBack(desktop, slots: slots)
}

@Test func aWindowMovedOnPurposeStaysWhereItIs() throws {
  var desktop = Desktop()
  let commit = desktop.commit(at: 1)
  desktop.stray(window(110), display: 0)

  let shown = desktop.displays.map(\.shown)
  let plan = try #require(
    TopologyRestore.plan(
      commit, observed: desktop.observed, target: desktop.target, pinned: [],
      skipping: [window(110)], visible: { shown[$0] }))

  #expect(plan.moves.isEmpty)
}

@Test func anExtraWithUnknownWindowsIsNotDestroyed() throws {
  var desktop = Desktop()
  let commit = desktop.commit(at: 1)
  desktop.displays[0].spaces.append(
    Desktop.Space(id: desktop.newID(), uuid: "extra", windows: [window(9999)]))

  let shown = desktop.displays.map(\.shown)
  let plan = try #require(
    TopologyRestore.plan(
      commit, observed: desktop.observed, target: desktop.target, pinned: [],
      visible: { shown[$0] }))

  #expect(plan.spacesAreDone)
  #expect(plan.binding.extras == ["extra"])
}

@Test func anEmptyExtraGoesAndAnEmptySlotStays() throws {
  var desktop = Desktop()
  desktop.displays[0].spaces[4].windows = []
  let commit = desktop.commit(at: 1)
  let extra = desktop.newID()
  desktop.displays[0].spaces.insert(
    Desktop.Space(id: extra, uuid: "extra", windows: []), at: 2)

  let shown = desktop.displays.map(\.shown)
  let plan = try #require(
    TopologyRestore.plan(
      commit, observed: desktop.observed, target: desktop.target, pinned: [],
      visible: { shown[$0] }))

  #expect(plan.step == .destroy(extra, on: 0))
}

@Test func aLayoutWithAnotherNumberOfSpacesHasNoPlan() {
  let desktop = Desktop()
  let commit = desktop.commit(at: 1)

  #expect(
    TopologyRestore.plan(
      commit, observed: desktop.observed, target: [15], pinned: [], visible: { _ in nil }) == nil)
}

@Test func theActiveSpaceIsShownAndTheOthersShowWhatTheyShowedLast() throws {
  let desktop = Desktop()
  var commit = desktop.commit(at: 1)
  commit.active = "space-3"
  commit.shown = ["D1": "space-1", "D2": "space-12"]

  let binding = TopologyRestore.bind(
    commit, displays: desktop.displays.map(\.uuid),
    spaces: desktop.displays.map { $0.spaces.map(\.uuid) }, windows: { _ in [] })
  let shown = TopologyRestore.shown(commit, binding: binding, observed: desktop.observed)

  #expect(shown == [0: SpaceID(rawValue: 3), 1: SpaceID(rawValue: 12)])
}

@Test func aShownStandInStillCountsAfterTheOriginalReturned() throws {
  var former = slot("stand-in")
  former.formerUUIDs = ["original"]
  var commit = commit(1, [former], active: "original")
  commit.shown = ["d1": "original"]

  let sid = SpaceID(rawValue: 7)
  let observed = TopologyObserved(
    displays: ["d1"], spaces: [[sid]], user: [[true]], uuids: [sid: "original"],
    windows: [sid: []])
  let binding = TopologyBinding(spaces: ["original"], extras: [])

  #expect(TopologyRestore.shown(commit, binding: binding, observed: observed) == [0: sid])
}

//
// NOTE: Any order of displays going and coming, with windows straying on the way, ends with every window on its slot and
// the spaces the layout asks for.
//

@Test(arguments: 0..<200)
func theDesktopSurvivesAnySequenceOfDisplayChanges(seed: Int) throws {
  var numbers = Numbers(state: UInt64(seed) &* 2_654_435_761 &+ 1)
  var desktop = Desktop()
  var ledger = TopologyLedger()
  let slots = desktop.slots
  let windows = desktop.allWindows
  var time = 1.0

  ledger.add(desktop.commit(at: time))

  for _ in 0..<(2 + numbers.next(6)) {
    let connected = desktop.displays.map(\.uuid)
    let missing = Desktop.order.filter { !connected.contains($0) }

    // NOTE: A change can be one display or two at once, before the restore gets to run.
    for _ in 0...numbers.next(2) {
      let connected = desktop.displays.map(\.uuid)
      if connected.count > 1, missing.isEmpty || numbers.next(2) == 0 {
        desktop.remove(connected[numbers.next(connected.count)])
      } else if let uuid = desktop.lost.first?.display {
        desktop.restore(uuid)
      }
    }

    for _ in 0..<numbers.next(4) {
      desktop.stray(
        windows[numbers.next(windows.count)], display: numbers.next(desktop.displays.count))
    }

    time += 1
    let commit = try #require(ledger.commit(before: time))
    let restored = desktop.restore(to: commit)
    let (binding, passes) = try #require(restored)

    #expect(passes < 100)
    expectBack(desktop, slots: slots)

    ledger.adopt(binding, of: commit)
    time += 1
    ledger.add(desktop.commit(at: time))
  }

  #expect(Set(desktop.allWindows) == Set(windows))
  #expect(desktop.allWindows.count == windows.count)
}
