import Testing
import CPrivate
@testable import Yabai

//
// NOTE: Ported from tests/src/tree.c and tests/src/tree_view.c. tree_workspace_layout_tabbed changes the space
// manager, and the tree reads it (con_apply_workspace_layout), so the tests are part of DaemonState.
//

/// `tree_test_window`
private func treeTestWindow(_ node: Con?) -> UInt32
{
    guard let node, con_is_leaf(node) else { return 0 }
    return node.window_id
}

/// `tree_test_child`
private func treeTestChild(_ node: Con, _ index: Int32) -> UInt32
{
    return index < node.child_count ? treeTestWindow(node.children[Int(index)]) : 0
}

/// A share of space in percent, rounded like the C tests did.
private func percent(_ node: Con, _ scale: Float = 100) -> Int32
{
    return Int32(node.percent * scale + 0.5)
}

/// A leaf that is not part of a tree.
private func treeTestCon(_ windowID: UInt32) -> Con
{
    let node = Yabai.con_create(CON_SPLITH)!
    node.window_id = windowID
    return node
}

/// `tree_view_test_view`
private func treeViewTestView(_ root: Con?) -> View
{
    let target = View()
    target.layout = VIEW_TREE
    target.tree = root
    return target
}

extension DaemonState
{
    @Suite
    struct TreeTests
    {
        // NOTE: the golden replay of this suite sets tree_workspace_layout tabbed, which wraps every container that is
        // attached to the workspace; the tests expect the default (Swift Testing creates the suite for each test)
        init()
        {
            space_manager_global().tree_workspace_tabbed = false
        }

        @Test("tree_attach_detach")
        func treeAttachDetach()
        {
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            #expect(root.child_count == 2)
            #expect(percent(a) == 50)
            #expect(percent(b) == 50)

            // a new child gets the average share and the shares are normalised
            let c = treeTestLeaf(root, 3)
            #expect(percent(c, 300) == 100)

            // detaching the last window of a container closes the container, but never the workspace
            let v = treeTestSplit(root, CON_SPLITV)
            let d = treeTestLeaf(v, 4)
            #expect(root.child_count == 4)
            #expect(Yabai.tree_detach(d) == root)
            Yabai.con_free(d)
            #expect(root.child_count == 3)

            #expect(Yabai.tree_detach(a) == root)
            #expect(Yabai.tree_detach(b) == root)
            #expect(Yabai.tree_detach(c) == root)
            #expect(root.child_count == 0)

            Yabai.con_free(a)
            Yabai.con_free(b)
            Yabai.con_free(c)
            Yabai.con_free(root)
        }

        @Test("tree_flatten")
        func treeFlatten()
        {
            // H[ V[ H[1 2] ] 3 ] flattens to H[1 2 3]
            let root = Yabai.con_create(CON_SPLITH)!
            let v = treeTestSplit(root, CON_SPLITV)
            let h = treeTestSplit(v, CON_SPLITH)
            treeTestLeaf(h, 1)
            treeTestLeaf(h, 2)
            treeTestLeaf(root, 3)

            Yabai.tree_flatten(root)
            #expect(root.child_count == 3)
            #expect(treeTestChild(root, 0) == 1)
            #expect(treeTestChild(root, 1) == 2)
            #expect(treeTestChild(root, 2) == 3)

            var total: Float = 0.0
            for i in 0..<Int(root.child_count) { total += root.children[i].percent }
            #expect(Int32(total * 100 + 0.5) == 100)

            // a single split around a window is kept, so that the next window opens inside of it
            let w = treeTestSplit(root, CON_SPLITV)
            treeTestLeaf(w, 4)
            Yabai.tree_flatten(root)
            #expect(root.child_count == 4)
            #expect(root.children[3] == w)

            Yabai.con_free(root)
        }

