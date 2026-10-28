import CoreGraphics
import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

// NOTE: Ported from tests/src/window_info.c.

private func windowInfoFixture(properties: Set<WindowInfo.Key> = Set(WindowInfo.Key.allCases))
  -> WindowInfo
{
  var info = WindowInfo(id: 42, properties: properties)
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
  ("--scripting-addition\0", .scriptingAddition),
]

@Test(arguments: queryCommandRows)
func queryCommandPropertiesAndTargets(_ text: String, _ command: QueryCommand) throws {
  var message = Message(text)
  #expect(try QueryCommand.parse(&message) == command)
}

private let queryCommandFailureRows: [(String, String)] = [
  (
    "--windows\0id\0--window\01\0extra\0",
    "unknown argument 'extra' given to command '--windows' for domain 'query'\n"
  ),
  (
    "--tree\0--space\0recent\0extra\0",
    "unknown argument 'extra' given to command '--tree' for domain 'query'\n"
  ),
  (
    "--tree\0--space\0recent\0\0",
    "unknown argument '' given to command '--tree' for domain 'query'\n"
  ),
  ("--unknown\0", "unknown command '--unknown' for domain 'query'\n"),
  ("--windows\0bogus\0", "'bogus' is not a valid property.\n"),
  (
    "--windows\0--other\0",
    "unknown option '--other' given to command '--windows' for domain 'query'\n"
  ),
  (
    "--tree\0--window\0", "unknown option '--window' given to command '--tree' for domain 'query'\n"
  ),
  (
    "--scripting-addition\0--space\0",
    "unknown argument '--space' given to command '--scripting-addition' for domain 'query'\n"
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
  let info = windowInfoFixture(properties: [.title, .id, .app])
  #expect(try json(info) == "{\"app\":\"Text\\\"Edit\",\"id\":42,\"title\":\"a\\tb\"}")

  var selected = windowInfoFixture(properties: [.splitType, .isVisible, .frame])
  selected.frame = CGRect(x: 0, y: 25, width: 1512.5, height: 957)
  #expect(
    try json(selected)
      == "{\"frame\":{\"h\":957,\"w\":1512.5,\"x\":0,\"y\":25},\"is-visible\":true,\"split-type\":\"horizontal\"}"
  )
}

// NOTE: every property that `query --windows` can select is written under its own name.
@Test func windowInfoEncodesEveryKey() throws {
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(try JSON.encode(windowInfoFixture())))
      as? [String: Any])
  #expect(Set(object.keys) == Set(WindowInfo.Key.allCases.map(\.rawValue)))
  #expect(object.count == 32)
}

// NOTE: every property that `query --displays` and `query --spaces` can select is written under its own name.
@Test func displayAndSpaceInfoEncodeEveryKey() throws {
  let display = try #require(
    try JSONSerialization.jsonObject(with: Data(try JSON.encode(DisplayInfo(id: 1))))
      as? [String: Any])
  #expect(Set(display.keys) == Set(DisplayInfo.Key.allCases.map(\.rawValue)))
  #expect(display.count == 7)

  let space = try #require(
    try JSONSerialization.jsonObject(with: Data(try JSON.encode(SpaceInfo(id: 3))))
      as? [String: Any])
  #expect(Set(space.keys) == Set(SpaceInfo.Key.allCases.map(\.rawValue)))
  #expect(space.count == 13)
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

@Test func scriptingAdditionInfoEncodesEveryCapabilityAndNullForUnknownValues() throws {
  let loaded = ScriptingAdditionInfo(
    embedded: "2.1.42", installed: "2.1.42", loaded: "2.1.42", attributes: 0x5f,
    dockUUID: "3BDF6A3B-866B-3C07-920C-E9E7FB57B56B", dockBuildKnown: true, sipCompatible: true)
  #expect(
    try json(loaded)
      == "{\"capabilities\":{\"add-space\":true,\"animation-patch\":true,\"desktop-picture-manager\":true,\"dock-spaces\":true,\"move-space\":true,\"remove-space\":true},\"dock-build-known\":true,\"dock-uuid\":\"3BDF6A3B-866B-3C07-920C-E9E7FB57B56B\",\"embedded\":\"2.1.42\",\"installed\":\"2.1.42\",\"is-current\":true,\"loaded\":\"2.1.42\",\"sip-compatible\":true}"
  )
  // No payload answers: every capability is false, and what only the payload knows is null.
  let absent = ScriptingAdditionInfo(
    embedded: "2.1.42", installed: nil, loaded: nil, attributes: nil, dockUUID: nil,
    dockBuildKnown: nil, sipCompatible: false)
  #expect(
    try json(absent)
      == "{\"capabilities\":{\"add-space\":false,\"animation-patch\":false,\"desktop-picture-manager\":false,\"dock-spaces\":false,\"move-space\":false,\"remove-space\":false},\"dock-build-known\":null,\"dock-uuid\":null,\"embedded\":\"2.1.42\",\"installed\":null,\"is-current\":false,\"loaded\":null,\"sip-compatible\":false}"
  )
}

@Test func ruleInfoEncodesSortedKeysWithNullForUnsetProperties() throws {
  var rule = Rule()
  rule.label = "a/b"
  rule.effects.manage = false
  rule.effects.grid = Grid(4, 4, 0, 0, 2, 2)
  #expect(
    try json(rule.info(index: 0, display: 0, space: 2))
      == "{\"app\":\"\",\"display\":0,\"flags\":\"0x0\",\"follow_space\":false,\"grid\":\"4:4:0:0:2:2\",\"index\":0,\"insert\":\"\",\"label\":\"a/b\",\"manage\":false,\"mouse_follows_focus\":null,\"native-fullscreen\":null,\"one-shot\":false,\"role\":\"\",\"scratchpad\":\"\",\"space\":2,\"sticky\":null,\"sub-layer\":\"\",\"subrole\":\"\",\"title\":\"\"}"
  )
}

private func queryThrownText(_ body: () throws(CommandError) -> Void) -> String? {
  do { try body() } catch { return error.description }
  return nil
}

@Test(arguments: WindowInfo.Key.allCases)
func everyWindowPropertyCanBeSelectedAlone(_ key: WindowInfo.Key) throws {
  let bytes = try JSON.encode(windowInfoFixture(properties: [key]))
  let value = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
  #expect(Set(value?.keys.map { $0 } ?? []) == [key.rawValue])
}

@Test(arguments: DisplayInfo.Key.allCases)
func everyDisplayPropertyCanBeSelectedAlone(_ key: DisplayInfo.Key) throws {
  let value =
    try JSONSerialization.jsonObject(
      with: Data(try JSON.encode(DisplayInfo(id: 1, properties: [key])))) as? [String: Any]
  #expect(Set(value?.keys.map { $0 } ?? []) == [key.rawValue])
}

@Test(arguments: SpaceInfo.Key.allCases)
func everySpacePropertyCanBeSelectedAlone(_ key: SpaceInfo.Key) throws {
  let value =
    try JSONSerialization.jsonObject(
      with: Data(try JSON.encode(SpaceInfo(id: 1, properties: [key])))) as? [String: Any]
  #expect(Set(value?.keys.map { $0 } ?? []) == [key.rawValue])
}
