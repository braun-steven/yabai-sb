import CPrivate
import Foundation
import YabaiCore

//
// NOTE: The container model and the i3 algorithms that work on it. Nothing here talks to the
// window server, so that it can be tested on its own. TreeView.swift applies a tree to the screen.
//
// The structure is only changed through a few primitives, like sway does it: insert(_:at:focusIndex:) and
// unlink() add and remove a child, replace(with:) puts a container in the place of another,
// wrap(_:) and wrapChildren() nest containers, reparentChildren(to:at:focusIndex:) moves all children
// and reapEmpty() closes the containers that are left without children.
//

/// The layout of a container, named as in `query --tree`.
enum ConLayout: String, Sendable
{
    case splitH = "splith"
    case splitV = "splitv"
    case tabbed
}

/// The axis along which a split container places its children.
enum ConOrientation: Sendable
{
    case horizontal
    case vertical
}

/// The zoom of a window's container: to its parent's area or to the whole view.
enum ConZoom: Sendable
{
    case none
    case parent
    case fullscreen
}

/// What a focus or move in the tree did: nothing, done within the tree, or it left the tree towards another output.
enum TreeResult: Sendable
{
    case none
    case done
    case output
}

/// Where directional focus goes from a container: nowhere, to the display in the direction, or to a container of the tree.
enum TreeNeighbor: Equatable
{
    case none
    case output
    case focus(Con)

    /// The container to focus, if any.
    var target: Con?
    {
        if case .focus(let node) = self { return node }
        return nil
    }
}

/// Where a container is inserted relative to its target.
enum TreePosition: Sendable
{
    case before
    case after
}

/// The orientation of the first split of a new tree (`config tree_default_orientation`).
enum TreeOrientation: String, CaseIterable, Sendable
{
    case auto
    case horizontal
    case vertical
}

/// Whether directional focus wraps around at the edge of the tree (`config focus_wrapping`).
enum FocusWrapping: String, CaseIterable, Sendable
{
    case off
    case on
    case force
}

/// The outline window of a container.
struct FeedbackWindow
{
    var id: WindowID?
    var context: CGContext?
}

//
// NOTE: What TreeView.swift keeps on screen for a container: the tab that was ordered above the
// others last (with the window and backdrop card it was ordered against), the outline window
// and the tab bar. raised is one of the children, and the tree clears it when the child leaves.
//

struct ConRender
{
    weak var raised: Con!
    var raisedAnchor: WindowID?
    var raisedCard: WindowID?
    var feedbackWindow = FeedbackWindow()
    let tabBar = TabBar()
}

//
// NOTE: A container owns its children; parent is weak so the tree has no retain cycle.
//

final class Con
{
    weak var parent: Con?
    var children: [Con] = []
    var focusOrder: [Con] = []
    var layout = ConLayout.splitH
    var lastSplit = ConLayout.splitH
    var percent: Float = 0
    var windowID: WindowID?
    var area = Area.zero
    var zoom = ConZoom.none
    var isSelected = false
    var insertDirection: InsertDirection?
    var render = ConRender()

    private static let minPercent: Float = 0.05
    private static let focusHead: Int? = 0
    private static let focusTail: Int? = nil

    init(layout: ConLayout = .splitH, windowID: WindowID? = nil)
    {
        self.layout = layout
        self.lastSplit = layout == .tabbed ? .splitH : layout
        self.windowID = windowID
    }
}

extension Con: Equatable
{
    static func == (a: Con, b: Con) -> Bool { a === b }
}

private extension Direction
{
    var orientation: ConOrientation
    {
        return self == .north || self == .south ? .vertical : .horizontal
    }

    var isBackward: Bool
    {
        return self == .north || self == .west
    }
}

private extension ConOrientation
{
    var splitLayout: ConLayout
    {
        return self == .vertical ? .splitV : .splitH
    }
}

extension Con
{
    /// Releases the windows the container and its descendants show on screen (outline, tab bar) and drops the children;
    /// the containers go away with the last reference.
    func destroy()
    {
        for child in children {
            child.destroy()
        }

        destroyFeedback()
        render.tabBar.destroy()
        children = []
        focusOrder = []
    }

