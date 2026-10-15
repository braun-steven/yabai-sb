import Testing
@testable import YabaiCore

// NOTE: Ported from tests/src/space_list.c.

private let spaces: [UInt64] = [3, 7, 9]

@Test("space_list_navigation") func spaceListNavigation()
{
    #expect(SpaceList.neighbour(spaces: spaces, sid: 7, offset: -1) == 3)
    #expect(SpaceList.neighbour(spaces: spaces, sid: 7, offset: 1) == 9)
    #expect(SpaceList.neighbour(spaces: spaces, sid: 3, offset: -1) == 0)
    #expect(SpaceList.neighbour(spaces: spaces, sid: 9, offset: 1) == 0)
    #expect(SpaceList.neighbour(spaces: spaces, sid: 5, offset: 1) == 0)
    #expect(SpaceList.neighbour(spaces: spaces, sid: 5, offset: -1) == 0)

    #expect(SpaceList.indexOf(spaces: spaces, sid: 9) == 2)
    #expect(SpaceList.indexOf(spaces: spaces, sid: 4) == nil)
    #expect(SpaceList.indexOf(spaces: [], sid: 4) == nil)
}
