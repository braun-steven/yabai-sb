import CoreGraphics
import Foundation
import CPrivate

//
// NOTE: Swift wrappers of the SkyLight functions in CPrivate.h, for the code that the port moves to Swift. They take the
// connection like the C calls do (g_connection of yabai.c is SLSMainConnectionID()). A failed call gives what the C
// helper it replaces gives: nil, an empty list or the zero value.
//

enum SLS
{
    /// A window as `SLSWindowQueryWindows` / `SLSWindowQueryResultCopyWindows` and the `SLSWindowIteratorGet*`
    /// functions report it.
    struct QueriedWindow
    {
        let id: UInt32
        let parent: UInt32
        let tags: UInt64
        let attributes: UInt64
        let level: Int32
    }

    /// `SLSMainConnectionID`, the connection yabai.c stores in `g_connection`.
    static var mainConnection: Int32
    {
        SLSMainConnectionID()
    }

    //
    // NOTE: The C code builds these lists with cfarray_of_cfnumbers: window ids as kCFNumberSInt32Type and space ids as
    // kCFNumberSInt64Type. NSNumber(value: Int32) and NSNumber(value: Int64) create the same CFNumber types.
    //

    private static func cfArray(windows: [UInt32]) -> CFArray
    {
        return windows.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
    }

    private static func cfArray(spaces: [UInt64]) -> CFArray
    {
        return spaces.map { NSNumber(value: Int64(bitPattern: $0)) } as CFArray
    }

    private static func ids<T: FixedWidthInteger>(_ array: CFArray?, as type: T.Type) -> [T]
    {
        guard let numbers = array as? [NSNumber] else { return [] }
        return numbers.map { T(truncatingIfNeeded: $0.int64Value) }
    }

    /// `SLSGetWindowBounds`
    static func windowBounds(_ cid: Int32, _ wid: UInt32) -> CGRect?
    {
        var frame = CGRect.zero
        guard SLSGetWindowBounds(cid, wid, &frame) == .success else { return nil }
        return frame
    }

    /// `SLSGetWindowAlpha`; 0 if the call fails, like `window_opacity`.
    static func windowAlpha(_ cid: Int32, _ wid: UInt32) -> Float
    {
        var alpha: Float = 0
        SLSGetWindowAlpha(cid, wid, &alpha)
        return alpha
    }

    /// `SLSGetWindowSubLevel`
    static func windowSubLevel(_ cid: Int32, _ wid: UInt32) -> Int32
    {
        return SLSGetWindowSubLevel(cid, wid)
    }

    /// `SLSCopyWindowProperty` with `kCGSWindowTitle`, as `window_property_title_ts` reads it.
    static func windowTitle(_ cid: Int32, _ wid: UInt32) -> String?
    {
        var value: Unmanaged<CFTypeRef>?
        SLSCopyWindowProperty(cid, wid, "kCGSWindowTitle" as CFString, &value)
        return value?.takeRetainedValue() as? String
    }

    /// `SLSWindowIsOrderedIn`
    static func windowIsOrderedIn(_ cid: Int32, _ wid: UInt32) -> Bool
    {
        var orderedIn: UInt8 = 0
        SLSWindowIsOrderedIn(cid, wid, &orderedIn)
        return orderedIn != 0
    }

    /// `SLSGetWindowOwner`: the connection of the process that owns the window.
    static func windowOwner(_ cid: Int32, _ wid: UInt32) -> Int32?
    {
        var owner: Int32 = 0
        guard SLSGetWindowOwner(cid, wid, &owner) == .success else { return nil }
        return owner
    }

    /// `SLSConnectionGetPID`
    static func connectionPID(_ cid: Int32) -> pid_t?
    {
        var pid: pid_t = 0
        guard SLSConnectionGetPID(cid, &pid) == .success else { return nil }
        return pid
    }

