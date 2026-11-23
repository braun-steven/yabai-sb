import CoreGraphics
//
// NOTE: The scroll layout, after niri: the root of a scroll space is a row of columns, each a window or a container,
// as wide as its own share of the view whatever the number of columns, so the row runs past the edges of the display
// and scrolls to keep the focused column in view. The math here works in the coordinates of the strip: a column starts
// at its distance from the start of the strip, and the offset is the distance of the view's left edge from that start.
//
// macOS cannot clip another application's window at the edge of a display, and the window server keeps part of every
// window on screen: asked to move a window wholly off, it pulls it back until 40 points show, but it accepts a position
// that leaves 1 point on screen, also through the scripting addition. A window scrolled out of view is parked there,
// with a strip of it left on screen so that it can be seen and clicked (`scroll_peek`, `park`). The strip keeps room
// for those strips (`ScrollInsets`): with more than one column, the columns share the view less the room at one
// edge, so that columns whose shares sum to one leave room for the strip beyond them at the end of the strip, and the
// column that the strip scrolls to stays clear of the room on each side with columns beyond it. So no column covers
// the display from edge to edge: one at an end of the strip is at most the view less the room at one edge wide, one
// in between at most the view less the room at both. An edge with another display beyond it is a wall: a window
// cannot hang over it, or it would show on that display, so it stops flush at the edge instead, behind the columns in
// view.
//

/// How a scroll space scrolls to the column that gets focus (config scroll_center), as niri's center-focused-column.
public enum ScrollCenter: String, CaseIterable, Sendable {
  /// Scroll as little as shows the column whole.
  case never
  /// Center the column when it does not fit on the display together with the column focused before it.
  case overflow
  /// Always center the column.
  case always
}

/// The edges of a display with another display beyond them, where a window cannot hang over.
public struct ScrollWalls: OptionSet, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let left = ScrollWalls(rawValue: 1 << 0)
  public static let right = ScrollWalls(rawValue: 1 << 1)
}

/// The room that the strip of a view keeps at its left and right edges, in points, for the strips of the windows
/// scrolled out on that side.
public struct ScrollInsets: Equatable, Sendable {
  public var left: Float
  public var right: Float

  public init(left: Float, right: Float) {
    self.left = left
    self.right = right
  }

  public static let zero = ScrollInsets(left: 0, right: 0)
}

/// Where the windows scrolled out of view are parked on a display: a window to the left of the view ends no further
/// left than `left`, one to the right starts no further right than `right`.
public struct ScrollEdges: Equatable, Sendable {
  public var left: Float
  public var right: Float

  public init(left: Float, right: Float) {
    self.left = left
    self.right = right
  }
}

/// A column of the strip: its start, from the start of the strip, and its width, in points.
public struct ColumnSpan: Equatable, Sendable {
  public var start: Float
  public var width: Float

  public init(start: Float, width: Float) {
    self.start = start
    self.width = width
  }

  public var end: Float { start + width }
}

/// The geometry of the strip of a scroll space, computed without the window server.
public enum ScrollStrip {
  /// The narrowest share a column can be given.
  public static let minimumShare: Float = 0.1
  /// The widest share a column can be given: the whole view.
  public static let maximumShare: Float = 1
  /// The least of a window that the window server keeps on screen, where a parked window goes when a column in view
  /// leaves no room for more.
  public static let sliver: Float = 1

  /// A share kept between the narrowest and the widest a column can be.
  public static func clampedShare(_ share: Float) -> Float {
    min(max(share, minimumShare), maximumShare)
  }

  /// The room a view keeps at each edge of the strip for the strips of parked windows: the peek, and the gap to the
  /// column beside it, less the padding between the view and that edge of the display, which the strip of a parked
  /// window shows as well.
  public static func insets(peek: Float, gap: Int, view: Area, display: Area) -> ScrollInsets {
    let left = view.x - display.x
    let right = display.x + display.w - (view.x + view.w)
    return ScrollInsets(
      left: max(0, peek + Float(gap) - left), right: max(0, peek + Float(gap) - right))
  }

  /// The columns of shares in a view of the given length, with the gap between neighbours. The columns share the
  /// length less the room at one edge (the mean of the insets); a column's width is its share of that plus one gap,
  /// less one gap, so that columns whose shares sum to one fill it exactly. A column is at most the length less the
  /// insets on its sides with columns beyond. A lone column fills the whole view whatever its share.
  public static func spans(
    shares: [Float], length: Float, gap: Int, insets: ScrollInsets = .zero
  ) -> [ColumnSpan] {
    if shares.count == 1 { return [ColumnSpan(start: 0, width: length)] }

    let shared = length - (insets.left + insets.right) / 2
    let gap = Float(gap)
    var start: Float = 0
    return shares.enumerated().map { index, share in
      let left = index > 0 ? insets.left : 0
      let right = index < shares.count - 1 ? insets.right : 0
      let widest = length - left - right
      let width = max(1, min((clampedShare(share) * (shared + gap)).rounded() - gap, widest))
      defer { start += width + gap }
      return ColumnSpan(start: start, width: width)
    }
  }

  /// The length of the whole strip: from the start of its first column to the end of its last.
  public static func length(of spans: [ColumnSpan]) -> Float {
    spans.last?.end ?? 0
  }

