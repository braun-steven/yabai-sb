import AppKit
import CPrivate
import Foundation
import YabaiCore

extension WindowManager {
  func setWindowInsertion(_ target: Window?, _ direction: InsertDirection)
    throws(WindowOperationError)
  {
    guard let target else { throw .invalidSourceView }

    guard let sid = target.id.space else { throw .invalidSourceView }
    let owner = SpaceManager.shared.view(for: sid)
    if owner.layout != .tree || owner.tree == nil { throw .invalidSourceView }

    guard let node = owner.tree?.find(target.id) else { throw .invalidSourceNode }

    setInsertion(of: node, in: owner, direction)
  }

  //
  // NOTE: The insertion of window --insert, shared with insert= rules. The view keeps one pending insertion: a new one
  // replaces it, and asking for the direction the node already has cancels it. The next add to the view consumes it.
  //

  func setInsertion(of node: Con, in owner: View, _ direction: InsertDirection) {
    if owner.insertionPoint != nil && owner.insertionPoint != node.windowID {
      if let insert = owner.tree?.find(owner.insertionPoint) {
        insert.insertDirection = nil
        insert.hideFeedback()
      }
    }

    if direction == node.insertDirection {
      node.insertDirection = nil
      node.hideFeedback()
      owner.insertionPoint = nil
      return
    }

    node.insertDirection = direction
    owner.insertionPoint = node.windowID
    if owner.sid.isVisible { node.showFeedback(direction: direction) }
  }

  //
  // NOTE: Stacking a window onto another puts it into the tabbed container of that window, and turns
  // the window into a tabbed container first when it is not a tab yet.
  //

  func stackWindow(_ a: Window, _ b: Window) throws(WindowOperationError) {
    if a.id == b.id { throw .sameWindow }

    guard let aView = treeView(for: a) else { throw .invalidSourceNode }
    if aView.tree?.find(a.id) == nil { throw .invalidSourceNode }

    if let bView = managedView(for: b) {
      unmanageWindow(b, from: bView)
    } else if b.isFloating {
      if !b.isEligibleForManagement { throw .invalidDestinationNode }
      b.rememberFloatingFrame()
      b.isFloating = false
      if b.isSticky { makeWindowSticky(b, shouldBeSticky: false) }
    }

    guard let aCon = aView.tree?.find(a.id) else { throw .invalidSourceNode }

    if b.id.space != aView.sid {
      aView.sid.moveWindow(b)
      _ = aView.sid.waitForWindow(b.id, timeoutMS: 200)
    }

    let node = Con(windowID: b.id)
    aCon.insert(node, toward: .stack)

    addManagedWindow(b, to: aView)
    b.adjustLayer(to: .below)
    treeApply(aView)
  }

  func setWindowLayout(_ target: Window?, _ layout: WindowLayout) throws(WindowOperationError) {
    guard let target, let owner = treeView(for: target) else { throw .invalidSourceView }
    guard let node = treeActingCon(in: owner, for: target) else { throw .invalidSourceNode }

    let parent = node.parent ?? node

    switch layout {
    case .tabbed: node.setLayout(.tabbed)
    case .splitH: node.setLayout(.splitH)
    case .splitV: node.setLayout(.splitV)
    case .split: node.setLayout(parent.layout == .tabbed ? parent.lastSplit : parent.layout)
    case .toggle: _ = node.toggleLayout(splitOnly: false)
    case .toggleSplit: _ = node.toggleLayout(splitOnly: true)
    }

    owner.tree!.flatten()
    treeApply(owner)
  }

  //
  // NOTE: Warping onto a window places the window right after it, in the container of that window.
  //

  func warpWindow(_ a: Window, _ b: Window) throws(WindowOperationError) {
    if a.id == b.id { throw .sameWindow }

    let aView = treeView(for: a)
    let bView = treeView(for: b)
    guard let aView else { throw .invalidSourceView }
    guard let bView else { throw .invalidDestinationView }

    let aCon = aView.tree?.find(a.id)
    let bCon = bView.tree?.find(b.id)
    guard let aCon else { throw .invalidSourceNode }
    guard let bCon else { throw .invalidDestinationNode }

    if aView == bView {
      aCon.place(.after, of: bCon)
      aView.tree!.flatten()
      treeApply(aView)
    } else {
      unmanage(a, from: aView, options: .flush)
      addManagedWindow(a, to: bView)
      bView.sid.moveWindow(a)
      _ = bView.sid.waitForWindow(a.id, timeoutMS: 200)
      _ = SpaceManager.shared.tile(a, on: bView.sid, insertionPoint: b.id)
    }
  }

  //
  // NOTE: sway swap_focus. When the focused window swaps with a window of another space, focus goes to the partner,
  // which now sits where the focused window was, so focus stays on the same space and display. Within one space focus
  // stays on the focused window, which moves with it. Con.swap gives the swapped-in container the slot of the other
  // in the focus order of its parent, so in a tabbed container it shows as the active tab when the other was, as sway
  // does by focusing it first; treeApply then makes the focused window the active tab of its new container.
  //

  func swapFocusTarget(_ a: WindowID, _ b: WindowID, acrossSpaces: Bool) -> WindowID? {
    guard acrossSpaces else { return nil }
    if focus.focused == a { return b }
    if focus.focused == b { return a }
    return nil
  }

  func swapWindow(_ a: Window, _ b: Window) throws(WindowOperationError) {
    if a.id == b.id { throw .sameWindow }

    let aView = treeView(for: a)
    let bView = treeView(for: b)
    guard let aView else { throw .invalidSourceView }
    guard let bView else { throw .invalidDestinationView }

    let aCon = aView.tree?.find(a.id)
    let bCon = bView.tree?.find(b.id)
    guard let aCon else { throw .invalidSourceNode }
    guard let bCon else { throw .invalidDestinationNode }

    let focusTarget = swapFocusTarget(a.id, b.id, acrossSpaces: aView != bView)
    guard aCon.swap(with: bCon) else { throw .invalidDestinationNode }

    if aView != bView {
      let aMoved = treeSetView(aCon, to: bView)
      let bMoved = treeSetView(bCon, to: aView)
      treeWaitForView(aMoved, bView)
      treeWaitForView(bMoved, aView)
      treeApply(bView)
    }

    treeApply(aView)
    focusWindow(id: focusTarget)
  }
}
