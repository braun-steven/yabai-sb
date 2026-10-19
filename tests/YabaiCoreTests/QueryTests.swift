import CoreGraphics
import Foundation
import Testing
import YabaiCore

// NOTE: Ported from tests/src/window_info.c.

private func windowInfoFixture() -> WindowInfo
{
    var info = WindowInfo(id: 42)
    info.app = "Text\"Edit"
    info.title = "a\tb"
    info.split = .x
    info.isVisible = true
    return info
}

@Test func queryCommandPropertiesAndTargets() throws
{
    var message = Message("--windows\0id,frame\0--space\0recent\0")
    #expect(try QueryCommand.parse(&message) == .windows(properties: [.id, .frame], target: .space(.recent)))

    message = Message("--displays\0--display\0west\0")
    #expect(try QueryCommand.parse(&message) == .displays(properties: Set(DisplayInfo.Key.allCases), target: .display(.direction(.west))))

    message = Message("--spaces\0--window\0")
    #expect(try QueryCommand.parse(&message) == .spaces(properties: Set(SpaceInfo.Key.allCases), target: .window(nil)))

    message = Message("--windows\0id\0")
    #expect(try QueryCommand.parse(&message) == .windows(properties: [.id], target: .all))
}

@Test func queryCommandTreeSpaceSelector() throws
{
    var message = Message("--tree\0--space\0recent\0")
    #expect(try QueryCommand.parse(&message) == .tree(space: .recent))

    message = Message("--tree\0")
    #expect(try QueryCommand.parse(&message) == .tree(space: nil))
}

@Test func queryCommandErrors()
{
    var message = Message("--unknown\0")
    #expect(queryThrownText { () throws(CommandError) in _ = try QueryCommand.parse(&message) } == "unknown command '--unknown' for domain 'query'\n")

    message = Message("--windows\0bogus\0")
    #expect(queryThrownText { () throws(CommandError) in _ = try QueryCommand.parse(&message) } == "'bogus' is not a valid property.\n")

    message = Message("--windows\0--other\0")
    #expect(queryThrownText { () throws(CommandError) in _ = try QueryCommand.parse(&message) } == "unknown option '--other' given to command '--windows' for domain 'query'\n")

    message = Message("--tree\0--window\0")
    #expect(queryThrownText { () throws(CommandError) in _ = try QueryCommand.parse(&message) } == "unknown option '--window' given to command '--tree' for domain 'query'\n")
}

private func json(_ value: some Encodable) -> String
{
    String(decoding: JSON.encode(value), as: UTF8.self)
}

@Test func windowInfoEncodesOnlySelectedKeysSorted()
{
    var info = windowInfoFixture()
    info.properties = [.title, .id, .app]
    #expect(json(info) == "{\"app\":\"Text\\\"Edit\",\"id\":42,\"title\":\"a\\tb\"}")

    info.properties = [.splitType, .isVisible, .frame]
    info.frame = CGRect(x: 0, y: 25, width: 1512.5, height: 957)
    #expect(json(info) == "{\"frame\":{\"h\":957,\"w\":1512.5,\"x\":0,\"y\":25},\"is-visible\":true,\"split-type\":\"horizontal\"}")
}

// NOTE: every property that `query --windows` can select is written under its own name.
@Test func windowInfoEncodesEveryKey() throws
{
    let object = try #require(try JSONSerialization.jsonObject(with: Data(JSON.encode(windowInfoFixture()))) as? [String: Any])
    #expect(Set(object.keys) == Set(WindowInfo.Key.allCases.map(\.rawValue)))
    #expect(object.count == 32)
}

@Test func displayAndSpaceInfoEncodeSelectedKeys()
{
    var display = DisplayInfo(id: 1, properties: [.id, .spaces, .hasFocus])
    display.spaces = [1, 2]
    display.hasFocus = true
    #expect(json(display) == "{\"has-focus\":true,\"id\":1,\"spaces\":[1,2]}")

    var space = SpaceInfo(id: 3, properties: [.windows, .firstWindow, .lastWindow, .label])
    space.windows = [7, 8]
    space.lastWindow = 8
    space.label = "web/dev"
    #expect(json(space) == "{\"first-window\":0,\"label\":\"web/dev\",\"last-window\":8,\"windows\":[7,8]}")
}

@Test func treeNodeWritesNullLayoutForWindows()
{
    let leaf = TreeNode(type: .window, layout: nil, percent: 0.5, window: 7, frame: Area(x: 0, y: 0, w: 10, h: 20), focused: true, selected: false, visible: true, nodes: [])
    let root = TreeNode(type: .workspace, layout: "splith", percent: 1, window: nil, frame: .zero, focused: false, selected: false, visible: true, nodes: [leaf])
    #expect(json(root) == "{\"focused\":false,\"frame\":{\"h\":0,\"w\":0,\"x\":0,\"y\":0},\"layout\":\"splith\",\"nodes\":[{\"focused\":true,\"frame\":{\"h\":20,\"w\":10,\"x\":0,\"y\":0},\"layout\":null,\"nodes\":[],\"percent\":0.5,\"selected\":false,\"type\":\"window\",\"visible\":true,\"window\":7}],\"percent\":1,\"selected\":false,\"type\":\"workspace\",\"visible\":true,\"window\":0}")
}

@Test func ruleInfoEncodesSortedKeysWithNullForUnsetProperties()
{
    var rule = Rule()
    rule.label = "a/b"
    rule.effects.manage = false
    rule.effects.grid = Grid(4, 4, 0, 0, 2, 2)
    #expect(json(rule.info(index: 0, display: 0, space: 2)) == "{\"app\":\"\",\"display\":0,\"flags\":\"0x00000000\",\"follow_space\":false,\"grid\":\"4:4:0:0:2:2\",\"index\":0,\"label\":\"a/b\",\"manage\":false,\"mouse_follows_focus\":null,\"native-fullscreen\":null,\"one-shot\":false,\"opacity\":0,\"role\":\"\",\"scratchpad\":\"\",\"space\":2,\"sticky\":null,\"sub-layer\":\"\",\"subrole\":\"\",\"title\":\"\"}")
}

private func queryThrownText(_ body: () throws(CommandError) -> Void) -> String?
{
    do { try body() } catch { return error.description }
    return nil
}