    var isLeaf: Bool
    {
        return windowID != nil
    }

    var orientation: ConOrientation
    {
        return layout == .splitV ? .vertical : .horizontal
    }

    private var isSplit: Bool
    {
        return !isLeaf && (layout == .splitH || layout == .splitV)
    }

    /// The index of the container among the children of its parent; nil without a parent.
    var index: Int?
    {
        return parent?.children.firstIndex(of: self)
    }

    /// The index of the container in the focus order of its parent; nil without a parent.
    private var focusIndex: Int?
    {
        return parent?.focusOrder.firstIndex(of: self)
    }

    //
    // NOTE: i3 con_fix_percent. Children without a share get the average share of the others,
    // then the shares are normalised so that they add up to 1.
    //

    func fixPercent()
    {
        if children.count == 0 { return }

        var total: Float = 0.0
        var childrenWithPercent = 0

        for child in children {
            if child.percent > 0.0 {
                total += child.percent
                childrenWithPercent += 1
            }
        }

        if childrenWithPercent != children.count {
            for next in children {
                if next.percent > 0.0 { continue }

                next.percent = childrenWithPercent == 0 ? 1.0 : total / Float(childrenWithPercent)
                total += next.percent
            }
        }

        for child in children {
            child.percent = total > 0.0 ? child.percent / total : 1.0 / Float(children.count)
        }
    }

    //
    // NOTE: Inserts the container among the children of the parent at the index, and at the focus index
    // in their focus order (0 is the most recently focused child). Either goes to the end when it is
    // nil or out of range. The share of space is left alone.
    //

    /// The index, or the end of a list of count elements when it is nil or out of range.
    private static func clampedIndex(_ index: Int?, _ count: Int) -> Int
    {
        guard let index, index >= 0 && index <= count else { return count }
        return index
    }

    private func insert(_ node: Con, at index: Int?, focusIndex: Int?)
    {
        let count = children.count

        children.insert(node, at: Con.clampedIndex(index, count))
        focusOrder.insert(node, at: Con.clampedIndex(focusIndex, count))

        node.parent = self

        //
        // NOTE: The new windows have to be ordered with the tabs of every tabbed container
        // around them, also when the active tab of that container stays the same.
        //

        var ancestor: Con? = self
        while let current = ancestor {
            if current.layout == .tabbed { current.render.raised = nil }
            ancestor = current.parent
        }
    }

    private func unlink()
    {
        guard let parent = self.parent else { return }

        parent.children.remove(at: index!)
        parent.focusOrder.remove(at: focusIndex!)

        if parent.render.raised == self { parent.render.raised = nil }
        self.parent = nil
    }

    //
    // NOTE: The replacement takes the place of the container among the children of its parent and in
    // their focus order, and gets its share of the space. Like sway container_replace.
    //

    private func replace(with replacement: Con)
    {
        let parent = self.parent!

        parent.children[index!] = replacement
        parent.focusOrder[focusIndex!] = replacement
        if parent.render.raised == self { parent.render.raised = nil }

        replacement.parent = parent
        replacement.percent = percent
        self.parent = nil
    }

    //
    // NOTE: Puts a new container with the layout in the place of the container, which becomes its only
    // child. Like steps 2 to 4 of i3 tree_split and sway container_split.
    //

    @discardableResult
    private func wrap(_ layout: ConLayout) -> Con
    {
        let wrap = Con(layout: layout)
        replace(with: wrap)
        wrap.insert(self, at: 0, focusIndex: Con.focusHead)
        percent = 1.0
        return wrap
    }

    //
    // NOTE: Moves every child of the container into another one, starting at the index. The children keep
    // their order and their shares, and take the place at the focus index in the focus order of the
    // other container, in the order they had among themselves.
    //

