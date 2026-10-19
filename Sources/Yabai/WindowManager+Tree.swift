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
        guard let sourceDid = owner.sid.display,
              let did = sourceDid.closestDisplay(in: direction) else { return nil }
        if let sid = did.currentSpace, sid.isFullscreen { return nil }
        return did
    }

    //
    // NOTE: Focusing a neighboring display selects the last focused window on its tree space;
    // otherwise macOS chooses which window to focus there.
    //

    private func treeFocusDisplay(_ did: DisplayID)
    {
        let sid = did.currentSpace
        let owner = sid.map { SpaceManager.shared.view(for: $0) }
        let leaf = owner?.layout == .tree && owner?.tree != nil ? owner?.tree?.focusedDescendant : nil

        if let leaf, leaf.isLeaf {
            focusWindow(id: leaf.windowID)
        } else {
            did.focus(space: sid)
        }
    }

    func treeActingCon(in owner: View, for target: Window) -> Con?
    {
        if let selected = owner.tree?.findSelected(), target.id == focusedWindowID { return selected }
        return owner.tree?.find(target.id)
    }

    func treeApply(_ owner: View)
    {
        //
        // NOTE: Operations on other windows must not hide the focused window in a tab that is not active.
        //

        if let focused = owner.tree?.find(focusedWindowID) { focused.focus() }

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
            owner.sid.moveWindows(moveList)
        }
        return moveList
    }

    func treeWaitForView(_ moveList: [WindowID], _ owner: View)
    {
        if moveList.isEmpty { return }

        _ = owner.sid.waitForWindows(moveList, timeoutMS: 200)
    }

    func treeFocus(direction: Direction, for target: Window?) throws(WindowOperationError)
    {
        guard let target, let owner = treeView(for: target) else { throw .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { throw .invalidSourceNode }

        let did = treeDisplay(in: direction, from: owner)

        switch node.neighbor(direction, wrapping: focusWrapping, hasOutput: did != nil) {
        case .focus(let result):
            guard result.isLeaf else { throw .invalidDestinationNode }
            if result.windowID == target.id && node.isLeaf { throw .invalidDestinationNode }
            owner.tree?.select(nil)
            focusWindow(id: result.windowID)
        case .output:
            owner.tree?.select(nil)
            guard let did else { throw .invalidDestinationNode }
            treeFocusDisplay(did)
        case .none:
            throw .invalidDestinationNode
        }
    }

    func treeFocusParent(for target: Window?) throws(WindowOperationError)
    {
        guard let target, let owner = treeView(for: target) else { throw .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { throw .invalidSourceNode }
        guard let parent = node.parent else { throw .invalidDestinationNode }

        owner.tree?.select(parent)
        if owner.sid.isVisible { parent.showSelection() }
    }

    func treeFocusChild(for target: Window?) throws(WindowOperationError)
    {
        guard let owner = treeView(for: target) else { throw .invalidSourceView }

        guard let selected = owner.tree?.findSelected(), selected.children.count != 0 else { throw .invalidDestinationNode }

        let child = selected.focusOrder[0]
        if child.isLeaf {
            owner.tree?.select(nil)
            focusWindow(id: child.windowID)
        } else {
            owner.tree?.select(child)
            if owner.sid.isVisible { child.showSelection() }
        }
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

        guard let sid = did.currentSpace else { return }
        let dstView = SpaceManager.shared.view(for: sid)

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

    func treeMove(direction: Direction, for target: Window) throws(WindowOperationError)
    {
        guard let owner = treeView(for: target) else { throw .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { throw .invalidSourceNode }

        let did = treeDisplay(in: direction, from: owner)

        switch node.move(direction, in: owner.tree!, hasOutput: did != nil) {
        case .done:
            treeApply(owner)
        case .output:
            guard let did else { throw .invalidDestinationNode }
            treeMove(node, from: owner, to: did, direction: direction)
        case .none:
            throw .invalidDestinationNode
        }
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

        var wasFocused = target.id == focusedWindowID
        if !wasFocused && target.id == lastWindowID {
            if let focusedID = focusedWindowID, let focused = window(for: focusedID) {
                wasFocused = focused.application == target.application || treeView(for: focused) == owner
            }
        }

        if !wasFocused { return nil }

        guard let node = owner.tree?.find(target.id), let candidate = node.focusCandidate else { return nil }
        return candidate.isLeaf ? candidate.windowID : nil
    }

    func treeFocusAfterClose(in owner: View, windowID: WindowID?)
    {
        guard let windowID, owner.sid.isVisible else { return }
        focusWindow(id: windowID)
    }

    func treeSplit(_ split: SplitOrientation, for target: Window?) throws(WindowOperationError)
    {
        guard let target, let owner = treeView(for: target) else { throw .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { throw .invalidSourceNode }

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
    }
}
