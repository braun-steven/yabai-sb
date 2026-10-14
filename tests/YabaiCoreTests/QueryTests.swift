import Testing
import YabaiCore

// NOTE: Ported from tests/src/window_info.c.

private func layerName(_ level: Int32) -> String
{
    "unknown"
}

private func windowInfoFixture() -> WindowInfo
{
    var info = WindowInfo()
    info.id = 42
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
