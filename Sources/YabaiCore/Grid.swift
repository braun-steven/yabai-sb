import CoreGraphics

/// A grid placement "rows:columns:x:y:width:height" (`unsigned grid[6]`). All 0 is no placement. The `%d` parser
/// accepts negative values and preserves their 32-bit bit pattern (so `-1` becomes `UInt32.max`), matching the grid
/// math's existing unsigned wrap behavior.
public struct Grid: Equatable, Sendable {
  public var rows: UInt32 = 0
  public var columns: UInt32 = 0
  public var x: UInt32 = 0
  public var y: UInt32 = 0
  public var width: UInt32 = 0
  public var height: UInt32 = 0

  public init() {}

  public init(
    _ rows: UInt32, _ columns: UInt32, _ x: UInt32, _ y: UInt32, _ width: UInt32, _ height: UInt32
  ) {
    (self.rows, self.columns, self.x, self.y, self.width, self.height) = (
      rows, columns, x, y, width, height
    )
  }

  //
  // NOTE: Negative input is accepted and its 32-bit bit pattern is used by the grid math, so the fields stay UInt32.
  // The parse is all or nothing: the grid changes only when all six values match.
  //

  /// Parses six colon-separated `%d` values, preserving negative inputs as their UInt32 bit patterns. Returns false,
  /// and leaves the grid as it was, unless all six match.
  public mutating func parse(_ value: Token) -> Bool {
    let scan = value.scanIntegers(count: 6)
    guard scan.assigned == 6 else { return false }

    let values = scan.values.map { UInt32(bitPattern: $0) }
    (rows, columns, x, y, width, height) = (
      values[0], values[1], values[2], values[3], values[4], values[5]
    )
    return true
  }
}

extension Grid {
  //
  // NOTE: The cell is clamped into the grid: x and y to the last column and row, width and height to at least one
  // cell and at most the rest of the grid. The clamping wraps like the unsigned C math, so a grid of 0 rows or
  // columns gives a frame that is not finite instead of trapping. The gap lies between every two neighboring cells,
  // not at the edges of bounds, and all cells are the same size.
  //

  /// The frame of the cell in bounds, inside padding (top, bottom, left, right) and the gap; nil leaves either out.
  public func frame(
    in bounds: CGRect, padding: (top: Int, bottom: Int, left: Int, right: Int)?, gap: Int?
  ) -> Area {
    var x = self.x
    var y = self.y
    var width = self.width
    var height = self.height
    if x >= columns { x = columns &- 1 }
    if y >= rows { y = rows &- 1 }
    if width <= 0 { width = 1 }
    if height <= 0 { height = 1 }
    if width > columns &- x { width = columns &- x }
    if height > rows &- y { height = rows &- y }

    var bounds = bounds

    if let padding {
      bounds.origin.x += CGFloat(padding.left)
      bounds.size.width -= CGFloat(padding.left + padding.right)
      bounds.origin.y += CGFloat(padding.top)
      bounds.size.height -= CGFloat(padding.top + padding.bottom)
    }

    let gap = CGFloat(gap ?? 0)
    let cellWidth = (bounds.size.width - gap * (CGFloat(columns) - 1)) / CGFloat(columns)
    let cellHeight = (bounds.size.height - gap * (CGFloat(rows) - 1)) / CGFloat(rows)
    return Area(
      x: Float(bounds.origin.x + CGFloat(x) * (cellWidth + gap)),
      y: Float(bounds.origin.y + CGFloat(y) * (cellHeight + gap)),
      w: Float(CGFloat(width) * cellWidth + CGFloat(width - 1) * gap),
      h: Float(CGFloat(height) * cellHeight + CGFloat(height - 1) * gap))
  }
}
