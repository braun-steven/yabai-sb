import CPrivate
import Foundation
import YabaiCore

//
// NOTE: The container model and the i3 algorithms that work on it. Nothing here talks to the
// window server, so that it can be tested on its own. TreeView.swift applies a tree to the screen.
// Ported from src/tree.c.
//
// The structure is only changed through a few primitives, like sway does it: con_insert and
// con_unlink add and remove a child, con_replace puts a container in the place of another,
// con_wrap and con_wrap_children nest containers, con_reparent_children moves all children
// and tree_reap_empty closes the containers that are left without children.
//

/// `struct feedback_window` (view.h): the outline of a container.
struct FeedbackWindow
{
    var id: UInt32 = 0
    var context: CGContext?
}

//
// NOTE: What TreeView.swift keeps on screen for a container: the tab that was ordered above the
// others last (with the window and backdrop card it was ordered against), the outline window
// and the tab bar. raised is one of the children, and the tree clears it when the child leaves.
//

/// `struct con_render`
struct ConRender
{
    weak var raised: Con!
    var raised_anchor: UInt32 = 0
    var raised_card: UInt32 = 0
    var feedback_window = FeedbackWindow()
    let tab_bar = TabBar()
}

//
// NOTE: A container owns its children; parent is weak, like the plain pointer of the C struct that the children kept.
//

/// `struct con`
final class Con
{
    weak var parent: Con!
    var children: [Con] = []
    var focus: [Con] = []
    var layout = CON_SPLITH
    var last_split = CON_SPLITH
    var percent: Float = 0
    var window_id: UInt32 = 0
    var area = Area.zero
    var zoom = CON_ZOOM_NONE
    var selected = false
    var insert_dir: InsertDirection?
    var render = ConRender()

    var child_count: Int32 { Int32(children.count) }
}

extension Con: Equatable
{
    static func == (a: Con, b: Con) -> Bool { a === b }
}

// TREE_MIN_PERCENT
private let treeMinPercent: Float = 0.05

private func child(_ node: Con, _ index: Int32) -> Con
{
    return node.children[Int(index)]
}

private func focusChild(_ node: Con, _ index: Int32) -> Con
{
    return node.focus[Int(index)]
}

/// `con_create`
func con_create(_ layout: con_layout) -> Con!
{
    let node = Con()
    node.layout = layout
    node.last_split = layout == CON_TABBED ? CON_SPLITH : layout
    return node
}

/// `con_free`: releases the windows of the container and its descendants on screen (outline, tab bar); the containers
/// go away with the last reference.
func con_free(_ node: Con!)
{
    for i in 0..<node.child_count {
        con_free(child(node, i))
    }

    treeFeedbackDestroy(node)
    tab_bar_release(node.render.tab_bar)
    node.children = []
    node.focus = []
}

/// `con_is_leaf`
func con_is_leaf(_ node: Con) -> Bool
{
    return node.window_id != 0
}

/// `con_orientation`
func con_orientation(_ node: Con) -> ConOrientation
{
    return node.layout == CON_SPLITV ? CON_VERTICAL : CON_HORIZONTAL
}

/// `direction_orientation`
private func directionOrientation(_ direction: Direction) -> ConOrientation
{
    return direction == .north || direction == .south ? CON_VERTICAL : CON_HORIZONTAL
}

/// `direction_is_backward`
private func directionIsBackward(_ direction: Direction) -> Bool
{
    return direction == .north || direction == .west
}

/// `orientation_layout`
private func orientationLayout(_ orientation: ConOrientation) -> con_layout
{
    return orientation == CON_VERTICAL ? CON_SPLITV : CON_SPLITH
}

/// `con_is_split`
private func conIsSplit(_ node: Con) -> Bool
{
    return !con_is_leaf(node) && (node.layout == CON_SPLITH || node.layout == CON_SPLITV)
}

/// `con_index`
func con_index(_ node: Con) -> Int32
{
    guard let parent = node.parent else { return -1 }

    for i in 0..<parent.child_count {
        if child(parent, i) == node { return i }
    }

    return -1
}

/// `con_focus_index`
private func conFocusIndex(_ node: Con) -> Int32
{
    guard let parent = node.parent else { return -1 }

    for i in 0..<parent.child_count {
        if focusChild(parent, i) == node { return i }
    }

    return -1
}

//
// NOTE: i3 con_fix_percent. Children without a share get the average share of the others,
// then the shares are normalised so that they add up to 1.
//

