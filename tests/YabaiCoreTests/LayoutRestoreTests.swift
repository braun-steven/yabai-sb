import Foundation
import Testing
import YabaiTestSupport

@testable import YabaiCore

//
// NOTE: The pure parts of space --restore-layout: the checks of a layout file, the matching of its slots with windows, and
// the tree that the matched slots make. The daemon tests (tests/YabaiTests/LayoutRestoreTests.swift) cover the rest.
//

private func matcher(
  _ app: String, bundle: String? = nil, title: String? = nil, role: String? = "AXWindow",
  subrole: String? = "AXStandardWindow"
) -> LayoutMatcher {
  LayoutMatcher(bundleID: bundle, app: app, title: title, role: role, subrole: subrole)
}

struct LayoutAssignRow: Sendable, CustomTestStringConvertible {
  var name: String
  var slots: [LayoutMatcher?]
  var windows: [LayoutMatcher]
  var expected: [Int?]

  var testDescription: String { name }
}

private let assignRows: [LayoutAssignRow] = [
  LayoutAssignRow(
    name: "two slots of one app take the windows by title",
    slots: [matcher("Notes", title: "A"), matcher("Notes", title: "B")],
    windows: [matcher("Notes", title: "B"), matcher("Notes", title: "A")], expected: [1, 0]),
  LayoutAssignRow(
    name: "a window is used once",
    slots: [matcher("Notes", title: "Draft"), matcher("Notes", title: "Draft")],
    windows: [matcher("Notes", title: "Draft")], expected: [0, nil]),
  LayoutAssignRow(
    name: "an application that is not open matches nothing",
    slots: [matcher("Safari", title: "x")], windows: [matcher("Notes", title: "x")],
    expected: [nil]),
  LayoutAssignRow(
    name: "a changed title matches by its prefix",
    slots: [matcher("Notes", title: "Report 2025 draft")],
    windows: [matcher("Notes", title: "Other"), matcher("Notes", title: "Report 2025 final")],
    expected: [1]),
  LayoutAssignRow(
    name: "an exact title beats a longer prefix",
    slots: [matcher("Notes", title: "Report")],
    windows: [matcher("Notes", title: "Report draft"), matcher("Notes", title: "Report")],
    expected: [1]),
  LayoutAssignRow(
    name: "the longer common prefix wins",
    slots: [matcher("Notes", title: "Inbox 3")],
    windows: [matcher("Notes", title: "Inbox 12"), matcher("Notes", title: "Inbox 3 new")],
    expected: [1]),
  LayoutAssignRow(
    name: "a nil title matches a nil title exactly",
    slots: [matcher("Notes", title: nil)],
    windows: [matcher("Notes", title: "X"), matcher("Notes", title: nil)], expected: [1]),
  LayoutAssignRow(
    name: "a slot without a bundle id matches by application name",
    slots: [matcher("Terminal", bundle: nil)],
    windows: [matcher("Terminal", bundle: "com.apple.Terminal")], expected: [0]),
  LayoutAssignRow(
    name: "a window without a bundle id matches by application name",
    slots: [matcher("Terminal", bundle: "com.apple.Terminal")], windows: [matcher("Terminal")],
    expected: [0]),
  LayoutAssignRow(
    name: "different bundle ids do not match, whatever the names",
    slots: [matcher("Terminal", bundle: "com.a")],
    windows: [matcher("Terminal", bundle: "com.b")], expected: [nil]),
  LayoutAssignRow(
    name: "the role breaks a tie",
    slots: [matcher("Notes", title: "T", role: "AXSheet", subrole: nil)],
    windows: [
      matcher("Notes", title: "T", role: "AXWindow", subrole: nil),
      matcher("Notes", title: "T", role: "AXSheet", subrole: nil),
    ], expected: [1]),
  LayoutAssignRow(
    name: "the subrole breaks a tie of the role",
    slots: [matcher("Notes", title: "T", role: "AXWindow", subrole: "AXDialog")],
    windows: [
      matcher("Notes", title: "T", role: "AXWindow", subrole: "AXStandardWindow"),
      matcher("Notes", title: "T", role: "AXWindow", subrole: "AXDialog"),
    ], expected: [1]),
  LayoutAssignRow(
    name: "more windows than slots",
    slots: [matcher("Notes", title: "A")],
    windows: [matcher("Notes", title: "B"), matcher("Notes", title: "A")], expected: [1]),
  LayoutAssignRow(
    name: "more slots than windows",
    slots: [
      matcher("Notes", title: "A"), matcher("Notes", title: "B"), matcher("Notes", title: "C"),
    ],
    windows: [matcher("Notes", title: "C")], expected: [nil, nil, 0]),
  LayoutAssignRow(
    name: "ties go to the lower slot, then to the lower window",
    slots: [matcher("Notes", title: nil), matcher("Notes", title: nil)],
    windows: [matcher("Notes", title: nil), matcher("Notes", title: nil)], expected: [0, 1]),
  LayoutAssignRow(
    name: "a slot without a matcher is left empty",
    slots: [nil, matcher("Notes", title: "A")], windows: [matcher("Notes", title: "A")],
    expected: [nil, 0]),
  LayoutAssignRow(
    name: "no slots and no windows",
    slots: [], windows: [], expected: []),
]

