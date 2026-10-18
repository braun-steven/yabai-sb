import ApplicationServices
import CPrivate
import Foundation
import YabaiCore

//
// NOTE: The notifications of the window server connection and the Mission Control notifications of the Dock. Both
// callbacks run on the main thread and only post events (and move the borders, which Border.swift locks). Ported from
// src/mission_control.c and src/mission_control.h.
//

/// What Mission Control shows. The raw value is the context of the Mission Control signals.
enum MissionControlMode: Int, Sendable
{
    case inactive
    case show
    case showAllWindows
    case showFrontWindows
    case showDesktop

    /// The value of `YABAI_MISSION_CONTROL_MODE` in the signals.
    var name: String
    {
        switch self {
        case .inactive:         "inactive"
        case .show:             "show"
        case .showAllWindows:   "show-all-windows"
        case .showFrontWindows: "show-front-windows"
        case .showDesktop:      "show-desktop"
        }
    }
}

/// `g_mission_control_mode`: the handlers on the event loop own it, like the C global (see the NOTE of g_display_manager).
nonisolated(unsafe) var g_mission_control_mode = MissionControlMode.inactive

/// `mission_control_is_active`
func mission_control_is_active() -> Bool
{
    return g_mission_control_mode != .inactive
}

/// `connection_handler`: registered for each notification type by yabai_main.
func connection_handler(_ type: UInt32, _ data: UnsafeMutableRawPointer?, _ dataLength: Int, _ context: UnsafeMutableRawPointer?, _ cid: Int32)
{
    switch type {
    case 1327:
        EventLoop.post(.slsSpaceCreated(spaceID: SpaceID(data!.loadUnaligned(as: UInt64.self))))
    case 1328:
        EventLoop.post(.slsSpaceDestroyed(spaceID: SpaceID(data!.loadUnaligned(as: UInt64.self))))
    case 808:
        let wid = data!.loadUnaligned(as: UInt32.self)
        border_window_ordered(wid)
        EventLoop.post(.slsWindowOrdered(windowID: wid))
    case 804:
        let wid = data!.loadUnaligned(as: UInt32.self)
        border_window_hidden(wid)
        EventLoop.post(.slsWindowDestroyed(windowID: wid))
    case 806:
        border_window_moved(data!.loadUnaligned(as: UInt32.self))
    case 807:
        border_window_resized(data!.loadUnaligned(as: UInt32.self))
    case 815:
        border_window_changed(data!.loadUnaligned(as: UInt32.self))
    case 816:
        border_window_hidden(data!.loadUnaligned(as: UInt32.self))
    case 1202:
        lastCmdTabTime.store(read_os_timer(), ordering: .releasing)
    default:
        break
    }
}

private enum Expose
{
    static let showAllWindows   = "AXExposeShowAllWindows"
    static let showFrontWindows = "AXExposeShowFrontWindows"
    static let showDesktop      = "AXExposeShowDesktop"
    static let exit             = "AXExposeExit"

    static let all = [showAllWindows, showFrontWindows, showDesktop, exit]
}

private struct MissionControlObserver
{
    var ref: AXUIElement?
    var observerRef: AXObserver?
    var isObserving = false
}

//
// NOTE: nonisolated(unsafe): mission_control_observe runs in yabai_main before the event loop starts, and after that
// only the DOCK_DID_RESTART handler on the event loop changes the observer, as in the C version.
//

nonisolated(unsafe) private var missionControlObserver = MissionControlObserver()

private func missionControlNotificationHandler(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?)
{
    if CFEqual(notification, Expose.showAllWindows as CFString) {
        EventLoop.post(.missionControlShowAllWindows)
    } else if CFEqual(notification, Expose.showFrontWindows as CFString) {
        EventLoop.post(.missionControlShowFrontWindows)
    } else if CFEqual(notification, Expose.showDesktop as CFString) {
        EventLoop.post(.missionControlShowDesktop)
    } else if CFEqual(notification, Expose.exit as CFString) {
        EventLoop.post(.missionControlExit)
    }
}

/// `mission_control_observe`
func mission_control_observe()
{
    if missionControlObserver.isObserving { return }

    let pid = workspace_get_dock_pid()
    missionControlObserver.ref = AXUIElementCreateApplication(pid)

    guard pid != 0, let ref = missionControlObserver.ref else { return }

    var observerRef: AXObserver?
    guard AXObserverCreate(pid, missionControlNotificationHandler, &observerRef) == .success, let observerRef else { return }

    for notification in Expose.all {
        AXObserverAddNotification(observerRef, ref, notification as CFString, nil)
    }

    missionControlObserver.observerRef = observerRef
    missionControlObserver.isObserving = true
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observerRef), .defaultMode)
}

/// `mission_control_unobserve`
func missionControlUnobserve()
{
    guard missionControlObserver.isObserving, let observerRef = missionControlObserver.observerRef, let ref = missionControlObserver.ref else { return }

    for notification in Expose.all {
        AXObserverRemoveNotification(observerRef, ref, notification as CFString)
    }

    missionControlObserver.isObserving = false
    CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observerRef))
    missionControlObserver.observerRef = nil
    missionControlObserver.ref = nil
}