/// `tree_fix_percent`
func tree_fix_percent(_ node: Con)
{
    if node.child_count == 0 { return }

    var total: Float = 0.0
    var childrenWithPercent: Int32 = 0

    for i in 0..<node.child_count {
        if child(node, i).percent > 0.0 {
            total += child(node, i).percent
            childrenWithPercent += 1
        }
    }

    if childrenWithPercent != node.child_count {
        for i in 0..<node.child_count {
            let next = child(node, i)
            if next.percent > 0.0 { continue }

            next.percent = childrenWithPercent == 0 ? 1.0 : total / Float(childrenWithPercent)
            total += next.percent
        }
    }

    for i in 0..<node.child_count {
        child(node, i).percent = total > 0.0 ? child(node, i).percent / total : 1.0 / Float(node.child_count)
    }
}

//
// NOTE: Inserts the container among the children of the parent at the index, and at the focus index
// in their focus order (0 is the most recently focused child). Either goes to the end when it is
// out of range. The share of space is left alone.
//

// CON_FOCUS_HEAD, CON_FOCUS_TAIL
private let conFocusHead: Int32 = 0
private let conFocusTail: Int32 = -1

/// `con_insert`
private func conInsert(_ parent: Con, _ node: Con, _ index: Int32, _ focusIndex: Int32)
{
    let count = parent.child_count

    let index = index < 0 || index > count ? count : index
    parent.children.insert(node, at: Int(index))

    let focusIndex = focusIndex < 0 || focusIndex > count ? count : focusIndex
    parent.focus.insert(node, at: Int(focusIndex))

    node.parent = parent

    //
    // NOTE: The new windows have to be ordered with the tabs of every tabbed container
    // around them, also when the active tab of that container stays the same.
    //

    var ancestor: Con? = parent
    while let current = ancestor {
        if current.layout == CON_TABBED { current.render.raised = nil }
        ancestor = current.parent
    }
}

/// `con_unlink`
private func conUnlink(_ node: Con)
{
    guard let parent = node.parent else { return }

    let index = con_index(node)
    let focusIndex = conFocusIndex(node)

    parent.children.remove(at: Int(index))
    parent.focus.remove(at: Int(focusIndex))

    if parent.render.raised == node { parent.render.raised = nil }
    node.parent = nil
}

//
// NOTE: The replacement takes the place of the container among the children of its parent and in
// their focus order, and gets its share of the space. Like sway container_replace.
//

/// `con_replace`
private func conReplace(_ node: Con, _ replacement: Con)
{
    let parent = node.parent!

    parent.children[Int(con_index(node))] = replacement
    parent.focus[Int(conFocusIndex(node))] = replacement
    if parent.render.raised == node { parent.render.raised = nil }

    replacement.parent = parent
    replacement.percent = node.percent
    node.parent = nil
}

//
// NOTE: Puts a new container with the layout in the place of the container, which becomes its only
// child. Like steps 2 to 4 of i3 tree_split and sway container_split.
//

/// `con_wrap`
@discardableResult
private func conWrap(_ node: Con, _ layout: con_layout) -> Con
{
    let wrap = con_create(layout)!
    conReplace(node, wrap)
    conInsert(wrap, node, 0, conFocusHead)
    node.percent = 1.0
    return wrap
}

//
// NOTE: Moves every child of the container into another one, starting at the index. The children keep
// their order and their shares, and take the place at the focus index in the focus order of the
// other container, in the order they had among themselves.
//

/// `con_reparent_children`
private func conReparentChildren(_ from: Con, _ to: Con, _ index: Int32, _ focusIndex: Int32)
{
    let count = from.child_count
    if count == 0 { return }

    let index = index < 0 || index > to.child_count ? to.child_count : index
    let focusIndex = focusIndex < 0 || focusIndex > to.child_count ? to.child_count : focusIndex

    let focus = from.focus

    for i in 0..<count {
        let next = child(from, 0)
        conUnlink(next)
        conInsert(to, next, index + i, conFocusTail)
    }

    //
    // NOTE: The children were appended to the focus order; they take the place at the focus index instead, in their
    // own focus order (the memmove of the C version).
    //

    to.focus.removeLast(Int(count))
    to.focus.insert(contentsOf: focus, at: Int(focusIndex))
}

//
// NOTE: i3 workspace_encapsulate and sway workspace_wrap_children. Moves every child of the container
// into a new container with the same layout, which becomes its only child.
//

/// `con_wrap_children`
private func conWrapChildren(_ node: Con) -> Con
{
    let wrap = con_create(node.layout)!
    wrap.last_split = node.last_split
    conReparentChildren(node, wrap, 0, 0)
    conInsert(node, wrap, 0, conFocusHead)
    wrap.percent = 1.0
    return wrap
}

//
// NOTE: Closes the container when it is left without children, and then every ancestor that is left
// empty, like i3 con_on_remove_child and sway container_reap_empty. The workspace itself stays.
// Returns the closest container that is still part of the tree, with the shares of its children fixed.
//