@Suite("layout matching")
struct LayoutMatchingTests {
  @Test(arguments: assignRows)
  func assignment(_ row: LayoutAssignRow) {
    #expect(LayoutMatching.assign(slots: row.slots, windows: row.windows) == row.expected)
  }
}

//
// NOTE: The file of the fixture tree is splith [ w1, tabbed [ splitv [ w2, w3 ], w4 ] ], with w3 saved without a matcher.
// Its slots are w1, w2, nil and w4, in pre-order.
//

private let fixtureIDs = [WindowID(rawValue: 1), WindowID(rawValue: 2), WindowID(rawValue: 4)]

/// One line per container and window, indented by depth, like treeDump in the daemon tests: the layout, the share and
/// the focus order when it differs from the children's order.
private func describe(_ node: TreeSnapshot, depth: Int = 0) -> [String] {
  var line = String(repeating: "  ", count: depth)
  if let windowID = node.windowID {
    line += "w\(windowID.rawValue)"
  } else {
    line += node.layout.rawValue
    if node.layout == .tabbed { line += "(\(node.lastSplit.rawValue))" }
  }
  if depth > 0 { line += String(format: " %.4f", node.percent) }
  if node.focusOrder != Array(node.children.indices) {
    line += " focus=" + node.focusOrder.map(String.init).joined(separator: ",")
  }

  return [line] + node.children.flatMap { describe($0, depth: depth + 1) }
}

private func restored(_ file: LayoutFile, _ assignment: [Int?], ids: [WindowID] = fixtureIDs)
  -> String?
{
  file.restoredTree(assignment: assignment, windowIDs: ids).map {
    describe($0).joined(separator: "\n")
  }
}

@Suite("layout tree")
struct LayoutTreeTests {
  private let file = LayoutFile(snapshot: LayoutFixtures.tree, matcher: LayoutFixtures.matcher)

  @Test func everySlotMatchedKeepsTheShape() {
    // NOTE: w3 has no matcher, so its container keeps w2 alone, which takes the share of that container.
    #expect(
      restored(file, [0, 1, nil, 2])
        == """
        splith focus=1,0
          w1 0.4000
          tabbed(splitv) 0.6000 focus=1,0
            w2 0.5000
            w4 0.5000
        """)
  }

  @Test func droppedSlotsCollapseTheirContainers() {
    // NOTE: Both windows of the splitv are gone, so the tabbed container is left with w4 alone.
    #expect(
      restored(file, [0, nil, nil, 2])
        == """
        splith focus=1,0
          w1 0.4000
          w4 0.6000
        """)
  }

  @Test func containerWithOneChildGivesItsPlaceAndTheSharesAreNormalized() {
    #expect(
      restored(file, [nil, 0, nil, 1])
        == """
        splith
          tabbed(splitv) 1.0000 focus=1,0
            w1 0.5000
            w2 0.5000
        """)
  }

  @Test func oneWindowLeftKeepsTheRootContainer() {
    #expect(
      restored(file, [0, nil, nil, nil])
        == """
        splith
          w1 1.0000
        """)
  }

  @Test func nothingMatchedGivesNoTree() {
    #expect(restored(file, [nil, nil, nil, nil]) == nil)
  }

  @Test func focusOrderKeepsTheRelativeOrderOfTheKeptChildren() {
    // NOTE: The middle child is dropped; the focus order was [2, 0, 1], so the kept children go in the order [1, 0].
    let leafNode = { (windowID: UInt32, percent: Float) in
      LayoutFile.Node(
        layout: .splitH, lastSplit: .splitH, percent: percent, zoom: .none, focusOrder: [],
        window: matcher("Notes", title: "\(windowID)"), children: [])
    }
    let custom = LayoutFile(
      tree: LayoutFile.Node(
        layout: .splitH, lastSplit: .splitH, percent: 0, zoom: .none, focusOrder: [2, 0, 1],
        window: nil, children: [leafNode(1, 0.2), leafNode(2, 0.3), leafNode(3, 0.5)]))

    #expect(
      restored(custom, [0, nil, 1], ids: [WindowID(rawValue: 1), WindowID(rawValue: 3)])
        == """
        splith focus=1,0
          w1 0.2857
          w3 0.7143
        """)
  }

  @Test func aFileThatIsOneWindowGetsTheContainerOfOneWindow() {
    let single = LayoutFile(
      tree: LayoutFile.Node(
        layout: .splitV, lastSplit: .splitV, percent: 0, zoom: .none, focusOrder: [],
        window: matcher("Notes", title: "A"), children: []))

    #expect(
      restored(single, [0], ids: [WindowID(rawValue: 1)])
        == """
        splitv
          w1 1.0000
        """)
  }
}

