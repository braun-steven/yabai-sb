import Testing
import CPrivate
import YabaiCore
@testable import Yabai

//
// NOTE: Tree layout tests share space-manager state, so they run in DaemonState.
//

private func treeTestWindow(_ node: Con?) -> WindowID?
{
    guard let node, node.isLeaf else { return nil }
    return node.windowID
}

private func treeTestChild(_ node: Con, _ index: Int) -> WindowID?
{
    return index < node.children.count ? treeTestWindow(node.children[Int(index)]) : nil
}

/// A share of space in percent, rounded to the nearest integer.
private func percent(_ node: Con, _ scale: Float = 100) -> Int
{
    return Int(node.percent * scale + 0.5)
}

/// A leaf that is not part of a tree.
private func treeTestCon(_ windowID: WindowID) -> Con
{
    let node = Con(windowID: windowID)
    return node
}

private func treeViewTestView(_ root: Con?) -> View
{
    let target = View(sid: 1)
    target.layout = .tree
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
            SpaceManager.shared.treeWorkspaceTabbed = false
        }

        @Test("tree_attach_detach")
        func treeAttachDetach()
        {
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            #expect(root.children.count == 2)
            #expect(percent(a) == 50)
            #expect(percent(b) == 50)

            // a new child gets the average share and the shares are normalised
            let c = treeTestLeaf(root, 3)
            #expect(percent(c, 300) == 100)

            // detaching the last window of a container closes the container, but never the workspace
            let v = treeTestSplit(root, .splitV)
            let d = treeTestLeaf(v, 4)
            #expect(root.children.count == 4)
            #expect(d.detach() == root)
            d.destroy()
            #expect(root.children.count == 3)

            #expect(a.detach() == root)
            #expect(b.detach() == root)
            #expect(c.detach() == root)
            #expect(root.children.count == 0)

            a.destroy()
            b.destroy()
            c.destroy()
            root.destroy()
        }

        @Test("tree_flatten")
        func treeFlatten()
        {
            // H[ V[ H[1 2] ] 3 ] flattens to H[1 2 3]
            let root = Con(layout: .splitH)
            let v = treeTestSplit(root, .splitV)
            let h = treeTestSplit(v, .splitH)
            treeTestLeaf(h, 1)
            treeTestLeaf(h, 2)
            treeTestLeaf(root, 3)

            root.flatten()
            #expect(root.children.count == 3)
            #expect(treeTestChild(root, 0) == 1)
            #expect(treeTestChild(root, 1) == 2)
            #expect(treeTestChild(root, 2) == 3)

            var total: Float = 0.0
            for i in 0..<Int(root.children.count) { total += root.children[i].percent }
            #expect(Int(total * 100 + 0.5) == 100)

            // a single split around a window is kept, so that the next window opens inside of it
            let w = treeTestSplit(root, .splitV)
            treeTestLeaf(w, 4)
            root.flatten()
            #expect(root.children.count == 4)
            #expect(root.children[3] == w)

            root.destroy()
        }

        @Test("tree_focus_direction")
        func treeFocusDirection()
        {
            // H[ 1 V[ 2 3 ] 4 ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, .splitV)
            let b = treeTestLeaf(v, 2)
            let c = treeTestLeaf(v, 3)
            let d = treeTestLeaf(root, 4)

            c.focus()
            a.focus()

            // entering the vertical split restores the window focused there last
            #expect(treeTestWindow(a.neighbor(.east, wrapping: .on, hasOutput: false).target) == 3)

            #expect(treeTestWindow(c.neighbor(.north, wrapping: .on, hasOutput: false).target) == 2)

            #expect(treeTestWindow(b.neighbor(.east, wrapping: .on, hasOutput: false).target) == 4)

            // at the edge of the workspace, a display in that direction comes first
            #expect(d.neighbor(.east, wrapping: .on, hasOutput: true) == .output)

            // otherwise focus wraps around, unless wrapping is off
            #expect(treeTestWindow(d.neighbor(.east, wrapping: .on, hasOutput: false).target) == 1)
            #expect(d.neighbor(.east, wrapping: .off, hasOutput: false) == TreeNeighbor.none)

            // 'up' from the top of the vertical split has nowhere to go and wraps within it
            #expect(treeTestWindow(b.neighbor(.north, wrapping: .on, hasOutput: false).target) == 3)

            // forced wrapping stays inside the innermost container
            #expect(treeTestWindow(c.neighbor(.south, wrapping: .force, hasOutput: true).target) == 2)

            root.destroy()
        }

        @Test("tree_focus_tabbed")
        func treeFocusTabbed()
        {
            // H[ 1 T[ 2 3 ] ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            let b = treeTestLeaf(t, 2)
            let c = treeTestLeaf(t, 3)

            b.focus()

            // tabs are laid out horizontally, so east/west cycles them
            #expect(treeTestWindow(b.neighbor(.east, wrapping: .on, hasOutput: false).target) == 3)
            #expect(treeTestWindow(b.neighbor(.west, wrapping: .on, hasOutput: false).target) == 1)

            // only the active tab is visible
            #expect(b.isVisible == true)
            #expect(c.isVisible == false)
            c.focus()
            #expect(b.isVisible == false)
            #expect(a.isVisible == true)

            root.destroy()
        }

        @Test("tree_move_within")
        func treeMoveWithin()
        {
            // H[ 1 2 V[ 3 4 ] ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            let v = treeTestSplit(root, .splitV)
            treeTestLeaf(v, 3)
            let d = treeTestLeaf(v, 4)
            d.focus()

            // a window swaps with a neighbouring window
            #expect(a.move(.east, in: root, hasOutput: false) == .done)
            #expect(treeTestChild(root, 0) == 2)
            #expect(treeTestChild(root, 1) == 1)

            // and enters a neighbouring container, next to its last focused window
            #expect(a.move(.east, in: root, hasOutput: false) == .done)
            #expect(root.children.count == 2)
            #expect(v.children.count == 3)
            #expect(treeTestChild(v, 0) == 3)
            #expect(treeTestChild(v, 1) == 4)
            #expect(treeTestChild(v, 2) == 1)

            // a vertical move inside the vertical split swaps
            #expect(a.move(.north, in: root, hasOutput: false) == .done)
            #expect(treeTestChild(v, 1) == 1)

            // leaving the container at its edge places the window next to it in the workspace
            #expect(a.move(.east, in: root, hasOutput: false) == .done)
            #expect(root.children.count == 3)
            #expect(treeTestChild(root, 2) == 1)
            #expect(v.children.count == 2)

            // at the edge of the workspace a display in that direction is used
            #expect(a.move(.east, in: root, hasOutput: true) == .output)
            #expect(a.move(.east, in: root, hasOutput: false) == .none)

            root.destroy()
        }

        @Test("tree_move_force_orientation")
        func treeMoveForceOrientation()
        {
            // H[ 1 2 ]: moving 2 down re-orients the workspace to V[ H[1] 2 ]
            let root = Con(layout: .splitH)
            treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            #expect(b.move(.south, in: root, hasOutput: false) == .done)
            #expect(root.layout == .splitV)
            #expect(root.children.count == 2)
            #expect(root.children[0].layout == .splitH)
            #expect(treeTestChild(root.children[0], 0) == 1)
            #expect(treeTestChild(root, 1) == 2)

            // moving it back up enters the horizontal container next to window 1, like i3 does
            #expect(b.move(.north, in: root, hasOutput: false) == .done)
            #expect(root.children.count == 1)
            #expect(treeTestChild(root.children[0], 0) == 1)
            #expect(treeTestChild(root.children[0], 1) == 2)

            root.destroy()
        }

        @Test("tree_move_tabbed")
        func treeMoveTabbed()
        {
            // H[ 1 T[ 2 3 ] ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            treeTestLeaf(t, 2)
            let c = treeTestLeaf(t, 3)

            // moving inside the tabs reorders them
            #expect(c.move(.west, in: root, hasOutput: false) == .done)
            #expect(treeTestChild(t, 0) == 3)

            // the first tab leaves the container to the west
            #expect(c.move(.west, in: root, hasOutput: false) == .done)
            #expect(root.children.count == 3)
            #expect(treeTestChild(root, 1) == 3)
            #expect(t.children.count == 1)

            // and a window moving into the tabbed container becomes a tab
            #expect(c.move(.east, in: root, hasOutput: false) == .done)
            #expect(t.children.count == 2)
            #expect(treeTestChild(t, 0) == 3)
            #expect(a.move(.east, in: root, hasOutput: false) == .done)
            #expect(t.children.count == 3)
            #expect(root.children.count == 1)

            root.destroy()
        }

        @Test("tree_split_layout")
        func treeSplitLayout()
        {
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            // splitting wraps the window, so the next window opens below it
            b.split(.vertical)
            let v = b.parent!
            #expect(v != root)
            #expect(v.layout == .splitV)
            #expect(v.children.count == 1)
            #expect(root.children[1] == v)

            // splitting the only child again just changes the orientation
            b.split(.horizontal)
            #expect(b.parent == v)
            #expect(v.layout == .splitH)

            // tabbed on a workspace window wraps the workspace in a tabbed container
            a.setLayout(.tabbed)
            #expect(root.children.count == 1)
            let t = a.parent!
            #expect(t.layout == .tabbed)
            #expect(t.parent == root)

            // toggle returns to the last split layout, toggle split flips the orientation
            #expect(a.toggleLayout(splitOnly: false) == .splitH)
            #expect(t.layout == .splitH)
            #expect(a.toggleLayout(splitOnly: true) == .splitV)
            #expect(a.toggleLayout(splitOnly: false) == .tabbed)
            #expect(a.toggleLayout(splitOnly: false) == .splitV)

            root.destroy()
        }

        @Test("tree_insert_relative")
        func treeInsertRelative()
        {
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let b = treeTestLeaf(root, 2)

            // east of a window in a horizontal split is a plain sibling
            a.insert(treeTestCon(3), toward: .east)
            #expect(treeTestChild(root, 1) == 3)

            // south of it splits the window
            b.insert(treeTestCon(4), toward: .south)
            #expect(b.parent?.layout == .splitV)
            #expect(treeTestChild(b.parent!, 1) == 4)

            // stacking creates a tabbed container around the target
            a.insert(treeTestCon(5), toward: .stack)
            #expect(a.parent?.layout == .tabbed)
            #expect(treeTestChild(a.parent!, 1) == 5)
            #expect(root.children[0] == a.parent)

            root.destroy()
        }

        @Test("tree_resize_update")
        func treeResizeUpdate()
        {
            // H[ 1 V[ 2 3 ] ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, .splitV)
            let b = treeTestLeaf(v, 2)
            let c = treeTestLeaf(v, 3)
            let full = Area(x: 0, y: 0, w: 1010, h: 810)

            root.layOut(full, gap: 10, barHeight: 24, barOffset: 0, barInset: 0)
            #expect(Int(a.area.w) == 500)
            #expect(Int(v.area.x) == 510)
            #expect(Int(b.area.h) == 400)
            #expect(Int(c.area.y) == 410)

            // growing the right edge of window 2 searches up to the horizontal split
            #expect(b.resize(.west, by: -100) == true)
            root.layOut(full, gap: 10, barHeight: 24, barOffset: 0, barInset: 0)
            #expect(Int(a.area.w) == 401)
            #expect(a.resize(.west, by: 10) == false)

            // the children of a tabbed container share its area below the bar
            b.setLayout(.tabbed)
            root.layOut(full, gap: 10, barHeight: 24, barOffset: 0, barInset: 0)
            #expect(Int(b.area.y) == 24)
            #expect(Int(c.area.y) == 24)
            #expect(Int(c.area.h) == 786)

            // the bar offset moves them further down, or up under the bar when negative
            root.layOut(full, gap: 10, barHeight: 24, barOffset: 6, barInset: 0)
            #expect(Int(c.area.y) == 30)
            #expect(Int(c.area.h) == 780)
            root.layOut(full, gap: 10, barHeight: 24, barOffset: -30, barInset: 0)
            #expect(Int(c.area.y) == 0)
            #expect(Int(c.area.h) == 810)

            // a backdrop card insets the windows from every edge of the container, below the bar
            root.layOut(full, gap: 10, barHeight: 24, barOffset: 4, barInset: 6)
            #expect(Int(c.area.x) == Int(b.area.x))
            #expect(Int(c.area.x) == Int(v.area.x) + 6)
            #expect(Int(c.area.w) == Int(v.area.w) - 12)
            #expect(Int(c.area.y) == 6 + 24 + 4)
            #expect(Int(c.area.h) == 810 - 12 - 24 - 4)
            root.layOut(full, gap: 10, barHeight: 24, barOffset: 0, barInset: 0)

            // and resizing a tab skips the tabbed container
            #expect(c.resize(.south, by: 10) == false)

            root.balance()
            #expect(percent(a) == 50)

            root.destroy()
        }

        @Test("tree_rotate_mirror_swap")
        func treeRotateMirrorSwap()
        {
            // H[ 1 V[ 2 3 ] ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, .splitV)
            let b = treeTestLeaf(v, 2)
            treeTestLeaf(v, 3)

            root.rotate(by: 90)
            #expect(root.layout == .splitV)
            #expect(v.layout == .splitH)
            #expect(root.children[1] == a)

            root.mirror(.horizontal)
            #expect(treeTestChild(v, 0) == 3)

            a.swap(with: b)
            #expect(root.children[1] == b)
            #expect(a.parent == v)

            root.destroy()
        }

        @Test("tree_focus_candidate")
        func treeFocusCandidate()
        {
            // H[ 1 T[ 2 3 ] ]: closing the active tab focuses the tab focused before it
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            let b = treeTestLeaf(t, 2)
            let c = treeTestLeaf(t, 3)

            b.focus()
            c.focus()
            a.focus()
            c.focus()
            #expect(treeTestWindow(c.focusCandidate) == 2)

            // the last window of a container hands focus to the previously focused sibling of the container
            b.detach()
            b.destroy()
            #expect(treeTestWindow(c.focusCandidate) == 1)

            root.destroy()
        }

        @Test("tree_flatten_same_orientation")
        func treeFlattenSameOrientation()
        {
            // H[ H[ 1 2 ] ] flattens to H[ 1 2 ], keeping the shares
            let root = Con(layout: .splitH)
            let h = treeTestSplit(root, .splitH)
            let a = treeTestLeaf(h, 1)
            treeTestLeaf(h, 2)
            a.percent = 0.7
            h.children[1].percent = 0.3
            a.focus()

            root.flatten()
            #expect(root.children.count == 2)
            #expect(treeTestChild(root, 0) == 1)
            #expect(percent(a, 10) == 7)
            #expect(root.focusOrder[0] == a)

            root.destroy()
        }

        @Test("tree_autotiling")
        func treeAutotiling()
        {
            // a wide window in a vertical split is split side by side
            var root = Con(layout: .splitV)
            var a = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            a.area.w = 800
            a.area.h = 400

            a.autotile()
            #expect(a.parent != root)
            #expect(a.parent?.layout == .splitH)
            #expect(a.parent?.parent == root)

            // a tall window in a vertical split stays, the new window goes below it
            let b = root.children[1]
            b.area.w = 400
            b.area.h = 800
            b.autotile()
            #expect(b.parent == root)
            root.destroy()

            // a tall window in a horizontal split is split on top of each other
            root = Con(layout: .splitH)
            a = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            a.area.w = 500
            a.area.h = 1000

            a.autotile()
            #expect(a.parent != root)
            #expect(a.parent?.layout == .splitV)
            root.destroy()

            // a tab is never split
            root = Con(layout: .splitH)
            let tabbed = treeTestSplit(root, .tabbed)
            a = treeTestLeaf(tabbed, 1)
            treeTestLeaf(tabbed, 2)
            a.area.w = 500
            a.area.h = 1000

            a.autotile()
            #expect(a.parent == tabbed)
            #expect(tabbed.layout == .tabbed)
            root.destroy()
        }

        @Test("tree_set_layout_single_tab")
        func treeSetLayoutSingleTab()
        {
            // H[ 1 T[ V[ 2 ] ] ]: splitting a single tab nests a split inside the tabbed container
            let root = Con(layout: .splitH)
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            let a = treeTestLeaf(t, 2)
            a.split(.vertical)
            #expect(a.parent?.parent == t)
            #expect(a.parent?.layout == .splitV)

            // switching it to tabbed closes the redundant split instead of nesting a tabbed container, like i3
            a.setLayout(.tabbed)
            #expect(a.parent == t)
            #expect(t.layout == .tabbed)
            #expect(root.children[1] == t)

            // and toggling back and forth keeps a single container
            a.toggleLayout(splitOnly: false)
            #expect(t.layout == .splitV)
            a.toggleLayout(splitOnly: false)
            #expect(t.layout == .tabbed)
            #expect(a.parent == t)
            #expect(t.parent == root)

            root.destroy()
        }

        @Test("tree_workspace_layout_tabbed")
        func treeWorkspaceLayoutTabbed()
        {
            let sm = SpaceManager.shared
            let workspaceTabbed = sm.treeWorkspaceTabbed
            sm.treeWorkspaceTabbed = true
            defer { sm.treeWorkspaceTabbed = workspaceTabbed }

            // the first window of an empty workspace opens in a tabbed container
            let root = Con(layout: .splitH)
            let a = treeTestCon(1)
            root.open(a, after: nil, autotile: false)
            #expect(root.children.count == 1)
            #expect(root.children[0].layout == .tabbed)
            let t = a.parent!

            let b = treeTestCon(2)
            root.open(b, after: a, autotile: false)
            #expect(b.parent == t)
            b.focus()

            // a tab that moves out to the workspace gets its own tabbed container, like i3 workspace_layout
            #expect(a.move(.west, in: root, hasOutput: false) == .done)
            #expect(root.children.count == 2)
            #expect(root.children[0].layout == .tabbed)
            #expect(treeTestChild(root.children[0], 0) == 1)
            #expect(root.children[1] == t)

            root.destroy()
        }

        @Test("tree_insert_focus_order")
        func treeInsertFocusOrder()
        {
            // H[ V[ 1 2 ] T[ 3 4 ] 5 ], with 5 focused and tab 3 active
            let root = Con(layout: .splitH)
            let v = treeTestSplit(root, .splitV)
            let a = treeTestLeaf(v, 1)
            let b = treeTestLeaf(v, 2)
            let t = treeTestSplit(root, .tabbed)
            let c = treeTestLeaf(t, 3)
            let d = treeTestLeaf(t, 4)
            let e = treeTestLeaf(root, 5)
            c.focus()
            e.focus()

            // a window that was focused less recently than the tabs does not become the active tab
            b.place(.after, of: c)
            #expect(t.children[1] == b)
            #expect(t.focusOrder[0] == c)

            // the focused window takes the focus with it
            a.focus()
            a.place(.after, of: d)
            #expect(t.focusOrder[0] == a)
            #expect(root.focusOrder[0] == t)
            #expect(root.children.count == 2)
            #expect(root.focusedDescendant == a)

            root.destroy()
        }

        @Test("tree_open_con_selected")
        func treeOpenConSelected()
        {
            // H[ 1 V[ 2 3 ] 4 ]
            let root = Con(layout: .splitH)
            let a = treeTestLeaf(root, 1)
            let v = treeTestSplit(root, .splitV)
            treeTestLeaf(v, 2)
            treeTestLeaf(v, 3)
            treeTestLeaf(root, 4)

            // a window opens after the selected container, not inside of it, like i3 and sway
            let e = treeTestCon(5)
            root.open(e, after: v, autotile: false)
            #expect(v.children.count == 2)
            #expect(root.children[2] == e)

            // with the workspace selected it opens after its most recently focused child
            a.focus()
            let f = treeTestCon(6)
            root.open(f, after: root, autotile: false)
            #expect(root.children[1] == f)

            root.destroy()
        }

        @Test("tree_attach_from_direction")
        func treeAttachFromDirection()
        {
            // H[ 1 2 ] receives T[ 3 4 ] from another display
            let root = Con(layout: .splitH)
            let x = treeTestLeaf(root, 1)
            treeTestLeaf(root, 2)
            let t = Con(layout: .tabbed)
            treeTestLeaf(t, 3)
            treeTestLeaf(t, 4)

            // along the layout of the workspace it arrives on the near side, with its structure
            root.attach(t, from: .east)
            #expect(root.children[0] == t)
            #expect(t.children.count == 2)
            #expect(root.focusOrder[0] == t)

            t.detach()
            root.attach(t, from: .west)
            #expect(root.children[2] == t)

            // across it, it arrives next to the window focused there
            t.detach()
            x.focus()
            root.attach(t, from: .south)
            #expect(root.children.count == 3)
            #expect(root.children[1] == t)

            // an empty workspace takes it as it is
            let empty = Con(layout: .splitH)
            t.detach()
            empty.attach(t, from: .north)
            #expect(empty.children[0] == t)
            #expect(percent(t) == 100)

            empty.destroy()
            root.destroy()
        }

        @Test("tree_window_order_collect")
        func treeWindowOrderCollect()
        {
            func orderIs(_ list: [WindowOrder], _ index: Int, _ aWid: WindowID, _ order: Int32, _ bWid: WindowID) -> Bool
            {
                if index >= list.count { return false }
                return list[index].window == aWid && list[index].order == order && list[index].relativeTo == bWid
            }

            // H[ 1 T[ 2 V[ 3 4 ] T[ 5 6 ] ] ] with 3 focused and 5 the active tab of the hidden tabbed container
            let root = Con(layout: .splitH)
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            treeTestLeaf(t, 2)
            let v = treeTestSplit(t, .splitV)
            let c3 = treeTestLeaf(v, 3)
            treeTestLeaf(v, 4)
            let t2 = treeTestSplit(t, .tabbed)
            let c5 = treeTestLeaf(t2, 5)
            let c6 = treeTestLeaf(t2, 6)
            c6.focus()
            c5.focus()
            c3.focus()

            // ordering below collects every window, hidden tabs included
            var list: [WindowOrder] = []
            t.collectWindowOrder(order: -1, relative: 99, into: &list)
            #expect(list.count == 5)
            #expect(orderIs(list, 0, 2, -1, 99))
            #expect(list.map(\.window) == [2, 3, 4, 5, 6])
            #expect(orderIs(list, 4, 6, -1, 99))

            // ordering above skips hidden tabs and the relative window itself
            list = []
            root.collectWindowOrder(order: 1, relative: 3, into: &list)
            #expect(list.count == 2)
            #expect(orderIs(list, 0, 1, 1, 3))
            #expect(orderIs(list, 1, 4, 1, 3))

            list = []
            v.collectWindowOrder(order: -1, relative: 4, into: &list)
            #expect(list.map(\.window) == [3])

            // a tab change orders the other tabs below the focused window, then the rest of the active tab above it
            list = []
            root.collectTabOrder(force: false, into: &list)
            #expect(list.count == 4)
            #expect(orderIs(list, 0, 2, -1, 3))
            #expect(orderIs(list, 1, 5, -1, 3))
            #expect(orderIs(list, 2, 6, -1, 3))
            #expect(orderIs(list, 3, 4, 1, 3))

            // nothing to do until the active tab changes, unless forced
            list = []
            root.collectTabOrder(force: false, into: &list)
            #expect(list.count == 0)
            root.collectTabOrder(force: true, into: &list)
            #expect(list.count == 4)

            // switching to the tab that holds 2 orders every other window of the container below it
            list = []
            t.children[0].focus()
            root.collectTabOrder(force: false, into: &list)
            #expect(list.count == 4)
            #expect(orderIs(list, 0, 3, -1, 2))
            #expect(orderIs(list, 3, 6, -1, 2))

            root.destroy()
        }

        @Test("tree_card_order")
        func treeCardOrder()
        {
            // H[ 1 T[ 2 V[ 3 4 ] ] ] with 3 focused
            let root = Con(layout: .splitH)
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            treeTestLeaf(t, 2)
            let v = treeTestSplit(t, .splitV)
            let c3 = treeTestLeaf(v, 3)
            treeTestLeaf(v, 4)
            c3.focus()

            // a card ordered below the focused window of a split tab orders the rest of the tab above it again
            var list: [WindowOrder] = []
            root.collectCardOrder(after: 3, into: &list)
            #expect(list.count == 1)
            #expect(list.first.map { $0.window == 4 && $0.order == 1 && $0.relativeTo == 3 } == true)

            // a card below any other window, or below the window of a single-window tab, orders nothing
            list = []
            root.collectCardOrder(after: 4, into: &list)
            #expect(list.isEmpty)
            t.children[0].focus()
            root.collectCardOrder(after: 2, into: &list)
            #expect(list.isEmpty)

            root.destroy()
        }

        @Test("tree_window_ids_collect")
        func treeWindowIDsCollect()
        {
            // H[ 1 T[ 2 V[ 3 4 ] ] ]: every window, hidden tabs included, in tree order
            let root = Con(layout: .splitH)
            treeTestLeaf(root, 1)
            let t = treeTestSplit(root, .tabbed)
            treeTestLeaf(t, 2)
            let v = treeTestSplit(t, .splitV)
            treeTestLeaf(v, 3)
            treeTestLeaf(v, 4)

            #expect(root.windowIDs == [1, 2, 3, 4])
            #expect(t.windowIDs == [2, 3, 4])
            #expect(v.children[1].windowIDs == [4])

            root.destroy()
        }

        @Test("tree_view_window_list_order")
        func treeViewWindowListOrder()
        {
            let root = Con(layout: .splitH)
            let tabs = treeTestSplit(root, .tabbed)
            for wid in (UInt32(1)...10).map(WindowID.init(rawValue:)) { treeTestLeaf(tabs, wid) }
            for wid in (UInt32(11)...20).map(WindowID.init(rawValue:)) { treeTestLeaf(root, wid) }
            let target = treeViewTestView(root)

            // NOTE: The list grows past its initial capacity.
            #expect(target.windowIDs == (UInt32(1)...20).map(WindowID.init(rawValue:)))

            let empty = treeViewTestView(nil)
            #expect(empty.windowIDs.isEmpty)

            root.destroy()
        }

        @Test("tree_view_zoom_frames")
        func treeViewZoomFrames()
        {
            let root = Con(layout: .splitH)
            let split = treeTestSplit(root, .splitV)
            let a = treeTestLeaf(split, 1)
            let b = treeTestLeaf(root, 2)
            let target = treeViewTestView(root)

            root.area  = Area(x: 0,   y: 0, w: 1000, h: 800)
            split.area = Area(x: 0,   y: 0, w: 500,  h: 800)
            a.area     = Area(x: 0,   y: 0, w: 500,  h: 400)
            b.area     = Area(x: 500, y: 0, w: 500,  h: 800)

            #expect(root.hasZoom(.none) == false)
            #expect(Int(target.frame(for: a).h) == 400)

            a.zoom = .parent
            #expect(root.hasZoom(.none) == true)
            #expect(root.hasZoom(.fullscreen) == false)
            #expect(Int(target.frame(for: a).h) == 800)
            #expect(Int(target.frame(for: a).w) == 500)

            a.zoom = .fullscreen
            #expect(root.hasZoom(.fullscreen) == true)
            #expect(Int(target.frame(for: a).w) == 1000)

            #expect(root.contains(2) == true)
            #expect(root.contains(3) == false)
            #expect(root.contains(0) == false)

            root.destroy()
        }
    }
}