        @Test("tree_focus_direction")
        func treeFocusDirection()
        {
            // H[ 1 V[ 2 3 ] 4 ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, CON_SPLITV)
            let b = treeTestLeaf(v, 2)
            let c = treeTestLeaf(v, 3)
            let d = treeTestLeaf(root, 4)

            var result: Con?
            Yabai.tree_focus(c)
            Yabai.tree_focus(a)

            // entering the vertical split restores the window focused there last
            #expect(tree_next(a, DIR_EAST, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 3)

            #expect(tree_next(c, DIR_NORTH, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 2)

            #expect(tree_next(b, DIR_EAST, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 4)

            // at the edge of the workspace, a display in that direction comes first
            #expect(tree_next(d, DIR_EAST, FOCUS_WRAPPING_ON, true, &result) == TREE_RESULT_OUTPUT)

            // otherwise focus wraps around, unless wrapping is off
            #expect(tree_next(d, DIR_EAST, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 1)
            #expect(tree_next(d, DIR_EAST, FOCUS_WRAPPING_OFF, false, &result) == TREE_RESULT_NONE)

            // 'up' from the top of the vertical split has nowhere to go and wraps within it
            #expect(tree_next(b, DIR_NORTH, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 3)

            // forced wrapping stays inside the innermost container
            #expect(tree_next(c, DIR_SOUTH, FOCUS_WRAPPING_FORCE, true, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 2)

            Yabai.con_free(root)
        }

        @Test("tree_focus_tabbed")
        func treeFocusTabbed()
        {
            // H[ 1 T[ 2 3 ] ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            let b = treeTestLeaf(t, 2)
            let c = treeTestLeaf(t, 3)

            var result: Con?
            Yabai.tree_focus(b)

            // tabs are laid out horizontally, so east/west cycles them
            #expect(tree_next(b, DIR_EAST, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 3)
            #expect(tree_next(b, DIR_WEST, FOCUS_WRAPPING_ON, false, &result) == TREE_RESULT_DONE)
            #expect(treeTestWindow(result) == 1)

            // only the active tab is visible
            #expect(tree_con_is_visible(b) == true)
            #expect(tree_con_is_visible(c) == false)
            Yabai.tree_focus(c)
            #expect(tree_con_is_visible(b) == false)
            #expect(tree_con_is_visible(a) == true)

            Yabai.con_free(root)
        }

        @Test("tree_move_within")
        func treeMoveWithin()
        {
            // H[ 1 2 V[ 3 4 ] ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            let v = treeTestSplit(root, CON_SPLITV)
            treeTestLeaf(v, 3)
            let d = treeTestLeaf(v, 4)
            Yabai.tree_focus(d)

            // a window swaps with a neighbouring window
            #expect(tree_move(root, a, DIR_EAST, false) == TREE_RESULT_DONE)
            #expect(treeTestChild(root, 0) == 2)
            #expect(treeTestChild(root, 1) == 1)

            // and enters a neighbouring container, next to its last focused window
            #expect(tree_move(root, a, DIR_EAST, false) == TREE_RESULT_DONE)
            #expect(root.child_count == 2)
            #expect(v.child_count == 3)
            #expect(treeTestChild(v, 0) == 3)
            #expect(treeTestChild(v, 1) == 4)
            #expect(treeTestChild(v, 2) == 1)

            // a vertical move inside the vertical split swaps
            #expect(tree_move(root, a, DIR_NORTH, false) == TREE_RESULT_DONE)
            #expect(treeTestChild(v, 1) == 1)

            // leaving the container at its edge places the window next to it in the workspace
            #expect(tree_move(root, a, DIR_EAST, false) == TREE_RESULT_DONE)
            #expect(root.child_count == 3)
            #expect(treeTestChild(root, 2) == 1)
            #expect(v.child_count == 2)

            // at the edge of the workspace a display in that direction is used
            #expect(tree_move(root, a, DIR_EAST, true) == TREE_RESULT_OUTPUT)
            #expect(tree_move(root, a, DIR_EAST, false) == TREE_RESULT_NONE)

            Yabai.con_free(root)
        }

