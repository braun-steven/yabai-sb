import CoreGraphics
import Testing
import CPrivate
import YabaiCore
@testable import Yabai

extension DaemonState
{
    @Suite
    @WM struct BorderTests
    {
        @Test("border_counts_visible_split_windows_in_active_tab")
        func visibleSplitCount()
        {
            // H[T[1 H[2 H[3 4]]]]: hidden tabs do not suppress split-window borders.
            let root = Con(layout: .splitH)
            defer { root.destroy() }
            let tabs = treeTestSplit(root, .tabbed)
            let single = treeTestLeaf(tabs, 1)
            let split = treeTestSplit(tabs, .splitH)
            treeTestLeaf(split, 2)
            let nested = treeTestSplit(split, .splitH)
            let focused = treeTestLeaf(nested, 3)
            treeTestLeaf(nested, 4)
            let owner = View(sid: 1)
            owner.tree = root
            focused.focus()
            #expect(root.visibleWindowCount() == 3)
            #expect(owner.tiledCount == 1)
            single.focus()
            #expect(root.visibleWindowCount() == 1)
            focused.focus()
            #expect(root.visibleWindowCount() == 3)
        }

        @Test("border_edge_frames_split")
        func edgeFramesSplit()
        {
            var edge = BorderEdges(around: CGRect(x: 100, y: 200, width: 800, height: 600), width: 6, radius: 10)
            #expect(edge[0] == CGRect(x: 94, y: 194, width: 812, height: 16))
            #expect(edge[1] == CGRect(x: 94, y: 790, width: 812, height: 16))
            #expect(edge[2] == CGRect(x: 94, y: 210, width: 7, height: 580))
            #expect(edge[3] == CGRect(x: 899, y: 210, width: 7, height: 580))
            edge = BorderEdges(around: CGRect(x: 0, y: 0, width: 400, height: 20), width: 6, radius: 10)
            #expect(edge[0] == CGRect(x: -6, y: -6, width: 412, height: 16))
            #expect(edge[1] == CGRect(x: -6, y: 10, width: 412, height: 16))
            #expect(edge[2].height == 0)
            #expect(edge[3].height == 0)
            edge = BorderEdges(around: CGRect(x: 0, y: 0, width: 400, height: 21), width: 4, radius: 12.5)
            #expect(edge[0].height == 14)
            #expect(edge[1].height == 15)
            #expect(edge[2].height == 0)
        }

        @Test("border_tabbed_container_area")
        func tabbedContainerArea()
        {
            let wm = WindowManager.shared
            let enabled = wm.tabBarEnabled
            let height = wm.tabBarHeight
            let backdrop = wm.tabBarBackdrop
            let workspaceTabbed = SpaceManager.shared.treeWorkspaceTabbed
            defer {
                wm.tabBarEnabled = enabled
                wm.tabBarHeight = height
                wm.tabBarBackdrop = backdrop
                SpaceManager.shared.treeWorkspaceTabbed = workspaceTabbed
            }
            wm.tabBarEnabled = true
            wm.tabBarHeight = 24
            wm.tabBarBackdrop = .off
            SpaceManager.shared.treeWorkspaceTabbed = false
            // H[ 1 T[ 2 T[ 4 5 ] 3 ] ]
            let root = Con(layout: .splitH)
            defer { root.destroy() }
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            let b = treeTestLeaf(t, 2)
            let nested = treeTestSplit(t, .tabbed)
            let d = treeTestLeaf(nested, 4)
            treeTestLeaf(nested, 5)
            treeTestLeaf(t, 3)
            b.focus()
            root.layOut(Area(x: 0, y: 0, w: 1010, h: 810), gap: 10, barHeight: 24, barOffset: 0, barInset: 0)
            let owner = View(sid: 1)
            owner.tree = root
            func same(_ lhs: Area, _ rhs: Area) -> Bool { lhs.x == rhs.x && lhs.y == rhs.y && lhs.w == rhs.w && lhs.h == rhs.h }
            var border = owner.borderArea(windowID: 1)
            #expect(border.visible)
            #expect(same(border.border, a.area))
            #expect(border.radius == 0)
            border = owner.borderArea(windowID: 2)
            #expect(border.visible)
            #expect(same(border.border, t.area))
            #expect(same(border.window, b.area))
            #expect(border.window.y - border.border.y == 24)
            #expect(!owner.borderArea(windowID: 3).visible)
            #expect(!owner.borderArea(windowID: 4).visible)
            d.focus()
            root.layOut(Area(x: 0, y: 0, w: 1010, h: 810), gap: 10, barHeight: 24, barOffset: 0, barInset: 0)
            border = owner.borderArea(windowID: 4)
            #expect(border.visible)
            #expect(same(border.border, t.area))
            #expect(border.window.y - border.border.y == 48)
            border = owner.borderArea(windowID: 99)
            #expect(border.visible)
            #expect(border.border.w == 0)
        }
    }
}
