import CoreGraphics
import CoreFoundation
import YabaiC

//
// NOTE: The reconfiguration callback runs on a thread of the window server. It only posts events; the handlers change
// the state on the @WM queue (see EventLoop.swift). Ported from src/display.c.
//

/// `display_handler`: registered by `display_manager_begin`.
let displayReconfigured: CGDisplayReconfigurationCallBack = { did, flags, _ in
    if flags.contains(.addFlag) {
        EventLoop.post(.displayAdded(displayID: did))
    } else if flags.contains(.removeFlag) {
        EventLoop.post(.displayRemoved(displayID: did))
    } else if flags.contains(.movedFlag) {
        EventLoop.post(.displayMoved(displayID: did))
    } else if flags.contains(.desktopShapeChangedFlag) {
        EventLoop.post(.displayResized(displayID: did))
    }
}

/// `display_uuid` as a CFString.
func displayUUIDObject(_ did: UInt32) -> CFString?
{
    guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(did) else { return nil }
    return CFUUIDCreateString(nil, uuidRef)
}

/// `display_uuid` as a Swift string.
func displayUUID(_ did: UInt32) -> String?
{
    return displayUUIDObject(did) as String?
}

//
// NOTE: Swift returns a CF object from a @_cdecl function autoreleased (+0), but the C prototypes of the uuid functions
// say CF_RETURNS_RETAINED. Their @_cdecl entry points therefore return Unmanaged at +1; Swift code calls the Swift
// functions (displayUUID, displayManagerArrangementDisplayUUID, …) instead.
//

/// `display_uuid`, for C callers: +1.
@_cdecl("display_uuid")
func displayUUIDRetained(_ did: UInt32) -> Unmanaged<CFString>?
{
    return displayUUIDObject(did).map { Unmanaged.passRetained($0) }
}

/// Passes a string to a C caller at +1, for the CF_RETURNS_RETAINED functions.
func retainedCFString(_ value: String?) -> Unmanaged<CFString>?
{
    return value.map { Unmanaged.passRetained($0 as CFString) }
}

/// `display_id`
@_cdecl("display_id")
func display_id(_ uuid: CFString?) -> UInt32
{
    guard let uuid else { return 0 }
    return displayID(uuid as String)
}

/// `display_id` for a uuid string.
func displayID(_ uuid: String) -> UInt32
{
    guard let uuidRef = CFUUIDCreateFromString(nil, uuid as CFString) else { return 0 }
    return CGDisplayGetDisplayIDFromUUID(uuidRef)
}

/// `display_bounds_constrained`
@_cdecl("display_bounds_constrained")
func display_bounds_constrained(_ did: UInt32, _ ignoreExternalBar: Bool) -> CGRect
{
    let dm = display_manager_global()!
    var frame = CGDisplayBounds(did)
    var effectiveExtTopPadding: Int32 = 0

    if !ignoreExternalBar {
        if (dm.pointee.mode == EXTERNAL_BAR_MAIN && did == display_manager_main_display_id()) ||
           (dm.pointee.mode == EXTERNAL_BAR_ALL) {
            effectiveExtTopPadding = dm.pointee.top_padding

            frame.origin.y    += CGFloat(effectiveExtTopPadding)
            frame.size.height -= CGFloat(effectiveExtTopPadding)
            frame.size.height -= CGFloat(dm.pointee.bottom_padding)
        }
    }

    if display_manager_menu_bar_hidden() {
        let notchHeight = workspace_display_notch_height(did)
        if notchHeight > effectiveExtTopPadding {
            frame.origin.y    += CGFloat(notchHeight - effectiveExtTopPadding)
            frame.size.height -= CGFloat(notchHeight - effectiveExtTopPadding)
        }
    } else {
        let menu = display_manager_menu_bar_rect(did)
        frame.origin.y    += menu.size.height
        frame.size.height -= menu.size.height
    }

    if !display_manager_dock_hidden() {
        if did == display_manager_dock_display_id() {
            let dock = display_manager_dock_rect()
            switch display_manager_dock_orientation() {
            case DOCK_ORIENTATION_LEFT:
                frame.origin.x   += dock.size.width
                frame.size.width -= dock.size.width
            case DOCK_ORIENTATION_RIGHT:
                frame.size.width -= dock.size.width
            case DOCK_ORIENTATION_BOTTOM:
                frame.size.height -= dock.size.height
            default: break
            }
        }
    }

    return frame
}

/// `display_center`
@_cdecl("display_center")
func display_center(_ did: UInt32) -> CGPoint
{
    let bounds = CGDisplayBounds(did)
    return CGPoint(x: bounds.origin.x + bounds.size.width/2, y: bounds.origin.y + bounds.size.height/2)
}

/// `display_space_id`
@_cdecl("display_space_id")
func display_space_id(_ did: UInt32) -> UInt64
{
    guard let uuid = displayUUID(did) else { return 0 }
    return SLS.currentSpace(connection_global(), forDisplay: uuid)
}

/// `display_space_list`: the spaces of a display in the order of the window server, in temporary storage. nil when
/// the display is unknown.
@_cdecl("display_space_list")
func display_space_list(_ did: UInt32, _ count: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<UInt64>?
{
    guard let spaces = displaySpaces(did) else { return nil }

    count.pointee = Int32(spaces.count)
    return temporaryList(spaces)
}

/// The spaces of a display, as `display_space_list` lists them; nil when the display or the window server does not know it.
func displaySpaces(_ did: UInt32) -> [UInt64]?
{
    guard let uuid = displayUUID(did) else { return nil }

    var result: [UInt64]?
    for display in SLS.managedDisplaySpaces(connection_global()) {
        guard let identifier = display["Display Identifier"] as? String, identifier.utf8.elementsEqual(uuid.utf8) else { continue }

        let spaces = display["Spaces"] as? [NSDictionary] ?? []
        result = spaces.map { ($0["id64"] as? NSNumber)?.uint64Value ?? 0 }
    }

    return result
}

/// Copies values into temporary storage, where C callers read the lists (`ts_alloc_list` in C). They are reset with
/// the rest of the temporary storage after each event.
func temporaryList<T>(_ values: [T]) -> UnsafeMutablePointer<T>
{
    return values.withUnsafeBytes { bytes in
        let list: UnsafeMutableRawPointer = ts_list_from_bytes(bytes.baseAddress, UInt64(bytes.count), UInt64(MemoryLayout<T>.alignment))
        return list.bindMemory(to: T.self, capacity: values.count)
    }
}
