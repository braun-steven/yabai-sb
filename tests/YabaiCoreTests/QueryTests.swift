import CoreGraphics
import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

// NOTE: Ported from tests/src/window_info.c.

private func windowInfoFixture() -> WindowInfo {
  var info = WindowInfo(id: 42)
  info.app = "Text\"Edit"
  info.title = "a\tb"
  info.split = .x
  info.isVisible = true
  return info
}

private let queryCommandRows: [(String, QueryCommand)] = [
  (
    "--windows\0id,frame\0--space\0recent\0",
    .windows(properties: [.id, .frame], target: .space(.recent))
  ),
  (
    "--displays\0--display\0west\0",
    .displays(properties: Set(DisplayInfo.Key.allCases), target: .display(.direction(.west)))
  ),
  ("--spaces\0--window\0", .spaces(properties: Set(SpaceInfo.Key.allCases), target: .window(nil))),
  ("--windows\0id\0", .windows(properties: [.id], target: .all)),
  ("--tree\0--space\0recent\0", .tree(space: .recent)),
  ("--tree\0", .tree(space: nil)),
]

@Test(arguments: queryCommandRows)
func queryCommandPropertiesAndTargets(_ text: String, _ command: QueryCommand) throws {
  var message = Message(text)
  #expect(try QueryCommand.parse(&message) == command)
}

private let queryCommandFailureRows: [(String, String)] = [
  ("--unknown\0", "unknown command '--unknown' for domain 'query'\n"),
  ("--windows\0bogus\0", "'bogus' is not a valid property.\n"),
  (
    "--windows\0--other\0",
    "unknown option '--other' given to command '--windows' for domain 'query'\n"
  ),
  (
    "--tree\0--window\0", "unknown option '--window' given to command '--tree' for domain 'query'\n"
  ),
]

@Test(arguments: queryCommandFailureRows)
func queryCommandFailure(_ text: String, _ failure: String) {
  var message = Message(text)
  #expect(
    queryThrownText { () throws(CommandError) in _ = try QueryCommand.parse(&message) } == failure)
}

private func json(_ value: some Encodable) throws -> String {
  String(decoding: try JSON.encode(value), as: UTF8.self)
}

@Test func windowInfoEncodesOnlySelectedKeysSorted() throws {
  var info = windowInfoFixture()
  info.properties = [.title, .id, .app]
  #expect(try json(info) == "{\"app\":\"Text\\\"Edit\",\"id\":42,\"title\":\"a\\tb\"}")

  info.properties = [.splitType, .isVisible, .frame]
  info.frame = CGRect(x: 0, y: 25, width: 1512.5, height: 957)
  #expect(
    try json(info)
      == "{\"frame\":{\"h\":957,\"w\":1512.5,\"x\":0,\"y\":25},\"is-visible\":true,\"split-type\":\"horizontal\"}"
  )
}

// NOTE: every property that `query --windows` can select is written under its own name.
@Test func windowInfoEncodesEveryKey() throws {
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(try JSON.encode(windowInfoFixture())))
      as? [String: Any])
  #expect(Set(object.keys) == Set(WindowInfo.Key.allCases.map(\.rawValue)))
  #expect(object.count == 33)
}

@Test func displayAndSpaceInfoEncodeSelectedKeys() throws {
  var display = DisplayInfo(id: 1, properties: [.id, .spaces, .hasFocus])
  display.spaces = [1, 2]
  display.hasFocus = true
  #expect(try json(display) == "{\"has-focus\":true,\"id\":1,\"spaces\":[1,2]}")

  var space = SpaceInfo(id: 3, properties: [.windows, .firstWindow, .lastWindow, .label])
  space.windows = [7, 8]
  space.lastWindow = 8
  space.label = "web/dev"
  #expect(
    try json(space)
      == "{\"first-window\":0,\"label\":\"web/dev\",\"last-window\":8,\"windows\":[7,8]}")

  // NOTE: pinned-display is the arrangement index of the display the space is pinned to, 0 without one.
  var pinned = SpaceInfo(id: 4, properties: [.id, .pinnedDisplay])
  #expect(try json(pinned) == "{\"id\":4,\"pinned-display\":0}")
  pinned.pinnedDisplay = 2
  #expect(try json(pinned) == "{\"id\":4,\"pinned-display\":2}")
}

@Test func treeNodeWritesNullLayoutForWindows() throws {
  let leaf = TreeNode(
    type: .window, layout: nil, percent: 0.5, window: 7, frame: Area(x: 0, y: 0, w: 10, h: 20),
    focused: true, selected: false, visible: true, nodes: [])
  let root = TreeNode(
    type: .workspace, layout: "splith", percent: 1, window: nil, frame: .zero, focused: false,
    selected: false, visible: true, nodes: [leaf])
  #expect(
    try json(root)
      == "{\"focused\":false,\"frame\":{\"h\":0,\"w\":0,\"x\":0,\"y\":0},\"layout\":\"splith\",\"nodes\":[{\"focused\":true,\"frame\":{\"h\":20,\"w\":10,\"x\":0,\"y\":0},\"layout\":null,\"nodes\":[],\"percent\":0.5,\"selected\":false,\"type\":\"window\",\"visible\":true,\"window\":7}],\"percent\":1,\"selected\":false,\"type\":\"workspace\",\"visible\":true,\"window\":0}"
  )
}

@Test func ruleInfoEncodesSortedKeysWithNullForUnsetProperties() throws {
  var rule = Rule()
  rule.label = "a/b"
  rule.effects.manage = false
  rule.effects.grid = Grid(4, 4, 0, 0, 2, 2)
  #expect(
    try json(rule.info(index: 0, display: 0, space: 2))
      == "{\"app\":\"\",\"display\":0,\"flags\":\"0x0\",\"follow_space\":false,\"grid\":\"4:4:0:0:2:2\",\"index\":0,\"insert\":\"\",\"label\":\"a/b\",\"manage\":false,\"mouse_follows_focus\":null,\"native-fullscreen\":null,\"one-shot\":false,\"opacity\":0,\"role\":\"\",\"scratchpad\":\"\",\"space\":2,\"sticky\":null,\"sub-layer\":\"\",\"subrole\":\"\",\"title\":\"\"}"
  )
}

private func queryThrownText(_ body: () throws(CommandError) -> Void) -> String? {
  do { try body() } catch { return error.description }
  return nil
}
