import Testing
@testable import YabaiCore

@Test("label_list") func labelList()
{
    var list = LabelList<SpaceID>()

    list.set(id: 4, name: "code")
    list.set(id: 5, name: "web")
    #expect(list.count == 2)
    #expect(list.id(named: "web") == 5)
    #expect(list.name(of: 4) == "code")

    // NOTE: a new name replaces the old name of an id
    list.set(id: 4, name: "mail")
    #expect(list.count == 2)
    #expect(list.id(named: "code") == nil)

    // NOTE: a name that is in use moves to the new id
    list.set(id: 6, name: "web")
    #expect(list.count == 2)
    #expect(list.name(of: 5) == nil)
    #expect(list.id(named: "web") == 6)

    #expect(list.remove(id: 6) == true)
    #expect(list.remove(id: 6) == false)
    #expect(list.id(named: "web") == nil)
    #expect(list.remove(id: 4) == true)
    #expect(list.count == 0)
}

@Test func labelListMovesIDs()
{
    var list = LabelList<SpaceID>()
    list.set(id: 1, name: "a")
    list.set(id: 2, name: "b")

    list.swap(1, 2)
    #expect(list.id(named: "a") == 2)
    #expect(list.id(named: "b") == 1)
    #expect(list.name(of: 1) == "b")

    // NOTE: swapping with an unlabeled id moves the label
    list.swap(1, 3)
    #expect(list.id(named: "b") == 3)
    #expect(list.name(of: 1) == nil)

    list.replace(id: 2, with: 7)
    #expect(list.id(named: "a") == 7)
    #expect(list.name(of: 2) == nil)
    list.replace(id: 4, with: 8)
    #expect(list.count == 2)

    // NOTE: the new id loses its own label
    list.replace(id: 7, with: 3)
    #expect(list.id(named: "a") == 3)
    #expect(list.id(named: "b") == nil)
    #expect(list.count == 1)
}

@Test func labelNamesCompareByCanonicalEquivalence()
{
    var list = LabelList<SpaceID>()
    list.set(id: 9, name: "\u{e9}")
    list.set(id: 10, name: "e\u{301}")

    #expect(list.count == 1)
    #expect(list.id(named: "\u{e9}") == 10)
    #expect(list.name(of: 9) == nil)
}
