import ApplicationServices
import CoreGraphics
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: The displays of yabai: their arrangement (display_arrangement_order and builtin_display_last), the menu bar and
// the Dock that shrink their area, and the focus of a display. Ported from src/display_manager.c.
//

/// `struct display_manager`
final class DisplayManager
{
    var current_display_id: UInt32 = 0
    var last_display_id: UInt32 = 0

    var top_padding: Int32 = 0
    var bottom_padding: Int32 = 0

    var order = DISPLAY_ARRANGEMENT_ORDER_DEFAULT
    var builtin_last = false
    var mode = EXTERNAL_BAR_OFF

    var labels: OpaquePointer?
}

//
// NOTE: The global singletons are created before the event loop starts. Like the C globals they replace, the event loop
// owns them; the producers on other threads read only what they read in C, under the locks named where they do.
//

/// `g_display_manager`
nonisolated(unsafe) let g_display_manager = DisplayManager()

func display_manager_global() -> DisplayManager
{
    g_display_manager
}

/// `display_manager_main_display_id`
@_cdecl("display_manager_main_display_id")
func display_manager_main_display_id() -> UInt32
{
    return CGMainDisplayID()
}

/// `display_manager_active_display_uuid`: the display with the active menu bar; +1 for C callers (see Display.swift).
@_cdecl("display_manager_active_display_uuid")
func displayManagerActiveDisplayUUIDRetained() -> Unmanaged<CFString>?
{
    return retainedCFString(SLS.activeMenuBarDisplay(connection_global()))
}

/// `display_manager_active_display_id`
@_cdecl("display_manager_active_display_id")
func display_manager_active_display_id() -> UInt32
{
    let uuid = SLS.activeMenuBarDisplay(connection_global())
    assert(uuid != nil)

    return uuid.map(displayID) ?? 0
}

/// `display_manager_dock_display_uuid`: the display that holds the Dock; +1 for C callers.
@_cdecl("display_manager_dock_display_uuid")
func displayManagerDockDisplayUUIDRetained() -> Unmanaged<CFString>?
{
    return retainedCFString(SLS.bestManagedDisplay(connection_global(), forRect: display_manager_dock_rect()))
}

/// `display_manager_dock_display_id`
@_cdecl("display_manager_dock_display_id")
func display_manager_dock_display_id() -> UInt32
{
    guard let uuid = SLS.bestManagedDisplay(connection_global(), forRect: display_manager_dock_rect()) else { return 0 }
    return displayID(uuid)
}

/// `display_manager_point_display_uuid`: the display that holds a point; +1 for C callers.
@_cdecl("display_manager_point_display_uuid")
func displayManagerPointDisplayUUIDRetained(_ point: CGPoint) -> Unmanaged<CFString>?
{
    return retainedCFString(SLS.bestManagedDisplay(connection_global(), forPoint: point))
}

/// `display_manager_point_display_id`
@_cdecl("display_manager_point_display_id")
func display_manager_point_display_id(_ point: CGPoint) -> UInt32
{
    guard let uuid = SLS.bestManagedDisplay(connection_global(), forPoint: point) else { return 0 }
    return displayID(uuid)
}

//
// NOTE: The order of display_arrangement_order compares the centers of two displays on the axis of the order, then on the
// other axis. The context of the comparator is the order itself.
//

private let displayCoordinateComparator: CFComparatorFunction = { a, b, context in
    let byY = UInt(bitPattern: context) == UInt(DISPLAY_ARRANGEMENT_ORDER_Y.rawValue)

    let aCenter = display_center(display_id(Unmanaged<CFString>.fromOpaque(a!).takeUnretainedValue()))
    let bCenter = display_center(display_id(Unmanaged<CFString>.fromOpaque(b!).takeUnretainedValue()))

    var aCoord = Float(byY ? aCenter.y : aCenter.x)
    var bCoord = Float(byY ? bCenter.y : bCenter.x)

    if aCoord < bCoord { return .compareLessThan }
    if aCoord > bCoord { return .compareGreaterThan }

    aCoord = Float(byY ? aCenter.x : aCenter.y)
    bCoord = Float(byY ? bCenter.x : bCenter.y)

    if aCoord < bCoord { return .compareLessThan }
    if aCoord > bCoord { return .compareGreaterThan }

    return .compareEqualTo
}

