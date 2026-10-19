import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The displays of yabai: their arrangement (display_arrangement_order and builtin_display_last), the menu bar and
// the Dock that shrink their area, and the focus of a display.
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

//
// NOTE: The reconfiguration callback runs on a thread of the window server. It only posts events; the handlers change
// the state on the @WM queue (see EventLoop.swift).
//

/// Registered by `DisplayManager.begin()`.
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

final class DisplayManager
{
    var currentDisplayID: DisplayID?
    var lastDisplayID: DisplayID?

    var topPadding: Int = 0
    var bottomPadding: Int = 0

    var order = DisplayArrangementOrder.default
    var builtinDisplayLast = false
    var mode = ExternalBarMode.off

    var labels = LabelList<DisplayID>()

    //
    // NOTE: The managers' shared instances are created before the event loop starts. The event loop owns them; producers
    // on other threads read only what the NOTEs at their reads name.
    //
    nonisolated(unsafe) static let shared = DisplayManager()

    /// Reads the active display and registers the reconfiguration callback.
    func begin() -> Bool
    {
        currentDisplayID = DisplayID.active
        lastDisplayID = currentDisplayID
        order = .default
        mode = .off
        topPadding = 0
        bottomPadding = 0

        return CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil) == .success
    }

    /// The display spaces of the window server, with builtin_display_last applied.
    var managedDisplaySpaces: [NSDictionary]
    {
        return orderedBuiltinLast(SLS.managedDisplaySpaces(SLS.connection), displaySpaces: true)
    }

    //
    // NOTE: The uuids of all displays in the order of their arrangement index (display_arrangement_order,
    // then builtin_display_last).
    //

    /// The uuids of all displays in arrangement order; nil when the window server does not list the displays.
    var arrangedDisplays: [String]?
    {
        guard let displays = SLS.managedDisplays(SLS.connection) else { return nil }

        let count = CFArrayGetCount(displays)
        let order = self.order

        var sorted = displays
        if count > 0 && order != .default {
            let mutable = CFArrayCreateMutableCopy(nil, count, displays)!
            CFArraySortValues(mutable, CFRangeMake(0, count), displayCoordinateComparator, UnsafeMutableRawPointer(bitPattern: order == .vertical ? 1 : 0))
            sorted = mutable as CFArray
        }

        return orderedBuiltinLast((sorted as NSArray as? [String]) ?? [], displaySpaces: false)
    }

    /// The uuid of the display at an arrangement index (1-based).
    func arrangedDisplayUUID(_ arrangement: Int) -> String?
    {
        guard let displays = arrangedDisplays else { return nil }

        let index = arrangement - 1
        guard index >= 0 && index < displays.count else { return nil }

        return displays[index]
    }

    /// Moves the first builtin display of a list to its end, when builtin_display_last is set. displaySpaces reads the uuid
    /// from the "Display Identifier" of each dictionary of the list.
    private func orderedBuiltinLast<T>(_ list: [T], displaySpaces: Bool) -> [T]
    {
        if !builtinDisplayLast { return list }

        for i in 0..<max(list.count - 1, 0) {
            let item = list[i]
            let uuid: Any? = displaySpaces ? (item as? NSDictionary)?["Display Identifier"] : (item as Any)
            if !DisplayManager.isBuiltin(uuid: uuid) { continue }

            var result = list
            result.remove(at: i)
            result.append(item)
            return result
        }

        return list
    }

    /// Whether a uuid names a builtin display.
    private static func isBuiltin(uuid value: Any?) -> Bool
    {
        guard let uuid = value as? String else { return false }

        guard let did = DisplayID(uuid: uuid) else { return false }
        return CGDisplayIsBuiltin(did.rawValue) != 0
    }

    var isMenuBarHidden: Bool
    {
        return SLS.menuBarAutohideEnabled(SLS.connection)
    }

    var isDockHidden: Bool
    {
        return CoreDock.autoHideEnabled
    }

    var dockOrientation: DockOrientation?
    {
        return DockOrientation(rawValue: CoreDock.orientationAndPinning.orientation)
    }

    var dockRect: CGRect
    {
        return SLS.dockRect(SLS.connection)
    }

    /// Focuses the window under a point; returns its id, or nil.
    @discardableResult
    func focusWindow(at point: CGPoint) -> WindowID?
    {
        guard let elementRef = element(at: point) else { return nil }

        guard let elementID = elementRef.windowID else { return nil }

        var elementPSN = SLS.connectionPSN(SLS.windowOwner(SLS.connection, elementID) ?? 0)
        WindowManager.shared.focusWithRaise(process: &elementPSN, windowID: elementID, reference: elementRef)

        return elementID
    }

    /// The window under a point, found through the accessibility element at it.
    private func element(at point: CGPoint) -> AXUIElement?
    {
        guard let elementRef = WindowManager.shared.systemElement!.element(at: point) else { return nil }
        guard let role = elementRef.attribute(kAXRoleAttribute) else { return nil }

        if CFEqual(role, kAXWindowRole as CFString) { return elementRef }

        return elementRef.elementAttribute(kAXWindowAttribute)
    }
}

//
// NOTE: The order of display_arrangement_order compares the centers of two displays on the axis of the order, then on the
// other axis. The context of the comparator is 1 for the vertical order and 0 for the horizontal one.
//

private let displayCoordinateComparator: CFComparatorFunction = { a, b, context in
    let byY = context != nil

    let aCenter = DisplayID(uuid: Unmanaged<CFString>.fromOpaque(a!).takeUnretainedValue() as String)?.center ?? .zero
    let bCenter = DisplayID(uuid: Unmanaged<CFString>.fromOpaque(b!).takeUnretainedValue() as String)?.center ?? .zero

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
