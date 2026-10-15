import CoreGraphics
import YabaiCore

//
// NOTE: The conversion of `struct area` (the container and view areas) to Area (Sources/YabaiCore/Area.swift).
//

extension Area
{
    init(_ area: area)
    {
        self.init(x: area.x, y: area.y, w: area.w, h: area.h)
    }
}
