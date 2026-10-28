import CPrivate
import CoreGraphics
import Darwin
import Foundation
import YabaiCore

//
// NOTE: Swift wrappers of the SkyLight functions in CPrivate.h, taking and returning Swift types. They take the
// connection like the SkyLight calls do (usually SLS.connection). A failed call gives nil, an empty list or the zero
// value, as each wrapper documents.
//

enum SLS {
  /// A window as `SLSWindowQueryWindows` / `SLSWindowQueryResultCopyWindows` and the `SLSWindowIteratorGet*`
  /// functions report it.
  struct QueriedWindow {
    let id: WindowID
    let parent: WindowID?
    let tags: UInt64
    let attributes: UInt64
    let level: Int32
  }

  /// The options of `_SLPSSetFrontProcessWithOptions`: activate a process for a user action, or without raising any of
  /// its windows.
  enum FrontProcessMode: UInt32 {
    case userGenerated = 0x200
    case noWindows = 0x400
  }

  /// The main connection of the daemon to the window server.
  static let connection: Int32 = SLSMainConnectionID()

  //
  // NOTE: SkyLight expects window ids as kCFNumberSInt32Type and space ids as kCFNumberSInt64Type numbers, which
  // NSNumber(value: Int32) and NSNumber(value: Int64) create.
  //

  static func cfArray(windows: [WindowID]) -> CFArray {
    return windows.map { NSNumber(value: Int32(bitPattern: $0.rawValue)) } as CFArray
  }

  static func cfArray(spaces: [SpaceID]) -> CFArray {
    return spaces.map { NSNumber(value: Int64(bitPattern: $0.rawValue)) } as CFArray
  }

  static func ids<T: FixedWidthInteger>(_ array: CFArray?, as type: T.Type) -> [T] {
    guard let numbers = array as? [NSNumber] else { return [] }
    return numbers.map { T(truncatingIfNeeded: $0.int64Value) }
  }

  /// `SLSGetWindowBounds`
  static func windowBounds(_ cid: Int32, _ wid: WindowID) -> CGRect? {
    var frame = CGRect.zero
    guard SLSGetWindowBounds(cid, wid.rawValue, &frame) == .success else { return nil }
    return frame
  }

  /// `SLSGetWindowAlpha`; nil if the call fails.
  static func windowAlpha(_ cid: Int32, _ wid: WindowID) -> Float? {
    var alpha: Float = 0
    guard SLSGetWindowAlpha(cid, wid.rawValue, &alpha) == .success else { return nil }
    return alpha
  }

  /// `SLSGetWindowSubLevel`
  static func windowSubLevel(_ cid: Int32, _ wid: WindowID) -> Int32 {
    return SLSGetWindowSubLevel(cid, wid.rawValue)
  }

  /// `SLSCopyWindowProperty` with `kCGSWindowTitle`: the title that the window server knows.
  static func windowTitle(_ cid: Int32, _ wid: WindowID) -> String? {
    var value: Unmanaged<CFTypeRef>?
    SLSCopyWindowProperty(cid, wid.rawValue, "kCGSWindowTitle" as CFString, &value)
    return value?.takeRetainedValue() as? String
  }

  /// `SLSWindowIsOrderedIn`
  static func windowIsOrderedIn(_ cid: Int32, _ wid: WindowID) -> Bool {
    var orderedIn: UInt8 = 0
    SLSWindowIsOrderedIn(cid, wid.rawValue, &orderedIn)
    return orderedIn != 0
  }

  /// `SLSGetWindowOwner`: the connection of the process that owns the window.
  static func windowOwner(_ cid: Int32, _ wid: WindowID) -> Int32? {
    var owner: Int32 = 0
    guard SLSGetWindowOwner(cid, wid.rawValue, &owner) == .success else { return nil }
    return owner
  }

  /// `SLSConnectionGetPID`
  static func connectionPID(_ cid: Int32) -> pid_t? {
    var pid: pid_t = 0
    guard SLSConnectionGetPID(cid, &pid) == .success else { return nil }
    return pid
  }

  /// `SLSCopySpacesForWindows`; `WindowID.space` and its callers pass the selector 0x7.
  static func spaces(_ cid: Int32, forWindows windows: [WindowID], selector: Int32 = 0x7)
    -> [SpaceID]
  {
    return ids(SLSCopySpacesForWindows(cid, selector, cfArray(windows: windows)), as: UInt64.self)
      .map { SpaceID($0) }
  }

