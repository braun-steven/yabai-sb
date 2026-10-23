import CoreGraphics

//
// NOTE: The gap between two children of a split, where a drag can start (P13.2). The strip of a gap runs along the
// split's axis from the end of one child to the start of the next, as wide as TreeLayout puts between them
// (TreeLayout.splitGap), widened by SplitHitTest.tolerance on each side and clipped to the area of the split. It runs
// across the full extent of that area. Tabbed containers have no gaps. Their children share one area, so a split inside
// a tab that is not shown gets the same strips as the visible tab: callers must only use the visible tab.
//

/// A gap between two adjacent children of a split container.
public struct SplitHandle: Equatable, Sendable {
  /// The pre-order index of the split container in the flat tree.
  public var container: Int
  /// The gap lies between the child at boundary and the child at boundary + 1 of the container.
  public var boundary: Int
  /// `.splitH` when the children sit side by side (the gap is vertical), `.splitV` when they are stacked.
  public var orientation: ConLayout

  public init(container: Int, boundary: Int, orientation: ConLayout) {
    self.container = container
    self.boundary = boundary
    self.orientation = orientation
  }
}

/// Finds the gap of a split under a point, on the areas that TreeLayout computed for the same tree and window gap.
public enum SplitHitTest {
  /// How far outside a gap a point may lie and still hit it, on each side.
  public static let tolerance: CGFloat = 2

  /// The gap under the point, or nil. nodes and areas are the flat pre-order arrays of the tree and of its layout (see
  /// TreeLayout.layOut), gap is the window gap. When the gaps of nested splits both match, the innermost split wins; of
  /// splits at the same depth, the first in pre-order. A point inside a window, outside the root, or in a tree whose
  /// arrays differ in count gives nil.
  public static func handle(
    nodes: [LayoutNode], areas: [Area], gap: Int, at point: CGPoint
  ) -> SplitHandle? {
    guard !nodes.isEmpty, nodes.count == areas.count else { return nil }

    var best: (handle: SplitHandle, depth: Int)?
    _ = visit(nodes, areas, gap: gap, point: point, index: 0, depth: 0, best: &best)
    return best?.handle
  }

  /// Checks the gaps between the children of the node at index, then those of its descendants. Returns the index after
  /// the subtree of the node.
  private static func visit(
    _ nodes: [LayoutNode], _ areas: [Area], gap: Int, point: CGPoint, index: Int, depth: Int,
    best: inout (handle: SplitHandle, depth: Int)?
  ) -> Int {
    let node = nodes[index]
    var next = index + 1
    guard node.childCount > 0 else { return next }

    let area = areas[index]
    let horizontal = node.layout == .splitH
    let split = horizontal || node.layout == .splitV
    let spacing =
      split
      ? TreeLayout.splitGap(gap, length: horizontal ? area.w : area.h, count: node.childCount) : 0

    var previousEnd: Float = 0
    for i in 0..<node.childCount {
      if split && i > 0 {
        // a match found earlier in a deeper split (or at the same depth) keeps the point
        let innermost = best.map { $0.depth < depth } ?? true
        let strip = (from: previousEnd, to: previousEnd + Float(spacing))
        if innermost && contains(point, strip: strip, of: area, horizontal: horizontal) {
          let handle = SplitHandle(container: index, boundary: i - 1, orientation: node.layout)
          best = (handle, depth)
        }
      }

      let child = areas[next]
      previousEnd = horizontal ? child.x + child.w : child.y + child.h
      next = visit(
        nodes, areas, gap: gap, point: point, index: next, depth: depth + 1, best: &best)
    }

    return next
  }

  /// Whether the point lies in the strip of a gap: between the strip ends widened by the tolerance and clipped to the
  /// split's area along the axis, and across the area (its start included, its end excluded, like a pixel edge).
  private static func contains(
    _ point: CGPoint, strip: (from: Float, to: Float), of area: Area, horizontal: Bool
  ) -> Bool {
    let along = horizontal ? point.x : point.y
    let across = horizontal ? point.y : point.x
    let areaStart = CGFloat(horizontal ? area.x : area.y)
    let areaEnd = areaStart + CGFloat(horizontal ? area.w : area.h)
    let crossStart = CGFloat(horizontal ? area.y : area.x)
    let crossEnd = crossStart + CGFloat(horizontal ? area.h : area.w)

    let from = max(CGFloat(strip.from) - tolerance, areaStart)
    let to = min(CGFloat(strip.to) + tolerance, areaEnd)
    return along >= from && along <= to && across >= crossStart && across < crossEnd
  }
}
