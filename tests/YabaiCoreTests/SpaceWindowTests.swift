import Testing
@testable import YabaiCore

// NOTE: Ported from tests/src/space_window.c.

@Test("space_window_user_predicates") func spaceWindowUserPredicates()
{
    let visibleTags: UInt64 = 0x1
    let minimizedTags: UInt64 = 0x1000000000000001

    #expect(SpaceWindow.isUserWindow(parentID: nil, level: 0, tags: visibleTags, attributes: 0x2) == true)
    #expect(SpaceWindow.isUserWindow(parentID: nil, level: 8, tags: 0x80000002, attributes: 0x2) == true)
    #expect(SpaceWindow.isUserWindow(parentID: nil, level: 3, tags: 0x400000000000001, attributes: 0x0) == true)

    // NOTE: child windows, other levels and windows without the tags are not user windows
    #expect(SpaceWindow.isUserWindow(parentID: 7, level: 0, tags: visibleTags, attributes: 0x2) == false)
    #expect(SpaceWindow.isUserWindow(parentID: nil, level: 25, tags: visibleTags, attributes: 0x2) == false)
    #expect(SpaceWindow.isUserWindow(parentID: nil, level: 0, tags: 0x2, attributes: 0x2) == false)
    #expect(SpaceWindow.isUserWindow(parentID: nil, level: 0, tags: visibleTags, attributes: 0x0) == false)

    #expect(SpaceWindow.isMinimizedUserWindow(parentID: nil, level: 0, tags: minimizedTags, attributes: 0x0) == true)
    #expect(SpaceWindow.isMinimizedUserWindow(parentID: nil, level: 0, tags: 0x100000000000001, attributes: 0x1) == true)
    #expect(SpaceWindow.isMinimizedUserWindow(parentID: nil, level: 0, tags: minimizedTags, attributes: 0x2) == false)
    #expect(SpaceWindow.isMinimizedUserWindow(parentID: nil, level: 0, tags: visibleTags, attributes: 0x0) == false)
    #expect(SpaceWindow.isMinimizedUserWindow(parentID: 3, level: 0, tags: minimizedTags, attributes: 0x0) == false)
}