  /// `SLSCopyWindowsWithOptionsAndTags` without tag filters, as `SpaceID.windows(on:connection:includingMinimized:)`
  /// calls it. A nil owner lists the windows of every connection, which the call expresses as owner 0. nil when the call
  /// fails, which the caller must tell apart from an empty list.
  static func windows(_ cid: Int32, owner: Int32?, spaces: [SpaceID], options: UInt32)
    -> [WindowID]?
  {
    var setTags: UInt64 = 0
    var clearTags: UInt64 = 0
    let ownerID = owner.map { UInt32(bitPattern: $0) } ?? 0
    guard
      let windows = SLSCopyWindowsWithOptionsAndTags(
        cid, ownerID, cfArray(spaces: spaces), options, &setTags, &clearTags)
    else { return nil }
    return ids(windows, as: UInt32.self).map { WindowID($0) }
  }

  /// `SLSWindowQueryWindows`, `SLSWindowQueryResultCopyWindows` and the `SLSWindowIterator*` functions: the windows of
  /// the list that the window server knows, in its order.
  static func queryWindows(_ cid: Int32, _ windows: [WindowID]) -> [QueriedWindow] {
    guard let query = SLSWindowQueryWindows(cid, cfArray(windows: windows), Int32(windows.count))
    else { return [] }
    guard let iterator = SLSWindowQueryResultCopyWindows(query) else { return [] }

    var result: [QueriedWindow] = []
    result.reserveCapacity(Int(SLSWindowIteratorGetCount(iterator)))

    while SLSWindowIteratorAdvance(iterator) {
      result.append(
        QueriedWindow(
          id: WindowID(SLSWindowIteratorGetWindowID(iterator)),
          parent: WindowID(nonzero: SLSWindowIteratorGetParentID(iterator)),
          tags: SLSWindowIteratorGetTags(iterator),
          attributes: SLSWindowIteratorGetAttributes(iterator),
          level: SLSWindowIteratorGetLevel(iterator)))
    }

    return result
  }

  /// `SLSCopyManagedDisplayForWindow`
  static func managedDisplay(_ cid: Int32, forWindow wid: WindowID) -> String? {
    return SLSCopyManagedDisplayForWindow(cid, wid.rawValue) as String?
  }

  /// `SLSCopyBestManagedDisplayForRect`
  static func bestManagedDisplay(_ cid: Int32, forRect rect: CGRect) -> String? {
    return SLSCopyBestManagedDisplayForRect(cid, rect) as String?
  }

  /// `SLSCopyBestManagedDisplayForPoint`
  static func bestManagedDisplay(_ cid: Int32, forPoint point: CGPoint) -> String? {
    return SLSCopyBestManagedDisplayForPoint(cid, point) as String?
  }

  /// `SLSCopyManagedDisplayForSpace`
  static func managedDisplay(_ cid: Int32, forSpace sid: SpaceID) -> String? {
    return SLSCopyManagedDisplayForSpace(cid, sid.rawValue) as String?
  }

  /// `SLSCopyActiveMenuBarDisplayIdentifier`
  static func activeMenuBarDisplay(_ cid: Int32) -> String? {
    return SLSCopyActiveMenuBarDisplayIdentifier(cid) as String?
  }