  /// The offset that shows the column at index (the focused column) in a view of the given length, starting from the
  /// current offset. previous is the column focused before, when focus just moved; it decides whether `overflow`
  /// centers. A strip that fits the view is centered in it. The column stays clear of the insets on each side that has
  /// columns beyond it, where their parked windows show. Without `always`, the strip never scrolls past either end.
  public static func offset(
    revealing index: Int?, previous: Int? = nil, current: Float, spans: [ColumnSpan],
    length: Float, insets: ScrollInsets = .zero, center: ScrollCenter
  ) -> Float {
    let total = self.length(of: spans)
    if total <= length { return -((length - total) / 2).rounded() }

    guard let index, spans.indices.contains(index) else {
      return clamped(current, total: total, length: length)
    }

    let column = spans[index]
    let left = index > 0 ? insets.left : 0
    let right = index < spans.count - 1 ? insets.right : 0
    let room = length - left - right
    let centered = (column.start + column.width / 2 - length / 2).rounded()
    switch center {
    case .always:
      return centered
    case .overflow:
      if let previous, previous != index, spans.indices.contains(previous) {
        let other = spans[previous]
        let together = max(column.end, other.end) - min(column.start, other.start)
        if together > room { return clamped(centered, total: total, length: length) }
      }
      fallthrough
    case .never:
      let shown =
        column.width > room
        ? centered : min(max(current, column.end + right - length), column.start - left)
      return clamped(shown, total: total, length: length)
    }
  }

  /// An offset kept between the start of the strip and the offset that shows its end.
  private static func clamped(_ offset: Float, total: Float, length: Float) -> Float {
    min(max(offset, 0), max(total - length, 0))
  }

  //
  // NOTE: A parked window shows peek points at the edge, unless a column in view reaches closer to the edge than that:
  // it then starts right after that column (or ends right before it), so that it does not cover it, and shows less.
  // The columns are walked from the edge's far side, so that each one finds the columns in view before it.
  //

  /// Where the windows of the strip that are out of view are parked, for columns at the given frames (left to right)
  /// on a display of the given horizontal extent, with peek points of each left on screen.
  public static func edges(of columns: [Area], display: Area, peek: Float, gap: Int) -> ScrollEdges {
    let gap = Float(gap)
    let right = display.x + display.w

    func rightEdge(after limit: Float) -> Float { min(max(right - peek, limit), right - sliver) }
    var rightLimit = -Float.infinity
    for column in columns where column.x < rightEdge(after: rightLimit) {
      rightLimit = column.x + column.w + gap
    }

    func leftEdge(before limit: Float) -> Float {
      max(min(display.x + peek, limit), display.x + sliver)
    }
    var leftLimit = Float.infinity
    for column in columns.reversed() where column.x + column.w > leftEdge(before: leftLimit) {
      leftLimit = column.x - gap
    }

    return ScrollEdges(left: leftEdge(before: leftLimit), right: rightEdge(after: rightLimit))
  }

  /// Whether a column of the strip at frame is out of view: it shows no more than a parked window does, or it is
  /// parked at a wall.
  public static func isScrolledOut(
    _ frame: Area, display: Area, walls: ScrollWalls, edges: ScrollEdges
  ) -> Bool {
    frame.x >= edges.right || frame.x + frame.w <= edges.left
      || park(frame, display: display, walls: walls, edges: edges).x != frame.x
  }

  /// Where a window of the strip goes on a display of the given horizontal extent: where the strip puts it, unless
  /// that is past the edges where windows out of view are parked; then it hangs off the edge of the display at them.
  /// At a wall it stays wholly on the display instead.
  public static func park(_ frame: Area, display: Area, walls: ScrollWalls, edges: ScrollEdges)
    -> Area
  {
    let right = display.x + display.w
    var x = frame.x
    x = min(x, walls.contains(.right) ? right - frame.w : edges.right)
    x = max(x, walls.contains(.left) ? display.x : edges.left - frame.w)

    var parked = frame
    parked.x = x
    return parked
  }

  /// The walls of a display among the frames of all displays: the edges with another display beyond them, at the
  /// same height, where a window hanging over the edge would show.
  public static func walls(of display: Area, among displays: [Area]) -> ScrollWalls {
    var walls: ScrollWalls = []
    for other in displays where other != display {
      let overlapsVertically = other.y < display.y + display.h && other.y + other.h > display.y
      if !overlapsVertically { continue }
      if other.x + other.w <= display.x + 1 { walls.insert(.left) }
      if other.x >= display.x + display.w - 1 { walls.insert(.right) }
    }
    return walls
  }

  /// Whether a window of the strip at frame is wholly on a display of the given horizontal extent.
  public static func isInView(_ frame: Area, display: Area) -> Bool {
    frame.x >= display.x - 1 && frame.x + frame.w <= display.x + display.w + 1
  }
}

/// The motion of a scroll animation: how far along its way a window is after part of the animation's duration.
public enum ScrollEasing {
  /// The share of the way covered after elapsed of duration, eased out (cubic): fast at first, settling at the end.
  /// Past the duration, and without one, it is the whole way.
  public static func progress(elapsed: Double, duration: Double) -> Double {
    guard duration > 0 else { return 1 }
    let t = min(max(elapsed / duration, 0), 1)
    let remaining = 1 - t
    return 1 - remaining * remaining * remaining
  }

  /// Whether a window that the window server has at bounds slides to target: it moves by a point or more without
  /// changing its size. A window without bounds, or one that is resized, is placed at once.
  public static func slides(from bounds: CGRect?, to target: CGRect) -> Bool {
    guard let bounds else { return false }
    if abs(bounds.width - target.width) >= 1 || abs(bounds.height - target.height) >= 1 {
      return false
    }
    return abs(bounds.minX - target.minX) >= 1 || abs(bounds.minY - target.minY) >= 1
  }

  /// The point at progress on the way from start to end, rounded to whole points.
  public static func position(from start: Float, to end: Float, progress: Double) -> Float {
    (start + (end - start) * Float(progress)).rounded()
  }
}