/// `tree_reap_empty`
@discardableResult
private func treeReapEmpty(_ node: Con) -> Con
{
    var node = node
    while let parent = node.parent, !con_is_leaf(node), node.child_count == 0 {
        let empty = node
        node = parent
        conUnlink(empty)
        con_free(empty)
    }

    tree_fix_percent(node)
    return node
}

//
// NOTE: i3 workspace_attach_to. With tree_workspace_layout tabbed, a container that is attached to
// the workspace itself is put into a new tabbed container, so that the windows opened next to it
// become tabs. A tabbed container is not nested into another one.
//

/// `con_apply_workspace_layout`
private func conApplyWorkspaceLayout(_ node: Con)
{
    if !space_manager_global().tree_workspace_tabbed { return }

    guard let root = node.parent, root.parent == nil else { return }
    if !con_is_leaf(node) && node.layout == CON_TABBED { return }

    conWrap(node, CON_TABBED).last_split = root.layout
}

/// `tree_attach`
func tree_attach(_ parent: Con!, _ node: Con!, _ index: Int32)
{
    node.percent = 0.0
    conInsert(parent, node, index, conFocusTail)
    tree_fix_percent(parent)
}

//
// NOTE: Takes the container out of the tree and closes the containers that are left empty.
// Returns the closest ancestor that is still part of the tree.
//

/// `tree_detach`
@discardableResult
func tree_detach(_ node: Con!) -> Con!
{
    guard let parent = node.parent else { return nil }

    conUnlink(node)
    return treeReapEmpty(parent)
}

//
// NOTE: i3 tree_flatten. A split container with a single split child of the other orientation,
// whose own parent has the child's orientation, is pointless nesting: the grandchildren are
// moved into the parent in place of the container.
//

/// `tree_flatten`
func tree_flatten(_ node: Con!)
{
    // NOTE: flattening a child can change the count, so it is read on every pass like the C loop did
    var i: Int32 = 0
    while i < node.child_count {
        tree_flatten(child(node, i))
        i += 1
    }

    guard let parent = node.parent, parent.layout != CON_TABBED else { return }
    if !conIsSplit(node) || node.child_count == 0 { return }

    //
    // NOTE: A split that is the only child of a split with the same orientation does not change
    // the layout either, so its children take its place.
    //

    if parent.child_count == 1 && con_orientation(node) == con_orientation(parent) {
        conUnlink(node)
        conReparentChildren(node, parent, 0, 0)
        con_free(node)
        return
    }

    if node.child_count != 1 { return }

    let only = child(node, 0)
    if !conIsSplit(only) { return }
    if con_orientation(node) == con_orientation(only) { return }
    if con_orientation(only) != con_orientation(parent) { return }

    for i in 0..<only.child_count {
        child(only, i).percent *= node.percent
    }

    let index = con_index(node)
    let focusIndex = conFocusIndex(node)

    conUnlink(node)
    conReparentChildren(only, parent, index, focusIndex)
    con_free(node)
    tree_fix_percent(parent)
}

/// `tree_find_window`
func tree_find_window(_ root: Con!, _ windowID: UInt32) -> Con!
{
    guard let root, windowID != 0 else { return nil }
    if root.window_id == windowID { return root }

    for i in 0..<root.child_count {
        if let node = tree_find_window(child(root, i), windowID) { return node }
    }

    return nil
}

/// `tree_find_selected`
func tree_find_selected(_ root: Con?) -> Con?
{
    guard let root else { return nil }
    if root.selected { return root }

    for i in 0..<root.child_count {
        if let node = tree_find_selected(child(root, i)) { return node }
    }

    return nil
}

/// `tree_select`
func tree_select(_ root: Con?, _ node: Con?)
{
    if let selected = tree_find_selected(root) {
        selected.selected = false
        treeFeedbackDestroy(selected)
    }

    node?.selected = true
}

//
// NOTE: The window that i3 focuses when this container goes away: the most recently focused
// sibling, or the closest ancestor's next most recently focused child.
//

/// `tree_focus_candidate`
func tree_focus_candidate(_ node: Con) -> Con?
{
    var node = node
    while let parent = node.parent {
        for i in 0..<parent.child_count {
            if focusChild(parent, i) != node { return tree_descend_focused(focusChild(parent, i)) }
        }
        node = parent
    }

    return nil
}

/// `tree_window_count`
func tree_window_count(_ node: Con) -> Int32
{
    if con_is_leaf(node) { return 1 }

    var count: Int32 = 0
    for i in 0..<node.child_count {
        count += tree_window_count(child(node, i))
    }

    return count
}

//
// NOTE: The windows of the leaves of con, in the order of the tree.
//

/// `tree_collect_window_ids`
func tree_collect_window_ids(_ node: Con, _ list: inout [UInt32])
{
    if con_is_leaf(node) {
        if node.window_id != 0 { list.append(node.window_id) }
        return
    }

    for i in 0..<node.child_count {
        tree_collect_window_ids(child(node, i), &list)
    }
}