  /// `SLSManagedDisplayGetCurrentSpace`; nil when the window server reports no space (0).
  static func currentSpace(_ cid: Int32, forDisplay uuid: String) -> SpaceID? {
    return SpaceID(nonzero: SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString))
  }

  /// `SLSCopyManagedDisplaySpaces`: one dictionary per display, as `DisplayID.spaces` reads it.
  static func managedDisplaySpaces(_ cid: Int32) -> [NSDictionary] {
    return SLSCopyManagedDisplaySpaces(cid) as? [NSDictionary] ?? []
  }

  /// `SLSSpaceGetType`
  static func spaceType(_ cid: Int32, _ sid: SpaceID) -> Int32 {
    return SLSSpaceGetType(cid, sid.rawValue)
  }

  /// `SLSSpaceCopyName`
  static func spaceName(_ cid: Int32, _ sid: SpaceID) -> String? {
    return SLSSpaceCopyName(cid, sid.rawValue) as String?
  }

  /// `SLSSpaceCopyName`, for the views, which keep the name as a CFString (`view->uuid`).
  static func spaceNameObject(_ cid: Int32, _ sid: SpaceID) -> CFString? {
    return SLSSpaceCopyName(cid, sid.rawValue)
  }

  /// `SLSCopyManagedDisplays`: the uuids of the displays in the order of the window server; nil when the call fails.
  static func managedDisplays(_ cid: Int32) -> CFArray? {
    return SLSCopyManagedDisplays(cid)
  }

  /// `SLSSetActiveMenuBarDisplayIdentifier`, with the display as both the identifier and the repeat identifier.
  static func setActiveMenuBarDisplay(_ cid: Int32, _ uuid: String) {
    SLSSetActiveMenuBarDisplayIdentifier(cid, uuid as CFString, uuid as CFString)
  }

  /// `SLSGetMenuBarAutohideEnabled`; false if the call fails, like `DisplayManager.isMenuBarHidden`.
  static func menuBarAutohideEnabled(_ cid: Int32) -> Bool {
    var status: Int32 = 0
    SLSGetMenuBarAutohideEnabled(cid, &status)
    return status != 0
  }

  /// `SLSGetDisplayMenubarHeight`; 0 if the call fails.
  static func displayMenuBarHeight(_ did: DisplayID) -> UInt32 {
    var height: UInt32 = 0
    SLSGetDisplayMenubarHeight(did.rawValue, &height)
    return height
  }

  /// `SLSGetDockRectWithReason`; the zero rect if the call fails, like `DisplayManager.dockRect`.
  static func dockRect(_ cid: Int32) -> CGRect {
    var bounds = CGRect.zero
    var reason: Int32 = 0
    SLSGetDockRectWithReason(cid, &bounds, &reason)
    return bounds
  }

  /// `SLSGetCurrentCursorLocation`; the zero point if the call fails.
  static func cursorLocation(_ cid: Int32) -> CGPoint {
    var point = CGPoint.zero
    SLSGetCurrentCursorLocation(cid, &point)
    return point
  }

  /// `SLSGetConnectionPSN`: the process serial number of the process that owns a connection.
  static func connectionPSN(_ cid: Int32) -> ProcessSerialNumber {
    var psn = ProcessSerialNumber()
    SLSGetConnectionPSN(cid, &psn)
    return psn
  }

  /// `_SLPSGetFrontProcess`: the process serial number of the frontmost process.
  static func frontProcess() -> ProcessSerialNumber {
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
  static func postEventRecord(_ bytes: UnsafeMutablePointer<UInt8>, to psn: ProcessSerialNumber) {
    var psn = psn
    SLPSPostEventRecordTo(&psn, bytes)
  }

  /// `SLSSpaceSetFrontPSN`: the process that is frontmost once the space becomes active.
  static func setFrontProcess(_ cid: Int32, _ psn: ProcessSerialNumber, forSpace sid: SpaceID) {
    SLSSpaceSetFrontPSN(cid, sid.rawValue, psn)
  }

  /// `SLSGetConnectionIDForPSN`; nil if the call fails.
  static func connectionID(_ cid: Int32, forProcess psn: ProcessSerialNumber) -> Int32? {
    var psn = psn
    var connection: Int32 = 0
    guard SLSGetConnectionIDForPSN(cid, &psn, &connection) == .success else { return nil }
    return connection
  }

  /// `SLSGetSpaceManagementMode`: 1 when displays have separate spaces.
  static func spaceManagementMode(_ cid: Int32) -> Int32 {
    return SLSGetSpaceManagementMode(cid)
  }

  /// `SLSRegisterConnectionNotifyProc` without a context.
  static func registerNotification(
    _ cid: Int32, _ event: UInt32,
    handler:
      @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) ->
      Void
  ) {
    SLSRegisterConnectionNotifyProc(cid, handler, event, nil)
  }

  //
  // NOTE: Without the bridged operation and the scripting addition, windows move to a space through the compat id
  // 'yabe' (0x79616265), which the space wears while SLSSetWindowListWorkspace moves the windows to it.
  //
  static func moveWindows(_ cid: Int32, _ windows: [WindowID], toSpaceByCompatID sid: SpaceID) {
    let compatID: Int32 = 0x7961_6265
    SLSSpaceSetCompatID(cid, sid.rawValue, compatID)
    var rawWindows = windows.map(\.rawValue)
    SLSSetWindowListWorkspace(cid, &rawWindows, Int32(rawWindows.count), compatID)
    SLSSpaceSetCompatID(cid, sid.rawValue, 0)
  }

  /// `SLSCopyAssociatedWindows`: the windows associated with the window (sheets, drawers, children); nil if the call
  /// fails.
  static func associatedWindows(_ cid: Int32, _ wid: WindowID) -> [WindowID]? {
    guard let windows = SLSCopyAssociatedWindows(cid, wid.rawValue) else { return nil }
    return ids(windows, as: UInt32.self).map { WindowID($0) }
  }

  /// `SLSRequestNotificationsForWindows`
  static func requestNotifications(_ cid: Int32, forWindows windows: [WindowID]) {
    var rawWindows = windows.map(\.rawValue)
    SLSRequestNotificationsForWindows(cid, &rawWindows, Int32(rawWindows.count))
  }

  //
  // NOTE: The bounded wait keeps a message that the window server does not answer (e.g. an unknown msgh_id on a new
  // macOS release) from blocking the event loop forever. Like MIG-generated code, the special reply port is destroyed on
  // failure, so that a late reply cannot be received by the next call on this thread.
  //
  // NOTE: Swift cannot read the NDR_record global of mach/ndr.h (Swift 6 rejects a reference to it as not
  // concurrency-safe), so the request writes the eight bytes of NDR_record as constants
  // (SubLevelMessage.ndrRecordBytes).
  //

  /// The sub-level of the window, asked from the window server like `SLSGetWindowSubLevel` but with a bounded wait for
  /// the reply; nil if `connectionPortFunction` did not resolve or the message failed.
  static func windowSubLevelBounded(_ cid: Int32, _ wid: WindowID) -> Int32? {
    guard let connectionPort = connectionPortFunction else { return nil }

    return withUnsafeTemporaryAllocation(byteCount: SubLevelMessage.size, alignment: 8) {
      message -> Int32? in
      message.initializeMemory(as: UInt8.self, repeating: 0)
      message.storeBytes(
        of: SubLevelMessage.bits, toByteOffset: SubLevelMessage.bitsOffset, as: UInt32.self)
      message.storeBytes(
        of: connectionPort(cid), toByteOffset: SubLevelMessage.remotePortOffset, as: UInt32.self)
      let replyPort = mig_get_special_reply_port()
      message.storeBytes(
        of: replyPort, toByteOffset: SubLevelMessage.localPortOffset, as: UInt32.self)
      message.storeBytes(
        of: SubLevelMessage.messageID, toByteOffset: SubLevelMessage.messageIDOffset, as: Int32.self
      )
      for (index, byte) in SubLevelMessage.ndrRecordBytes.enumerated() {
        message.storeBytes(
          of: byte, toByteOffset: SubLevelMessage.ndrRecordOffset + index, as: UInt8.self)
      }
      message.storeBytes(
        of: wid.rawValue, toByteOffset: SubLevelMessage.windowIDOffset, as: UInt32.self)

      let header = message.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
      let result = mach_msg(
        header, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT, SubLevelMessage.sendSize,
        SubLevelMessage.receiveSize, replyPort, SubLevelMessage.timeout, 0)
      guard result == MACH_MSG_SUCCESS else {
        mig_dealloc_special_reply_port(replyPort)
        return nil
      }

      return message.load(fromByteOffset: SubLevelMessage.subLevelOffset, as: Int32.self)
    }
  }

  /// The message of `windowSubLevelBounded`: a `mach_msg_header_t` at offset 0, then the NDR record, the window id,
  /// the sub-level that the reply fills in and two paddings. Swift writes and reads the fields at these byte offsets
  /// in a raw buffer of `size` bytes, not through a struct with the same layout.
  private enum SubLevelMessage {
    static let size = 48
    static let bits: UInt32 = 0x1513
    static let messageID: Int32 = 0x76E3
    static let sendSize: UInt32 = 0x24
    static let receiveSize: UInt32 = 0x30
    /// Milliseconds.
    static let timeout: UInt32 = 100

    static let bitsOffset = 0
    static let remotePortOffset = 8
    static let localPortOffset = 12
    static let messageIDOffset = 20
    static let ndrRecordOffset = 24
    static let windowIDOffset = 32
    static let subLevelOffset = 36

    /// The bytes of NDR_record: mig_vers, if_vers, reserved1, mig_encoding, int_rep (1: little endian), char_rep,
    /// float_rep, reserved2.
    static let ndrRecordBytes: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0]
  }

  /// Turns the shadow of the window off by setting its shadow density to zero.
  static func disableShadow(_ wid: WindowID) {
    let options =
      ["com.apple.WindowShadowDensity" as CFString: NSNumber(value: Int32(0))] as CFDictionary
    SLSWindowSetShadowProperties(wid.rawValue, options)
  }

  /// `SLSFindWindowAndOwner`: the window at the point and the connection that owns it, from the top (start nil,
  /// order 1) or below `start` (order -1).
  static func findWindow(_ cid: Int32, at point: CGPoint, startingAt start: WindowID?, order: Int32)
    -> (window: WindowID?, owner: Int32)
  {
    var point = point
    var windowPoint = CGPoint.zero
    var wid: UInt32 = 0
    var owner: Int32 = 0
    SLSFindWindowAndOwner(
      cid, Int32(bitPattern: start?.rawValue ?? 0), order, 0, &point, &windowPoint, &wid, &owner)
    return (WindowID(nonzero: wid), owner)
  }

  /// The topmost window at the point that another connection than `cid` owns: the windows of `cid` (yabai's borders
  /// and tab bars) are skipped. Nil when there is none.
  static func topWindow(at point: CGPoint, skipping cid: Int32) -> WindowID? {
    var (found, owner) = findWindow(cid, at: point, startingAt: nil, order: 1)
    while let current = found, owner == cid {
      (found, owner) = findWindow(cid, at: point, startingAt: current, order: -1)
    }
    return found
  }

  //
  // NOTE: SkyLight does not export two functions that yabai calls. They are in its symbol table, so they are found with
  // MachOSymbol.address(of:inImage:). Each one resolves on first use, and Daemon.run reads both at startup to log the
  // ones that did not resolve. Swift calls them through @convention(c) types made from the addresses: a C
  // function-pointer variable is rejected as a Swift 6 global, so the pointers are not in CPrivate.
  //

  /// `CGSGetConnectionPortById`: the Mach port of a connection id.
  typealias ConnectionPortFunction = @convention(c) (Int32) -> mach_port_t

  /// `SLSPerformAsynchronousBridgedWindowManagementOperation`: runs an operation object; the result is not used.
  typealias BridgedOperationFunction = @convention(c) (UnsafeMutableRawPointer) -> Int64

  /// The image of SkyLight whose symbol table holds the two functions.
  static let skyLightImage =
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"

  /// The symbol of `CGSGetConnectionPortById`.
  static let connectionPortSymbol = "_CGSGetConnectionPortById"

  /// The mangled symbol of `SLSPerformAsynchronousBridgedWindowManagementOperation`.
  static let bridgedOperationSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

  /// `CGSGetConnectionPortById`, resolved on first use; nil if the symbol did not resolve.
  static let connectionPortFunction: ConnectionPortFunction? = {
    guard let address = skyLightSymbol(connectionPortSymbol) else { return nil }
    return unsafeBitCast(address, to: ConnectionPortFunction.self)
  }()

  /// `SLSPerformAsynchronousBridgedWindowManagementOperation`, resolved on first use; nil if it did not resolve.
  static let bridgedOperationFunction: BridgedOperationFunction? = {
    guard let address = skyLightSymbol(bridgedOperationSymbol) else { return nil }
    return unsafeBitCast(address, to: BridgedOperationFunction.self)
  }()

  /// A function of SkyLight that it does not export, found in its symbol table.
  private static func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    return MachOSymbol.address(of: name, inImage: skyLightImage)
  }

  /// Whether `SLSPerformAsynchronousBridgedWindowManagementOperation` is resolved.
  static var hasBridgedWindowOperation: Bool {
    return bridgedOperationFunction != nil
  }

  /// `[[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:spaceID:]`, run through
  /// `SLSPerformAsynchronousBridgedWindowManagementOperation` and released after the window server took it.
  /// The Objective-C messages go through objc_msgSend, cast to the signature of each call.
  static func bridgedMoveWindows(_ windows: [WindowID], toSpace sid: SpaceID) {
    guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
      let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend"),
      let perform = bridgedOperationFunction
    else { return }

    typealias Alloc =
      @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    typealias InitWithWindows =
      @convention(c) (
        UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt64
      ) -> UnsafeMutableRawPointer?
    let alloc = unsafeBitCast(send, to: Alloc.self)
    let initWithWindows = unsafeBitCast(send, to: InitWithWindows.self)

    let classObject = Unmanaged.passUnretained(cls as AnyObject).toOpaque()
    let windowList = windows.map { NSNumber(value: Int32(bitPattern: $0.rawValue)) } as NSArray

    let selectorAlloc = unsafeBitCast(sel_registerName("alloc"), to: UnsafeMutableRawPointer.self)
    let selectorInit = unsafeBitCast(
      sel_registerName("initWithWindows:spaceID:"), to: UnsafeMutableRawPointer.self)

    guard let allocated = alloc(classObject, selectorAlloc),
      let operation = initWithWindows(
        allocated, selectorInit,
        Unmanaged.passUnretained(windowList).toOpaque(), sid.rawValue)
    else { return }

    withExtendedLifetime(windowList) {
      _ = perform(operation)
    }

    Unmanaged<AnyObject>.fromOpaque(operation).release()
  }
}
