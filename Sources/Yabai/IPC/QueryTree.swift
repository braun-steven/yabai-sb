import YabaiCore

// MARK: Tree

extension View {
  //
  // NOTE: The container tree of a space, similar to i3's get_tree. Containers list their children
  // in tab or split order. Spaces without the tree layout have no tree.
  //

  /// The tree for `query --tree`; nil unless the space uses the tree layout.
  func treeNode() -> TreeNode? {
    guard layout == .tree else { return nil }
    return treeNode(for: root)
  }

  private func treeNode(for node: Con) -> TreeNode {
    let leaf = node.isLeaf
    let parent = node.parent

    return TreeNode(
      type: parent == nil ? .workspace : leaf ? .window : .container,
      layout: leaf ? nil : node.layout.rawValue,
      percent: parent != nil ? node.percent : 1.0,
      window: node.windowID,
      frame: leaf ? frame(for: node) : node.area,
      focused: leaf && node.windowID == WindowManager.shared.focus.focused,
      selected: node.isSelected,
      visible: node.isVisible,
      nodes: node.children.map { treeNode(for: $0) })
  }
}
