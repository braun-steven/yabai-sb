import CoreGraphics
import CoreFoundation
import CPrivate
import Foundation
import YabaiCore

//
// NOTE: The reconfiguration callback runs on a thread of the window server. It only posts events; the handlers change
// the state on the @WM queue (see EventLoop.swift). Ported from src/display.c.
//

/// `display_handler`: registered by `display_manager_begin`.
let displayReconfigured: CGDisplayReconfigurationCallBack = { did, flags, _ in
    if flags.contains(.addFlag) {
        EventLoop.post(.displayAdded(displayID: DisplayID(did)))
    } else if flags.contains(.removeFlag) {
        EventLoop.post(.displayRemoved(displayID: DisplayID(did)))
    } else if flags.contains(.movedFlag) {
        EventLoop.post(.displayMoved(displayID: DisplayID(did)))
    } else if flags.contains(.desktopShapeChangedFlag) {
        EventLoop.post(.displayResized(displayID: DisplayID(did)))
    }
}

/// `display_uuid` as a CFString.
func displayUUIDObject(_ did: DisplayID) -> CFString?
{
    guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(did.rawValue) else { return nil }
    return CFUUIDCreateString(nil, uuidRef)
}

/// `display_uuid` as a Swift string.
func displayUUID(_ did: DisplayID) -> String?
{
    return displayUUIDObject(did) as String?
}

/// `display_id`
func display_id(_ uuid: CFString?) -> DisplayID
{
    guard let uuid else { return 0 }
    return displayID(uuid as String)
}

/// `display_id` for a uuid string.
func displayID(_ uuid: String) -> DisplayID
{
    guard let uuidRef = CFUUIDCreateFromString(nil, uuid as CFString) else { return 0 }
    return DisplayID(CGDisplayGetDisplayIDFromUUID(uuidRef))
}

/// `display_bounds_constrained`
func display_bounds_constrained(_ did: DisplayID, _ ignoreExternalBar: Bool) -> CGRect
{
    let dm = display_manager_global()
    var frame = CGDisplayBounds(did.rawValue)
    var effectiveExtTopPadding: Int32 = 0

    if !ignoreExternalBar {
        if (dm.mode == .main && did == display_manager_main_display_id()) ||
           (dm.mode == .all) {
            effectiveExtTopPadding = dm.top_padding

            frame.origin.y    += CGFloat(effectiveExtTopPadding)
            frame.size.height -= CGFloat(effectiveExtTopPadding)
            frame.size.height -= CGFloat(dm.bottom_padding)
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
            case .left:
                frame.origin.x   += dock.size.width
                frame.size.width -= dock.size.width
            case .right:
                frame.size.width -= dock.size.width
            case .bottom:
                frame.size.height -= dock.size.height
            case nil: break
            }
        }
    }

    return frame
}

/// `display_center`
func display_center(_ did: DisplayID) -> CGPoint
{
    let bounds = CGDisplayBounds(did.rawValue)
    return CGPoint(x: bounds.origin.x + bounds.size.width/2, y: bounds.origin.y + bounds.size.height/2)
}

/// `display_space_id`
func display_space_id(_ did: DisplayID) -> SpaceID
{
    guard let uuid = displayUUID(did) else { return 0 }
    return SLS.currentSpace(connection_global(), forDisplay: uuid)
}

/// `display_space_list`: the spaces of a display in the order of the window server; nil when the display or the
/// window server does not know it.
func displaySpaces(_ did: DisplayID) -> [SpaceID]?
{
    guard let uuid = displayUUID(did) else { return nil }

    var result: [SpaceID]?
    for display in SLS.managedDisplaySpaces(connection_global()) {
        guard let identifier = display["Display Identifier"] as? String, identifier.utf8.elementsEqual(uuid.utf8) else { continue }

        let spaces = display["Spaces"] as? [NSDictionary] ?? []
        result = spaces.map { SpaceID(($0["id64"] as? NSNumber)?.uint64Value ?? 0) }
    }

    return result
}