/// `tree_first_leaf`
func tree_first_leaf(_ node: Con?) -> Con?
{
    var node = node
    while let current = node, !con_is_leaf(current) {
        node = current.child_count != 0 ? child(current, 0) : nil
    }

    return node
}

/// `tree_last_leaf`
func tree_last_leaf(_ node: Con?) -> Con?
{
    var node = node
    while let current = node, !con_is_leaf(current) {
        node = current.child_count != 0 ? child(current, current.child_count - 1) : nil
    }

    return node
}

/// `tree_next_leaf`
func tree_next_leaf(_ node: Con) -> Con?
{
    var node = node
    while let parent = node.parent {
        let index = con_index(node)
        if index + 1 < parent.child_count {
            return tree_first_leaf(child(parent, index + 1))
        }

        node = parent
    }

    return nil
}

/// `tree_prev_leaf`
func tree_prev_leaf(_ node: Con) -> Con?
{
    var node = node
    while let parent = node.parent {
        let index = con_index(node)
        if index > 0 {
            return tree_last_leaf(child(parent, index - 1))
        }

        node = parent
    }

    return nil
}

/// `tree_tabbed_ancestor`
func tree_tabbed_ancestor(_ node: Con) -> Con?
{
    var parent = node.parent
    while let current = parent {
        if current.layout == CON_TABBED { return current }
        parent = current.parent
    }

    return nil
}

//
// NOTE: A container is visible unless it sits in a tab that is not the active one.
//

/// `tree_con_is_visible`
func tree_con_is_visible(_ node: Con) -> Bool
{
    var node = node
    while let parent = node.parent {
        if parent.layout == CON_TABBED && focusChild(parent, 0) != node { return false }
        node = parent
    }

    return true
}

/// `tree_focus`
func tree_focus(_ node: Con!)
{
    var node: Con = node
    while let parent = node.parent {
        let focusIndex = conFocusIndex(node)

        parent.focus.remove(at: Int(focusIndex))
        parent.focus.insert(node, at: 0)
        node = parent
    }
}

/// `tree_descend_focused`
func tree_descend_focused(_ node: Con?) -> Con?
{
    var node = node
    while let current = node, !con_is_leaf(current), current.child_count != 0 {
        node = focusChild(current, 0)
    }

    return node
}

//
// NOTE: i3 con_descend_direction. Enters a container from the given direction: along its own
// orientation it takes the child on the near side, otherwise the most recently focused one.
//

/// `tree_descend_direction`
func tree_descend_direction(_ node: Con, _ direction: Direction) -> Con
{
    var node = node
    while !con_is_leaf(node) && node.child_count != 0 {
        if con_orientation(node) == directionOrientation(direction) {
            node = direction == .east || direction == .south ? child(node, 0) : child(node, node.child_count - 1)
        } else {
            node = focusChild(node, 0)
        }
    }

    return node
}

//
// NOTE: i3 get_tree_next, for 'focus left/right/up/down'. Walks up to the closest ancestor that is
// laid out in the direction (tabbed counts as horizontal) and has a neighbouring child there, and
// focuses that child, descending along its focus history. At the edge of the workspace the result
// says to try the display in that direction. Wrapping goes around the innermost container laid out
// in the direction: right away with 'force', and with 'on' only when there is no display either.
//

/// `tree_next`
func tree_next(_ node: Con, _ direction: Direction, _ wrapping: focus_wrapping, _ hasOutput: Bool, _ result: inout Con?) -> tree_result
{
    let orientation = directionOrientation(direction)
    let backward = directionIsBackward(direction)
    var wrap: Con?

    var node = node
    while let parent = node.parent {
        defer { node = parent }
        if parent.child_count < 2 || con_orientation(parent) != orientation { continue }

        let index = con_index(node) + (backward ? -1 : 1)
        if index >= 0 && index < parent.child_count {
            result = tree_descend_focused(child(parent, index))
            return TREE_RESULT_DONE
        }

        let first = child(parent, backward ? parent.child_count - 1 : 0)
        if wrapping == FOCUS_WRAPPING_FORCE {
            result = tree_descend_focused(first)
            return TREE_RESULT_DONE
        }

        if wrapping == FOCUS_WRAPPING_ON && wrap == nil { wrap = first }
    }

    if hasOutput { return TREE_RESULT_OUTPUT }
    guard let wrap else { return TREE_RESULT_NONE }

    result = tree_descend_focused(wrap)
    return TREE_RESULT_DONE
}

//
// NOTE: i3 ws_force_orientation. Wraps everything on the workspace in a container with the
// current layout, then lays the workspace out in the requested orientation. Returns the new container.
//