/// `display_manager_uuid_is_builtin`
private func displayManagerUUIDIsBuiltin(_ value: Any?) -> Bool
{
    guard let uuid = value as? String else { return false }

    let did = displayID(uuid)
    return did != 0 && CGDisplayIsBuiltin(did) != 0
}

/// `display_manager_order_builtin_last`: moves the first builtin display of a list to its end, when builtin_display_last
/// is set. display_spaces reads the uuid from the "Display Identifier" of each dictionary of the list.
private func displayManagerOrderBuiltinLast<T>(_ list: [T], displaySpaces: Bool) -> [T]
{
    if !display_manager_global().builtin_last { return list }

    for i in 0..<max(list.count - 1, 0) {
        let item = list[i]
        let uuid: Any? = displaySpaces ? (item as? NSDictionary)?["Display Identifier"] : (item as Any)
        if !displayManagerUUIDIsBuiltin(uuid) { continue }

        var result = list
        result.remove(at: i)
        result.append(item)
        return result
    }

    return list
}

/// `display_manager_copy_managed_display_spaces`: the display spaces of the window server, with builtin_display_last applied.
func display_manager_copy_managed_display_spaces() -> [NSDictionary]
{
    return displayManagerOrderBuiltinLast(SLS.managedDisplaySpaces(connection_global()), displaySpaces: true)
}

//
// NOTE: The uuids of all displays in the order of their arrangement index (display_arrangement_order,
// then builtin_display_last).
//

/// `display_manager_copy_arranged_displays`; nil when the window server does not list the displays.
private func displayManagerCopyArrangedDisplays() -> [String]?
{
    guard let displays = SLS.managedDisplays(connection_global()) else { return nil }

    let count = CFArrayGetCount(displays)
    let order = display_manager_global().order

    var sorted = displays
    if count > 0 && order != DISPLAY_ARRANGEMENT_ORDER_DEFAULT {
        let mutable = CFArrayCreateMutableCopy(nil, count, displays)!
        CFArraySortValues(mutable, CFRangeMake(0, count), displayCoordinateComparator, UnsafeMutableRawPointer(bitPattern: UInt(order.rawValue)))
        sorted = mutable as CFArray
    }

    return displayManagerOrderBuiltinLast((sorted as NSArray as? [String]) ?? [], displaySpaces: false)
}

/// `display_manager_display_id_arrangement`
@_cdecl("display_manager_display_id_arrangement")
func display_manager_display_id_arrangement(_ did: UInt32) -> Int32
{
    guard let uuid = displayUUID(did) else { return 0 }
    guard let displays = displayManagerCopyArrangedDisplays() else { return 0 }
    guard let index = displays.firstIndex(where: { $0.utf8.elementsEqual(uuid.utf8) }) else { return 0 }

    return Int32(index + 1)
}

/// `display_manager_arrangement_display_uuid`
func displayManagerArrangementDisplayUUID(_ arrangement: Int32) -> String?
{
    guard let displays = displayManagerCopyArrangedDisplays() else { return nil }

    let index = Int(arrangement) - 1
    guard index >= 0 && index < displays.count else { return nil }

    return displays[index]
}

/// `display_manager_arrangement_display_uuid`, for C callers: +1.
@_cdecl("display_manager_arrangement_display_uuid")
func displayManagerArrangementDisplayUUIDRetained(_ arrangement: Int32) -> Unmanaged<CFString>?
{
    return retainedCFString(displayManagerArrangementDisplayUUID(arrangement))
}

/// `display_manager_arrangement_display_id`
@_cdecl("display_manager_arrangement_display_id")
func display_manager_arrangement_display_id(_ arrangement: Int32) -> UInt32
{
    guard let uuid = displayManagerArrangementDisplayUUID(arrangement) else { return 0 }
    return displayID(uuid)
}

/// `display_manager_cursor_display_id`
@_cdecl("display_manager_cursor_display_id")
func display_manager_cursor_display_id() -> UInt32
{
    return display_manager_point_display_id(SLS.cursorLocation(connection_global()))
}

