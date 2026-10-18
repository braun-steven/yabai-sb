import Testing
@testable import YabaiCore

// NOTE: Ported from tests/src/space_layout.c.

@Test("space_layout_parse") func spaceLayoutParse() throws
{
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

@Test("space_layout_targets") func spaceLayoutTargets() throws
{
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
private func spaceTestLists(_ mask: String) -> ([SpaceID], [Bool])
{
    ((0..<mask.count).map { SpaceID(UInt64($0 + 1)) }, mask.map { $0 == "u" })
}

private func moveReplacement(_ mask: String, _ sid: SpaceID, _ visible: SpaceID) -> SpaceID
{
    let (spaces, user) = spaceTestLists(mask)
    return SpaceList.moveReplacement(spaces: spaces, user: user, sid: sid, visible: visible)
}

private func moveCandidate(_ mask: String, _ visible: SpaceID, _ fromEnd: Bool) -> SpaceID
{
    let (spaces, user) = spaceTestLists(mask)
    return SpaceLayout.moveCandidate(spaces: spaces, user: user, visible: visible, fromEnd: fromEnd)
}

@Test("space_move_replacement") func spaceMoveReplacement()
{
    // NOTE: The regression: a visible space is replaced even when it is not the focused space,
    // so the scripting addition hides it before the move and it never stays shown on the
    // destination display as a second menubar.
    #expect(moveReplacement("uuuu", 1, 1) == 2)
    #expect(moveReplacement("uuuu", 3, 3) == 2)
    #expect(moveReplacement("uuuu", 4, 4) == 3)

    // A hidden space needs no replacement.
    #expect(moveReplacement("uuuu", 2, 1) == 0)

    // The replacement is always a user space on the same display.
    #expect(moveReplacement("-u-u", 2, 2) == 4)
    #expect(moveReplacement("-u-u", 4, 4) == 2)
    #expect(moveReplacement("u", 1, 1) == 0)
}

@Test("space_layout_move_candidate") func spaceLayoutMoveCandidate()
{
    // The visible space is skipped, from either edge.
    #expect(moveCandidate("uuuu", 3, false) == 1)
    #expect(moveCandidate("uuuu", 1, false) == 2)
    #expect(moveCandidate("uuuu", 3, true) == 4)
    #expect(moveCandidate("uuuu", 4, true) == 3)

    #expect(moveCandidate("-uu-", 2, false) == 3)
    #expect(moveCandidate("-uu-", 3, true) == 2)

    // The visible space is only moved when it is the only user space.
    #expect(moveCandidate("-u--", 2, false) == 2)
    #expect(moveCandidate("----", 2, false) == 0)
}