    private func reparentChildren(to target: Con, at index: Int?, focusIndex: Int?)
    {
        let count = children.count
        if count == 0 { return }

        let index = Con.clampedIndex(index, target.children.count)
        let focusIndex = Con.clampedIndex(focusIndex, target.children.count)

        let focus = focusOrder

        for i in 0..<count {
            let next = children[0]
            next.unlink()
            target.insert(next, at: index + i, focusIndex: Con.focusTail)
        }

        //
        // NOTE: The children were appended to the focus order; they take the place at the focus index instead, in their
        // own focus order (the memmove of the C version).
        //

        target.focusOrder.removeLast(count)
        target.focusOrder.insert(contentsOf: focus, at: focusIndex)
    }

    //
    // NOTE: i3 workspace_encapsulate and sway workspace_wrap_children. Moves every child of the container
    // into a new container with the same layout, which becomes its only child.
    //

    private func wrapChildren() -> Con
    {
        let wrap = Con(layout: layout)
        wrap.lastSplit = lastSplit
        reparentChildren(to: wrap, at: 0, focusIndex: 0)
        insert(wrap, at: 0, focusIndex: Con.focusHead)
        wrap.percent = 1.0
        return wrap
    }

    //
    // NOTE: Closes the container when it is left without children, and then every ancestor that is left
    // empty, like i3 con_on_remove_child and sway container_reap_empty. The workspace itself stays.
    // Returns the closest container that is still part of the tree, with the shares of its children fixed.
    //

    @discardableResult
    private func reapEmpty() -> Con
    {
        var node = self
        while let parent = node.parent, !node.isLeaf, node.children.count == 0 {
            let empty = node
            node = parent
            empty.unlink()
            empty.destroy()
        }

        node.fixPercent()
        return node
    }

    //
    // NOTE: i3 workspace_attach_to. With tree_workspace_layout tabbed, a container that is attached to
    // the workspace itself is put into a new tabbed container, so that the windows opened next to it
    // become tabs. A tabbed container is not nested into another one.
    //

    private func applyWorkspaceLayout()
    {
        if !SpaceManager.shared.treeWorkspaceTabbed { return }

        guard let root = self.parent, root.parent == nil else { return }
        if !isLeaf && layout == .tabbed { return }

        wrap(.tabbed).lastSplit = root.layout
    }

    func attach(_ node: Con, at index: Int?)
    {
        node.percent = 0.0
        insert(node, at: index, focusIndex: Con.focusTail)
        fixPercent()
    }

    //
    // NOTE: Takes the container out of the tree and closes the containers that are left empty.
    // Returns the closest ancestor that is still part of the tree.
    //

    @discardableResult
    func detach() -> Con?
    {
        guard let parent = self.parent else { return nil }

        unlink()
        return parent.reapEmpty()
    }

    //
    // NOTE: i3 tree_flatten. A split container with a single split child of the other orientation,
    // whose own parent has the child's orientation, is pointless nesting: the grandchildren are
    // moved into the parent in place of the container.
    //

    func flatten()
    {
        // NOTE: Flattening a child can change the count, so it is read on every pass.
        var i = 0
        while i < children.count {
            children[i].flatten()
            i += 1
        }

        guard let parent = self.parent, parent.layout != .tabbed else { return }
        if !isSplit || children.count == 0 { return }

        //
        // NOTE: A split that is the only child of a split with the same orientation does not change
        // the layout either, so its children take its place.
        //

        if parent.children.count == 1 && orientation == parent.orientation {
            unlink()
            reparentChildren(to: parent, at: 0, focusIndex: 0)
            destroy()
            return
        }

        if children.count != 1 { return }

        let only = children[0]
        if !only.isSplit { return }
        if orientation == only.orientation { return }
        if only.orientation != parent.orientation { return }

        for child in only.children {
            child.percent *= percent
        }

        let index = self.index!
        let focusIndex = self.focusIndex!

        unlink()
        only.reparentChildren(to: parent, at: index, focusIndex: focusIndex)
        destroy()
        parent.fixPercent()
    }

    func find(_ windowID: WindowID?) -> Con?
    {
        guard let windowID else { return nil }
        if self.windowID == windowID { return self }

        for child in children {
            if let node = child.find(windowID) { return node }
        }

        return nil
    }

