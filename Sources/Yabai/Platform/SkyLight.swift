import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Swift wrappers of the SkyLight functions in CPrivate.h, taking and returning Swift types. They take the
// connection like the SkyLight calls do (usually SLS.connection). A failed call gives nil, an empty list or the zero
// value, as each wrapper documents.
//

enum SLS
{
    /// A window as `SLSWindowQueryWindows` / `SLSWindowQueryResultCopyWindows` and the `SLSWindowIteratorGet*`
    /// functions report it.
    struct QueriedWindow
    {
        let id: WindowID
        let parent: WindowID?
        let tags: UInt64
        let attributes: UInt64
        let level: Int32
    }

    /// The options of `_SLPSSetFrontProcessWithOptions`: activate a process for a user action, or without raising any of
    /// its windows.
    enum FrontProcessMode: UInt32
    {
        case userGenerated = 0x200
        case noWindows     = 0x400
    }

    /// The main connection of the daemon to the window server.
    static let connection: Int32 = SLSMainConnectionID()

    //
    // NOTE: SkyLight expects window ids as kCFNumberSInt32Type and space ids as kCFNumberSInt64Type numbers, which
    // NSNumber(value: Int32) and NSNumber(value: Int64) create.
    //

    static func cfArray(windows: [WindowID]) -> CFArray
    {
        return windows.map { NSNumber(value: Int32(bitPattern: $0.rawValue)) } as CFArray
    }

    static func cfArray(spaces: [SpaceID]) -> CFArray
    {
        return spaces.map { NSNumber(value: Int64(bitPattern: $0.rawValue)) } as CFArray
    }

    static func ids<T: FixedWidthInteger>(_ array: CFArray?, as type: T.Type) -> [T]
    {
        guard let numbers = array as? [NSNumber] else { return [] }
        return numbers.map { T(truncatingIfNeeded: $0.int64Value) }
    }

    /// `SLSGetWindowBounds`
    static func windowBounds(_ cid: Int32, _ wid: WindowID) -> CGRect?
    {
        var frame = CGRect.zero
        guard SLSGetWindowBounds(cid, wid.rawValue, &frame) == .success else { return nil }
        return frame
    }

    /// `SLSGetWindowAlpha`; nil if the call fails.
    static func windowAlpha(_ cid: Int32, _ wid: WindowID) -> Float?
    {
        var alpha: Float = 0
        guard SLSGetWindowAlpha(cid, wid.rawValue, &alpha) == .success else { return nil }
        return alpha
    }

    /// `SLSGetWindowSubLevel`
    static func windowSubLevel(_ cid: Int32, _ wid: WindowID) -> Int32
    {
        return SLSGetWindowSubLevel(cid, wid.rawValue)
    }

    /// `SLSCopyWindowProperty` with `kCGSWindowTitle`: the title that the window server knows.
    static func windowTitle(_ cid: Int32, _ wid: WindowID) -> String?
    {
        var value: Unmanaged<CFTypeRef>?
        SLSCopyWindowProperty(cid, wid.rawValue, "kCGSWindowTitle" as CFString, &value)
        return value?.takeRetainedValue() as? String
    }

    /// `SLSWindowIsOrderedIn`
    static func windowIsOrderedIn(_ cid: Int32, _ wid: WindowID) -> Bool
    {
        var orderedIn: UInt8 = 0
        SLSWindowIsOrderedIn(cid, wid.rawValue, &orderedIn)
        return orderedIn != 0
    }

    /// `SLSGetWindowOwner`: the connection of the process that owns the window.
    static func windowOwner(_ cid: Int32, _ wid: WindowID) -> Int32?
    {
        var owner: Int32 = 0
        guard SLSGetWindowOwner(cid, wid.rawValue, &owner) == .success else { return nil }
        return owner
    }

    /// `SLSConnectionGetPID`
    static func connectionPID(_ cid: Int32) -> pid_t?
    {
        var pid: pid_t = 0
        guard SLSConnectionGetPID(cid, &pid) == .success else { return nil }
        return pid
    }

    /// `SLSCopySpacesForWindows`; `WindowID.space` and its callers pass the selector 0x7.
    static func spaces(_ cid: Int32, forWindows windows: [WindowID], selector: Int32 = 0x7) -> [SpaceID]
    {
        return ids(SLSCopySpacesForWindows(cid, selector, cfArray(windows: windows)), as: UInt64.self).map { SpaceID($0) }
    }

