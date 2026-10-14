import CoreGraphics
import YabaiC
import YabaiCore

//
// NOTE: The C entry points of Area (Sources/YabaiCore/Area.swift) while display_manager.c is C. They go when
// their callers are Swift (P9).
//

extension Area
{
    init(_ area: area)
    {
        self.init(x: area.x, y: area.y, w: area.w, h: area.h)
    }
}

@_cdecl("area_max_point")
func area_max_point(_ area: area) -> CGPoint
{
    Area(area).maxPoint
}

@_cdecl("area_is_in_direction")
func area_is_in_direction(_ r1: UnsafeMutablePointer<area>, _ r1Max: CGPoint, _ r2: UnsafeMutablePointer<area>, _ r2Max: CGPoint, _ direction: Int32) -> Bool
{
    guard let direction = Direction(rawValue: direction) else { return false }
    return Area.isInDirection(Area(r1.pointee), r1Max, Area(r2.pointee), r2Max, direction)
}

@_cdecl("area_distance_in_direction")
func area_distance_in_direction(_ r1: UnsafeMutablePointer<area>, _ r1Max: CGPoint, _ r2: UnsafeMutablePointer<area>, _ r2Max: CGPoint, _ direction: Int32) -> Int32
{
    guard let direction = Direction(rawValue: direction) else { return Int32.max }
    return Int32(Area.distanceInDirection(Area(r1.pointee), r1Max, Area(r2.pointee), r2Max, direction))
}
