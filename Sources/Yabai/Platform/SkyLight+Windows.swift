import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: SkyLight wrappers for the windows the daemon creates itself: borders, tab bars, the insertion feedback and the
// proxies of animations. They take the connection like the SkyLight calls do (usually SLS.connection).
//

extension SLS
{
    /// How `order(_:_:_:relativeTo:)` places a window (the mode of `SLSOrderWindow`).
    enum Order: Int32
    {
        case below = -1
        case out = 0
        case above = 1
    }

    /// `CGSNewRegionWithRect`: a region with the rect, for the shape of a window.
    static func region(_ rect: CGRect) -> CFTypeRef?
    {
        var rect = rect
        var region: CFTypeRef?
        CGSNewRegionWithRect(&rect, &region)
        return region
    }

    /// `SLSNewWindow` of type 2 at the origin; nil if the window server created none.
    static func newWindow(_ cid: Int32, at origin: CGPoint, shape: CFTypeRef) -> WindowID?
    {
        var wid: UInt32 = 0
        SLSNewWindow(cid, 2, Float(origin.x), Float(origin.y), shape, &wid)
        return WindowID(nonzero: wid)
    }

    /// `SLSNewWindowWithOpaqueShapeAndContext` of type 2 with an empty opaque shape and 64 tag bits; nil if the empty
    /// region or the window could not be created.
    static func newWindow(_ cid: Int32, shape: CFTypeRef, options: Int32, tags: UInt64) -> WindowID?
    {
        guard let emptyRegion = CGRegionCreateEmptyRegion() else { return nil }
        var tags = tags
        var wid: UInt32 = 0
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, shape, emptyRegion, options, &tags, 0, 0, 64, &wid, nil)
        return WindowID(nonzero: wid)
    }

    /// `SLSReleaseWindow`
    static func releaseWindow(_ cid: Int32, _ wid: WindowID)
    {
        SLSReleaseWindow(cid, wid.rawValue)
    }

    /// `SLSSetWindowTags` with 64 tag bits.
    static func setTags(_ cid: Int32, _ wid: WindowID, _ tags: UInt64)
    {
        var tags = tags
        SLSSetWindowTags(cid, wid.rawValue, &tags, 64)
    }

    /// `SLSClearWindowTags` with 64 tag bits.
    static func clearTags(_ cid: Int32, _ wid: WindowID, _ tags: UInt64)
    {
        var tags = tags
        SLSClearWindowTags(cid, wid.rawValue, &tags, 64)
    }

    /// `SLSSetWindowResolution`
    static func setResolution(_ cid: Int32, _ wid: WindowID, _ resolution: Double)
    {
        SLSSetWindowResolution(cid, wid.rawValue, resolution)
    }

    /// `SLSSetWindowOpacity`
    static func setOpaque(_ cid: Int32, _ wid: WindowID, _ opaque: Bool)
    {
        SLSSetWindowOpacity(cid, wid.rawValue, opaque)
    }

    /// `SLSSetWindowAlpha`
    static func setAlpha(_ cid: Int32, _ wid: WindowID, _ alpha: Float)
    {
        SLSSetWindowAlpha(cid, wid.rawValue, alpha)
    }

    /// `SLSSetWindowLevel`
    static func setLevel(_ cid: Int32, _ wid: WindowID, _ level: Int32)
    {
        SLSSetWindowLevel(cid, wid.rawValue, level)
    }

    /// `SLSSetWindowSubLevel`
    static func setSubLevel(_ cid: Int32, _ wid: WindowID, _ subLevel: Int32)
    {
        SLSSetWindowSubLevel(cid, wid.rawValue, subLevel)
    }

    /// `SLSSetWindowShape`, with the shape moved by the offset.
    static func setShape(_ cid: Int32, _ wid: WindowID, _ shape: CFTypeRef, offset: CGPoint = .zero)
    {
        SLSSetWindowShape(cid, wid.rawValue, Float(offset.x), Float(offset.y), shape)
    }

    /// `SLSOrderWindow`: the window ordered above, below or out, relative to another window when one is given.
    static func order(_ cid: Int32, _ wid: WindowID, _ order: Order, relativeTo relative: WindowID? = nil)
    {
        SLSOrderWindow(cid, wid.rawValue, order.rawValue, relative?.rawValue ?? 0)
    }

    /// `SLSMoveWindow`
    static func moveWindow(_ cid: Int32, _ wid: WindowID, to origin: CGPoint)
    {
        var origin = origin
        SLSMoveWindow(cid, wid.rawValue, &origin)
    }

    /// `SLSMoveWindowsToManagedSpace`; nil moves the windows to space 0, as the callers did before.
    static func moveWindows(_ cid: Int32, _ windows: [WindowID], toSpace sid: SpaceID?)
    {
        SLSMoveWindowsToManagedSpace(cid, cfArray(windows: windows), sid?.rawValue ?? 0)
    }

    /// `SLWindowContextCreate`
    static func context(_ cid: Int32, _ wid: WindowID) -> CGContext?
    {
        SLWindowContextCreate(cid, wid.rawValue, nil)
    }

    /// `SLSDisableUpdate`
    static func disableUpdate(_ cid: Int32)
    {
        SLSDisableUpdate(cid)
    }

    /// `SLSReenableUpdate`
    static func reenableUpdate(_ cid: Int32)
    {
        SLSReenableUpdate(cid)
    }

    /// The corner radius that the window server reports for the window (the first of
    /// `SLSWindowIteratorGetCornerRadii`); nil when it reports none.
    static func cornerRadius(_ cid: Int32, _ wid: WindowID) -> Int32?
    {
        guard let query = SLSWindowQueryWindows(cid, cfArray(windows: [wid]), 1),
              let iterator = SLSWindowQueryResultCopyWindows(query), SLSWindowIteratorAdvance(iterator),
              let radii = SLSWindowIteratorGetCornerRadii(iterator), CFArrayGetCount(radii) > 0 else { return nil }
        var radius: Int32 = 0
        let number = unsafeBitCast(CFArrayGetValueAtIndex(radii, 0), to: CFNumber.self)
        CFNumberGetValue(number, .intType, &radius)
        return radius
    }
}
