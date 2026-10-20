import CoreGraphics
import Testing
@testable import YabaiCore
import YabaiTestSupport

// NOTE: Ported from the pure parts of tests/src/auto_padding.c. The tests that build a tree stay in tests/YabaiTests.

@Test("auto_padding_applies") func autoPaddingApplies()
{
    #expect(ViewArea.autoPaddingApplies(isTree: true, autoPadding: true, tiledCount: 0) == true)
    #expect(ViewArea.autoPaddingApplies(isTree: true, autoPadding: true, tiledCount: 1) == true)
    #expect(ViewArea.autoPaddingApplies(isTree: true, autoPadding: true, tiledCount: 2) == false)
    #expect(ViewArea.autoPaddingApplies(isTree: true, autoPadding: true, tiledCount: 5) == false)

    #expect(ViewArea.autoPaddingApplies(isTree: true, autoPadding: false, tiledCount: 0) == false)
    #expect(ViewArea.autoPaddingApplies(isTree: true, autoPadding: false, tiledCount: 1) == false)

    #expect(ViewArea.autoPaddingApplies(isTree: false, autoPadding: true, tiledCount: 1) == false)
}

@Test("auto_padding_root_area") func autoPaddingRootArea()
{
    let frame = Area(CGRect(x: 0, y: 25, width: 1000, height: 775))

    // the padding is top 10, bottom 20, left 30, right 40
    var area = ViewArea.rootArea(frame, paddingEnabled: true, unpadded: false, top: 10, bottom: 20, left: 30, right: 40)
    #expect(Int(area.x) == 30)
    #expect(Int(area.y) == 35)
    #expect(Int(area.w) == 930)
    #expect(Int(area.h) == 745)

    area = ViewArea.rootArea(frame, paddingEnabled: true, unpadded: true, top: 10, bottom: 20, left: 30, right: 40)
    #expect(Int(area.x) == 0)
    #expect(Int(area.y) == 25)
    #expect(Int(area.w) == 1000)
    #expect(Int(area.h) == 775)

    // padding toggled off stays off regardless of auto_padding
    area = ViewArea.rootArea(frame, paddingEnabled: false, unpadded: false, top: 10, bottom: 20, left: 30, right: 40)
    #expect(Int(area.x) == 0)
    #expect(Int(area.y) == 25)
    #expect(Int(area.w) == 1000)
    #expect(Int(area.h) == 775)
}