        @Test("tree_move_force_orientation")
        func treeMoveForceOrientation()
        {
            // H[ 1 2 ]: moving 2 down re-orients the workspace to V[ H[1] 2 ]
            let root = Yabai.con_create(CON_SPLITH)!
            treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            #expect(tree_move(root, b, DIR_SOUTH, false) == TREE_RESULT_DONE)
            #expect(root.layout == CON_SPLITV)
            #expect(root.child_count == 2)
            #expect(root.children[0].layout == CON_SPLITH)
            #expect(treeTestChild(root.children[0], 0) == 1)
            #expect(treeTestChild(root, 1) == 2)

            // moving it back up enters the horizontal container next to window 1, like i3 does
            #expect(tree_move(root, b, DIR_NORTH, false) == TREE_RESULT_DONE)
            #expect(root.child_count == 1)
            #expect(treeTestChild(root.children[0], 0) == 1)
            #expect(treeTestChild(root.children[0], 1) == 2)

            Yabai.con_free(root)
        }

        @Test("tree_move_tabbed")
        func treeMoveTabbed()
        {
            // H[ 1 T[ 2 3 ] ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            treeTestLeaf(t, 2)
            let c = treeTestLeaf(t, 3)

            // moving inside the tabs reorders them
            #expect(tree_move(root, c, DIR_WEST, false) == TREE_RESULT_DONE)
            #expect(treeTestChild(t, 0) == 3)

            // the first tab leaves the container to the west
            #expect(tree_move(root, c, DIR_WEST, false) == TREE_RESULT_DONE)
            #expect(root.child_count == 3)
            #expect(treeTestChild(root, 1) == 3)
            #expect(t.child_count == 1)

            // and a window moving into the tabbed container becomes a tab
            #expect(tree_move(root, c, DIR_EAST, false) == TREE_RESULT_DONE)
            #expect(t.child_count == 2)
            #expect(treeTestChild(t, 0) == 3)
            #expect(tree_move(root, a, DIR_EAST, false) == TREE_RESULT_DONE)
            #expect(t.child_count == 3)
            #expect(root.child_count == 1)

            Yabai.con_free(root)
        }

        @Test("tree_split_layout")
        func treeSplitLayout()
        {
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            // splitting wraps the window, so the next window opens below it
            tree_split(b, CON_VERTICAL)
            let v = b.parent!
            #expect(v != root)
            #expect(v.layout == CON_SPLITV)
            #expect(v.child_count == 1)
            #expect(root.children[1] == v)

            // splitting the only child again just changes the orientation
            tree_split(b, CON_HORIZONTAL)
            #expect(b.parent == v)
            #expect(v.layout == CON_SPLITH)

            // tabbed on a workspace window wraps the workspace in a tabbed container
            tree_set_layout(a, CON_TABBED)
            #expect(root.child_count == 1)
            let t = a.parent!
            #expect(t.layout == CON_TABBED)
            #expect(t.parent == root)

            // toggle returns to the last split layout, toggle split flips the orientation
            #expect(tree_toggle_layout(a, false) == CON_SPLITH)
            #expect(t.layout == CON_SPLITH)
            #expect(tree_toggle_layout(a, true) == CON_SPLITV)
            #expect(tree_toggle_layout(a, false) == CON_TABBED)
            #expect(tree_toggle_layout(a, false) == CON_SPLITV)

            Yabai.con_free(root)
        }

