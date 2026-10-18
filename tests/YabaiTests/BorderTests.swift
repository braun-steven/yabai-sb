import CoreGraphics
import Testing
import CPrivate
import YabaiCore
@testable import Yabai

extension DaemonState
{
    @Suite
    struct BorderTests
    {
        @Test("border_counts_visible_split_windows_in_active_tab")
        func visibleSplitCount()
        {
            // H[T[1 H[2 H[3 4]]]]: hidden tabs do not suppress split-window borders.
            let root = Yabai.con_create(CON_SPLITH)!
            defer { Yabai.con_free(root) }
            let tabs = treeTestSplit(root, CON_TABBED)
            let single = treeTestLeaf(tabs, 1)
            let split = treeTestSplit(tabs, CON_SPLITH)
            treeTestLeaf(split, 2)
            let nested = treeTestSplit(split, CON_SPLITH)
            let focused = treeTestLeaf(nested, 3)
            treeTestLeaf(nested, 4)
            let owner = View()
            owner.tree = root
            Yabai.tree_focus(focused)
            #expect(treeVisibleWindowCount(root) == 3)
            #expect(Yabai.tree_view_tiled_count(owner) == 1)
            Yabai.tree_focus(single)
            #expect(treeVisibleWindowCount(root) == 1)
            Yabai.tree_focus(focused)
            #expect(treeVisibleWindowCount(root) == 3)
        }

        @Test("border_edge_frames_split")
        func edgeFramesSplit()
        {
            var edge = borderEdgeFrames(CGRect(x: 100, y: 200, width: 800, height: 600), 6, 10)
            #expect(edge[0] == CGRect(x: 94, y: 194, width: 812, height: 16))
            #expect(edge[1] == CGRect(x: 94, y: 790, width: 812, height: 16))
            #expect(edge[2] == CGRect(x: 94, y: 210, width: 7, height: 580))
            #expect(edge[3] == CGRect(x: 899, y: 210, width: 7, height: 580))
            edge = borderEdgeFrames(CGRect(x: 0, y: 0, width: 400, height: 20), 6, 10)
            #expect(edge[0] == CGRect(x: -6, y: -6, width: 412, height: 16))
            #expect(edge[1] == CGRect(x: -6, y: 10, width: 412, height: 16))
            #expect(edge[2].height == 0)
            #expect(edge[3].height == 0)
            edge = borderEdgeFrames(CGRect(x: 0, y: 0, width: 400, height: 21), 4, 12.5)
            #expect(edge[0].height == 14)
            #expect(edge[1].height == 15)
            #expect(edge[2].height == 0)
        }

        @Test("border_tabbed_container_area")
        func tabbedContainerArea()
        {
            let wm = window_manager_global()
            let enabled = wm.enable_tab_bar
            let height = wm.tab_bar_height
            let backdrop = wm.tab_bar_backdrop
            let workspaceTabbed = space_manager_global().tree_workspace_tabbed
            defer {
                wm.enable_tab_bar = enabled
                wm.tab_bar_height = height
                wm.tab_bar_backdrop = backdrop
                space_manager_global().tree_workspace_tabbed = workspaceTabbed
            }
            wm.enable_tab_bar = true
            wm.tab_bar_height = 24
            wm.tab_bar_backdrop = TAB_BAR_BACKDROP_OFF
            space_manager_global().tree_workspace_tabbed = false
            // H[ 1 T[ 2 T[ 4 5 ] 3 ] ]
            let root = Yabai.con_create(CON_SPLITH)!
            defer { Yabai.con_free(root) }
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            let b = treeTestLeaf(t, 2)
            let nested = treeTestSplit(t, CON_TABBED)
            let d = treeTestLeaf(nested, 4)
            treeTestLeaf(nested, 5)
            treeTestLeaf(t, 3)
            Yabai.tree_focus(b)
            Yabai.tree_update(root, Area(x: 0, y: 0, w: 1010, h: 810), 10, 24, 0, 0)
            let owner = View()
            owner.tree = root
            var windowArea = Area.zero
            var borderArea = Area.zero
            var radius: Int32 = -1
            func same(_ lhs: Area, _ rhs: Area) -> Bool { lhs.x == rhs.x && lhs.y == rhs.y && lhs.w == rhs.w && lhs.h == rhs.h }
            #expect(Yabai.tree_window_border_area(owner,1, &windowArea, &borderArea, &radius))
            #expect(same(borderArea, a.area))
            #expect(radius == 0)
            #expect(Yabai.tree_window_border_area(owner,2, &windowArea, &borderArea, &radius))
            #expect(same(borderArea, t.area))
            #expect(same(windowArea, b.area))
            #expect(windowArea.y - borderArea.y == 24)
            #expect(!Yabai.tree_window_border_area(owner,3, &windowArea, &borderArea, &radius))
            #expect(!Yabai.tree_window_border_area(owner,4, &windowArea, &borderArea, &radius))
            Yabai.tree_focus(d)
            Yabai.tree_update(root, Area(x: 0, y: 0, w: 1010, h: 810), 10, 24, 0, 0)
            #expect(Yabai.tree_window_border_area(owner,4, &windowArea, &borderArea, &radius))
            #expect(same(borderArea, t.area))
            #expect(windowArea.y - borderArea.y == 48)
            #expect(Yabai.tree_window_border_area(owner,99, &windowArea, &borderArea, &radius))
            #expect(borderArea.w == 0)
        }
    }
}
