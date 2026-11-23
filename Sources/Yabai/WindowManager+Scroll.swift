import YabaiCore

//
// NOTE: The window commands on a scroll view (ScrollView.swift) where they differ from a tree, after niri and Dinky. The
// i3 operations of the tree would re-orient the root, the strip, when a move or a layout reaches it, so these act on
// columns instead:
// - `--warp east|west` takes a window that shares its column out into a new column on that side, and swaps a whole
//   column (a window alone in its column, or a column selected with `--focus parent`) with its neighbour. At the end of
//   the strip a column goes to the display in that direction, as in a tree.
// - `--warp north|south` moves a window only within its column.
// - `--ratio` of a column, and the left and right edges of `--resize`, set the width of the column.
// - `--layout` and `--split` of a window alone in its column change that column, not the strip.
//

extension WindowManager {
  /// The child of the root of a scroll view that holds the container: its column.
  private func column(of node: Con, in root: Con) -> Con? {
    var column = node
    while let parent = column.parent, parent !== root { column = parent }
    return column.parent === root ? column : nil
  }

  /// The column of the container when the container holds all of its windows (it is the column, or the column holds
  /// nothing else): the container then acts as the whole column. Nil for a window that shares its column.
  func wholeColumn(of node: Con, in owner: View) -> Con? {
    guard let root = owner.tree, let column = column(of: node, in: root) else { return nil }
    if column === node || column.windowCount == node.windowCount { return column }
    return nil
  }

  /// `window --warp` in a scroll view. Returns `.output` when the container should go to the display in the direction.
  func scrollMove(_ node: Con, in owner: View, direction: Direction, hasOutput: Bool) -> TreeResult {
    guard let root = owner.tree, let column = column(of: node, in: root),
      let index = column.index
    else { return .none }

    if direction == .north || direction == .south {
      return scrollMoveStaysInColumn(node, direction, root: root)
        ? node.move(direction, in: root, hasOutput: false) : .none
    }

    let forward = direction == .east
    if wholeColumn(of: node, in: owner) == nil {
      // NOTE: A window that shares its column leaves it for a new column on that side, as wide as the column was.
      let width = column.columnWidth
      node.detach()
      root.attach(node, at: index + (forward ? 1 : 0))
      node.columnWidth = width
      root.flatten()
      node.focus()
      return .done
    }

    let neighbour = index + (forward ? 1 : -1)
    guard root.children.indices.contains(neighbour) else { return hasOutput ? .output : .none }
    guard column.swap(with: root.children[neighbour]) else { return .none }
    return .done
  }

  //
  // NOTE: Con.move climbs from the window to the first container laid out in the direction of the move. In a scroll view
  // the root is laid out across a vertical move, so a move that climbs to the root would re-orient it. This follows the
  // same climb and is true when the move stops inside the column: at a vertical container below the root with a
  // neighbour on that side, or at the second vertical container it reaches.
  //

  private func scrollMoveStaysInColumn(_ node: Con, _ direction: Direction, root: Con) -> Bool {
    let offset = direction == .north ? -1 : 1
    var current = node
    while let parent = current.parent, parent !== root {
      if parent.orientation != .vertical {
        current = parent
        continue
      }
      if current !== node { return true }
      if let index = current.index, parent.children.indices.contains(index + offset) {
        return true
      }
      current = parent
    }
    return false
  }

  /// `window --ratio` of a column of a scroll view: sets its width as a share of the view (abs), or adds to it (rel).
  func setColumnWidth(_ column: Con, in owner: View, type: ValueType?, ratio: Float) {
    let share = type == .rel ? owner.columnShare(of: column) + ratio : ratio
    column.columnWidth = ScrollStrip.clampedShare(share)
    treeApply(owner)
  }

  /// The left and right edges of `window --resize` in a scroll view: widens (positive) or narrows the column of the
  /// container by delta points. False when the column is already as wide or as narrow as it goes.
  func resizeColumn(of node: Con, in owner: View, by delta: Float) -> Bool {
    guard let root = owner.tree, let column = column(of: node, in: root) else { return false }
    let before = owner.columnShare(of: column)
    let share = ScrollStrip.clampedShare(
      before + delta / (owner.sharedColumnLength + Float(owner.windowGapValue)))
    if share == before { return false }
    column.columnWidth = share
    return true
  }

  /// `window --layout` and `window --split` in a scroll view act on the column of a window alone in it: the window is
  /// put in a column container first, so that the change reaches that container and not the strip. A selected column
  /// passes the change to its focused child, whose parent is the column. Returns the container to act on.
  func scrollLayoutTarget(_ node: Con, in owner: View) -> Con {
    guard let root = owner.tree, node.parent === root else { return node }
    if node.isLeaf {
      node.wrapInColumn()
      return node
    }
    return node.focusOrder.first ?? node
  }

  /// `window --center`: scrolls the strip of the window's scroll view so that its column is centered.
  func centerColumn(of target: Window) throws(WindowOperationError) {
    guard let owner = managedView(for: target), owner.layout == .scroll, let root = owner.tree
    else { throw .invalidSourceView }
    guard let node = root.find(target.id), let column = column(of: node, in: root),
      let index = column.index
    else { throw .invalidSourceNode }

    owner.centerColumn(at: index)
  }
}