        @Test("tree_insert_relative")
        func treeInsertRelative()
        {
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            // east of a window in a horizontal split is a plain sibling
            Yabai.tree_insert_relative(a, treeTestCon(3), DIR_EAST)
            #expect(treeTestChild(root, 1) == 3)

            // south of it splits the window
            Yabai.tree_insert_relative(b, treeTestCon(4), DIR_SOUTH)
            #expect(b.parent.layout == CON_SPLITV)
            #expect(treeTestChild(b.parent, 1) == 4)

            // stacking creates a tabbed container around the target
            Yabai.tree_insert_relative(a, treeTestCon(5), STACK)
            #expect(a.parent.layout == CON_TABBED)
            #expect(treeTestChild(a.parent, 1) == 5)
            #expect(root.children[0] == a.parent)

            Yabai.con_free(root)
        }

        @Test("tree_resize_update")
        func treeResizeUpdate()
        {
            // H[ 1 V[ 2 3 ] ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, CON_SPLITV)
            let b = treeTestLeaf(v, 2)
            let c = treeTestLeaf(v, 3)
            let full = area(x: 0, y: 0, w: 1010, h: 810)

            Yabai.tree_update(root, full, 10, 24, 0, 0)
            #expect(Int32(a.area.w) == 500)
            #expect(Int32(v.area.x) == 510)
            #expect(Int32(b.area.h) == 400)
            #expect(Int32(c.area.y) == 410)

            // growing the right edge of window 2 searches up to the horizontal split
            #expect(tree_resize(b, DIR_WEST, -100) == true)
            Yabai.tree_update(root, full, 10, 24, 0, 0)
            #expect(Int32(a.area.w) == 401)
            #expect(tree_resize(a, DIR_WEST, 10) == false)

            // the children of a tabbed container share its area below the bar
            tree_set_layout(b, CON_TABBED)
            Yabai.tree_update(root, full, 10, 24, 0, 0)
            #expect(Int32(b.area.y) == 24)
            #expect(Int32(c.area.y) == 24)
            #expect(Int32(c.area.h) == 786)

            // the bar offset moves them further down, or up under the bar when negative
            Yabai.tree_update(root, full, 10, 24, 6, 0)
            #expect(Int32(c.area.y) == 30)
            #expect(Int32(c.area.h) == 780)
            Yabai.tree_update(root, full, 10, 24, -30, 0)
            #expect(Int32(c.area.y) == 0)
            #expect(Int32(c.area.h) == 810)

            // a backdrop card insets the windows from every edge of the container, below the bar
            Yabai.tree_update(root, full, 10, 24, 4, 6)
            #expect(Int32(c.area.x) == Int32(b.area.x))
            #expect(Int32(c.area.x) == Int32(v.area.x) + 6)
            #expect(Int32(c.area.w) == Int32(v.area.w) - 12)
            #expect(Int32(c.area.y) == 6 + 24 + 4)
            #expect(Int32(c.area.h) == 810 - 12 - 24 - 4)
            Yabai.tree_update(root, full, 10, 24, 0, 0)

            // and resizing a tab skips the tabbed container
            #expect(tree_resize(c, DIR_SOUTH, 10) == false)

            tree_balance(root)
            #expect(percent(a) == 50)

            Yabai.con_free(root)
        }

        @Test("tree_rotate_mirror_swap")
        func treeRotateMirrorSwap()
        {
            // H[ 1 V[ 2 3 ] ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, CON_SPLITV)
            let b = treeTestLeaf(v, 2)
            treeTestLeaf(v, 3)

            tree_rotate(root, 90)
            #expect(root.layout == CON_SPLITV)
            #expect(v.layout == CON_SPLITH)
            #expect(root.children[1] == a)

            tree_mirror(root, CON_HORIZONTAL)
            #expect(treeTestChild(v, 0) == 3)

            tree_swap(a, b)
            #expect(root.children[1] == b)
            #expect(a.parent == v)

            Yabai.con_free(root)
        }