/// `tree_force_orientation`
@discardableResult
func tree_force_orientation(_ root: Con, _ orientation: ConOrientation) -> Con
{
    let split = conWrapChildren(root)
    root.layout = orientationLayout(orientation)
    root.last_split = root.layout
    return split
}

/// `con_lowest_common_ancestor`
private func conLowestCommonAncestor(_ a: Con, _ b: Con?) -> Con?
{
    var x: Con? = a
    while let left = x {
        var y = b
        while let right = y {
            if left == right { return left }
            y = right.parent
        }
        x = left.parent
    }

    return nil
}

/// `con_child_containing`
private func conChildContaining(_ ancestor: Con, _ node: Con) -> Con
{
    var node = node
    while node.parent != ancestor { node = node.parent! }
    return node
}

/// `con_is_focused_descendant`
private func conIsFocusedDescendant(_ node: Con, _ ancestor: Con) -> Bool
{
    var node = node
    while node != ancestor {
        let parent = node.parent!
        if focusChild(parent, 0) != node { return false }
        node = parent
    }

    return true
}

//
// NOTE: i3 insert_con_into. Places the container next to the target, where it gets an average share
// of the space. Its place in the focus order of the new parent follows the focus order of the lowest
// common ancestor: when it was focused more recently than the target, it goes before the target.
// So a container that was not focused does not become the active tab of a tabbed container, and
// one that was focused keeps the focus. A container that is not part of a tree goes first.
//

/// `tree_insert_con`
func tree_insert_con(_ node: Con, _ target: Con, _ position: tree_position)
{
    let parent = target.parent!
    let oldParent = node.parent
    var focusBefore = true
    var lca: Con?

    if oldParent != nil {
        lca = conLowestCommonAncestor(node, parent)
        guard let lca, lca != node else { return }

        let conAncestor = conChildContaining(lca, node)
        let targetAncestor = conChildContaining(lca, target)
        let movesFocus = conIsFocusedDescendant(node, conAncestor)

        if conAncestor == targetAncestor {
            focusBefore = movesFocus
        } else {
            focusBefore = conFocusIndex(conAncestor) < conFocusIndex(targetAncestor)

            //
            // NOTE: The focused container takes the focus with it to the ancestor it moves into,
            // so that it stays focused when the workspace is focused again later.
            //

            if movesFocus && focusBefore {
                let conFocus = conFocusIndex(conAncestor)
                let targetFocus = conFocusIndex(targetAncestor)
                lca.focus.remove(at: Int(targetFocus))
                lca.focus.insert(targetAncestor, at: Int(conFocus))
            }
        }

        conUnlink(node)
    }

    let focusIndex: Int32
    if parent == lca {
        focusIndex = conFocusIndex(target) + (focusBefore ? 0 : 1)
    } else {
        focusIndex = focusBefore ? conFocusHead : conFocusTail
    }

    node.percent = 0.0
    conInsert(parent, node, con_index(target) + (position == TREE_AFTER ? 1 : 0), focusIndex)
    tree_fix_percent(parent)
    conApplyWorkspaceLayout(node)

    if let oldParent { treeReapEmpty(oldParent) }
}

//
// NOTE: The container moves toward next, its neighbour in the direction, or the neighbour of its
// ancestor above. A window of its own container swaps places with it. A container is entered on
// the near side (i3 con_descend_direction), next to the window found there. Otherwise it is placed
// between above and next.
//

/// `tree_move_toward`
private func treeMoveToward(_ node: Con, _ above: Con, _ next: Con, _ direction: Direction)
{
    let backward = directionIsBackward(direction)

    if !con_is_leaf(next) {
        let target = tree_descend_direction(next, direction)
        let after = con_orientation(target.parent!) != directionOrientation(direction) || backward
        tree_insert_con(node, target, after ? TREE_AFTER : TREE_BEFORE)
    } else if above == node {
        let parent = node.parent!
        let index = con_index(node)
        let nextIndex = con_index(next)
        parent.children[Int(index)] = next
        parent.children[Int(nextIndex)] = node
    } else {
        tree_insert_con(node, above, backward ? TREE_BEFORE : TREE_AFTER)
    }
}

//
// NOTE: i3 tree_move, for 'move left/right/up/down', written as the single loop of sway
// container_move_in_direction. Walks up from the container to the closest ancestor that is laid out
// in the direction and has a neighbour there. The container swaps with a sibling window, moves into
// a neighbouring container, or leaves its container at the edge and is placed next to the ancestor.
// When no ancestor is laid out in the direction, the workspace is re-oriented (ws_force_orientation).
// The result asks the caller to move the container to the display in that direction when it
// cannot move any further on this workspace, which is tried before re-orienting.
//

