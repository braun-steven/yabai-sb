import CoreGraphics
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

@Suite struct DisplayManagerTests {
  static let builtinLastRows: [([String], Bool, [String])] = [
    (["builtin", "a", "b"], true, ["a", "b", "builtin"]),
    (["a", "builtin", "b"], true, ["a", "b", "builtin"]),
    (["a", "b", "builtin"], true, ["a", "b", "builtin"]),
    // only the first builtin display moves
    (["builtin", "builtin", "a"], true, ["builtin", "a", "builtin"]),
    (["a", "b"], true, ["a", "b"]),
    (["builtin"], true, ["builtin"]),
    ([], true, []),
    (["builtin", "a", "b"], false, ["builtin", "a", "b"]),
  ]

  @Test(arguments: builtinLastRows)
  func builtinDisplayMovesLast(_ list: [String], _ enabled: Bool, _ expected: [String]) {
    #expect(
      DisplayManager.orderedBuiltinLast(list, enabled: enabled) { $0 == "builtin" } == expected)
  }

  // The arrangement of the window server's displays: the sort, then builtin_display_last.
  @Test func arrangementThenBuiltinLast() {
    let placements = [
      DisplayArrangement.Placement(uuid: "builtin", center: CGPoint(x: 0, y: 0)),
      DisplayArrangement.Placement(uuid: "b", center: CGPoint(x: 300, y: 0)),
      DisplayArrangement.Placement(uuid: "a", center: CGPoint(x: 100, y: 0)),
    ]
    let sorted = DisplayArrangement.sorted(placements, vertical: false)
    #expect(
      DisplayManager.orderedBuiltinLast(sorted, enabled: true) { $0 == "builtin" } == [
        "a", "b", "builtin",
      ])
    #expect(
      DisplayManager.orderedBuiltinLast(sorted, enabled: false) { $0 == "builtin" } == [
        "builtin", "a", "b",
      ])
  }
}