        @Test("tree_focus_candidate")
        func treeFocusCandidate()
        {
            // H[ 1 T[ 2 3 ] ]: closing the active tab focuses the tab focused before it
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            let b = treeTestLeaf(t, 2)
            let c = treeTestLeaf(t, 3)

            Yabai.tree_focus(b)
            Yabai.tree_focus(c)
            Yabai.tree_focus(a)
            Yabai.tree_focus(c)
            #expect(treeTestWindow(tree_focus_candidate(c)) == 2)

            // the last window of a container hands focus to the previously focused sibling of the container
            Yabai.tree_detach(b)
            Yabai.con_free(b)
            #expect(treeTestWindow(tree_focus_candidate(c)) == 1)

            Yabai.con_free(root)
        }

        @Test("tree_flatten_same_orientation")
        func treeFlattenSameOrientation()
        {
            // H[ H[ 1 2 ] ] flattens to H[ 1 2 ], keeping the shares
            let root = Yabai.con_create(CON_SPLITH)!
            let h = treeTestSplit(root, CON_SPLITH)
            let a = treeTestLeaf(h, 1)
            treeTestLeaf(h, 2)
            a.percent = 0.7
            h.children[1].percent = 0.3
            Yabai.tree_focus(a)

            Yabai.tree_flatten(root)
            #expect(root.child_count == 2)
            #expect(treeTestChild(root, 0) == 1)
            #expect(percent(a, 10) == 7)
            #expect(root.focus[0] == a)

            Yabai.con_free(root)
        }

        @Test("tree_autotiling")
        func treeAutotiling()
        {
            // a wide window in a vertical split is split side by side
            var root = Yabai.con_create(CON_SPLITV)!
            var a = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            a.area.w = 800
            a.area.h = 400

            tree_autotile(a)
            #expect(a.parent != root)
            #expect(a.parent.layout == CON_SPLITH)
            #expect(a.parent.parent == root)

            // a tall window in a vertical split stays, the new window goes below it
            let b = root.children[1]
            b.area.w = 400
            b.area.h = 800
            tree_autotile(b)
            #expect(b.parent == root)
            Yabai.con_free(root)

            // a tall window in a horizontal split is split on top of each other
            root = Yabai.con_create(CON_SPLITH)!
            a = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            a.area.w = 500
            a.area.h = 1000

            tree_autotile(a)
            #expect(a.parent != root)
            #expect(a.parent.layout == CON_SPLITV)
            Yabai.con_free(root)

            // a tab is never split
            root = Yabai.con_create(CON_SPLITH)!
            let tabbed = treeTestSplit(root, CON_TABBED)
            a = treeTestLeaf(tabbed, 1)
            treeTestLeaf(tabbed, 2)
            a.area.w = 500
            a.area.h = 1000

            tree_autotile(a)
            #expect(a.parent == tabbed)
            #expect(tabbed.layout == CON_TABBED)
            Yabai.con_free(root)
        }

        @Test("tree_set_layout_single_tab")
        func treeSetLayoutSingleTab()
        {
            // H[ 1 T[ V[ 2 ] ] ]: splitting a single tab nests a split inside the tabbed container
            let root = Yabai.con_create(CON_SPLITH)!
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            let a = treeTestLeaf(t, 2)
            tree_split(a, CON_VERTICAL)
            #expect(a.parent.parent == t)
            #expect(a.parent.layout == CON_SPLITV)

            // switching it to tabbed closes the redundant split instead of nesting a tabbed container, like i3
            tree_set_layout(a, CON_TABBED)
            #expect(a.parent == t)
            #expect(t.layout == CON_TABBED)
            #expect(root.children[1] == t)

            // and toggling back and forth keeps a single container
            tree_toggle_layout(a, false)
            #expect(t.layout == CON_SPLITV)
            tree_toggle_layout(a, false)
            #expect(t.layout == CON_TABBED)
            #expect(a.parent == t)
            #expect(t.parent == root)

            Yabai.con_free(root)
        }