    /// `SLSCopySpacesForWindows`; `window_space` and `window_space_list` pass the selector 0x7.
    static func spaces(_ cid: Int32, forWindows windows: [UInt32], selector: Int32 = 0x7) -> [UInt64]
    {
        return ids(SLSCopySpacesForWindows(cid, selector, cfArray(windows: windows)), as: UInt64.self)
    }

    /// `SLSCopyWindowsWithOptionsAndTags` without tag filters, as `space_window_list_for_connection` calls it.
    static func windows(_ cid: Int32, owner: UInt32, spaces: [UInt64], options: UInt32) -> [UInt32]
    {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        return ids(SLSCopyWindowsWithOptionsAndTags(cid, owner, cfArray(spaces: spaces), options, &setTags, &clearTags), as: UInt32.self)
    }

    /// `SLSWindowQueryWindows`, `SLSWindowQueryResultCopyWindows` and the `SLSWindowIterator*` functions: the windows of
    /// the list that the window server knows, in its order.
    static func queryWindows(_ cid: Int32, _ windows: [UInt32]) -> [QueriedWindow]
    {
        guard let query = SLSWindowQueryWindows(cid, cfArray(windows: windows), Int32(windows.count)) else { return [] }
        guard let iterator = SLSWindowQueryResultCopyWindows(query) else { return [] }

        var result: [QueriedWindow] = []
        result.reserveCapacity(Int(SLSWindowIteratorGetCount(iterator)))

        while SLSWindowIteratorAdvance(iterator) {
            result.append(QueriedWindow(id: SLSWindowIteratorGetWindowID(iterator),
                                        parent: SLSWindowIteratorGetParentID(iterator),
                                        tags: SLSWindowIteratorGetTags(iterator),
                                        attributes: SLSWindowIteratorGetAttributes(iterator),
                                        level: SLSWindowIteratorGetLevel(iterator)))
        }

        return result
    }

    /// `SLSCopyManagedDisplayForWindow`
    static func managedDisplay(_ cid: Int32, forWindow wid: UInt32) -> String?
    {
        return SLSCopyManagedDisplayForWindow(cid, wid) as String?
    }

    /// `SLSCopyBestManagedDisplayForRect`
    static func bestManagedDisplay(_ cid: Int32, forRect rect: CGRect) -> String?
    {
        return SLSCopyBestManagedDisplayForRect(cid, rect) as String?
    }

    /// `SLSCopyBestManagedDisplayForPoint`
    static func bestManagedDisplay(_ cid: Int32, forPoint point: CGPoint) -> String?
    {
        return SLSCopyBestManagedDisplayForPoint(cid, point) as String?
    }

    /// `SLSCopyManagedDisplayForSpace`
    static func managedDisplay(_ cid: Int32, forSpace sid: UInt64) -> String?
    {
        return SLSCopyManagedDisplayForSpace(cid, sid) as String?
    }

    /// `SLSCopyActiveMenuBarDisplayIdentifier`
    static func activeMenuBarDisplay(_ cid: Int32) -> String?
    {
        return SLSCopyActiveMenuBarDisplayIdentifier(cid) as String?
    }

    /// `SLSManagedDisplayGetCurrentSpace`
    static func currentSpace(_ cid: Int32, forDisplay uuid: String) -> UInt64
    {
        return SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString)
    }

    /// `SLSCopyManagedDisplaySpaces`: one dictionary per display, as `display_space_list` reads it.
    static func managedDisplaySpaces(_ cid: Int32) -> [NSDictionary]
    {
        return SLSCopyManagedDisplaySpaces(cid) as? [NSDictionary] ?? []
    }

    /// `SLSSpaceGetType`
    static func spaceType(_ cid: Int32, _ sid: UInt64) -> Int32
    {
        return SLSSpaceGetType(cid, sid)
    }

    /// `SLSSpaceCopyName`
    static func spaceName(_ cid: Int32, _ sid: UInt64) -> String?
    {
        return SLSSpaceCopyName(cid, sid) as String?
    }
}