    func findSelected() -> Con?
    {
        if isSelected { return self }

        for child in children {
            if let node = child.findSelected() { return node }
        }

        return nil
    }

    func select(_ node: Con?)
    {
        if let selected = findSelected() {
            selected.isSelected = false
            selected.destroyFeedback()
        }

        node?.isSelected = true
    }

    //
    // NOTE: The window that i3 focuses when this container goes away: the most recently focused
    // sibling, or the closest ancestor's next most recently focused child.
    //

    var focusCandidate: Con?
    {
        var node = self
        while let parent = node.parent {
            for next in parent.focusOrder {
                if next != node { return next.focusedDescendant }
            }
            node = parent
        }

        return nil
    }

    var windowCount: Int
    {
        if isLeaf { return 1 }

        var count = 0
        for child in children {
            count += child.windowCount
        }

        return count
    }

    //
    // NOTE: The windows of the leaves of con, in the order of the tree.
    //

    var windowIDs: [WindowID]
    {
        var list: [WindowID] = []
        collectWindowIDs(into: &list)
        return list
    }

    private func collectWindowIDs(into list: inout [WindowID])
    {
        if isLeaf {
            if let windowID = self.windowID { list.append(windowID) }
            return
        }

        for child in children {
            child.collectWindowIDs(into: &list)
        }
    }

    var firstLeaf: Con?
    {
        var node: Con? = self
        while let current = node, !current.isLeaf {
            node = current.children.count != 0 ? current.children[0] : nil
        }

        return node
    }

    var lastLeaf: Con?
    {
        var node: Con? = self
        while let current = node, !current.isLeaf {
            node = current.children.count != 0 ? current.children[current.children.count - 1] : nil
        }

        return node
    }

    var nextLeaf: Con?
    {
        var node = self
        while let parent = node.parent {
            let index = node.index!
            if index + 1 < parent.children.count {
                return parent.children[index + 1].firstLeaf
            }

            node = parent
        }

        return nil
    }

    var previousLeaf: Con?
    {
        var node = self
        while let parent = node.parent {
            let index = node.index!
            if index > 0 {
                return parent.children[index - 1].lastLeaf
            }

            node = parent
        }

        return nil
    }

    var tabbedAncestor: Con?
    {
        var parent = self.parent
        while let current = parent {
            if current.layout == .tabbed { return current }
            parent = current.parent
        }

        return nil
    }

    //
    // NOTE: A container is visible unless it sits in a tab that is not the active one.
    //

    var isVisible: Bool
    {
        var node = self
        while let parent = node.parent {
            if parent.layout == .tabbed && parent.focusOrder[0] != node { return false }
            node = parent
        }

        return true
    }

    func focus()
    {
        var node = self
        while let parent = node.parent {
            let focusIndex = node.focusIndex!

            parent.focusOrder.remove(at: focusIndex)
            parent.focusOrder.insert(node, at: 0)
            node = parent
        }
    }

    var focusedDescendant: Con
    {
        var node = self
        while !node.isLeaf && node.children.count != 0 {
            node = node.focusOrder[0]
        }

        return node
    }

    //
    // NOTE: i3 con_descend_direction. Enters a container from the given direction: along its own
    // orientation it takes the child on the near side, otherwise the most recently focused one.
    //

