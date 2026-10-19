import ApplicationServices
import CPrivate
import Foundation
import Synchronization
import YabaiCore

//
// NOTE: The notifications of the window server connection and the Mission Control notifications of the Dock. Both
// callbacks run on the main thread and only post events (and move the borders, which Border.swift locks).
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

/// Registered for each notification type by Daemon.run.
func connectionNotificationHandler(_ type: UInt32, _ data: UnsafeMutableRawPointer?, _ dataLength: Int, _ context: UnsafeMutableRawPointer?, _ cid: Int32)
{
    switch type {
    case 1327:
        EventLoop.post(.slsSpaceCreated(spaceID: SpaceID(data!.loadUnaligned(as: UInt64.self))))
    case 1328:
        EventLoop.post(.slsSpaceDestroyed(spaceID: SpaceID(data!.loadUnaligned(as: UInt64.self))))
    case 808:
        let wid = data!.loadUnaligned(as: UInt32.self)
        Border.windowOrdered(WindowID(wid))
        EventLoop.post(.slsWindowOrdered(windowID: WindowID(wid)))
    case 804:
        let wid = data!.loadUnaligned(as: UInt32.self)
        Border.windowHidden(WindowID(wid))
        EventLoop.post(.slsWindowDestroyed(windowID: WindowID(wid)))
    case 806:
        Border.windowMoved(WindowID(data!.loadUnaligned(as: UInt32.self)))
    case 807:
        Border.windowResized(WindowID(data!.loadUnaligned(as: UInt32.self)))
    case 815:
        Border.windowChanged(WindowID(data!.loadUnaligned(as: UInt32.self)))
    case 816:
        Border.windowHidden(WindowID(data!.loadUnaligned(as: UInt32.self)))
    case 1202:
        lastCmdTabTime.store(OSTimer.now, ordering: .releasing)
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

private struct MissionControlState: @unchecked Sendable
{
    var mode = MissionControlMode.inactive
    var ref: AXUIElement?
    var observerRef: AXObserver?
    var isObserving = false
}

/// Mission Control: its mode, and the observer of the Mission Control notifications of the Dock.
final class MissionControl: @unchecked Sendable
{
    // NOTE: Daemon.run calls observe() during startup; yabai.wm reads and changes mode and reattaches the Dock observer
    // after restarts. Those observer lifecycle calls are sequential. stateLock protects state and retained references
    // across those threads, but AX, Workspace, and CFRunLoop calls stay outside it to avoid callback reentrancy.
    // The AX callback only posts events.
    static let shared = MissionControl()

    private let stateLock = Mutex(MissionControlState())

    var mode: MissionControlMode
    {
        get { stateLock.withLock { $0.mode } }
        set { stateLock.withLock { $0.mode = newValue } }
    }

    var isActive: Bool { mode != .inactive }

    func observe()
    {
        let alreadyObserving = stateLock.withLock { $0.isObserving }
        guard !alreadyObserving, let pid = Workspace.dockPID else { return }

        let ref = AXUIElement.application(pid)
        guard let observerRef = AXObserver.create(pid: pid, callback: missionControlNotificationHandler) else { return }

        for notification in Expose.all {
            observerRef.add(notification, for: ref, context: nil)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), observerRef.runLoopSource, .defaultMode)

        stateLock.withLock { state in
            state.ref = ref
            state.observerRef = observerRef
            state.isObserving = true
        }
    }

    func unobserve()
    {
        let observer = stateLock.withLock { state -> (AXObserver, AXUIElement)? in
            guard state.isObserving, let observerRef = state.observerRef, let ref = state.ref else { return nil }

            state.isObserving = false
            state.observerRef = nil
            state.ref = nil
            return (observerRef, ref)
        }
        guard let (observerRef, ref) = observer else { return }

        for notification in Expose.all {
            observerRef.remove(notification, for: ref)
        }

        CFRunLoopSourceInvalidate(observerRef.runLoopSource)
    }
}
