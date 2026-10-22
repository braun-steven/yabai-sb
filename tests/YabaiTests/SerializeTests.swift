import Testing
import CPrivate
import YabaiCore
@testable import Yabai
import YabaiTestSupport

// NOTE: Ported from tests/src/window_info.c and tests/src/tree_view.c. The tree json reads the focused window of the
// window manager, so these tests are part of DaemonState.

extension DaemonState
{
    @Suite
    @WM struct SerializeTests
    {
        @Test("window_info_tree_fields")
        func windowInfoTreeFields()
        {
            let root = Con(layout: .splitH)
            defer { root.destroy() }

            let tabs = treeTestSplit(root, .tabbed)
            treeTestLeaf(tabs, 1)
            let split = treeTestSplit(tabs, .splitV)
            let leaf = treeTestLeaf(split, 2)
            let side = treeTestLeaf(root, 3)
            leaf.zoom = .parent

            var info = WindowInfo(id: 1)
            info.setTree(leaf)
            #expect(info.split == .x)
            #expect(info.stackIndex == 2)
            #expect(info.hasParentZoom)
            #expect(!info.hasFullscreenZoom)

            info = WindowInfo(id: 1)
            info.setTree(side)
            #expect(info.split == .y)
            #expect(info.stackIndex == 0)

            info = WindowInfo(id: 1)
            info.setTree(nil)
            #expect(info.split == WindowSplit.none)
        }

        @Test
        func treeNodeOfTreeView() throws
        {
            let root = Con(layout: .splitH)
            defer { root.destroy() }

            let tabs = treeTestSplit(root, .tabbed)
            treeTestLeaf(tabs, 7)

            let testView = View(sid: 1)
            testView.layout = .tree
            testView.tree = root

            let tree = try #require(testView.treeNode())
            let text = String(decoding: try JSON.encode(tree), as: UTF8.self)
            #expect(text.hasPrefix("{\"focused\":false,"))
            #expect(text.contains("\"layout\":\"splith\""))
            #expect(text.contains("\"layout\":\"tabbed\""))
            #expect(text.contains("\"layout\":null,\"nodes\":[],\"percent\":1,\"selected\":"))
            #expect(text.contains("\"type\":\"window\",\"visible\":true,\"window\":7}"))

            testView.layout = .float
            #expect(testView.treeNode() == nil)
        }
    }
}
