import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore
import Logging

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

@WM final class DisplayManager
{
    var currentDisplayID: DisplayID?
    var lastDisplayID: DisplayID?

    var labels = LabelList<DisplayID>()

    //
    // NOTE: The space and display lists are read often (SpaceID.all for every Mission Control index, and every display
    // arrangement index), and each read is a window server call. They are cached on the event loop: the handlers of the
    // space and display events, the Mission Control exit, every space operation and each space layout pass invalidate
    // them (`invalidateSpaceCaches`), and the lifetime bounds a change that was not reported.
    //
    private var managedDisplaySpacesCache = Cached<[[SpaceID]]>(lifetime: .seconds(2))
    private var arrangedDisplaysCache = Cached<[String]>(lifetime: .seconds(2))

    //
    // NOTE: The managers are @WM: the event loop owns their state, and producers on other threads read only what the
    // NOTEs at their reads name (atomics, immutable ids). shared of DisplayManager and ProcessManager is nonisolated so
    // that Daemon.run can call their nonisolated begin() on the main thread; begin() still changes the state through
    // WM.sync.
    //
    nonisolated static let shared = DisplayManager()

    /// Called by Daemon.run on the main thread: reads the active display on the event loop's queue, then registers
    /// the reconfiguration callback, which posts events to the event loop.
    nonisolated func begin() -> Bool
    {
        WM.sync {
            let manager = DisplayManager.shared
            manager.currentDisplayID = DisplayID.active
            manager.lastDisplayID = manager.currentDisplayID
        }

        return CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil) == .success
    }

    //
    // NOTE: The spaces of each display, in the order of the window server with builtin_display_last applied. The cache
    // keeps the space ids rather than the window server's dictionaries, because the cached values must be Sendable: the
    // default values of the stored properties are checked as nonisolated (DisplayManager.shared is nonisolated), and a
    // non-Sendable default fails to compile.
    //

    /// The spaces of each display (cached, see `invalidateSpaceCaches`). A display without spaces, or with an id that is
    /// not a space, contributes nothing.
    var managedDisplaySpaces: [[SpaceID]]
    {
        let now = ContinuousClock.now
        if let cached = managedDisplaySpacesCache.value(at: now) { return cached }

        Logger.spaces.debug("managed display spaces: cache miss")
        let displays = DisplayManager.orderedBuiltinLast(SLS.managedDisplaySpaces(SLS.connection), enabled: Config.current.display.builtinDisplayLast) {
            DisplayManager.isBuiltin(uuid: $0["Display Identifier"])
        }

        let fresh = displays.map { display -> [SpaceID] in
            guard let spaces = display["Spaces"] as? [NSDictionary] else { return [] }

            return spaces.compactMap { space in
                (space["id64"] as? NSNumber).flatMap { SpaceID(nonzero: $0.uint64Value) }
            }
        }

        managedDisplaySpacesCache.store(fresh, at: now)
        return fresh
    }

    /// Drops the cached space and display lists, so that the next read asks the window server. Called by the handlers of
    /// the space and display events and of the Mission Control exit, after the operations that change spaces or displays,
    /// before each space layout pass, and when a display config option that orders the lists changes.
    func invalidateSpaceCaches()
    {
        managedDisplaySpacesCache.invalidate()
        arrangedDisplaysCache.invalidate()
    }

    //
    // NOTE: The uuids of all displays in the order of their arrangement index (display_arrangement_order,
    // then builtin_display_last).
    //

    /// The uuids of all displays in arrangement order; nil when the window server does not list the displays (cached, see
    /// `invalidateSpaceCaches`; a failed read is not cached).
    var arrangedDisplays: [String]?
    {
        let now = ContinuousClock.now
        if let cached = arrangedDisplaysCache.value(at: now) { return cached }

        guard let fresh = DisplayManager.queryArrangedDisplays() else { return nil }

        Logger.spaces.debug("arranged displays: cache miss, \(fresh.count) display(s)")
        arrangedDisplaysCache.store(fresh, at: now)
        return fresh
    }

    /// The uuids of all displays from the window server, sorted by display_arrangement_order and then moved by
    /// builtin_display_last.
    private static func queryArrangedDisplays() -> [String]?
    {
        guard let displays = SLS.managedDisplays(SLS.connection) else { return nil }

        let uuids = (displays as NSArray as? [String]) ?? []
        let order = Config.current.display.order

        var sorted = uuids
        if order != .default {
            let placements = uuids.map { uuid in
                DisplayArrangement.Placement(uuid: uuid, center: DisplayID(uuid: uuid)?.center ?? .zero)
            }
            sorted = DisplayArrangement.sorted(placements, vertical: order == .vertical)
        }

        return DisplayManager.orderedBuiltinLast(sorted, enabled: Config.current.display.builtinDisplayLast) {
            DisplayManager.isBuiltin(uuid: $0)
        }
    }

    /// The uuid of the display at an arrangement index (1-based).
    func arrangedDisplayUUID(_ arrangement: Int) -> String?
    {
        guard let displays = arrangedDisplays else { return nil }

        let index = arrangement - 1
        guard index >= 0 && index < displays.count else { return nil }

        return displays[index]
    }

    /// Moves the first builtin display of a list to its end when enabled (builtin_display_last); isBuiltin tells
    /// whether an item of the list is a builtin display.
    nonisolated static func orderedBuiltinLast<T>(_ list: [T], enabled: Bool, isBuiltin: (T) -> Bool) -> [T]
    {
        if !enabled { return list }

        for i in 0..<max(list.count - 1, 0) where isBuiltin(list[i]) {
            var result = list
            result.append(result.remove(at: i))
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

        let elementPSN = SLS.connectionPSN(SLS.windowOwner(SLS.connection, elementID) ?? 0)
        WindowManager.shared.focusWithRaise(process: elementPSN, windowID: elementID, reference: elementRef)

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
