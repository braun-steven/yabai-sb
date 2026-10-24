import Testing
import YabaiTestSupport

@testable import YabaiCore

// NOTE: Ported from tests/src/space_layout.c.

@Test("space_layout_parse") func spaceLayoutParse() throws {
  var layout = try #require(SpaceLayout(parsing: "15"))
  #expect(layout.count == 1)
  #expect(layout.target[0] == 15)
  #expect(layout.builtinIndex == nil)

  layout = try #require(SpaceLayout(parsing: "10:5"))
  #expect(layout.count == 2)
  #expect(layout.target[0] == 10)
  #expect(layout.target[1] == 5)

  layout = try #require(SpaceLayout(parsing: "10:5:1b"))
  #expect(layout.count == 3)
  #expect(layout.target[2] == 1)
  #expect(layout.builtinIndex == 2)

  for text in ["", "0", "10:", ":10", "10::5", "10:x", "b", "1b:2b", "1:1:1:1:1:1:1:1:1"] {
    #expect(SpaceLayout(parsing: text) == nil, "\(text)")
  }
}

@Test("space_layout_targets") func spaceLayoutTargets() throws {
  var layout = try #require(SpaceLayout(parsing: "10:5"))
  #expect(layout.targets(builtin: nil) == [10, 5])

  layout = try #require(SpaceLayout(parsing: "10:5:1b"))
  #expect(layout.targets(builtin: 2) == [10, 5, 1])
  #expect(layout.targets(builtin: 0) == [1, 10, 5])
  #expect(layout.targets(builtin: 1) == [10, 1, 5])
  #expect(layout.targets(builtin: nil) == [10, 5, 1])

  layout = try #require(SpaceLayout(parsing: "1b:10:5"))
  #expect(layout.targets(builtin: 2) == [10, 5, 1])
}

// NOTE: The display holds the spaces 1..n, one per character of the mask, and 'u' marks a user space.
private func spaceTestLists(_ mask: String) -> ([SpaceID], [Bool]) {
  ((0..<mask.count).map { SpaceID(UInt64($0 + 1)) }, mask.map { $0 == "u" })
}

private func moveReplacement(_ mask: String, _ sid: SpaceID, _ visible: SpaceID) -> SpaceID? {
  let (spaces, user) = spaceTestLists(mask)
  return SpaceList.moveReplacement(spaces: spaces, user: user, sid: sid, visible: visible)
}

private func moveCandidate(_ mask: String, _ visible: SpaceID, _ fromEnd: Bool) -> SpaceID? {
  let (spaces, user) = spaceTestLists(mask)
  return SpaceLayout.moveCandidate(spaces: spaces, user: user, visible: visible, fromEnd: fromEnd)
}

@Test("space_move_replacement") func spaceMoveReplacement() {
  // NOTE: The regression: a visible space is replaced even when it is not the focused space,
  // so the scripting addition hides it before the move and it never stays shown on the
  // destination display as a second menubar.
  #expect(moveReplacement("uuuu", 1, 1) == 2)
  #expect(moveReplacement("uuuu", 3, 3) == 2)
  #expect(moveReplacement("uuuu", 4, 4) == 3)

  // A hidden space needs no replacement.
  #expect(moveReplacement("uuuu", 2, 1) == nil)

  // The replacement is always a user space on the same display.
  #expect(moveReplacement("-u-u", 2, 2) == 4)
  #expect(moveReplacement("-u-u", 4, 4) == 2)
  #expect(moveReplacement("u", 1, 1) == nil)
}

@Test("space_layout_move_candidate") func spaceLayoutMoveCandidate() {
  // The visible space is skipped, from either edge.
  #expect(moveCandidate("uuuu", 3, false) == 1)
  #expect(moveCandidate("uuuu", 1, false) == 2)
  #expect(moveCandidate("uuuu", 3, true) == 4)
  #expect(moveCandidate("uuuu", 4, true) == 3)

  #expect(moveCandidate("-uu-", 2, false) == 3)
  #expect(moveCandidate("-uu-", 3, true) == 2)

  // The visible space is only moved when it is the only user space.
  #expect(moveCandidate("-u--", 2, false) == 2)
  #expect(moveCandidate("----", 2, false) == nil)
}

// NOTE: Display i holds the spaces 10i+1..10i+n, one per character of its mask, and 'u' marks a user space. isEmpty
// records each space it is asked about.
private func reconcileStep(
  _ masks: [String], target: [Int], visible: [SpaceID?] = [], pinned: Set<SpaceID> = [],
  empty: Set<SpaceID> = [], asked: inout [SpaceID]
) -> SpaceLayoutStep {
  let spaces = masks.indices.map { i in
    (0..<masks[i].count).map { SpaceID(UInt64(10 * i + $0 + 1)) }
  }
  var queries: [SpaceID] = []
  defer { asked = queries }
  return SpaceLayout.reconcileStep(
    target: target, spaces: spaces, user: masks.map { $0.map { $0 == "u" } }, pinned: pinned,
    visible: { $0 < visible.count ? visible[$0] : nil },
    isEmpty: { sid in
      queries.append(sid)
      return empty.contains(sid)
    })
}

private func reconcileStep(
  _ masks: [String], target: [Int], visible: [SpaceID?] = [], pinned: Set<SpaceID> = [],
  empty: Set<SpaceID> = []
) -> SpaceLayoutStep {
  var asked: [SpaceID] = []
  return reconcileStep(
    masks, target: target, visible: visible, pinned: pinned, empty: empty, asked: &asked)
}

@Test func spaceLayoutReconcileMovesAndCreates() {
  #expect(reconcileStep(["u", "u"], target: [1, 1]) == .done)

  // The first unpinned, non-visible user space moves towards a later display.
  #expect(
    reconcileStep(["uuu-", "u"], target: [2, 2], visible: [2], pinned: [1])
      == .move(3, from: 0, to: 1))
  #expect(
    reconcileStep(["u", "uuu"], target: [2, 2], visible: [nil, 13]) == .move(11, from: 1, to: 0))

  #expect(reconcileStep(["u", "u"], target: [1, 2]) == .create(on: 1, pinnedDisplay: nil))
  #expect(
    reconcileStep(["uu", "u"], target: [1, 2], visible: [1], pinned: [1, 2])
      == .create(on: 1, pinnedDisplay: 0))
}

@Test func spaceLayoutReconcileDestroysTheLastEmptySpaceAndAsksTheVisibleOneLast() {
  var asked: [SpaceID] = []
  #expect(
    reconcileStep(
      ["uuuu-"], target: [1], visible: [4], pinned: [2], empty: [1, 3, 4], asked: &asked)
      == .destroy(3, on: 0))
  #expect(asked == [3])

  #expect(
    reconcileStep(["uuu"], target: [1], visible: [3], empty: [3], asked: &asked)
      == .destroy(3, on: 0))
  #expect(asked == [2, 1, 3])

  #expect(reconcileStep(["uuu"], target: [1], visible: [3], asked: &asked) == .keep(display: 0))
  #expect(asked == [2, 1, 3])
}

@Test func spaceLayoutReconcileKeepsTheLastUserSpaceAndPinnedSpaces() {
  var asked: [SpaceID] = []
  #expect(reconcileStep(["-u-"], target: [0], empty: [2], asked: &asked) == .keep(display: 0))
  #expect(asked.isEmpty)

  #expect(
    reconcileStep(["uu"], target: [1], pinned: [1, 2], empty: [1, 2], asked: &asked)
      == .keep(display: 0))
  #expect(asked.isEmpty)
}