/// `tree_move`
func tree_move(_ root: Con, _ node: Con, _ direction: Direction, _ hasOutput: Bool) -> tree_result
{
    if node == root || node.parent == nil { return TREE_RESULT_NONE }

    let edge = hasOutput ? TREE_RESULT_OUTPUT : TREE_RESULT_NONE
    if node.parent == root && root.child_count == 1 { return edge }

    let orientation = directionOrientation(direction)
    let offset: Int32 = directionIsBackward(direction) ? -1 : 1
    var wrapped = false

    var current = node
    var next: Con?

    while true {
        guard let parent = current.parent else {
            if hasOutput { return TREE_RESULT_OUTPUT }
            current = tree_force_orientation(root, orientation)
            wrapped = true
            continue
        }

        if con_orientation(parent) != orientation {
            current = parent
            continue
        }

        let index = con_index(current) + offset
        next = index >= 0 && index < parent.child_count ? child(parent, index) : nil
        if current != node { break }

        if let next {
            treeMoveToward(node, node, next, direction)
            tree_flatten(root)
            return TREE_RESULT_DONE
        }

        if parent == root { return edge }
        current = parent
    }

    if let next {
        treeMoveToward(node, current, next, direction)
    } else if !wrapped && node.parent.parent == root && node.parent.child_count == 1 {
        //
        // NOTE: The lone child of a container at the edge of the workspace is treated as if the
        // workspace was its parent, like i3 does.
        //

        return edge
    } else {
        tree_insert_con(node, current, offset < 0 ? TREE_BEFORE : TREE_AFTER)
    }

    tree_flatten(root)
    return TREE_RESULT_DONE
}

//
// NOTE: Places the container on one side of the target, as seen on screen. Used for insertion points
// and mouse drops. Within a split of the matching orientation it becomes a sibling, otherwise the
// target is split first. stack puts it into the tabbed container of the target, creating one if needed.
//

/// `tree_insert_relative`
func tree_insert_relative(_ target: Con!, _ node: Con!, _ insertion: InsertDirection)
{
    guard let direction = insertion.direction else {
        if target.parent.layout != CON_TABBED {
            let lastSplit = target.parent.layout
            conWrap(target, CON_TABBED).last_split = lastSplit
        }

        tree_attach(target.parent, node, con_index(target) + 1)
        return
    }

    let orientation = directionOrientation(direction)
    let matches = conIsSplit(target.parent) && con_orientation(target.parent) == orientation

    if !matches {
        let parent: Con = target.parent
        if parent.parent != nil && parent.child_count == 1 && conIsSplit(parent) {
            parent.layout = orientationLayout(orientation)
        } else if parent.parent == nil && parent.child_count == 1 {
            parent.layout = orientationLayout(orientation)
            parent.last_split = parent.layout
        } else {
            tree_split(target, orientation)
        }
    }

    tree_attach(target.parent, node, con_index(target) + (directionIsBackward(direction) ? 0 : 1))
    conApplyWorkspaceLayout(node)
}

//
// NOTE: i3 tree_split. If the parent only holds this container, its orientation is changed.
// Otherwise the container is wrapped in a new split container, so that the next window opens
// inside of it, next to this one.
//

/// `tree_split`
func tree_split(_ node: Con, _ orientation: ConOrientation)
{
    var node = node
    if node.parent == nil {
        if node.child_count < 2 {
            node.layout = orientationLayout(orientation)
            node.last_split = node.layout
            return
        }

        node = conWrapChildren(node)
    }

    let parent = node.parent!
    if parent.child_count == 1 && conIsSplit(parent) {
        parent.layout = orientationLayout(orientation)
        return
    }

    conWrap(node, orientationLayout(orientation))
}

//
// NOTE: Like the i3 autotiling script: a window that opens next to the target splits it along its
// longer side, so every new window halves the target. Tabbed containers are left alone.
//

/// `tree_autotile`
func tree_autotile(_ target: Con)
{
    guard let parent = target.parent, parent.layout != CON_TABBED else { return }

    let orientation = target.area.w >= target.area.h ? CON_HORIZONTAL : CON_VERTICAL
    if con_orientation(parent) != orientation { tree_split(target, orientation) }
}

//
// NOTE: i3 tree_open_con. A new window opens right after the target, inside the same container:
// after the focused window, or after the selected container like i3 and sway do it. On an empty
// workspace, or when the workspace itself is the target, it opens after the most recently focused
// child of the workspace. With autotile, a target window is split along its longer side first.
//

/// `tree_open_con`
func tree_open_con(_ root: Con, _ node: Con, _ target: Con?, _ autotile: Bool)
{
    if let target, target != root {
        if autotile && con_is_leaf(target) { tree_autotile(target) }
        tree_attach(target.parent, node, con_index(target) + 1)
    } else {
        tree_attach(root, node, root.child_count != 0 ? con_index(focusChild(root, 0)) + 1 : -1)
    }

    conApplyWorkspaceLayout(node)
}

