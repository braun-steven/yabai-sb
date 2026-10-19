import Testing
import CPrivate
import YabaiCore
@testable import Yabai

//
// NOTE: Ported from the tree tests of tests/src/auto_padding.c (auto_padding_tiled_count, auto_padding_gap and
// auto_padding_split_in_tab). They build trees and lay them out, so they are part of DaemonState. The pure parts
// (auto_padding_applies, auto_padding_root_area) are in tests/YabaiCoreTests/ViewAreaTests.swift.
//

extension DaemonState
{
    @Suite
    struct ViewTests
    {
        /// `auto_padding_view_init`: a tree view with padding and a gap, and auto_padding on.
        private func autoPaddingView() -> View
        {
            let target = View(sid: 1)

            target.tree = Con(layout: .splitH)
            target.layout = .tree
            target.autoPadding = true
            target.topPadding = 10
            target.bottomPadding = 20
            target.leftPadding = 30
            target.rightPadding = 40
            target.windowGap = 8
            target.isPaddingEnabled = true
            target.isGapEnabled = true

            return target
        }

        @Test("auto_padding_tiled_count")
        func autoPaddingTiledCount()
        {
            let target = autoPaddingView()

            #expect(target.tiledCount == 0)

            let a = treeTestLeaf(target.tree!, 1)
            #expect(target.tiledCount == 1)

            // a tabbed container counts once, however many tabs it holds
            let tabbed = Con(layout: .tabbed)
            target.tree!.attach(tabbed, at: nil)
            let b = treeTestLeaf(tabbed, 2)
            let c = treeTestLeaf(tabbed, 3)
            #expect(target.tiledCount == 2)

            // a split inside a tab is still part of that one container
            c.split(.vertical)
            treeTestLeaf(c.parent!, 4)
            #expect(target.tiledCount == 2)

            // a window in zoom-fullscreen does not count
            a.zoom = .fullscreen
            #expect(target.tiledCount == 1)

            // zoom-parent still counts
            b.zoom = .parent
            #expect(target.tiledCount == 1)

            // a tabbed container as the only container: no padding
            #expect(View.autoPaddingApplies(layout: target.layout, autoPadding: target.autoPadding, tiledCount: target.tiledCount) == true)

            // tabs turned into a split count individually again
            tabbed.layout = .splitH
            #expect(target.tiledCount == 3)

            target.tree!.destroy()
            target.tree = nil
            #expect(target.tiledCount == 0)
        }

        @Test("auto_padding_gap")
        func autoPaddingGap()
        {
            let target = autoPaddingView()

            let a = treeTestLeaf(target.tree!, 1)
            let b = treeTestLeaf(target.tree!, 2)

            let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

            #expect(target.windowGapValue == 8)

            target.area = target.rootArea(in: frame)
            Yabai.tree_view_update(target)
            #expect(Int(a.area.x) == 30)
            #expect(Int(a.area.w) == 461)
            #expect(Int(b.area.x) == 30 + 461 + 8)
            #expect(Int(b.area.w) == 461)

            // one tiled window next to a zoom-fullscreen one: no padding, the gap stays
            target.isUnpadded = true
            #expect(target.windowGapValue == 8)

            target.area = target.rootArea(in: frame)
            Yabai.tree_view_update(target)
            #expect(Int(a.area.x) == 0)
            #expect(Int(a.area.w) == 496)
            #expect(Int(b.area.x) == 496 + 8)
            #expect(Int(b.area.w) == 496)

            // the configured gap used by --grid is unchanged
            #expect(target.windowGap == 8)

            target.isUnpadded = false
            target.isGapEnabled = false
            #expect(target.windowGapValue == 0)

            target.tree!.destroy()
        }

        @Test("auto_padding_split_in_tab")
        func autoPaddingSplitInTab()
        {
            let target = autoPaddingView()
            target.tree!.layout = .tabbed

            let split = Con(layout: .splitH)
            target.tree!.attach(split, at: nil)
            let a = treeTestLeaf(split, 1)
            let b = treeTestLeaf(split, 2)

            // the tabbed container is the only container: no padding, but its split keeps the gap
            let unpadded = View.autoPaddingApplies(layout: target.layout, autoPadding: target.autoPadding, tiledCount: target.tiledCount)
            #expect(unpadded == true)
            target.isUnpadded = true

            target.area = target.rootArea(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
            Yabai.tree_view_update(target)
            #expect(Int(a.area.x) == 0)
            #expect(Int(a.area.w) == 496)
            #expect(Int(b.area.x) == 496 + 8)
            #expect(Int(b.area.x) + Int(b.area.w) == 1000)

            target.tree!.destroy()
        }
    }
}