/// `display_manager_prev_display_id`
@_cdecl("display_manager_prev_display_id")
func display_manager_prev_display_id(_ did: UInt32) -> UInt32
{
    let arrangement = display_manager_display_id_arrangement(did)
    if arrangement <= 1 { return 0 }

    return display_manager_arrangement_display_id(arrangement - 1)
}

/// `display_manager_next_display_id`
@_cdecl("display_manager_next_display_id")
func display_manager_next_display_id(_ did: UInt32) -> UInt32
{
    let arrangement = display_manager_display_id_arrangement(did)
    if arrangement >= display_manager_active_display_count() { return 0 }

    return display_manager_arrangement_display_id(arrangement + 1)
}

/// `display_manager_first_display_id`
@_cdecl("display_manager_first_display_id")
func display_manager_first_display_id() -> UInt32
{
    return display_manager_arrangement_display_id(1)
}

/// `display_manager_last_display_id`
@_cdecl("display_manager_last_display_id")
func display_manager_last_display_id() -> UInt32
{
    let arrangement = display_manager_active_display_count()
    return display_manager_arrangement_display_id(arrangement)
}

/// `display_manager_find_closest_display_in_direction`: the nearest display in a direction, 0 if there is none.
@_cdecl("display_manager_find_closest_display_in_direction")
func display_manager_find_closest_display_in_direction(_ sourceDid: UInt32, _ direction: Int32) -> UInt32
{
    guard let direction = Direction(rawValue: direction) else { return 0 }

    var bestDid: UInt32 = 0
    var bestDistance = Int.max

    let sourceArea = Area(CGDisplayBounds(sourceDid))
    let sourceAreaMax = sourceArea.maxPoint

    for did in displayManagerActiveDisplays() {
        if did == sourceDid { continue }

        let targetArea = Area(CGDisplayBounds(did))
        let targetAreaMax = targetArea.maxPoint

        if Area.isInDirection(sourceArea, sourceAreaMax, targetArea, targetAreaMax, direction) {
            let distance = Area.distanceInDirection(sourceArea, sourceAreaMax, targetArea, targetAreaMax, direction)
            if distance < bestDistance {
                bestDid = did
                bestDistance = distance
            }
        }
    }

    return bestDid
}

/// `display_manager_menu_bar_hidden`
@_cdecl("display_manager_menu_bar_hidden")
func display_manager_menu_bar_hidden() -> Bool
{
    return SLS.menuBarAutohideEnabled(connection_global())
}

/// `display_manager_menu_bar_rect`
@_cdecl("display_manager_menu_bar_rect")
func display_manager_menu_bar_rect(_ did: UInt32) -> CGRect
{
    //
    // NOTE(asmvik): SLSGetRevealedMenuBarBounds is broken on Apple Silicon,
    // but we expected it to return the full display bounds along with the menubar
    // height. Combine this information ourselves using two separate functions..
    //

    var bounds = CGDisplayBounds(did)
    bounds.size.height = CGFloat(SLS.displayMenuBarHeight(did))

    //
    // NOTE(asmvik): Height needs to be offset by 1 because that is the actual
    // position on the screen that windows can be positioned at..
    //

    bounds.size.height += 1
    return bounds
}

/// `display_manager_dock_hidden`
@_cdecl("display_manager_dock_hidden")
func display_manager_dock_hidden() -> Bool
{
    return CoreDock.autoHideEnabled
}

/// `display_manager_dock_orientation`
@_cdecl("display_manager_dock_orientation")
func display_manager_dock_orientation() -> Int32
{
    return CoreDock.orientationAndPinning.orientation
}

/// `display_manager_dock_rect`
@_cdecl("display_manager_dock_rect")
func display_manager_dock_rect() -> CGRect
{
    return SLS.dockRect(connection_global())
}

/// `display_manager_active_display_count`
@_cdecl("display_manager_active_display_count")
func display_manager_active_display_count() -> Int32
{
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    return Int32(count)
}

