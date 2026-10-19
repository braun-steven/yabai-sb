import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The displays of yabai: their arrangement (display_arrangement_order and builtin_display_last), the menu bar and
// the Dock that shrink their area, and the focus of a display. Ported from src/display_manager.c.
//

/// The order of the display indices (`config display_arrangement_order`): the window server's, or by the centers of the
/// displays from left to right or top to bottom.
enum DisplayArrangementOrder: String, CaseIterable, Sendable
{
    case `default`
    case horizontal
    case vertical
}

/// The displays whose area leaves room for an external bar (`config external_bar`): none, the main one, or all.
enum ExternalBarMode: String, CaseIterable, Sendable
{
    case off
    case main
    case all
}

/// The screen edge of the Dock, with the values of `CoreDockGetOrientationAndPinning`.
enum DockOrientation: Int32, Sendable
{
    case bottom = 2
    case left   = 3
    case right  = 4
}

/// `struct display_manager`
final class DisplayManager
{
    var current_display_id: DisplayID?
    var last_display_id: DisplayID?

    var top_padding: Int = 0
    var bottom_padding: Int = 0

    var order = DisplayArrangementOrder.default
    var builtin_last = false
    var mode = ExternalBarMode.off

    var labels = LabelList<DisplayID>()
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
func display_manager_main_display_id() -> DisplayID
{
    return DisplayID(CGMainDisplayID())
}

/// `display_manager_active_display_id`; nil when the window server names no active display.
func display_manager_active_display_id() -> DisplayID?
{
    let uuid = SLS.activeMenuBarDisplay(connection_global())
    assert(uuid != nil)

    return uuid.flatMap(displayID)
}

/// `display_manager_dock_display_id`
func display_manager_dock_display_id() -> DisplayID?
{
    guard let uuid = SLS.bestManagedDisplay(connection_global(), forRect: display_manager_dock_rect()) else { return nil }
    return displayID(uuid)
}

/// `display_manager_point_display_id`
func display_manager_point_display_id(_ point: CGPoint) -> DisplayID?
{
    guard let uuid = SLS.bestManagedDisplay(connection_global(), forPoint: point) else { return nil }
    return displayID(uuid)
}

//
// NOTE: The order of display_arrangement_order compares the centers of two displays on the axis of the order, then on the
// other axis. The context of the comparator is 1 for the vertical order and 0 for the horizontal one.
//

private let displayCoordinateComparator: CFComparatorFunction = { a, b, context in
    let byY = context != nil

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

    guard let did = displayID(uuid) else { return false }
    return CGDisplayIsBuiltin(did.rawValue) != 0
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
    if count > 0 && order != .default {
        let mutable = CFArrayCreateMutableCopy(nil, count, displays)!
        CFArraySortValues(mutable, CFRangeMake(0, count), displayCoordinateComparator, UnsafeMutableRawPointer(bitPattern: order == .vertical ? 1 : 0))
        sorted = mutable as CFArray
    }

    return displayManagerOrderBuiltinLast((sorted as NSArray as? [String]) ?? [], displaySpaces: false)
}

/// `display_manager_display_id_arrangement`
func display_manager_display_id_arrangement(_ did: DisplayID) -> Int
{
    guard let uuid = displayUUID(did) else { return 0 }
    guard let displays = displayManagerCopyArrangedDisplays() else { return 0 }
    guard let index = displays.firstIndex(where: { $0.utf8.elementsEqual(uuid.utf8) }) else { return 0 }

    return index + 1
}

/// `display_manager_arrangement_display_uuid`
func displayManagerArrangementDisplayUUID(_ arrangement: Int) -> String?
{
    guard let displays = displayManagerCopyArrangedDisplays() else { return nil }

    let index = arrangement - 1
    guard index >= 0 && index < displays.count else { return nil }

    return displays[index]
}

/// `display_manager_arrangement_display_id`
func display_manager_arrangement_display_id(_ arrangement: Int) -> DisplayID?
{
    guard let uuid = displayManagerArrangementDisplayUUID(arrangement) else { return nil }
    return displayID(uuid)
}

/// `display_manager_cursor_display_id`
func display_manager_cursor_display_id() -> DisplayID?
{
    return display_manager_point_display_id(SLS.cursorLocation(connection_global()))
}

/// `display_manager_prev_display_id`
func display_manager_prev_display_id(_ did: DisplayID) -> DisplayID?
{
    let arrangement = display_manager_display_id_arrangement(did)
    if arrangement <= 1 { return nil }

    return display_manager_arrangement_display_id(arrangement - 1)
}

/// `display_manager_next_display_id`
func display_manager_next_display_id(_ did: DisplayID) -> DisplayID?
{
    let arrangement = display_manager_display_id_arrangement(did)
    if arrangement >= display_manager_active_display_count() { return nil }

    return display_manager_arrangement_display_id(arrangement + 1)
}

/// `display_manager_first_display_id`
func display_manager_first_display_id() -> DisplayID?
{
    return display_manager_arrangement_display_id(1)
}

/// `display_manager_last_display_id`
func display_manager_last_display_id() -> DisplayID?
{
    let arrangement = display_manager_active_display_count()
    return display_manager_arrangement_display_id(arrangement)
}

/// `display_manager_find_closest_display_in_direction`: the nearest display in a direction, nil if there is none.
func display_manager_find_closest_display_in_direction(_ sourceDid: DisplayID, _ direction: Direction) -> DisplayID?
{

    var bestDid: DisplayID? = nil
    var bestDistance = Int.max

    let sourceArea = Area(CGDisplayBounds(sourceDid.rawValue))
    let sourceAreaMax = sourceArea.maxPoint

    for did in displayManagerActiveDisplays() {
        if did == sourceDid { continue }

        let targetArea = Area(CGDisplayBounds(did.rawValue))
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
func display_manager_menu_bar_hidden() -> Bool
{
    return SLS.menuBarAutohideEnabled(connection_global())
}

/// `display_manager_menu_bar_rect`
func display_manager_menu_bar_rect(_ did: DisplayID) -> CGRect
{
    //
    // NOTE(asmvik): SLSGetRevealedMenuBarBounds is broken on Apple Silicon,
    // but we expected it to return the full display bounds along with the menubar
    // height. Combine this information ourselves using two separate functions..
    //

    var bounds = CGDisplayBounds(did.rawValue)
    bounds.size.height = CGFloat(SLS.displayMenuBarHeight(did))

    //
    // NOTE(asmvik): Height needs to be offset by 1 because that is the actual
    // position on the screen that windows can be positioned at..
    //

    bounds.size.height += 1
    return bounds
}

/// `display_manager_dock_hidden`
func display_manager_dock_hidden() -> Bool
{
    return CoreDock.autoHideEnabled
}

/// `display_manager_dock_orientation`
func display_manager_dock_orientation() -> DockOrientation?
{
    return DockOrientation(rawValue: CoreDock.orientationAndPinning.orientation)
}

/// `display_manager_dock_rect`
func display_manager_dock_rect() -> CGRect
{
    return SLS.dockRect(connection_global())
}

/// `display_manager_active_display_count`
func display_manager_active_display_count() -> Int
{
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    return Int(count)
}

/// The active displays, as `display_manager_active_display_list` lists them.
func displayManagerActiveDisplays() -> [DisplayID]
{
    let displayCount = display_manager_active_display_count()

    var displays = [UInt32](repeating: 0, count: displayCount)
    var actual: UInt32 = 0
    CGGetActiveDisplayList(UInt32(displayCount), &displays, &actual)

    return displays.prefix(Int(actual)).map { DisplayID($0) }
}

/// `display_manager_find_element_at_point`: the window under a point, found through the accessibility element at it.
private func displayManagerFindElementAtPoint(_ point: CGPoint) -> AXUIElement?
{
    var elementRef: AXUIElement?
    AXUIElementCopyElementAtPosition(window_manager_global().systemElement!, Float(point.x), Float(point.y), &elementRef)
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

/// `display_manager_focus_display_with_window_at_point`: focuses the window under a point; returns its id, or nil.
func display_manager_focus_display_with_window_at_point(_ point: CGPoint) -> WindowID?
{
    guard let elementRef = displayManagerFindElementAtPoint(point) else { return nil }

    guard let elementID = ax_window_id(elementRef) else { return nil }

    var elementPSN = SLS.connectionPSN(SLS.windowOwner(connection_global(), elementID) ?? 0)
    WindowManager.shared.focusWithRaise(process: &elementPSN, windowID: elementID, reference: elementRef)

    return elementID
}

/// `display_manager_set_active_display_id`
func display_manager_set_active_display_id(_ did: DisplayID)
{
    guard let uuid = displayUUID(did) else { return }
    SLS.setActiveMenuBarDisplay(connection_global(), uuid)
}

/// `display_manager_focus_display`: focuses the display, through its frontmost window on the space, or its cursor.
func display_manager_focus_display(_ did: DisplayID, _ sid: SpaceID?)
{
    let wm = window_manager_global()

    if let sid, let window = wm.window(on: sid, byRank: 1, excluding: nil) {
        WindowManager.shared.focusWithRaise(window)
        wm.centerMouse(on: window)
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
func display_manager_focus_space(_ did: DisplayID, _ sid: SpaceID) -> SpaceOperationResult
{
    if mission_control_is_active() { return .inMissionControl }

    let spaceDid = space_display_id(sid)
    if spaceDid != did { return .sameDisplay }

    return scripting_addition_focus_space(sid) ? .success : .scriptingAdditionFailed
}

/// `display_manager_begin`: reads the active display and registers the reconfiguration callback.
func display_manager_begin(_ dm: DisplayManager) -> Bool
{
    dm.current_display_id = display_manager_active_display_id()
    dm.last_display_id = dm.current_display_id
    dm.order = .default
    dm.mode = .off
    dm.top_padding = 0
    dm.bottom_padding = 0

    return CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil) == .success
}
