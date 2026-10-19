import Foundation
import AppKit
import CPrivate
import YabaiCore

/// The orientation of `window --split`: a fixed one, or across the orientation of the parent container (`toggle`).
enum SplitOrientation: Equatable, Sendable
{
    case fixed(ConOrientation)
    case toggle
}

extension WindowManager
{
    //
    // NOTE: Tree navigation and moves can cross to a neighboring display. Fullscreen spaces are
    // excluded because they cannot receive a moved container.
    //

    private func treeDisplay(in direction: Direction, from owner: View) -> DisplayID?
    {
        guard let sourceDid = space_display_id(owner.sid),
              let did = display_manager_find_closest_display_in_direction(sourceDid, direction) else { return nil }
        if let sid = display_space_id(did), space_is_fullscreen(sid) { return nil }
        return did
    }

    //
    // NOTE: Focusing a neighboring display selects the last focused window on its tree space;
    // otherwise macOS chooses which window to focus there.
    //

    private func treeFocusDisplay(_ did: DisplayID)
    {
        let sid = display_space_id(did)
        let owner = sid.map { space_manager_find_view(SpaceManager.shared, $0) }
        let leaf = owner?.layout == .tree && owner?.tree != nil ? owner?.tree?.focusedDescendant : nil

        if let leaf, leaf.isLeaf {
            focusWindow(id: leaf.windowID)
        } else {
            display_manager_focus_display(did, sid)
        }
    }

    func treeActingCon(in owner: View, for target: Window) -> Con?
    {
        if let selected = owner.tree?.findSelected(), target.id == focused_window_id { return selected }
        return owner.tree?.find(target.id)
    }

    func treeApply(_ owner: View)
    {
        //
        // NOTE: Operations on other windows must not hide the focused window in a tab that is not active.
        //

        if let focused = owner.tree?.find(focused_window_id) { focused.focus() }

        if !owner.updateAutoPadding() { owner.updateTree() }
        owner.flush()
    }

    //
    // NOTE: Moving a container across spaces is asynchronous. Wait for its windows to arrive before
    // applying the destination layout, so frame updates do not run against the old space.
    //

    func treeSetView(_ node: Con, to owner: View) -> [WindowID]
    {
        let windowList = node.windowIDs

        var moveList: [WindowID] = []
        for windowID in windowList {
            guard let target = window(for: windowID) else { continue }

            if target.id.space != owner.sid { moveList.append(target.id) }
            removeManagedWindow(target.id)
            addManagedWindow(target, to: owner)
        }

        if !moveList.isEmpty {
            space_manager_move_window_list_to_space(owner.sid, moveList)
        }
        return moveList
    }

    func treeWaitForView(_ moveList: [WindowID], _ owner: View)
    {
        if moveList.isEmpty { return }

        _ = space_manager_wait_for_windows_on_space(moveList, owner.sid, 200)
    }

