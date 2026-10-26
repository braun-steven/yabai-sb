import CoreGraphics

/// The directions of the selectors, in degrees (north is 360).
public enum Direction: Int, Sendable {
  case north = 360
  case east = 90
  case south = 180
  case west = 270
}

/// A rectangle in float precision: the areas of containers and views.
public struct Area: Equatable, Sendable, Encodable {
  public static let zero = Area(x: 0, y: 0, w: 0, h: 0)

  public var x: Float
  public var y: Float
  public var w: Float
  public var h: Float

  public init(x: Float, y: Float, w: Float, h: Float) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }

  /// The area of a CGRect, converted to float precision.
  public init(_ rect: CGRect) {
    self.init(
      x: Float(rect.origin.x), y: Float(rect.origin.y), w: Float(rect.size.width),
      h: Float(rect.size.height))
  }

  //
  // NOTE: Geometry of areas in a direction, used to find the closest display. maxPoint is the last
  // pixel inside an area.
  //

  /// The last pixel inside the area.
  public var maxPoint: CGPoint {
    CGPoint(x: CGFloat(x + w - 1), y: CGFloat(y + h - 1))
  }

  /// Whether r2 lies in the direction of r1.
  public static func isInDirection(
    _ r1: Area, _ r1Max: CGPoint, _ r2: Area, _ r2Max: CGPoint, _ direction: Direction
  ) -> Bool {
    let r1x = CGFloat(r1.x)
    let r1y = CGFloat(r1.y)
    let r2x = CGFloat(r2.x)
    let r2y = CGFloat(r2.y)

    if direction == .north && r1Max.y <= r2y { return false }
    if direction == .east && r2Max.x <= r1x { return false }
    if direction == .south && r2Max.y <= r1y { return false }
    if direction == .west && r1Max.x <= r2x { return false }

    switch direction {
    case .north, .south:
      return
        ((r2Max.x > r1x && r2Max.x <= r1Max.x) || (r2x < r1x && r2Max.x > r1Max.x)
        || (r2x >= r1x && r2x < r1Max.x))
    case .east, .west:
      return
        ((r2Max.y > r1y && r2Max.y <= r1Max.y) || (r2y < r1y && r2Max.y > r1Max.y)
        || (r2y >= r1y && r2y < r1Max.y))
    }
  }

  /// The distance from r1 to r2 in a direction, truncated toward zero as `Int(_:)` does.
  public static func distanceInDirection(
    _ r1: Area, _ r1Max: CGPoint, _ r2: Area, _ r2Max: CGPoint, _ direction: Direction
  ) -> Int {
    let r1x = CGFloat(r1.x)
    let r1y = CGFloat(r1.y)
    let r2x = CGFloat(r2.x)
    let r2y = CGFloat(r2.y)

    switch direction {
    case .north: return Int(r2Max.y > r1y ? r2Max.y - r1y : r1y - r2Max.y)
    case .east: return Int(r2x < r1Max.x ? r1Max.x - r2x : r2x - r1Max.x)
    case .south: return Int(r2y < r1Max.y ? r1Max.y - r2y : r2y - r1Max.y)
    case .west: return Int(r2Max.x > r1x ? r2Max.x - r1x : r1x - r2Max.x)
    }
  }

  /// The index of the area in candidates that is nearest in a direction, nil if none lies in it. Of areas at the same
  /// distance, the first one wins.
  public func closest(in direction: Direction, among candidates: [Area]) -> Int? {
    var best: Int? = nil
    var bestDistance = Int.max
    let max = maxPoint

    for (index, candidate) in candidates.enumerated() {
      let candidateMax = candidate.maxPoint
      guard Area.isInDirection(self, max, candidate, candidateMax, direction) else { continue }

      let distance = Area.distanceInDirection(self, max, candidate, candidateMax, direction)
      if distance < bestDistance {
        best = index
        bestDistance = distance
      }
    }

    return best
  }

  /// The index of the area in candidates whose center is nearest in a direction, measured along the direction only, as
  /// sway picks a floating window (`node_get_in_direction_floating`): an area counts when its center lies past the
  /// center of this one, however far it is off to the side. When none does and `wrapping` is set, the area whose center
  /// lies farthest the other way. Of areas at the same distance, the first one wins; nil without candidates.
  public func closestCenter(in direction: Direction, among candidates: [Area], wrapping: Bool)
    -> Int?
  {
    var closest: Int? = nil
    var closestDistance = Float.greatestFiniteMagnitude
    var furthest: Int? = nil
    var furthestDistance: Float = 1

    for (index, candidate) in candidates.enumerated() {
      var distance: Float =
        switch direction {
        case .east, .west: (candidate.x + candidate.w / 2) - (x + w / 2)
        case .north, .south: (candidate.y + candidate.h / 2) - (y + h / 2)
        }
      if direction == .west || direction == .north { distance = -distance }

      if distance <= 0 {
        if distance < furthestDistance {
          furthest = index
          furthestDistance = distance
        }
      } else if distance < closestDistance {
        closest = index
        closestDistance = distance
      }
    }

    return closest ?? (wrapping ? furthest : nil)
  }
}
