import YabaiCore

//
// NOTE: The snapshot of a container tree, for space --undo. A tree rebuilt from a snapshot has the containers, shares,
// zoom, selection and focus order of the snapshot and the windows of its leaves. Frames, tab bars and the render state
// of the containers are made again when the view is laid out and flushed.
//

extension Con {
  /// The tree under this container.
  var snapshot: TreeSnapshot {
    let focusOrder = self.focusOrder.compactMap { child in children.firstIndex(of: child) }

    return TreeSnapshot(
      layout: layout, lastSplit: lastSplit, percent: percent, zoom: zoom, isSelected: isSelected,
      windowID: windowID, children: children.map(\.snapshot), focusOrder: focusOrder)
  }

  /// A container with the tree of a snapshot: its children are linked to it, in the order and focus order of the snapshot.
  convenience init(snapshot: TreeSnapshot) {
    self.init(layout: snapshot.layout, windowID: snapshot.windowID)
    lastSplit = snapshot.lastSplit
    percent = snapshot.percent
    zoom = snapshot.zoom
    isSelected = snapshot.isSelected

    for child in snapshot.children {
      let node = Con(snapshot: child)
      node.parent = self
      children.append(node)
    }

    focusOrder = snapshot.focusOrder.compactMap { index in
      children.indices.contains(index) ? children[index] : nil
    }
  }
}
