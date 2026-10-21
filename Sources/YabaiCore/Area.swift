import CoreGraphics

/// The directions of the selectors, in degrees (north is 360).
public enum Direction: Int, Sendable
{
    case north = 360
    case east  = 90
    case south = 180
    case west  = 270
}

/// A rectangle in float precision: the areas of containers and views.
public struct Area: Equatable, Sendable, Encodable
{
    public static let zero = Area(x: 0, y: 0, w: 0, h: 0)

    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    public init(x: Float, y: Float, w: Float, h: Float)
    {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// `area_from_cgrect`
    public init(_ rect: CGRect)
    {
        self.init(x: Float(rect.origin.x), y: Float(rect.origin.y), w: Float(rect.size.width), h: Float(rect.size.height))
    }

    //
    // NOTE: Geometry of areas in a direction, used to find the closest display. maxPoint is the last
    // pixel inside an area.
    //

    /// `area_max_point`
    public var maxPoint: CGPoint
    {
        CGPoint(x: CGFloat(x + w - 1), y: CGFloat(y + h - 1))
    }

    /// `area_is_in_direction`: whether r2 lies in the direction of r1.
    public static func isInDirection(_ r1: Area, _ r1Max: CGPoint, _ r2: Area, _ r2Max: CGPoint, _ direction: Direction) -> Bool
    {
        let r1x = CGFloat(r1.x), r1y = CGFloat(r1.y)
        let r2x = CGFloat(r2.x), r2y = CGFloat(r2.y)

        if direction == .north && r1Max.y <= r2y { return false }
        if direction == .east  && r2Max.x <= r1x { return false }
        if direction == .south && r2Max.y <= r1y { return false }
        if direction == .west  && r1Max.x <= r2x { return false }

        switch direction {
        case .north, .south:
            return ((r2Max.x >  r1x && r2Max.x <= r1Max.x) ||
                    (r2x     <  r1x && r2Max.x >  r1Max.x) ||
                    (r2x     >= r1x && r2x     <  r1Max.x))
        case .east, .west:
            return ((r2Max.y >  r1y && r2Max.y <= r1Max.y) ||
                    (r2y     <  r1y && r2Max.y >  r1Max.y) ||
                    (r2y     >= r1y && r2y     <  r1Max.y))
        }
    }

    /// `area_distance_in_direction`: the distance from r1 to r2 in a direction, truncated like the C conversion to int.
    public static func distanceInDirection(_ r1: Area, _ r1Max: CGPoint, _ r2: Area, _ r2Max: CGPoint, _ direction: Direction) -> Int
    {
        let r1x = CGFloat(r1.x), r1y = CGFloat(r1.y)
        let r2x = CGFloat(r2.x), r2y = CGFloat(r2.y)

        switch direction {
        case .north: return Int(r2Max.y > r1y ? r2Max.y - r1y : r1y - r2Max.y)
        case .east:  return Int(r2x < r1Max.x ? r1Max.x - r2x : r2x - r1Max.x)
        case .south: return Int(r2y < r1Max.y ? r1Max.y - r2y : r2y - r1Max.y)
        case .west:  return Int(r2Max.x > r1x ? r2Max.x - r1x : r1x - r2Max.x)
        }
    }

    /// The index of the area in candidates that is nearest in a direction, nil if none lies in it. Of areas at the same
    /// distance, the first one wins.
    public func closest(in direction: Direction, among candidates: [Area]) -> Int?
    {
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
}
