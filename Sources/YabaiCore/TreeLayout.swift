/// The layout of a container, named as in `query --tree`.
public enum ConLayout: String, Sendable {
  case splitH = "splith"
  case splitV = "splitv"
  case tabbed
}

/// What the layout math reads of a container: its layout, its share of the length of its parent and its number of
/// children. A tree is a flat array of these in pre-order: each container is followed by the subtrees of its children.
public struct LayoutNode: Equatable, Sendable {
  public var layout: ConLayout
  public var percent: Float
  /// The number of direct children; zero for a window or a container without children.
  public var childCount: Int

  public init(layout: ConLayout, percent: Float, childCount: Int) {
    self.layout = layout
    self.percent = percent
    self.childCount = childCount
  }

  /// A node without children.
  public static func leaf(percent: Float) -> LayoutNode {
    LayoutNode(layout: .splitH, percent: percent, childCount: 0)
  }
}

/// The settings a layout takes from its view and the config.
public struct LayoutParams: Equatable, Sendable {
  public var gap: Int
  public var barHeight: Int
  public var barOffset: Int
  public var barInset: Int

  public init(gap: Int, barHeight: Int, barOffset: Int, barInset: Int) {
    self.gap = gap
    self.barHeight = barHeight
    self.barOffset = barOffset
    self.barInset = barInset
  }
}

/// The area of every container of a tree, computed without the window server.
public enum TreeLayout {
  //
  // NOTE: Computes the area of every container. Splits divide the area along their orientation by
  // the share of each child, with the window gap in between; a gap is never longer than the average
  // child, so the gaps of a split only a few gaps long shrink instead of leaving its children a
  // negative length, and a child that rounding leaves no room for gets none. The children of a tabbed container
  // share its area below the tab bar, moved down by the bar offset (a negative offset lets them
  // reach under the bar). They always keep at least the height of the bar. With a backdrop card
  // the bar and the windows are additionally inset from every edge of the container by bar_inset.
  //

  /// The inset of the bar and the windows from the edges of a container with a backdrop card.
  public static func cardInset(_ area: Area, barHeight: Int, barInset: Int) -> Int {
    if barInset <= 0 { return 0 }
    if area.w <= Float(4 * barInset) || area.h - Float(2 * barInset) <= Float(2 * barHeight) {
      return 0
    }
    return barInset
  }

  /// The gap between the count children of a split of the given length: at most the length of an average child.
  public static func splitGap(_ gap: Int, length: Float, count: Int) -> Int {
    min(gap, max(0, Int(length) / (2 * count - 1)))
  }

  /// The area of every node of a tree in pre-order (nodes[0] is the root, which gets area). The children of a split
  /// share its length, a tabbed container gives its children one area below its bar, and a node without children
  /// is not split any further.
  public static func layOut(_ nodes: [LayoutNode], in area: Area, params: LayoutParams) -> [Area] {
    var areas = [Area](repeating: .zero, count: nodes.count)
    if !nodes.isEmpty {
      _ = place(nodes, 0, area, params, &areas)
    }
    return areas
  }

  /// Places the node at index in area and its descendants after it. Returns the index after the subtree of the node.
  private static func place(
    _ nodes: [LayoutNode], _ index: Int, _ area: Area, _ params: LayoutParams, _ areas: inout [Area]
  ) -> Int {
    areas[index] = area

    let node = nodes[index]
    let count = node.childCount
    var next = index + 1
    if count == 0 { return next }

    if node.layout == .tabbed {
      var childArea = area
      if params.barHeight > 0 && area.h > Float(2 * params.barHeight) {
        let inset = cardInset(area, barHeight: params.barHeight, barInset: params.barInset)
        childArea.x += Float(inset)
        childArea.y += Float(inset)
        childArea.w -= Float(2 * inset)
        childArea.h -= Float(2 * inset)

        let reserve = max(
          0, min(params.barHeight + params.barOffset, Int(childArea.h) - params.barHeight))
        childArea.y += Float(reserve)
        childArea.h -= Float(reserve)
      }

      for _ in 0..<count {
        next = place(nodes, next, childArea, params, &areas)
      }
      return next
    }

    let horizontal = node.layout == .splitH
    let length = horizontal ? area.w : area.h
    let gap = splitGap(params.gap, length: length, count: count)
    let total = length - Float(gap * (count - 1))
    var offset = horizontal ? area.x : area.y
    let end = horizontal ? area.x + area.w : area.y + area.h

    for i in 0..<count {
      let child = nodes[next]
      let room = end - offset - Float(gap * (count - 1 - i))
      let size = i == count - 1 ? room : min(room, Float(Int(total * child.percent + 0.5)))

      var childArea = area
      if horizontal {
        childArea.x = offset
        childArea.w = size
      } else {
        childArea.y = offset
        childArea.h = size
      }

      next = place(nodes, next, childArea, params, &areas)
      offset += size + Float(gap)
    }

    return next
  }
}

/// The tab title of a container, like i3 shows it: the bracket of its layout and the names of the windows inside,
/// for example `H[iTerm2 Safari]`. A window is its name, or nothing when it has none.
public enum TreeTitle {
  /// The title of node. container gives the layout and the children of a container, nil for a window; leafName gives
  /// the name of a window, nil for none.
  public static func title<Node>(
    of node: Node, container: (Node) -> (layout: ConLayout, children: [Node])?,
    leafName: (Node) -> String?
  ) -> String {
    var string = ""
    append(node, container: container, leafName: leafName, to: &string)
    return string
  }

  private static func append<Node>(
    _ node: Node, container: (Node) -> (layout: ConLayout, children: [Node])?,
    leafName: (Node) -> String?, to string: inout String
  ) {
    guard let members = container(node) else {
      if let name = leafName(node) { string += name }
      return
    }

    string += members.layout == .splitH ? "H[" : members.layout == .splitV ? "V[" : "T["
    for (index, child) in members.children.enumerated() {
      if index > 0 { string += " " }
      append(child, container: container, leafName: leafName, to: &string)
    }
    string += "]"
  }
}
