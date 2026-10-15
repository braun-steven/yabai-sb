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
            let target = View()

            target.tree = Yabai.con_create(CON_SPLITH)
            target.layout = VIEW_TREE
            target.auto_padding = true
            target.top_padding = 10
            target.bottom_padding = 20
            target.left_padding = 30
            target.right_padding = 40
            target.window_gap = 8
            setViewFlag(target, VIEW_ENABLE_PADDING)
            setViewFlag(target, VIEW_ENABLE_GAP)

            return target
        }

        @Test("auto_padding_tiled_count")
        func autoPaddingTiledCount()
        {
            let target = autoPaddingView()

            #expect(view_tiled_count(target) == 0)

            let a = treeTestLeaf(target.tree, 1)
            #expect(view_tiled_count(target) == 1)

            // a tabbed container counts once, however many tabs it holds
            let tabbed = Yabai.con_create(CON_TABBED)!
            Yabai.tree_attach(target.tree, tabbed, -1)
            let b = treeTestLeaf(tabbed, 2)
            let c = treeTestLeaf(tabbed, 3)
            #expect(view_tiled_count(target) == 2)

            // a split inside a tab is still part of that one container
            tree_split(c, CON_VERTICAL)
            treeTestLeaf(c.parent, 4)
            #expect(view_tiled_count(target) == 2)

            // a window in zoom-fullscreen does not count
            a.zoom = CON_ZOOM_FULLSCREEN
            #expect(view_tiled_count(target) == 1)

            // zoom-parent still counts
            b.zoom = CON_ZOOM_PARENT
            #expect(view_tiled_count(target) == 1)

            // a tabbed container as the only container: no padding
            #expect(Yabai.view_auto_padding_applies(target.layout, target.auto_padding, view_tiled_count(target)) == true)

            // tabs turned into a split count individually again
            tabbed.layout = CON_SPLITH
            #expect(view_tiled_count(target) == 3)

            Yabai.con_free(target.tree)
            target.tree = nil
            #expect(view_tiled_count(target) == 0)
        }

        @Test("auto_padding_gap")
        func autoPaddingGap()
        {
            let target = autoPaddingView()

            let a = treeTestLeaf(target.tree, 1)
            let b = treeTestLeaf(target.tree, 2)

            let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

            #expect(view_window_gap(target) == 8)

            target.area = view_root_area(target, frame)
            Yabai.tree_view_update(target)
            #expect(Int(a.area.x) == 30)
            #expect(Int(a.area.w) == 461)
            #expect(Int(b.area.x) == 30 + 461 + 8)
            #expect(Int(b.area.w) == 461)

            // one tiled window next to a zoom-fullscreen one: no padding, the gap stays
            setViewFlag(target, VIEW_IS_UNPADDED)
            #expect(view_window_gap(target) == 8)

            target.area = view_root_area(target, frame)
            Yabai.tree_view_update(target)
            #expect(Int(a.area.x) == 0)
            #expect(Int(a.area.w) == 496)
            #expect(Int(b.area.x) == 496 + 8)
            #expect(Int(b.area.w) == 496)

            // the configured gap used by --grid is unchanged
            #expect(target.window_gap == 8)

            clearViewFlag(target, VIEW_IS_UNPADDED)
            clearViewFlag(target, VIEW_ENABLE_GAP)
            #expect(view_window_gap(target) == 0)

            Yabai.con_free(target.tree)
        }

        @Test("auto_padding_split_in_tab")
        func autoPaddingSplitInTab()
        {
            let target = autoPaddingView()
            target.tree.layout = CON_TABBED

            let split = Yabai.con_create(CON_SPLITH)!
            Yabai.tree_attach(target.tree, split, -1)
            let a = treeTestLeaf(split, 1)
            let b = treeTestLeaf(split, 2)

            // the tabbed container is the only container: no padding, but its split keeps the gap
            let unpadded = Yabai.view_auto_padding_applies(target.layout, target.auto_padding, view_tiled_count(target))
            #expect(unpadded == true)
            setViewFlag(target, VIEW_IS_UNPADDED)

            target.area = view_root_area(target, CGRect(x: 0, y: 0, width: 1000, height: 800))
            Yabai.tree_view_update(target)
            #expect(Int(a.area.x) == 0)
            #expect(Int(a.area.w) == 496)
            #expect(Int(b.area.x) == 496 + 8)
            #expect(Int(b.area.x) + Int(b.area.w) == 1000)

            Yabai.con_free(target.tree)
        }
    }
}