    /// `SLSCopyWindowsWithOptionsAndTags` without tag filters, as `SpaceID.windows(on:connection:includingMinimized:)`
    /// calls it. nil when the call fails, which the caller must tell apart from an empty list.
    static func windows(_ cid: Int32, owner: UInt32, spaces: [SpaceID], options: UInt32) -> [WindowID]?
    {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windows = SLSCopyWindowsWithOptionsAndTags(cid, owner, cfArray(spaces: spaces), options, &setTags, &clearTags) else { return nil }
        return ids(windows, as: UInt32.self).map { WindowID($0) }
    }

    /// `SLSWindowQueryWindows`, `SLSWindowQueryResultCopyWindows` and the `SLSWindowIterator*` functions: the windows of
    /// the list that the window server knows, in its order.
    static func queryWindows(_ cid: Int32, _ windows: [WindowID]) -> [QueriedWindow]
    {
        guard let query = SLSWindowQueryWindows(cid, cfArray(windows: windows), Int32(windows.count)) else { return [] }
        guard let iterator = SLSWindowQueryResultCopyWindows(query) else { return [] }

        var result: [QueriedWindow] = []
        result.reserveCapacity(Int(SLSWindowIteratorGetCount(iterator)))

        while SLSWindowIteratorAdvance(iterator) {
            result.append(QueriedWindow(id: WindowID(SLSWindowIteratorGetWindowID(iterator)),
                                        parent: WindowID(nonzero: SLSWindowIteratorGetParentID(iterator)),
                                        tags: SLSWindowIteratorGetTags(iterator),
                                        attributes: SLSWindowIteratorGetAttributes(iterator),
                                        level: SLSWindowIteratorGetLevel(iterator)))
        }

        return result
    }