        @Test("tree_workspace_layout_tabbed")
        func treeWorkspaceLayoutTabbed()
        {
            let sm = space_manager_global()
            let workspaceTabbed = sm.tree_workspace_tabbed
            sm.tree_workspace_tabbed = true
            defer { sm.tree_workspace_tabbed = workspaceTabbed }

            // the first window of an empty workspace opens in a tabbed container
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestCon(1)
            tree_open_con(root, a, nil, false)
            #expect(root.child_count == 1)
            #expect(root.children[0].layout == CON_TABBED)
            let t = a.parent!

            let b = treeTestCon(2)
            tree_open_con(root, b, a, false)
            #expect(b.parent == t)
            Yabai.tree_focus(b)

            // a tab that moves out to the workspace gets its own tabbed container, like i3 workspace_layout
            #expect(tree_move(root, a, DIR_WEST, false) == TREE_RESULT_DONE)
            #expect(root.child_count == 2)
            #expect(root.children[0].layout == CON_TABBED)
            #expect(treeTestChild(root.children[0], 0) == 1)
            #expect(root.children[1] == t)

            Yabai.con_free(root)
        }

        @Test("tree_insert_focus_order")
        func treeInsertFocusOrder()
        {
            // H[ V[ 1 2 ] T[ 3 4 ] 5 ], with 5 focused and tab 3 active
            let root = Yabai.con_create(CON_SPLITH)!
            let v = treeTestSplit(root, CON_SPLITV)
            let a = treeTestLeaf(v, 1)
            let b = treeTestLeaf(v, 2)
            let t = treeTestSplit(root, CON_TABBED)
            let c = treeTestLeaf(t, 3)
            let d = treeTestLeaf(t, 4)
            let e = treeTestLeaf(root, 5)
            Yabai.tree_focus(c)
            Yabai.tree_focus(e)

            // a window that was focused less recently than the tabs does not become the active tab
            tree_insert_con(b, c, TREE_AFTER)
            #expect(t.children[1] == b)
            #expect(t.focus[0] == c)

            // the focused window takes the focus with it
            Yabai.tree_focus(a)
            tree_insert_con(a, d, TREE_AFTER)
            #expect(t.focus[0] == a)
            #expect(root.focus[0] == t)
            #expect(root.child_count == 2)
            #expect(tree_descend_focused(root) == a)

            Yabai.con_free(root)
        }

        @Test("tree_open_con_selected")
        func treeOpenConSelected()
        {
            // H[ 1 V[ 2 3 ] 4 ]
            let root = Yabai.con_create(CON_SPLITH)!
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, CON_SPLITV)
            treeTestLeaf(v, 2)
            treeTestLeaf(v, 3)
            treeTestLeaf(root, 4)

            // a window opens after the selected container, not inside of it, like i3 and sway
            let e = treeTestCon(5)
            tree_open_con(root, e, v, false)
            #expect(v.child_count == 2)
            #expect(root.children[2] == e)

            // with the workspace selected it opens after its most recently focused child
            Yabai.tree_focus(a)
            let f = treeTestCon(6)
            tree_open_con(root, f, root, false)
            #expect(root.children[1] == f)

            Yabai.con_free(root)
        }

        @Test("tree_attach_from_direction")
        func treeAttachFromDirection()
        {
            // H[ 1 2 ] receives T[ 3 4 ] from another display
            let root = Yabai.con_create(CON_SPLITH)!
            let x = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            let t = Yabai.con_create(CON_TABBED)!
            treeTestLeaf(t, 3)
            treeTestLeaf(t, 4)

            // along the layout of the workspace it arrives on the near side, with its structure
            tree_attach_from_direction(root, t, DIR_EAST)
            #expect(root.children[0] == t)
            #expect(t.child_count == 2)
            #expect(root.focus[0] == t)

            Yabai.tree_detach(t)
            tree_attach_from_direction(root, t, DIR_WEST)
            #expect(root.children[2] == t)

            // across it, it arrives next to the window focused there
            Yabai.tree_detach(t)
            Yabai.tree_focus(x)
            tree_attach_from_direction(root, t, DIR_SOUTH)
            #expect(root.child_count == 3)
            #expect(root.children[1] == t)

            // an empty workspace takes it as it is
            let empty = Yabai.con_create(CON_SPLITH)!
            Yabai.tree_detach(t)
            tree_attach_from_direction(empty, t, DIR_NORTH)
            #expect(empty.children[0] == t)
            #expect(percent(t) == 100)

            Yabai.con_free(empty)
            Yabai.con_free(root)
        }