    func treeFocus(direction: Direction, for target: Window?) -> WindowOperationResult
    {
        guard let target, let owner = treeView(for: target) else { return .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { return .invalidSourceNode }

        let did = treeDisplay(in: direction, from: owner)

        switch node.neighbor(direction, wrapping: focus_wrapping, hasOutput: did != nil) {
        case .focus(let result):
            guard result.isLeaf else { return .invalidDestinationNode }
            if result.windowID == target.id && node.isLeaf { return .invalidDestinationNode }
            owner.tree?.select(nil)
            focusWindow(id: result.windowID)
        case .output:
            owner.tree?.select(nil)
            guard let did else { return .invalidDestinationNode }
            treeFocusDisplay(did)
        case .none:
            return .invalidDestinationNode
        }

        return .success
    }

    func treeFocusParent(for target: Window?) -> WindowOperationResult
    {
        guard let target, let owner = treeView(for: target) else { return .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { return .invalidSourceNode }
        guard let parent = node.parent else { return .invalidDestinationNode }

        owner.tree?.select(parent)
        if space_is_visible(owner.sid) { parent.showSelection() }

        return .success
    }

    func treeFocusChild(for target: Window?) -> WindowOperationResult
    {
        guard let owner = treeView(for: target) else { return .invalidSourceView }

        guard let selected = owner.tree?.findSelected(), selected.children.count != 0 else { return .invalidDestinationNode }

        let child = selected.focusOrder[0]
        if child.isLeaf {
            owner.tree?.select(nil)
            focusWindow(id: child.windowID)
        } else {
            owner.tree?.select(child)
            if space_is_visible(owner.sid) { child.showSelection() }
        }

        return .success
    }

    //
    // NOTE: A container moved to another tree space keeps its structure and arrives on the side it
    // came from. On other spaces its windows move individually.
    //

    private func treeMove(_ node: Con, from owner: View, to did: DisplayID, direction: Direction)
    {
        owner.tree?.select(nil)

        //
        // NOTE: A display without a current space has no space to move the node to.
        //

        guard let sid = display_space_id(did) else { return }
        let dstView = space_manager_find_view(SpaceManager.shared, sid)

        if dstView.layout == .tree {
            let focus = node.focusedDescendant

            node.detach()
            owner.tree!.flatten()

            if dstView.isInvalid { dstView.update() }
            dstView.attach(node, from: direction)
            let moved = treeSetView(node, to: dstView)
            treeWaitForView(moved, dstView)
            dstView.tree!.flatten()

            focus.focus()
            treeApply(owner)
            treeApply(dstView)

            if focus.isLeaf { focusWindow(id: focus.windowID) }
            return
        }

        var windowList: [WindowID?] = []

        var leaf = node.firstLeaf
        while let current = leaf, windowList.count < 256 {
            windowList.append(current.windowID)
            if current == node.lastLeaf { break }
            leaf = current.nextLeaf
        }

        for windowID in windowList {
            if let windowID, let target = window(for: windowID) {
                sendWindow(target, to: sid, movedByRule: false)
            }
        }

        if let focus = (windowList.first ?? nil).flatMap({ window(for: $0) }) {
            WindowManager.shared.focusWithRaise(focus)
        }
    }

    func treeMove(direction: Direction, for target: Window) -> WindowOperationResult
    {
        guard let owner = treeView(for: target) else { return .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { return .invalidSourceNode }

        let did = treeDisplay(in: direction, from: owner)

        switch node.move(direction, in: owner.tree!, hasOutput: did != nil) {
        case .done:
            treeApply(owner)
        case .output:
            guard let did else { return .invalidDestinationNode }
            treeMove(node, from: owner, to: did, direction: direction)
        case .none:
            return .invalidDestinationNode
        }

        return .success
    }

    //
    // NOTE: The focus candidate is computed before a closing window leaves the tree. When the
    // focused window closes, the previous focus in its container is selected.
    //

    func treeFocusCandidate(in owner: View?, for target: Window) -> WindowID?
    {
        guard let owner, owner.layout == .tree else { return nil }

        //
        // NOTE: macOS can focus another application window before reporting this window destroyed.
        // That window may be on another space or display, so a window of the same application counts.
        //

        var wasFocused = target.id == focused_window_id
        if !wasFocused && target.id == last_window_id {
            if let focusedID = focused_window_id, let focused = window(for: focusedID) {
                wasFocused = focused.application == target.application || treeView(for: focused) == owner
            }
        }

        if !wasFocused { return nil }

        guard let node = owner.tree?.find(target.id), let candidate = node.focusCandidate else { return nil }
        return candidate.isLeaf ? candidate.windowID : nil
    }

    func treeFocusAfterClose(in owner: View, windowID: WindowID?)
    {
        guard let windowID, space_is_visible(owner.sid) else { return }
        focusWindow(id: windowID)
    }

    func treeSplit(_ split: SplitOrientation, for target: Window?) -> WindowOperationResult
    {
        guard let target, let owner = treeView(for: target) else { return .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { return .invalidSourceNode }

        let orientation: ConOrientation
        switch split {
        case .fixed(let fixed):
            orientation = fixed
        case .toggle:
            let parent = node.parent ?? node
            orientation = parent.layout == .splitH ? .vertical : .horizontal
        }

        node.split(orientation)
        treeApply(owner)

        return .success
    }
}
