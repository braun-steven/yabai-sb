import CoreGraphics

//
// NOTE: The arithmetic of dragging the gap between two children of a split (P13.2), and the flat tree that the event tap
// hit-tests. Con.resize and the split drag share SplitRatio, so a keyboard resize and a mouse drag move the same way.
//

/// The percents of the two children next to a gap, after the gap moves.
public enum SplitRatio {
  /// The percents after the boundary between two children moved by delta pixels along a split of size pixels (positive
  /// is right or down: the first child grows). The change is a share of size and is applied to the first child and taken
  /// from the second. A child that would get less than minPercent is held at it, and the other child gives up the rest.
  /// Nil when size is not positive or delta is not finite.
  public static func resized(
    first: Float, second: Float, delta: Float, size: Float, minPercent: Float
  ) -> (first: Float, second: Float)? {
    if size <= 0.0 || !delta.isFinite { return nil }

    let change = delta / size
    var firstPercent = first + change
    var secondPercent = second - change

    if firstPercent < minPercent {
      secondPercent -= minPercent - firstPercent
      firstPercent = minPercent
    }

    if secondPercent < minPercent {
      firstPercent -= minPercent - secondPercent
      secondPercent = minPercent
    }

    return (firstPercent, secondPercent)
  }
}

/// What the visible-path walk reads of a container.
public struct SplitLayoutInfo: Sendable {
  public var layout: ConLayout
  public var percent: Float
  public var area: Area
  /// Whether the container is zoomed (to its parent or the whole view), so that it covers the gaps of its view.
  public var isZoomed: Bool

  public init(layout: ConLayout, percent: Float, area: Area, isZoomed: Bool) {
    self.layout = layout
    self.percent = percent
    self.area = area
    self.isZoomed = isZoomed
  }
}

/// The visible path of a tree as TreeLayout sees it: the flat pre-order arrays that SplitHitTest reads, with the element
/// of every node (the same index), so a hit can be mapped back to its container.
public struct SplitLayoutPath<Element> {
  public var nodes: [LayoutNode]
  public var areas: [Area]
  public var elements: [Element]

  public init(nodes: [LayoutNode], areas: [Area], elements: [Element]) {
    self.nodes = nodes
    self.areas = areas
    self.elements = elements
  }
}

public enum SplitLayoutWalk {
  //
  // NOTE: The children laid out under a container are given by the caller. A tabbed container lists only its visible
  // child: its children share one area, so the visible child gives the same gaps and areas. A zoomed container anywhere
  // on the path gives nil, because a zoomed window covers the gaps of its view.
  //

  /// The visible path below root in pre-order, or nil when a container on the path is zoomed.
  public static func visiblePath<Element>(
    _ root: Element,
    info: (Element) -> SplitLayoutInfo,
    children: (Element) -> [Element]
  ) -> SplitLayoutPath<Element>? {
    var path = SplitLayoutPath<Element>(nodes: [], areas: [], elements: [])
    return append(root, info: info, children: children, into: &path) ? path : nil
  }

  private static func append<Element>(
    _ element: Element,
    info: (Element) -> SplitLayoutInfo,
    children: (Element) -> [Element],
    into path: inout SplitLayoutPath<Element>
  ) -> Bool {
    let node = info(element)
    if node.isZoomed { return false }

    let laidOut = children(element)
    path.nodes.append(
      LayoutNode(layout: node.layout, percent: node.percent, childCount: laidOut.count))
    path.areas.append(node.area)
    path.elements.append(element)

    for child in laidOut {
      if !append(child, info: info, children: children, into: &path) { return false }
    }
    return true
  }
}