    func descend(_ direction: Direction) -> Con
    {
        var node = self
        while !node.isLeaf && node.children.count != 0 {
            if node.orientation == direction.orientation {
                node = direction == .east || direction == .south ? node.children[0] : node.children[node.children.count - 1]
            } else {
                node = node.focusOrder[0]
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

    func neighbor(_ direction: Direction, wrapping: FocusWrapping, hasOutput: Bool) -> TreeNeighbor
    {
        let orientation = direction.orientation
        let backward = direction.isBackward
        var wrap: Con?

        var node = self
        while let parent = node.parent {
            defer { node = parent }
            if parent.children.count < 2 || parent.orientation != orientation { continue }

            let index = node.index! + (backward ? -1 : 1)
            if index >= 0 && index < parent.children.count {
                return .focus(parent.children[index].focusedDescendant)
            }

            let first = parent.children[backward ? parent.children.count - 1 : 0]
            if wrapping == .force {
                return .focus(first.focusedDescendant)
            }

            if wrapping == .on && wrap == nil { wrap = first }
        }

        if hasOutput { return .output }
        guard let wrap else { return .none }

        return .focus(wrap.focusedDescendant)
    }

    //
    // NOTE: i3 ws_force_orientation. Wraps everything on the workspace in a container with the
    // current layout, then lays the workspace out in the requested orientation. Returns the new container.
    //

    @discardableResult
    func forceOrientation(_ orientation: ConOrientation) -> Con
    {
        let split = wrapChildren()
        layout = orientation.splitLayout
        lastSplit = layout
        return split
    }

    private func lowestCommonAncestor(with other: Con?) -> Con?
    {
        var x: Con? = self
        while let left = x {
            var y = other
            while let right = y {
                if left == right { return left }
                y = right.parent
            }
            x = left.parent
        }

        return nil
    }

    private func child(containing node: Con) -> Con
    {
        var node = node
        while node.parent != self { node = node.parent! }
        return node
    }

    private func isFocusedDescendant(of ancestor: Con) -> Bool
    {
        var node = self
        while node != ancestor {
            let parent = node.parent!
            if parent.focusOrder[0] != node { return false }
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

    func place(_ position: TreePosition, of target: Con)
    {
        let parent = target.parent!
        let oldParent = self.parent
        var focusBefore = true
        var lca: Con?

        if oldParent != nil {
            lca = lowestCommonAncestor(with: parent)
            guard let lca, lca != self else { return }

            let conAncestor = lca.child(containing: self)
            let targetAncestor = lca.child(containing: target)
            let movesFocus = isFocusedDescendant(of: conAncestor)

            if conAncestor == targetAncestor {
                focusBefore = movesFocus
            } else {
                focusBefore = conAncestor.focusIndex! < targetAncestor.focusIndex!

                //
                // NOTE: The focused container takes the focus with it to the ancestor it moves into,
                // so that it stays focused when the workspace is focused again later.
                //

                if movesFocus && focusBefore {
                    let conFocus = conAncestor.focusIndex!
                    let targetFocus = targetAncestor.focusIndex!
                    lca.focusOrder.remove(at: targetFocus)
                    lca.focusOrder.insert(targetAncestor, at: conFocus)
                }
            }

            unlink()
        }

        let focusIndex: Int?
        if parent == lca {
            focusIndex = target.focusIndex! + (focusBefore ? 0 : 1)
        } else {
            focusIndex = focusBefore ? Con.focusHead : Con.focusTail
        }

        percent = 0.0
        parent.insert(self, at: target.index! + (position == .after ? 1 : 0), focusIndex: focusIndex)
        parent.fixPercent()
        applyWorkspaceLayout()

        if let oldParent { oldParent.reapEmpty() }
    }

    //
    // NOTE: The container moves toward next, its neighbour in the direction, or the neighbour of its
    // ancestor above. A window of its own container swaps places with it. A container is entered on
    // the near side (i3 con_descend_direction), next to the window found there. Otherwise it is placed
    // between above and next.
    //

    private func move(toward next: Con, from above: Con, _ direction: Direction)
    {
        let backward = direction.isBackward

        if !next.isLeaf {
            let target = next.descend(direction)
            let after = target.parent!.orientation != direction.orientation || backward
            place(after ? .after : .before, of: target)
        } else if above == self {
            let parent = self.parent!
            let index = self.index!
            let nextIndex = next.index!
            parent.children[index] = next
            parent.children[nextIndex] = self
        } else {
            place(backward ? .before : .after, of: above)
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

    func move(_ direction: Direction, in root: Con, hasOutput: Bool) -> TreeResult
    {
        if self == root || parent == nil { return .none }

        let edge: TreeResult = hasOutput ? .output : .none
        if parent == root && root.children.count == 1 { return edge }

        let orientation = direction.orientation
        let offset = direction.isBackward ? -1 : 1
        var wrapped = false

        var current = self
        var next: Con?

        while true {
            guard let parent = current.parent else {
                if hasOutput { return .output }
                current = root.forceOrientation(orientation)
                wrapped = true
                continue
            }

            if parent.orientation != orientation {
                current = parent
                continue
            }

            let index = current.index! + offset
            next = index >= 0 && index < parent.children.count ? parent.children[index] : nil
            if current != self { break }

            if let next {
                move(toward: next, from: self, direction)
                root.flatten()
                return .done
            }

            if parent == root { return edge }
            current = parent
        }

        if let next {
            move(toward: next, from: current, direction)
        } else if !wrapped && self.parent!.parent == root && self.parent!.children.count == 1 {
            //
            // NOTE: The lone child of a container at the edge of the workspace is treated as if the
            // workspace was its parent, like i3 does.
            //

            return edge
        } else {
            place(offset < 0 ? .before : .after, of: current)
        }

        root.flatten()
        return .done
    }

    //
    // NOTE: Places the container on one side of the target, as seen on screen. Used for insertion points
    // and mouse drops. Within a split of the matching orientation it becomes a sibling, otherwise the
    // target is split first. stack puts it into the tabbed container of the target, creating one if needed.
    //

    func insert(_ node: Con, toward insertion: InsertDirection)
    {
        guard let direction = insertion.direction else {
            if parent!.layout != .tabbed {
                let lastSplit = parent!.layout
                wrap(.tabbed).lastSplit = lastSplit
            }

            parent!.attach(node, at: index! + 1)
            return
        }

        let orientation = direction.orientation
        let matches = parent!.isSplit && parent!.orientation == orientation

        if !matches {
            let parent: Con = self.parent!
            if parent.parent != nil && parent.children.count == 1 && parent.isSplit {
                parent.layout = orientation.splitLayout
            } else if parent.parent == nil && parent.children.count == 1 {
                parent.layout = orientation.splitLayout
                parent.lastSplit = parent.layout
            } else {
                split(orientation)
            }
        }

        parent!.attach(node, at: index! + (direction.isBackward ? 0 : 1))
        node.applyWorkspaceLayout()
    }

    //
    // NOTE: i3 tree_split. If the parent only holds this container, its orientation is changed.
    // Otherwise the container is wrapped in a new split container, so that the next window opens
    // inside of it, next to this one.
    //

    func split(_ orientation: ConOrientation)
    {
        var node = self
        if self.parent == nil {
            if children.count < 2 {
                layout = orientation.splitLayout
                lastSplit = layout
                return
            }

            node = wrapChildren()
        }

        let parent = node.parent!
        if parent.children.count == 1 && parent.isSplit {
            parent.layout = orientation.splitLayout
            return
        }

        node.wrap(orientation.splitLayout)
    }

    //
    // NOTE: Like the i3 autotiling script: a window that opens next to the target splits it along its
    // longer side, so every new window halves the target. Tabbed containers are left alone.
    //

    func autotile()
    {
        guard let parent = self.parent, parent.layout != .tabbed else { return }

        let orientation: ConOrientation = area.w >= area.h ? .horizontal : .vertical
        if parent.orientation != orientation { split(orientation) }
    }

    //
    // NOTE: i3 tree_open_con. A new window opens right after the target, inside the same container:
    // after the focused window, or after the selected container like i3 and sway do it. On an empty
    // workspace, or when the workspace itself is the target, it opens after the most recently focused
    // child of the workspace. With autotile, a target window is split along its longer side first.
    //

    func open(_ node: Con, after target: Con?, autotile: Bool)
    {
        if let target, target != self {
            if autotile && target.isLeaf { target.autotile() }
            target.parent!.attach(node, at: target.index! + 1)
        } else {
            attach(node, at: children.count != 0 ? focusOrder[0].index! + 1 : nil)
        }

        node.applyWorkspaceLayout()
    }

    //
    // NOTE: sway container_move_to_workspace_from_direction. A container that moves here from the display
    // in the opposite direction keeps its structure and arrives on the near side: first or last on a
    // workspace laid out in the direction, and otherwise next to the window focused there, entered
    // from that side like a neighbouring container in move(_:in:hasOutput:).
    //

    func attach(_ node: Con, from direction: Direction)
    {
        if children.count == 0 || orientation == direction.orientation {
            node.percent = 0.0
            insert(node, at: direction.isBackward ? nil : 0, focusIndex: Con.focusHead)
            fixPercent()
            node.applyWorkspaceLayout()
            return
        }

        let target = descend(direction)
        let after = target.parent!.orientation != direction.orientation || direction.isBackward
        node.place(after ? .after : .before, of: target)
    }

    //
    // NOTE: i3 con_set_layout. The layout of the parent changes, unless the container is the workspace.
    // The workspace itself is always a split, so a tabbed layout wraps its contents in a new container.
    // A container that is the only child of a container that holds nothing else is closed first and
    // the layout of its parent changes instead (i3 #3001), so that switching a single tab between split
    // and tabbed does not nest one more container each time.
    //

    func setLayout(_ layout: ConLayout)
    {
        var node = self
        if let parent = self.parent { node = parent }
        if node.layout != .tabbed { node.lastSplit = node.layout }

        if let parent = node.parent, parent.parent != nil, node.children.count == 1, parent.children.count == 1 {
            let only = node.children[0]

            only.unlink()
            node.replace(with: only)
            parent.lastSplit = node.lastSplit
            node.destroy()
            node = parent
        }

        if node.parent == nil {
            if layout != .tabbed {
                node.layout = layout
                node.lastSplit = layout
            } else if node.children.count != 0 {
                let wrap = node.wrapChildren()
                wrap.layout = .tabbed
            }

            return
        }

        node.layout = layout
    }

    //
    // NOTE: i3 'layout toggle split' when split_only is set, which switches between the two split layouts,
    // or returns to the last split layout from tabbed. Otherwise switches between tabbed and the last split.
    //

    @discardableResult
    func toggleLayout(splitOnly: Bool) -> ConLayout
    {
        let parent = self.parent ?? self
        let layout: ConLayout

        if splitOnly {
            if parent.layout == .tabbed {
                layout = parent.lastSplit
            } else {
                layout = parent.layout == .splitH ? .splitV : .splitH
            }
        } else {
            layout = parent.layout == .tabbed ? parent.lastSplit : .tabbed
        }

        setLayout(layout)
        return layout
    }

    //
    // NOTE: i3 resize_find_tiling_participants + resize_neighboring_cons. Moves the edge of the container in
    // the given direction by delta pixels (positive is right or down), taking the space from or giving it to
    // the neighbour on the other side of that edge. Tabbed containers are skipped while searching.
    //

    @discardableResult
    func resize(_ direction: Direction, by delta: Float) -> Bool
    {
        let orientation = direction.orientation
        let backward = direction.isBackward

        var first = self
        var second: Con?

        while let parent = first.parent, second == nil {
            if parent.orientation != orientation || parent.layout == .tabbed {
                first = parent
                continue
            }

            let index = first.index! + (backward ? -1 : 1)
            if index >= 0 && index < parent.children.count {
                second = parent.children[index]
            } else {
                first = parent
            }
        }

        guard let second else { return false }

        let parent = first.parent!
        let size = orientation == .horizontal ? parent.area.w : parent.area.h
        if size <= 0.0 { return false }

        let change = (backward ? -delta : delta) / size
        var firstPercent = first.percent + change
        var secondPercent = second.percent - change

        if firstPercent < Con.minPercent {
            secondPercent -= Con.minPercent - firstPercent
            firstPercent = Con.minPercent
        }

        if secondPercent < Con.minPercent {
            firstPercent -= Con.minPercent - secondPercent
            secondPercent = Con.minPercent
        }

        first.percent = firstPercent
        second.percent = secondPercent
        parent.fixPercent()

        return true
    }

    func balance()
    {
        for child in children {
            child.percent = 1.0 / Float(children.count)
            child.balance()
        }
    }

    //
    // NOTE: Rotates the layout like yabai always has: 90 and 270 degrees swap the split orientation,
    // reversing the side-by-side (90) or top-to-bottom (270) splits, and 180 reverses every split.
    //

    func rotate(by degrees: Int)
    {
        if isSplit {
            if (degrees ==  90 && layout == .splitH) ||
               (degrees == 270 && layout == .splitV) ||
               (degrees == 180) {
                children.reverse()
            }

            if degrees != 180 {
                layout = layout == .splitH ? .splitV : .splitH
                lastSplit = layout
            }
        }

        for child in children {
            child.rotate(by: degrees)
        }
    }

    func mirror(_ orientation: ConOrientation)
    {
        if isSplit && self.orientation == orientation {
            children.reverse()
        }

        for child in children {
            child.mirror(orientation)
        }
    }

    //
    // NOTE: Swaps two containers in place. They keep the share of space of the position they move to.
    //

    func swap(with b: Con)
    {
        if self == b { return }

        let aParent = parent!
        let bParent = b.parent!
        let aIndex = index!
        let bIndex = b.index!
        let aFocusIndex = focusIndex!
        let bFocusIndex = b.focusIndex!

        aParent.children[aIndex] = b
        aParent.focusOrder[aFocusIndex] = b
        bParent.children[bIndex] = self
        bParent.focusOrder[bFocusIndex] = self

        parent = bParent
        b.parent = aParent

        let aPercent = percent
        percent = b.percent
        b.percent = aPercent

        if aParent.render.raised == self { aParent.render.raised = nil }
        if bParent.render.raised == b { bParent.render.raised = nil }
    }

    //
    // NOTE: Computes the area of every container. Splits divide the area along their orientation by
    // the share of each child, with the window gap in between. The children of a tabbed container
    // share its area below the tab bar, moved down by the bar offset (a negative offset lets them
    // reach under the bar). They always keep at least the height of the bar. With a backdrop card
    // the bar and the windows are additionally inset from every edge of the container by bar_inset.
    //

    static func cardInset(_ area: Area, barHeight: Int, barInset: Int) -> Int
    {
        if barInset <= 0 { return 0 }
        if area.w <= Float(4 * barInset) || area.h - Float(2 * barInset) <= Float(2 * barHeight) { return 0 }
        return barInset
    }

    func layOut(_ area: Area, gap: Int, barHeight: Int, barOffset: Int, barInset: Int)
    {
        self.area = area
        if isLeaf || children.count == 0 { return }

        if layout == .tabbed {
            var childArea = area
            if barHeight > 0 && area.h > Float(2 * barHeight) {
                let inset = Con.cardInset(area, barHeight: barHeight, barInset: barInset)
                childArea.x += Float(inset)
                childArea.y += Float(inset)
                childArea.w -= Float(2 * inset)
                childArea.h -= Float(2 * inset)

                let reserve = max(0, min(barHeight + barOffset, Int(childArea.h) - barHeight))
                childArea.y += Float(reserve)
                childArea.h -= Float(reserve)
            }

            for child in children {
                child.layOut(childArea, gap: gap, barHeight: barHeight, barOffset: barOffset, barInset: barInset)
            }

            return
        }

        let horizontal = layout == .splitH
        let total = (horizontal ? area.w : area.h) - Float(gap * (children.count - 1))
        var offset = horizontal ? area.x : area.y
        let end = horizontal ? area.x + area.w : area.y + area.h

        for (i, next) in children.enumerated() {
            let size = i == children.count - 1 ? end - offset : Float(Int(total * next.percent + 0.5))

            var childArea = area
            if horizontal {
                childArea.x = offset
                childArea.w = size
            } else {
                childArea.y = offset
                childArea.h = size
            }

            next.layOut(childArea, gap: gap, barHeight: barHeight, barOffset: barOffset, barInset: barInset)
            offset += size + Float(gap)
        }
    }
}