        @Test("tree_window_order_collect")
        func treeWindowOrderCollect()
        {
            /// `tree_test_order_is`
            func orderIs(_ list: [sa_window_order], _ index: Int, _ aWid: UInt32, _ order: Int32, _ bWid: UInt32) -> Bool
            {
                if index >= list.count { return false }
                return list[index].a_wid == aWid && list[index].order == order && list[index].b_wid == bWid
            }

            // H[ 1 T[ 2 V[ 3 4 ] T[ 5 6 ] ] ] with 3 focused and 5 the active tab of the hidden tabbed container
            let root = Yabai.con_create(CON_SPLITH)!
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            treeTestLeaf(t, 2)
            let v = treeTestSplit(t, CON_SPLITV)
            let c3 = treeTestLeaf(v, 3)
            treeTestLeaf(v, 4)
            let t2 = treeTestSplit(t, CON_TABBED)
            let c5 = treeTestLeaf(t2, 5)
            let c6 = treeTestLeaf(t2, 6)
            Yabai.tree_focus(c6)
            Yabai.tree_focus(c5)
            Yabai.tree_focus(c3)

            // ordering below collects every window, hidden tabs included
            var list: [sa_window_order] = []
            treeCollectWindowOrder(t, -1, 99, &list)
            #expect(list.count == 5)
            #expect(orderIs(list, 0, 2, -1, 99))
            #expect(list.map(\.a_wid) == [2, 3, 4, 5, 6])
            #expect(orderIs(list, 4, 6, -1, 99))

            // ordering above skips hidden tabs and the relative window itself
            list = []
            treeCollectWindowOrder(root, 1, 3, &list)
            #expect(list.count == 2)
            #expect(orderIs(list, 0, 1, 1, 3))
            #expect(orderIs(list, 1, 4, 1, 3))

            list = []
            treeCollectWindowOrder(v, -1, 4, &list)
            #expect(list.map(\.a_wid) == [3])

            // a tab change orders the other tabs below the focused window, then the rest of the active tab above it
            list = []
            treeCollectTabOrder(root, false, &list)
            #expect(list.count == 4)
            #expect(orderIs(list, 0, 2, -1, 3))
            #expect(orderIs(list, 1, 5, -1, 3))
            #expect(orderIs(list, 2, 6, -1, 3))
            #expect(orderIs(list, 3, 4, 1, 3))

            // nothing to do until the active tab changes, unless forced
            list = []
            treeCollectTabOrder(root, false, &list)
            #expect(list.count == 0)
            treeCollectTabOrder(root, true, &list)
            #expect(list.count == 4)

            // switching to the tab that holds 2 orders every other window of the container below it
            list = []
            Yabai.tree_focus(t.children[0])
            treeCollectTabOrder(root, false, &list)
            #expect(list.count == 4)
            #expect(orderIs(list, 0, 3, -1, 2))
            #expect(orderIs(list, 3, 6, -1, 2))

            Yabai.con_free(root)
        }