//
// NOTE: The checks of a file. Each row is a file and the start of the failure text; the text names the path, since the
// daemon prints it as it is.
//

private func node(
  layout: String = "splith", percent: String = "1", window: String = "null",
  children: String = "[]", focusOrder: String = "[]"
) -> String {
  #"{"layout":"\#(layout)","lastSplit":"splith","percent":\#(percent),"zoom":"none","focusOrder":\#(focusOrder),"window":\#(window),"children":\#(children)}"#
}

private let windowJSON = #"{"app":"Notes"}"#
private let leaf = node(percent: "0.5", window: windowJSON)

private func layout(_ tree: String, version: Int = 1) -> Data {
  Data(#"{"version":\#(version),"tree":\#(tree)}"#.utf8)
}

struct LayoutFileRow: Sendable, CustomTestStringConvertible {
  var name: String
  var data: Data
  var failure: String

  var testDescription: String { name }
}

private let fileRows: [LayoutFileRow] = [
  LayoutFileRow(
    name: "a version of another number",
    data: layout(leaf, version: 2),
    failure: "'work.json' has layout version 2; this yabai reads version 1\n"),
  LayoutFileRow(
    name: "text that is not JSON",
    data: Data("nope".utf8), failure: "'work.json' is not a layout file: "),
  LayoutFileRow(
    name: "no version",
    data: Data(#"{"tree":\#(leaf)}"#.utf8), failure: "'work.json' is not a layout file: "),
  LayoutFileRow(
    name: "an unknown layout",
    data: layout(node(layout: "diagonal")), failure: "'work.json' is not a layout file: "),
  LayoutFileRow(
    name: "a share of zero",
    data: layout(node(children: "[\(node(percent: "0", window: windowJSON))]", focusOrder: "[0]")),
    failure:
      "'work.json' is not a layout file: tree.children[0] has percent 0.0; a share must be a number above 0\n"
  ),
  LayoutFileRow(
    name: "a negative share",
    data: layout(
      node(children: "[\(node(percent: "-0.5", window: windowJSON))]", focusOrder: "[0]")),
    failure:
      "'work.json' is not a layout file: tree.children[0] has percent -0.5; a share must be a number above 0\n"
  ),
  LayoutFileRow(
    name: "a window with children",
    data: layout(
      node(
        children: "[\(node(window: windowJSON, children: "[\(leaf)]", focusOrder: "[0]"))]",
        focusOrder: "[0]")),
    failure:
      "'work.json' is not a layout file: tree.children[0] has a window and children; a leaf has no children\n"
  ),
  LayoutFileRow(
    name: "a focus order that repeats a child",
    data: layout(node(children: "[\(leaf), \(leaf)]", focusOrder: "[0, 0]")),
    failure:
      "'work.json' is not a layout file: tree has a focus order that is not a permutation of its children\n"
  ),
  LayoutFileRow(
    name: "a focus order on a leaf",
    data: layout(
      node(
        children: "[\(node(percent: "0.5", window: windowJSON, focusOrder: "[0]"))]",
        focusOrder: "[0]")),
    failure:
      "'work.json' is not a layout file: tree.children[0] has a focus order but no children\n"
  ),
]

@Suite("layout file checks")
struct LayoutFileCheckTests {
  @Test(arguments: fileRows)
  func aBadFileIsRefusedWithItsPath(_ row: LayoutFileRow) {
    do {
      _ = try LayoutFile.validated(row.data, path: "work.json")
      Issue.record("the file was accepted")
    } catch {
      #expect(error.description.hasPrefix(row.failure))
    }
  }

  @Test func aRootShareOfZeroIsAccepted() throws {
    // NOTE: The root of a daemon tree has no share (its percent is 0), so the file of a space keeps it.
    let file = try LayoutFile.validated(
      layout(node(percent: "0", children: "[\(leaf), \(leaf)]", focusOrder: "[0, 1]")),
      path: "work.json")
    #expect(file.slots.count == 2)
  }

  @Test func slotsAreTheLeavesInPreOrder() throws {
    // NOTE: The second leaf is inside a container, after the first one; a decoded {"app":"Notes"} has no other fields.
    let inner = node(children: "[\(leaf)]", focusOrder: "[0]")
    let file = try LayoutFile.validated(
      layout(node(children: "[\(leaf), \(inner)]", focusOrder: "[0, 1]")), path: "work.json")

    let notes = LayoutMatcher(bundleID: nil, app: "Notes", title: nil, role: nil, subrole: nil)
    #expect(file.slots == [notes, notes])
  }
}