//
// NOTE: sway container_move_to_workspace_from_direction. A container that moves here from the display
// in the opposite direction keeps its structure and arrives on the near side: first or last on a
// workspace laid out in the direction, and otherwise next to the window focused there, entered
// from that side like a neighbouring container in tree_move.
//

/// `tree_attach_from_direction`
func tree_attach_from_direction(_ root: Con, _ node: Con, _ direction: Direction)
{
    if root.child_count == 0 || con_orientation(root) == directionOrientation(direction) {
        node.percent = 0.0
        conInsert(root, node, directionIsBackward(direction) ? -1 : 0, conFocusHead)
        tree_fix_percent(root)
        conApplyWorkspaceLayout(node)
        return
    }

    let target = tree_descend_direction(root, direction)
    let after = con_orientation(target.parent!) != directionOrientation(direction) || directionIsBackward(direction)
    tree_insert_con(node, target, after ? TREE_AFTER : TREE_BEFORE)
}

//
// NOTE: i3 con_set_layout. The layout of the parent changes, unless the container is the workspace.
// The workspace itself is always a split, so a tabbed layout wraps its contents in a new container.
// A container that is the only child of a container that holds nothing else is closed first and
// the layout of its parent changes instead (i3 #3001), so that switching a single tab between split
// and tabbed does not nest one more container each time.
//

/// `tree_set_layout`
func tree_set_layout(_ node: Con, _ layout: con_layout)
{
    var node = node
    if let parent = node.parent { node = parent }
    if node.layout != CON_TABBED { node.last_split = node.layout }

    if let parent = node.parent, parent.parent != nil, node.child_count == 1, parent.child_count == 1 {
        let only = child(node, 0)

        conUnlink(only)
        conReplace(node, only)
        parent.last_split = node.last_split
        con_free(node)
        node = parent
    }

    if node.parent == nil {
        if layout != CON_TABBED {
            node.layout = layout
            node.last_split = layout
        } else if node.child_count != 0 {
            let wrap = conWrapChildren(node)
            wrap.layout = CON_TABBED
        }

        return
    }

    node.layout = layout
}

//
// NOTE: i3 'layout toggle split' when split_only is set, which switches between the two split layouts,
// or returns to the last split layout from tabbed. Otherwise switches between tabbed and the last split.
//

/// `tree_toggle_layout`
@discardableResult
func tree_toggle_layout(_ node: Con, _ splitOnly: Bool) -> con_layout
{
    let parent = node.parent ?? node
    let layout: con_layout

    if splitOnly {
        if parent.layout == CON_TABBED {
            layout = parent.last_split
        } else {
            layout = parent.layout == CON_SPLITH ? CON_SPLITV : CON_SPLITH
        }
    } else {
        layout = parent.layout == CON_TABBED ? parent.last_split : CON_TABBED
    }

    tree_set_layout(node, layout)
    return layout
}

//
// NOTE: i3 resize_find_tiling_participants + resize_neighboring_cons. Moves the edge of the container in
// the given direction by delta pixels (positive is right or down), taking the space from or giving it to
// the neighbour on the other side of that edge. Tabbed containers are skipped while searching.
//

/// `tree_resize`
@discardableResult
func tree_resize(_ node: Con, _ direction: Direction, _ delta: Float) -> Bool
{
    let orientation = directionOrientation(direction)
    let backward = directionIsBackward(direction)

    var first = node
    var second: Con?

    while let parent = first.parent, second == nil {
        if con_orientation(parent) != orientation || parent.layout == CON_TABBED {
            first = parent
            continue
        }

        let index = con_index(first) + (backward ? -1 : 1)
        if index >= 0 && index < parent.child_count {
            second = child(parent, index)
        } else {
            first = parent
        }
    }

    guard let second else { return false }

    let parent = first.parent!
    let size = orientation == CON_HORIZONTAL ? parent.area.w : parent.area.h
    if size <= 0.0 { return false }

    let change = (backward ? -delta : delta) / size
    var firstPercent = first.percent + change
    var secondPercent = second.percent - change

    if firstPercent < treeMinPercent {
        secondPercent -= treeMinPercent - firstPercent
        firstPercent = treeMinPercent
    }

    if secondPercent < treeMinPercent {
        firstPercent -= treeMinPercent - secondPercent
        secondPercent = treeMinPercent
    }

    first.percent = firstPercent
    second.percent = secondPercent
    tree_fix_percent(parent)

    return true
}

/// `tree_balance`
func tree_balance(_ node: Con)
{
    for i in 0..<node.child_count {
        child(node, i).percent = 1.0 / Float(node.child_count)
        tree_balance(child(node, i))
    }
}