    /// `SLSCopyManagedDisplayForWindow`
    static func managedDisplay(_ cid: Int32, forWindow wid: WindowID) -> String?
    {
        return SLSCopyManagedDisplayForWindow(cid, wid.rawValue) as String?
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
    static func managedDisplay(_ cid: Int32, forSpace sid: SpaceID) -> String?
    {
        return SLSCopyManagedDisplayForSpace(cid, sid.rawValue) as String?
    }

    /// `SLSCopyActiveMenuBarDisplayIdentifier`
    static func activeMenuBarDisplay(_ cid: Int32) -> String?
    {
        return SLSCopyActiveMenuBarDisplayIdentifier(cid) as String?
    }

    /// `SLSManagedDisplayGetCurrentSpace`; nil when the window server reports no space (0).
    static func currentSpace(_ cid: Int32, forDisplay uuid: String) -> SpaceID?
    {
        return SpaceID(nonzero: SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
    }

    /// `SLSCopyManagedDisplaySpaces`: one dictionary per display, as `DisplayID.spaces` reads it.
    static func managedDisplaySpaces(_ cid: Int32) -> [NSDictionary]
    {
        return SLSCopyManagedDisplaySpaces(cid) as? [NSDictionary] ?? []
    }

    /// `SLSSpaceGetType`
    static func spaceType(_ cid: Int32, _ sid: SpaceID) -> Int32
    {
        return SLSSpaceGetType(cid, sid.rawValue)
    }

    /// `SLSSpaceCopyName`
    static func spaceName(_ cid: Int32, _ sid: SpaceID) -> String?
    {
        return SLSSpaceCopyName(cid, sid.rawValue) as String?
    }

    /// `SLSSpaceCopyName`, for the views, which keep the name as a CFString (`view->uuid`).
    static func spaceNameObject(_ cid: Int32, _ sid: SpaceID) -> CFString?
    {
        return SLSSpaceCopyName(cid, sid.rawValue)
    }

    /// `SLSCopyManagedDisplays`: the uuids of the displays in the order of the window server; nil when the call fails.
    static func managedDisplays(_ cid: Int32) -> CFArray?
    {
        return SLSCopyManagedDisplays(cid)
    }

    /// `SLSSetActiveMenuBarDisplayIdentifier`, with the display as both the identifier and the repeat identifier.
    static func setActiveMenuBarDisplay(_ cid: Int32, _ uuid: String)
    {
        SLSSetActiveMenuBarDisplayIdentifier(cid, uuid as CFString, uuid as CFString)
    }

    /// `SLSGetMenuBarAutohideEnabled`; false if the call fails, like `DisplayManager.isMenuBarHidden`.
    static func menuBarAutohideEnabled(_ cid: Int32) -> Bool
    {
        var status: Int32 = 0
        SLSGetMenuBarAutohideEnabled(cid, &status)
        return status != 0
    }

    /// `SLSGetDisplayMenubarHeight`; 0 if the call fails.
    static func displayMenuBarHeight(_ did: DisplayID) -> UInt32
    {
        var height: UInt32 = 0
        SLSGetDisplayMenubarHeight(did.rawValue, &height)
        return height
    }

    /// `SLSGetDockRectWithReason`; the zero rect if the call fails, like `DisplayManager.dockRect`.
    static func dockRect(_ cid: Int32) -> CGRect
    {
        var bounds = CGRect.zero
        var reason: Int32 = 0
        SLSGetDockRectWithReason(cid, &bounds, &reason)
        return bounds
    }

    /// `SLSGetCurrentCursorLocation`; the zero point if the call fails.
    static func cursorLocation(_ cid: Int32) -> CGPoint
    {
        var point = CGPoint.zero
        SLSGetCurrentCursorLocation(cid, &point)
        return point
    }

    /// `SLSGetConnectionPSN`: the process serial number of the process that owns a connection.
    static func connectionPSN(_ cid: Int32) -> ProcessSerialNumber
    {
        var psn = ProcessSerialNumber()
        SLSGetConnectionPSN(cid, &psn)
        return psn
    }

    /// `_SLPSGetFrontProcess`: the process serial number of the frontmost process.
    static func frontProcess() -> ProcessSerialNumber
    {
        var psn = ProcessSerialNumber()
        _SLPSGetFrontProcess(&psn)
        return psn
    }

    /// `_SLPSSetFrontProcessWithOptions`: makes the process frontmost, with the window (nil: none) as its key window.
    static func setFrontProcess(_ psn: ProcessSerialNumber, window: WindowID?, mode: FrontProcessMode)
    {
        var psn = psn
        _SLPSSetFrontProcessWithOptions(&psn, window?.rawValue ?? 0, mode.rawValue)
    }

    /// `SLPSPostEventRecordTo`: posts a synthesized event record to the process.
    static func postEventRecord(_ bytes: UnsafeMutablePointer<UInt8>, to psn: ProcessSerialNumber)
    {
        var psn = psn
        SLPSPostEventRecordTo(&psn, bytes)
    }

    /// `SLSSpaceSetFrontPSN`: the process that is frontmost once the space becomes active.
    static func setFrontProcess(_ cid: Int32, _ psn: ProcessSerialNumber, forSpace sid: SpaceID)
    {
        SLSSpaceSetFrontPSN(cid, sid.rawValue, psn)
    }

    /// `SLSGetConnectionIDForPSN`; nil if the call fails.
    static func connectionID(_ cid: Int32, forProcess psn: ProcessSerialNumber) -> Int32?
    {
        var psn = psn
        var connection: Int32 = 0
        guard SLSGetConnectionIDForPSN(cid, &psn, &connection) == .success else { return nil }
        return connection
    }

    /// `SLSSetMenuBarInsetAndAlpha` with the insets the window server uses (0, 1).
    static func setMenuBarAlpha(_ cid: Int32, _ alpha: Float)
    {
        SLSSetMenuBarInsetAndAlpha(cid, 0, 1, alpha)
    }

    /// `SLSGetSpaceManagementMode`: 1 when displays have separate spaces.
    static func spaceManagementMode(_ cid: Int32) -> Int32
    {
        return SLSGetSpaceManagementMode(cid)
    }

    /// `SLSRegisterConnectionNotifyProc` without a context.
    static func registerNotification(_ cid: Int32, _ event: UInt32,
                                     handler: @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void)
    {
        SLSRegisterConnectionNotifyProc(cid, handler, event, nil)
    }

    //
    // NOTE: Without the bridged operation and the scripting addition, windows move to a space through the compat id
    // 'yabe' (0x79616265), which the space wears while SLSSetWindowListWorkspace moves the windows to it.
    //
    static func moveWindows(_ cid: Int32, _ windows: [WindowID], toSpaceByCompatID sid: SpaceID)
    {
        let compatID: Int32 = 0x79616265
        SLSSpaceSetCompatID(cid, sid.rawValue, compatID)
        var rawWindows = windows.map(\.rawValue)
        SLSSetWindowListWorkspace(cid, &rawWindows, Int32(rawWindows.count), compatID)
        SLSSpaceSetCompatID(cid, sid.rawValue, 0)
    }

    /// `SLSCopyAssociatedWindows`: the windows associated with the window (sheets, drawers, children); nil if the call
    /// fails.
    static func associatedWindows(_ cid: Int32, _ wid: WindowID) -> [WindowID]?
    {
        guard let windows = SLSCopyAssociatedWindows(cid, wid.rawValue) else { return nil }
        return ids(windows, as: UInt32.self).map { WindowID($0) }
    }

    /// `SLSRequestNotificationsForWindows`
    static func requestNotifications(_ cid: Int32, forWindows windows: [WindowID])
    {
        var rawWindows = windows.map(\.rawValue)
        SLSRequestNotificationsForWindows(cid, &rawWindows, Int32(rawWindows.count))
    }

    /// `SLSGetWindowSubLevelBounded` (CPrivate.c): the sub-level with a bounded wait; nil if it failed.
    static func windowSubLevelBounded(_ cid: Int32, _ wid: WindowID) -> Int32?
    {
        var subLevel: Int32 = 0
        return SLSGetWindowSubLevelBounded(cid, wid.rawValue, &subLevel) ? subLevel : nil
    }

    /// Turns the shadow of the window off by setting its shadow density to zero.
    static func disableShadow(_ wid: WindowID)
    {
        let options = ["com.apple.WindowShadowDensity" as CFString: NSNumber(value: Int32(0))] as CFDictionary
        SLSWindowSetShadowProperties(wid.rawValue, options)
    }

    /// `SLSFindWindowAndOwner`: the window at the point and the connection that owns it, from the top (start nil,
    /// order 1) or below `start` (order -1).
    static func findWindow(_ cid: Int32, at point: CGPoint, startingAt start: WindowID?, order: Int32) -> (window: WindowID?, owner: Int32)
    {
        var point = point
        var windowPoint = CGPoint.zero
        var wid: UInt32 = 0
        var owner: Int32 = 0
        SLSFindWindowAndOwner(cid, Int32(bitPattern: start?.rawValue ?? 0), order, 0, &point, &windowPoint, &wid, &owner)
        return (WindowID(nonzero: wid), owner)
    }

    //
    // NOTE: The bridged operation moves windows asynchronously, and the window server has it on macOS 27. Daemon.run
    // resolves its function pointer; Swift reads it through the accessors of CPrivate.h.
    //

    /// Whether `SLSPerformAsynchronousBridgedWindowManagementOperation` is resolved.
    static var hasBridgedWindowOperation: Bool
    {
        return SLSHasBridgedWindowOperation()
    }

    /// `[[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:spaceID:]`, run through
    /// `SLSPerformAsynchronousBridgedWindowManagementOperation` and released after the window server took it.
    /// The Objective-C messages go through objc_msgSend, cast to the signature of each call.
    static func bridgedMoveWindows(_ windows: [WindowID], toSpace sid: SpaceID)
    {
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return }

        typealias Alloc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        typealias InitWithWindows = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt64) -> UnsafeMutableRawPointer?
        let alloc = unsafeBitCast(send, to: Alloc.self)
        let initWithWindows = unsafeBitCast(send, to: InitWithWindows.self)

        let classObject = Unmanaged.passUnretained(cls as AnyObject).toOpaque()
        let windowList = windows.map { NSNumber(value: Int32(bitPattern: $0.rawValue)) } as NSArray

        let selectorAlloc = unsafeBitCast(sel_registerName("alloc"), to: UnsafeMutableRawPointer.self)
        let selectorInit = unsafeBitCast(sel_registerName("initWithWindows:spaceID:"), to: UnsafeMutableRawPointer.self)

        guard let allocated = alloc(classObject, selectorAlloc),
              let operation = initWithWindows(allocated, selectorInit,
                                              Unmanaged.passUnretained(windowList).toOpaque(), sid.rawValue) else { return }

        withExtendedLifetime(windowList) {
            _ = SLSPerformBridgedWindowOperation(operation)
        }

        Unmanaged<AnyObject>.fromOpaque(operation).release()
    }
}
