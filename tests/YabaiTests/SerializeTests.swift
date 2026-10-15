import Testing
import YabaiC
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
            let root = Yabai.con_create(CON_SPLITH)!
            defer { Yabai.con_free(root) }

            let tabs = treeTestSplit(root, CON_TABBED)
            treeTestLeaf(tabs, 1)
            let split = treeTestSplit(tabs, CON_SPLITV)
            let leaf = treeTestLeaf(split, 2)
            let side = treeTestLeaf(root, 3)
            leaf.pointee.zoom = CON_ZOOM_PARENT

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
            let root = Yabai.con_create(CON_SPLITH)!
            defer { Yabai.con_free(root) }

            let tabs = treeTestSplit(root, CON_TABBED)
            treeTestLeaf(tabs, 7)

            var testView = view()
            testView.layout = VIEW_TREE
            testView.tree = root

            var response = Response()
            #expect(treeSerialize(&response, &testView))
            #expect(response.text.hasPrefix("{\"type\":\"workspace\",\"layout\":\"splith\""))
            #expect(response.text.contains("{\"type\":\"container\",\"layout\":\"tabbed\""))
            #expect(response.text.contains("{\"type\":\"window\",\"layout\":null,\"percent\":1.0000,\"window\":7"))

            testView.layout = VIEW_FLOAT
            var floating = Response()
            #expect(!treeSerialize(&floating, &testView))
            #expect(floating.bytes.isEmpty)
        }
    }
}
