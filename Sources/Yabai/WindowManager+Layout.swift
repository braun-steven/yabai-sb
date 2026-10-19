import Foundation
import AppKit
import CPrivate
import YabaiCore

extension WindowManager
{
    func setWindowInsertion(_ target: Window?, _ direction: InsertDirection) -> WindowOperationResult
    {
        guard let target else { return .invalidSourceView }

        guard let sid = target.id.space else { return .invalidSourceView }
        let owner = space_manager_find_view(SpaceManager.shared, sid)
        if owner.layout != .tree || owner.tree == nil { return .invalidSourceView }

        guard let node = owner.tree?.find(target.id) else { return .invalidSourceNode }

        if owner.insertionPoint != nil && owner.insertionPoint != target.id {
            if let insert = owner.tree?.find(owner.insertionPoint) {
                insert.insertDirection = nil
                insert.hideFeedback()
            }
        }

        if direction == node.insertDirection {
            node.insertDirection = nil
            node.hideFeedback()
            owner.insertionPoint = nil
            return .success
        }

        node.insertDirection = direction
        owner.insertionPoint = target.id
        if owner.sid.isVisible { node.showFeedback(direction: direction) }

        return .success
    }

    //
    // NOTE: Stacking a window onto another puts it into the tabbed container of that window, and turns
    // the window into a tabbed container first when it is not a tab yet.
    //

    func stackWindow(_ a: Window, _ b: Window) -> WindowOperationResult
    {
        if a.id == b.id { return .sameWindow }

        guard let aView = treeView(for: a) else { return .invalidSourceNode }
        if aView.tree?.find(a.id) == nil { return .invalidSourceNode }

        if let bView = managedView(for: b) {
            unmanageWindow(b, from: bView)
        } else if b.isFloating {
            if !b.isEligibleForManagement { return .invalidDestinationNode }
            b.isFloating = false
            if b.isSticky { makeWindowSticky(b, shouldBeSticky: false) }
        }

        guard let aCon = aView.tree?.find(a.id) else { return .invalidSourceNode }

        if b.id.space != aView.sid {
            aView.sid.moveWindow(b)
            _ = aView.sid.waitForWindow(b.id, timeoutMS: 200)
        }

        let node = Con(windowID: b.id)
        aCon.insert(node, toward: .stack)

        addManagedWindow(b, to: aView)
        b.adjustLayer(to: .below)
        treeApply(aView)

        return .success
    }

    func setWindowLayout(_ target: Window?, _ layout: WindowLayout) -> WindowOperationResult
    {
        guard let target, let owner = treeView(for: target) else { return .invalidSourceView }
        guard let node = treeActingCon(in: owner, for: target) else { return .invalidSourceNode }

        let parent = node.parent ?? node

        switch layout {
        case .tabbed:      node.setLayout(.tabbed)
        case .splitH:      node.setLayout(.splitH)
        case .splitV:      node.setLayout(.splitV)
        case .split:       node.setLayout(parent.layout == .tabbed ? parent.lastSplit : parent.layout)
        case .toggle:      _ = node.toggleLayout(splitOnly: false)
        case .toggleSplit: _ = node.toggleLayout(splitOnly: true)
        }

        owner.tree!.flatten()
        treeApply(owner)
        return .success
    }

    //
    // NOTE: Warping onto a window places the window right after it, in the container of that window.
    //

    func warpWindow(_ a: Window, _ b: Window) -> WindowOperationResult
    {
        if a.id == b.id { return .sameWindow }

        let aView = treeView(for: a)
        let bView = treeView(for: b)
        guard let aView else { return .invalidSourceView }
        guard let bView else { return .invalidDestinationView }

        let aCon = aView.tree?.find(a.id)
        let bCon = bView.tree?.find(b.id)
        guard let aCon else { return .invalidSourceNode }
        guard let bCon else { return .invalidDestinationNode }

        if aView == bView {
            aCon.place(.after, of: bCon)
            aView.tree!.flatten()
            treeApply(aView)
        } else {
            space_manager_untile_window(aView, a)
            removeManagedWindow(a.id)
            addManagedWindow(a, to: bView)
            bView.sid.moveWindow(a)
            _ = bView.sid.waitForWindow(a.id, timeoutMS: 200)
            _ = space_manager_tile_window_on_space_with_insertion_point(SpaceManager.shared, a, bView.sid, b.id)
        }

        return .success
    }

    func swapWindow(_ a: Window, _ b: Window) -> WindowOperationResult
    {
        if a.id == b.id { return .sameWindow }

        let aView = treeView(for: a)
        let bView = treeView(for: b)
        guard let aView else { return .invalidSourceView }
        guard let bView else { return .invalidDestinationView }

        let aCon = aView.tree?.find(a.id)
        let bCon = bView.tree?.find(b.id)
        guard let aCon else { return .invalidSourceNode }
        guard let bCon else { return .invalidDestinationNode }

        aCon.swap(with: bCon)

        if aView != bView {
            let aMoved = treeSetView(aCon, to: bView)
            let bMoved = treeSetView(bCon, to: aView)
            treeWaitForView(aMoved, bView)
            treeWaitForView(bMoved, aView)
            treeApply(bView)
        }

        treeApply(aView)
        return .success
    }
}