        @Test("tree_card_order")
        func treeCardOrder()
        {
            // H[ 1 T[ 2 V[ 3 4 ] ] ] with 3 focused
            let root = Yabai.con_create(CON_SPLITH)!
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            treeTestLeaf(t, 2)
            let v = treeTestSplit(t, CON_SPLITV)
            let c3 = treeTestLeaf(v, 3)
            treeTestLeaf(v, 4)
            Yabai.tree_focus(c3)

            // a card ordered below the focused window of a split tab orders the rest of the tab above it again
            var list: [sa_window_order] = []
            treeCollectCardOrder(root, 3, &list)
            #expect(list.count == 1)
            #expect(list.first.map { $0.a_wid == 4 && $0.order == 1 && $0.b_wid == 3 } == true)

            // a card below any other window, or below the window of a single-window tab, orders nothing
            list = []
            treeCollectCardOrder(root, 4, &list)
            #expect(list.isEmpty)
            Yabai.tree_focus(t.children[0])
            treeCollectCardOrder(root, 2, &list)
            #expect(list.isEmpty)

            Yabai.con_free(root)
        }

        @Test("tree_window_ids_collect")
        func treeWindowIDsCollect()
        {
            // H[ 1 T[ 2 V[ 3 4 ] ] ]: every window, hidden tabs included, in tree order
            let root = Yabai.con_create(CON_SPLITH)!
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, CON_TABBED)
            treeTestLeaf(t, 2)
            let v = treeTestSplit(t, CON_SPLITV)
            treeTestLeaf(v, 3)
            treeTestLeaf(v, 4)

            var list: [UInt32] = []
            tree_collect_window_ids(root, &list)
            #expect(list == [1, 2, 3, 4])

            list = []
            tree_collect_window_ids(t, &list)
            #expect(list == [2, 3, 4])

            list = []
            tree_collect_window_ids(v.children[1], &list)
            #expect(list == [4])

            Yabai.con_free(root)
        }

        @Test("tree_view_window_list_order")
        func treeViewWindowListOrder()
        {
            let root = Yabai.con_create(CON_SPLITH)!
            let tabs = treeTestSplit(root, CON_TABBED)
            for wid in UInt32(1)...10 { treeTestLeaf(tabs, wid) }
            for wid in UInt32(11)...20 { treeTestLeaf(root, wid) }
            let target = treeViewTestView(root)

            // NOTE: the C test checked that the list grows past its initial capacity; the list is an array now
            #expect(treeViewWindowList(target) == Array(UInt32(1)...20))

            let empty = treeViewTestView(nil)
            #expect(treeViewWindowList(empty).isEmpty)

            Yabai.con_free(root)
        }

        @Test("tree_view_zoom_frames")
        func treeViewZoomFrames()
        {
            let root = Yabai.con_create(CON_SPLITH)!
            let split = treeTestSplit(root, CON_SPLITV)
            let a = treeTestLeaf(split, 1)
            let b = treeTestLeaf(root, 2)
            let target = treeViewTestView(root)

            root.area  = area(x: 0,   y: 0, w: 1000, h: 800)
            split.area = area(x: 0,   y: 0, w: 500,  h: 800)
            a.area     = area(x: 0,   y: 0, w: 500,  h: 400)
            b.area     = area(x: 500, y: 0, w: 500,  h: 800)

            #expect(treeHasZoom(root, CON_ZOOM_NONE) == false)
            #expect(Int32(tree_con_frame(target, a).h) == 400)

            a.zoom = CON_ZOOM_PARENT
            #expect(treeHasZoom(root, CON_ZOOM_NONE) == true)
            #expect(treeHasZoom(root, CON_ZOOM_FULLSCREEN) == false)
            #expect(Int32(tree_con_frame(target, a).h) == 800)
            #expect(Int32(tree_con_frame(target, a).w) == 500)

            a.zoom = CON_ZOOM_FULLSCREEN
            #expect(treeHasZoom(root, CON_ZOOM_FULLSCREEN) == true)
            #expect(Int32(tree_con_frame(target, a).w) == 1000)

            #expect(treeContainsWindow(root, 2) == true)
            #expect(treeContainsWindow(root, 3) == false)
            #expect(treeContainsWindow(root, 0) == false)

            Yabai.con_free(root)
        }
    }
}
