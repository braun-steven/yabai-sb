import AppKit
import CPrivate
import CoreGraphics
import Foundation
import YabaiCore

//
// NOTE: WindowManager finds windows by stacking rank, point, direction, tree order, tab stack, and area.
//

extension WindowManager {
  /// The window with the rank (from 1, top first) among the known windows of a space, excluding `windowID`.
  func window(on sid: SpaceID, byRank rank: Int, excluding windowID: WindowID?) -> Window? {
    guard let windowList = sid.windows(includingMinimized: false) else { return nil }

    var index = 0
    for id in windowList {
      if id == windowID { continue }

      guard let target = window(for: id) else { continue }

      index += 1
      if index == rank { return target }
    }

    return nil
  }

  //
  // NOTE: The window that gets focus when focus moves to a space on another display, coming from the display in the
  // opposite direction or from no direction (nil). On a tree space it is the window the tree enters at
  // (Con.entry(from:)). Elsewhere, and on a tree space without tiled windows, it is the frontmost window that yabai
  // could manage there: windows on every space and windows of other roles, such as system dialogs, are skipped. Nil
  // when there is no such window.
  //

  func displayFocusTarget(on sid: SpaceID, from direction: Direction?) -> Window? {
    let owner = SpaceManager.shared.view(for: sid)
    if owner.layout == .tree, let leaf = owner.tree?.entry(from: direction), leaf.isLeaf,
      let target = leaf.windowID.flatMap({ window(for: $0) })
    {
      return target
    }

    guard let windowList = sid.windows(includingMinimized: false) else { return nil }
    for id in windowList {
      guard let target = window(for: id) else { continue }
      if target.isSticky || !target.isEligibleForManagement { continue }
      return target
    }

    return nil
  }

  // NOTE: The window at a point, starting below `startID` (order -1) or from the top (nil, order 1). Windows of our
  // own connection (borders, tab bars) are skipped.
  private func window(at point: CGPoint, startingBelow startID: WindowID?, order: Int32) -> Window?
  {
    var (found, owner) = SLS.findWindow(
      SLS.connection, at: point, startingAt: startID, order: order)
    while let current = found, owner == SLS.connection {
      (found, owner) = SLS.findWindow(SLS.connection, at: point, startingAt: current, order: -1)
    }

    guard let found else { return nil }
    return window(for: found)
  }

  func window(at point: CGPoint, excluding windowID: WindowID) -> Window? {
    window(at: point, startingBelow: windowID, order: -1)
  }

  func window(at point: CGPoint) -> Window? {
    window(at: point, startingBelow: nil, order: 1)
  }

  func windowBelowCursor() -> Window? {
    window(at: SLS.cursorLocation(SLS.connection))
  }

  func closestManagedWindow(to target: Window, in direction: Direction) -> Window? {
    guard let owner = treeView(for: target) else { return nil }
    guard let node = owner.tree?.find(target.id) else { return nil }

    guard let result = node.neighbor(direction, wrapping: .off, hasOutput: false).target else {
      return nil
    }
    guard result.isLeaf, result != node else { return nil }

    return result.windowID.flatMap { window(for: $0) }
  }

  private func activeTreeView() -> View? {
    guard let sid = Headless.isEnabled ? Headless.activeSpace : SpaceID.active else { return nil }
    let owner = SpaceManager.shared.view(for: sid)
    return owner.tree != nil ? owner : nil
  }

  private func window(for node: Con?) -> Window? {
    guard let node, node.isLeaf, let id = node.windowID else { return nil }
    return window(for: id)
  }

  /// The leaf of a window in the active space's tree.
  private func activeCon(for target: Window) -> Con? {
    guard let owner = activeTreeView() else { return nil }
    return owner.tree?.find(target.id)
  }

  func previousManagedWindow(from target: Window) -> Window? {
    guard let node = activeCon(for: target) else { return nil }
    return window(for: node.previousLeaf)
  }

  func nextManagedWindow(from target: Window) -> Window? {
    guard let node = activeCon(for: target) else { return nil }
    return window(for: node.nextLeaf)
  }

  func firstManagedWindow() -> Window? {
    guard let owner = activeTreeView() else { return nil }
    return window(for: owner.tree?.firstLeaf)
  }

  func lastManagedWindow() -> Window? {
    guard let owner = activeTreeView() else { return nil }
    return window(for: owner.tree?.lastLeaf)
  }

  func recentManagedWindow() -> Window? {
    guard let lastWindowID = focus.last, let target = window(for: lastWindowID) else { return nil }
    if managedView(for: target) == nil { return nil }

    return target
  }

  // NOTE: The stack.* selectors pick tabs of the closest tabbed container. A tab that holds a container resolves to
  // the window focused in it last.
  private func tab(for target: Window) -> (tab: Con, tabbed: Con)? {
    guard var node = activeCon(for: target) else { return nil }
    guard let parent = node.tabbedAncestor else { return nil }

    while node.parent != parent { node = node.parent! }
    return (node, parent)
  }

  /// A position of a tab in the stack around a window.
  private enum TabPosition {
    /// The tab at an offset from the tab of the window.
    case offset(Int)
    /// The tab at an index (from 0).
    case index(Int)
    case last
  }

  private func window(inTabStackAround target: Window, at position: TabPosition) -> Window? {
    guard let found = tab(for: target) else { return nil }
    let (tab, tabbed) = found

    let index =
      switch position {
      case .offset(let offset): tab.index! + offset
      case .index(let index): index
      case .last: tabbed.children.count - 1
      }
    if index < 0 || index >= tabbed.children.count { return nil }

    return window(for: tabbed.children[index].focusedDescendant)
  }

  func previousWindowInStack(around target: Window) -> Window? {
    window(inTabStackAround: target, at: .offset(-1))
  }

  func nextWindowInStack(around target: Window) -> Window? {
    window(inTabStackAround: target, at: .offset(1))
  }

  func firstWindowInStack(around target: Window) -> Window? {
    window(inTabStackAround: target, at: .index(0))
  }

  func lastWindowInStack(around target: Window) -> Window? {
    window(inTabStackAround: target, at: .last)
  }

  func recentWindowInStack(around target: Window) -> Window? {
    guard let found = tab(for: target), found.tabbed.children.count >= 2 else { return nil }
    let (tab, tabbed) = found

    let recent = tabbed.focusOrder[0] == tab ? tabbed.focusOrder[1] : tabbed.focusOrder[0]
    return window(for: recent.focusedDescendant)
  }

  /// The tab at a one-based index in the stack around a window.
  func windowInStack(around target: Window, at index: Int) -> Window? {
    window(inTabStackAround: target, at: .index(index - 1))
  }

  /// The visible leaf with the largest area (the first one), or the smallest area (the last one).
  private func managedWindow(byArea largest: Bool) -> Window? {
    guard let owner = activeTreeView() else { return nil }

    var bestID: WindowID?
    var bestArea: Float = largest ? 0 : Float.greatestFiniteMagnitude

    var node = owner.tree?.firstLeaf
    while let leaf = node, leaf.isLeaf {
      if leaf.isVisible {
        let area = leaf.area.w * leaf.area.h
        if largest ? area > bestArea : area <= bestArea {
          bestID = leaf.windowID
          bestArea = area
        }
      }

      node = leaf.nextLeaf
    }

    return bestID.flatMap { window(for: $0) }
  }

  func largestManagedWindow() -> Window? {
    managedWindow(byArea: true)
  }

  func smallestManagedWindow() -> Window? {
    managedWindow(byArea: false)
  }
}