/// The active displays, as `display_manager_active_display_list` lists them.
func displayManagerActiveDisplays() -> [UInt32]
{
    let displayCount = display_manager_active_display_count()

    var displays = [UInt32](repeating: 0, count: Int(displayCount))
    var actual: UInt32 = 0
    CGGetActiveDisplayList(UInt32(displayCount), &displays, &actual)

    return Array(displays.prefix(Int(actual)))
}

/// `display_manager_active_display_list`, in temporary storage; count gets the number of displays.
@_cdecl("display_manager_active_display_list")
func display_manager_active_display_list(_ count: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<UInt32>?
{
    let displays = displayManagerActiveDisplays()

    count.pointee = Int32(displays.count)
    return temporaryList(displays)
}

/// `display_manager_find_element_at_point`: the window under a point, found through the accessibility element at it.
private func displayManagerFindElementAtPoint(_ point: CGPoint) -> AXUIElement?
{
    var elementRef: AXUIElement?
    AXUIElementCopyElementAtPosition(window_manager_global().system_element!, Float(point.x), Float(point.y), &elementRef)
    guard let elementRef else { return nil }

    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(elementRef, kAXRoleAttribute as CFString, &role)
    guard let role else { return nil }

    if CFEqual(role, kAXWindowRole as CFString) { return elementRef }

    var windowRef: CFTypeRef?
    AXUIElementCopyAttributeValue(elementRef, kAXWindowAttribute as CFString, &windowRef)
    guard let windowRef else { return nil }

    return (windowRef as! AXUIElement)
}

/// `display_manager_focus_display_with_window_at_point`: focuses the window under a point; returns its id, or 0.
@_cdecl("display_manager_focus_display_with_window_at_point")
func display_manager_focus_display_with_window_at_point(_ point: CGPoint) -> UInt32
{
    guard let elementRef = displayManagerFindElementAtPoint(point) else { return 0 }

    let elementID = ax_window_id(elementRef)
    if elementID == 0 { return 0 }

    var elementPSN = SLS.connectionPSN(SLS.windowOwner(connection_global(), elementID) ?? 0)
    window_manager_focus_window_with_raise(&elementPSN, elementID, elementRef)

    return elementID
}

/// `display_manager_set_active_display_id`
@_cdecl("display_manager_set_active_display_id")
func display_manager_set_active_display_id(_ did: UInt32)
{
    guard let uuid = displayUUID(did) else { return }
    SLS.setActiveMenuBarDisplay(connection_global(), uuid)
}

/// `display_manager_focus_display`: focuses the display, through its frontmost window on the space, or its cursor.
@_cdecl("display_manager_focus_display")
func display_manager_focus_display(_ did: UInt32, _ sid: UInt64)
{
    let wm = window_manager_global()

    if let window = window_manager_find_window_on_space_by_rank_filtering_window(wm, sid, 1, 0) {
        window_manager_focus_window_with_raise(&window.pointee.application.pointee.psn, window.pointee.id, window.pointee.ref.takeUnretainedValue())
        window_manager_center_mouse(wm, window)
        display_manager_set_active_display_id(did)
    } else {
        let point = display_center(did)
        CGWarpMouseCursorPosition(point)
        display_manager_set_active_display_id(did)

        if space_manager_active_space() != display_space_id(did) {
            CGPostMouseEventC(point, false, true)
            CGPostMouseEventC(point, false, false)
        }
    }
}

/// `display_manager_focus_space`
@_cdecl("display_manager_focus_space")
func display_manager_focus_space(_ did: UInt32, _ sid: UInt64) -> space_op_error
{
    if mission_control_is_active() { return SPACE_OP_ERROR_IN_MISSION_CONTROL }

    let spaceDid = space_display_id(sid)
    if spaceDid != did { return SPACE_OP_ERROR_SAME_DISPLAY }

    return scripting_addition_focus_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION
}

/// `display_manager_begin`: reads the active display and registers the reconfiguration callback.
func display_manager_begin(_ dm: DisplayManager) -> Bool
{
    dm.current_display_id = display_manager_active_display_id()
    dm.last_display_id = dm.current_display_id
    dm.order = DISPLAY_ARRANGEMENT_ORDER_DEFAULT
    dm.mode = EXTERNAL_BAR_OFF
    dm.top_padding = 0
    dm.bottom_padding = 0

    return CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil) == .success
}
