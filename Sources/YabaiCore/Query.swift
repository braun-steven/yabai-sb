import CoreGraphics

//
// NOTE: The values that `query --displays`, `--spaces`, `--windows` and `--tree` report.
//

/// The split a window's container makes with its sibling, by its parent's layout; also the axis of `space --mirror`.
public enum WindowSplit: Sendable {
  case none
  case y
  case x

  /// The name in `query --windows`.
  public var name: String {
    switch self {
    case .none: "none"
    case .y: "vertical"
    case .x: "horizontal"
    }
  }
}

/// A frame of a display or window in query json.
public struct QueryFrame: Encodable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(_ rect: CGRect) {
    x = rect.origin.x
    y = rect.origin.y
    w = rect.size.width
    h = rect.size.height
  }
}
