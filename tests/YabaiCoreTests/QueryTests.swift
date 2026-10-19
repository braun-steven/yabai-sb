import Testing
import YabaiCore

// NOTE: Ported from tests/src/window_info.c.

private func layerName(_ level: Int32) -> String
{
    "unknown"
}

private func windowInfoFixture() -> WindowInfo
{
    var info = WindowInfo(id: 42)
    info.app = "Text\"Edit"
    info.title = "a\tb"
    info.split = .x
    info.isVisible = true
    return info
}

@Test("window_info_serialize_selected")
func windowInfoSerializeSelected()
{
    let info = windowInfoFixture()

    #expect(info.serialize(WindowProperty.id, layer: layerName) == "{\n\t\"id\":42\n}")
    #expect(info.serialize(WindowProperty.id | WindowProperty.app | WindowProperty.title, layer: layerName)
            == "{\n\t\"id\":42,\n\t\"app\":\"Text\\\"Edit\",\n\t\"title\":\"a\\tb\"\n}")
    #expect(info.serialize(WindowProperty.splitType | WindowProperty.isVisible, layer: layerName)
            == "{\n\t\"split-type\":\"horizontal\",\n\t\"is-visible\":true\n}")
}

// NOTE: every property of a list is written by its serializer, in the order of the list (which `query` documents).
@Test func windowInfoWritesEveryPropertyInListOrder()
{
    let json = windowInfoFixture().serialize(~0, layer: layerName)
    let keys = json.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("\t\"") else { return nil }
        return String(line.dropFirst(2).prefix { $0 != "\"" })
    }

    #expect(keys == WindowProperty.list.map(\.name))
    #expect(WindowProperty.list.reduce(0) { $0 | $1.value } == 0x1fffdffff)
}

@Test func queryCommandPropertiesAndTargets() throws
{
    var message = Message("--windows\0id,frame\0--space\0recent\0")
    #expect(try QueryCommand.parse(&message) == .windows(properties: WindowProperty.id | WindowProperty.frame, target: .space(.recent)))

    message = Message("--displays\0--display\0west\0")
    #expect(try QueryCommand.parse(&message) == .displays(properties: 0, target: .display(.direction(.west))))

    message = Message("--spaces\0--window\0")
    #expect(try QueryCommand.parse(&message) == .spaces(properties: 0, target: .window(nil)))

    message = Message("--windows\0id\0")
    #expect(try QueryCommand.parse(&message) == .windows(properties: WindowProperty.id, target: .all))
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

private func queryThrownText(_ body: () throws(CommandError) -> Void) -> String?
{
    do { try body() } catch { return error.description }
    return nil
}
