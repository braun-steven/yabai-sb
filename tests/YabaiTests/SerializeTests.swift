import Testing
import CPrivate
import YabaiCore
@testable import Yabai

// NOTE: Ported from tests/src/window_info.c and tests/src/tree_view.c. The tree json reads the focused window of the
// window manager, so these tests are part of DaemonState.

extension DaemonState
{
    @Suite
    struct SerializeTests
    {
        @Test("window_info_tree_fields")
        func windowInfoTreeFields()
        {
            let root = Yabai.con_create(.splitH)!
            defer { Yabai.con_free(root) }

            let tabs = treeTestSplit(root, .tabbed)
            treeTestLeaf(tabs, 1)
            let split = treeTestSplit(tabs, .splitV)
            let leaf = treeTestLeaf(split, 2)
            let side = treeTestLeaf(root, 3)
            leaf.zoom = .parent

            var info = WindowInfo()
            windowInfoSetTree(&info, leaf)
            #expect(info.split == .x)
            #expect(info.stackIndex == 2)
            #expect(info.hasParentZoom)
            #expect(!info.hasFullscreenZoom)

            info = WindowInfo()
            windowInfoSetTree(&info, side)
            #expect(info.split == .y)
            #expect(info.stackIndex == 0)

            info = WindowInfo()
            windowInfoSetTree(&info, nil)
            #expect(info.split == WindowSplit.none)
        }

        @Test("tree_view_serialize_tree")
        func treeViewSerializeTree()
        {
            let root = Yabai.con_create(.splitH)!
            defer { Yabai.con_free(root) }

            let tabs = treeTestSplit(root, .tabbed)
            treeTestLeaf(tabs, 7)

            let testView = View()
            testView.layout = .tree
            testView.tree = root

            var response = Response()
            #expect(treeSerialize(&response, testView))
            #expect(response.text.hasPrefix("{\"type\":\"workspace\",\"layout\":\"splith\""))
            #expect(response.text.contains("{\"type\":\"container\",\"layout\":\"tabbed\""))
            #expect(response.text.contains("{\"type\":\"window\",\"layout\":null,\"percent\":1.0000,\"window\":7"))

            testView.layout = .float
            var floating = Response()
            #expect(!treeSerialize(&floating, testView))
            #expect(floating.bytes.isEmpty)
        }
    }
}