/// `con_reverse_children`
private func conReverseChildren(_ node: Con)
{
    var i = 0
    var j = Int(node.child_count) - 1
    while i < j {
        let temp = node.children[i]
        node.children[i] = node.children[j]
        node.children[j] = temp
        i += 1
        j -= 1
    }
}

//
// NOTE: Rotates the layout like yabai always has: 90 and 270 degrees swap the split orientation,
// reversing the side-by-side (90) or top-to-bottom (270) splits, and 180 reverses every split.
//

/// `tree_rotate`
func tree_rotate(_ node: Con, _ degrees: Int32)
{
    if conIsSplit(node) {
        if (degrees ==  90 && node.layout == CON_SPLITH) ||
           (degrees == 270 && node.layout == CON_SPLITV) ||
           (degrees == 180) {
            conReverseChildren(node)
        }

        if degrees != 180 {
            node.layout = node.layout == CON_SPLITH ? CON_SPLITV : CON_SPLITH
            node.last_split = node.layout
        }
    }

    for i in 0..<node.child_count {
        tree_rotate(child(node, i), degrees)
    }
}

/// `tree_mirror`
func tree_mirror(_ node: Con, _ orientation: ConOrientation)
{
    if conIsSplit(node) && con_orientation(node) == orientation {
        conReverseChildren(node)
    }

    for i in 0..<node.child_count {
        tree_mirror(child(node, i), orientation)
    }
}

//
// NOTE: Swaps two containers in place. They keep the share of space of the position they move to.
//

/// `tree_swap`
func tree_swap(_ a: Con, _ b: Con)
{
    if a == b { return }

    let aParent = a.parent!
    let bParent = b.parent!
    let aIndex = Int(con_index(a))
    let bIndex = Int(con_index(b))
    let aFocusIndex = Int(conFocusIndex(a))
    let bFocusIndex = Int(conFocusIndex(b))

    aParent.children[aIndex] = b
    aParent.focus[aFocusIndex] = b
    bParent.children[bIndex] = a
    bParent.focus[bFocusIndex] = a

    a.parent = bParent
    b.parent = aParent

    let percent = a.percent
    a.percent = b.percent
    b.percent = percent

    if aParent.render.raised == a { aParent.render.raised = nil }
    if bParent.render.raised == b { bParent.render.raised = nil }
}

//
// NOTE: Computes the area of every container. Splits divide the area along their orientation by
// the share of each child, with the window gap in between. The children of a tabbed container
// share its area below the tab bar, moved down by the bar offset (a negative offset lets them
// reach under the bar). They always keep at least the height of the bar. With a backdrop card
// the bar and the windows are additionally inset from every edge of the container by bar_inset.
//

/// `tree_bar_card_inset`
func tree_bar_card_inset(_ area: Area, _ barHeight: Int32, _ barInset: Int32) -> Int32
{
    if barInset <= 0 { return 0 }
    if area.w <= Float(4 * barInset) || area.h - Float(2 * barInset) <= Float(2 * barHeight) { return 0 }
    return barInset
}

/// `tree_update`
func tree_update(_ node: Con!, _ area: Area, _ gap: Int32, _ barHeight: Int32, _ barOffset: Int32, _ barInset: Int32)
{
    node.area = area
    if con_is_leaf(node) || node.child_count == 0 { return }

    if node.layout == CON_TABBED {
        var childArea = area
        if barHeight > 0 && area.h > Float(2 * barHeight) {
            let inset = tree_bar_card_inset(area, barHeight, barInset)
            childArea.x += Float(inset)
            childArea.y += Float(inset)
            childArea.w -= Float(2 * inset)
            childArea.h -= Float(2 * inset)

            let reserve = max(0, min(barHeight + barOffset, Int32(childArea.h) - barHeight))
            childArea.y += Float(reserve)
            childArea.h -= Float(reserve)
        }

        for i in 0..<node.child_count {
            tree_update(child(node, i), childArea, gap, barHeight, barOffset, barInset)
        }

        return
    }

    let horizontal = node.layout == CON_SPLITH
    let total = (horizontal ? area.w : area.h) - Float(gap * (node.child_count - 1))
    var offset = horizontal ? area.x : area.y
    let end = horizontal ? area.x + area.w : area.y + area.h

    for i in 0..<node.child_count {
        let next = child(node, i)
        let size = i == node.child_count - 1 ? end - offset : Float(Int32(total * next.percent + 0.5))

        var childArea = area
        if horizontal {
            childArea.x = offset
            childArea.w = size
        } else {
            childArea.y = offset
            childArea.h = size
        }

        tree_update(next, childArea, gap, barHeight, barOffset, barInset)
        offset += size + Float(gap)
    }
}
