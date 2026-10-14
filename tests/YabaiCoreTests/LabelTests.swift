import Testing
@testable import YabaiCore

// NOTE: Ported from tests/src/label.c.

@Test("label_list") func labelList()
{
    var list = LabelList()

    list.set(id: 4, name: "code")
    list.set(id: 5, name: "web")
    #expect(list.labels.count == 2)
    #expect(list.find(name: "web")?.id == 5)
    #expect(list.find(id: 4)?.name == "code")

    // NOTE: a new name replaces the old name of an id
    list.set(id: 4, name: "mail")
    #expect(list.labels.count == 2)
    #expect(list.find(name: "code") == nil)

    // NOTE: a name that is in use moves to the new id
    list.set(id: 6, name: "web")
    #expect(list.labels.count == 2)
    #expect(list.find(id: 5) == nil)
    #expect(list.find(name: "web")?.id == 6)

    #expect(list.remove(id: 6) == true)
    #expect(list.remove(id: 6) == false)
    #expect(list.remove(id: 4) == true)
    #expect(list.labels.count == 0)
}

@Test func labelListMovesIDs()
{
    var list = LabelList()
    list.set(id: 1, name: "a")
    list.set(id: 2, name: "b")

    list.swap(1, 2)
    #expect(list.find(name: "a")?.id == 2)
    #expect(list.find(name: "b")?.id == 1)

    list.replace(id: 2, with: 7)
    #expect(list.find(name: "a")?.id == 7)
    list.replace(id: 3, with: 8)
    #expect(list.labels.map(\.id).sorted() == [1, 7])

    // NOTE: names compare byte for byte, like string_equals
    list.set(id: 9, name: "\u{e9}")
    list.set(id: 10, name: "e\u{301}")
    #expect(list.find(name: "\u{e9}")?.id == 9)
    #expect(list.find(name: "e\u{301}")?.id == 10)
}
