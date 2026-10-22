import ApplicationServices
import CPrivate
import AppKit
import YabaiCore
import Logging

// NOTE: An application that yabai observes, a thin wrapper of its AX element and observer.
@WM final class Application
{
    var ref: AXUIElement!
    var connection: Int32 = 0
    var psn = ProcessSerialNumber()
    var pid: pid_t = 0
    var name = ""
    var icon: CGImage?
    var observerRef: AXObserver!
    var notifications: ApplicationNotifications = []
    var isObserving = false
    var isHidden = false
    var axRetry = false

    init() {}

    init(process: Process)
    {
        ref = AXUIElement.application(process.pid)
        psn = process.psn
        pid = process.pid
        name = process.name
        isHidden = !ProcessIsVisibleC(psn)

        connection = SLS.connectionID(SLS.connection, forProcess: psn) ?? 0
    }

    /// The AX notifications that `observe()` registered for this application.
    func observe() -> Bool
    {
        if let observer = AXObserver.create(pid: pid, callback: applicationNotificationHandler) {
            observerRef = observer

            for notification in axApplicationNotifications {
                let result = observer.add(notification.name, for: ref, context: Unmanaged.passUnretained(self).toOpaque())
                if result == .success || result == .notificationAlreadyRegistered {
                    notifications.insert(notification.notification)
                } else {
                    Logger.processes.debug("\(name): observing \(notification.text) failed with \(result.name)")

                    // NOTE: Once an application times out, each remaining AX notification would wait for the same timeout.
                    if result == .cannotComplete {
                        axRetry = true
                        break
                    }
                }
            }

            isObserving = true
            CFRunLoopAddSource(CFRunLoopGetMain(), observer.runLoopSource, .defaultMode)
        }

        return notifications.isSuperset(of: .required)
    }

    func unobserve()
    {
        guard isObserving else { return }

        let observer = observerRef!
        for notification in axApplicationNotifications where notifications.contains(notification.notification) {
            observer.remove(notification.name, for: ref)
            notifications.remove(notification.notification)
        }

        isObserving = false
        CFRunLoopSourceInvalidate(observer.runLoopSource)
        observerRef = nil
    }

    /// The id of this application's focused window, or nil.
    var focusedWindowID: WindowID?
    {
        return ref.elementAttribute(kAXFocusedWindowAttribute)?.windowID
    }

    var isFrontmost: Bool
    {
        let processSerialNumber = SLS.frontProcess()
        return processSerialNumber.isSame(as: psn)
    }

    /// The AX windows of this application, or nil.
    var windowList: CFArray?
    {
        return ref.arrayAttribute(kAXWindowsAttribute)
    }

    // NOTE: Keep the AX element and icon (which tab bars set) until `destroy()`.
    func destroy()
    {
        ref = nil
        icon = nil
    }
}

extension Application: Hashable
{
    nonisolated static func == (a: Application, b: Application) -> Bool { a === b }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The AX notifications that an application can observe.
struct ApplicationNotifications: OptionSet, Sendable
{
    let rawValue: UInt8

    static let created              = ApplicationNotifications(rawValue: 1 << 0)
    static let focusedWindowChanged = ApplicationNotifications(rawValue: 1 << 1)
    static let windowMoved          = ApplicationNotifications(rawValue: 1 << 2)
    static let windowResized        = ApplicationNotifications(rawValue: 1 << 3)
    static let titleChanged         = ApplicationNotifications(rawValue: 1 << 4)
    static let menuOpened           = ApplicationNotifications(rawValue: 1 << 5)
    static let menuClosed           = ApplicationNotifications(rawValue: 1 << 6)

    /// The window notifications required for application observation; menu notifications are optional.
    static let required: ApplicationNotifications = [.created, .focusedWindowChanged, .windowMoved, .windowResized, .titleChanged]
}

private let axApplicationNotifications: [(notification: ApplicationNotifications, name: String, text: String)] =
[
    (.created,              kAXCreatedNotification,              "kAXCreatedNotification"),
    (.focusedWindowChanged, kAXFocusedWindowChangedNotification, "kAXFocusedWindowChangedNotification"),
    (.windowMoved,          kAXWindowMovedNotification,          "kAXWindowMovedNotification"),
    (.windowResized,        kAXWindowResizedNotification,        "kAXWindowResizedNotification"),
    (.titleChanged,         kAXTitleChangedNotification,         "kAXTitleChangedNotification"),
    (.menuOpened,           kAXMenuOpenedNotification,           "kAXMenuOpenedNotification"),
    (.menuClosed,           kAXMenuClosedNotification,           "kAXMenuClosedNotification"),
]

// NOTE: The callback runs on the main run loop and only posts events, on the main thread it never touches a window.
// The context is the application (unretained) for application notifications, which do not read it, and the window id
// for those of Window.observe(), which uses the same observer. An id is no pointer, so a callback that runs after its
// window is gone only posts the id: the handlers on @WM look the window up and ignore it when it is missing. The
// handler of `.windowDestroyed` invalidates the window on @WM before it tears the window down, so a window destroyed
// twice (or destroyed after its application terminated) is torn down once.
private func applicationNotificationHandler(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?)
{
    switch notification as String {
    case kAXCreatedNotification:
        EventLoop.post(.windowCreated(Handoff(value: Unmanaged.passRetained(element))))
    case kAXFocusedWindowChangedNotification:
        pendingWindowFocus.store(true, ordering: .releasing)
        EventLoop.post(.windowFocused(windowID: element.windowID))
    case kAXWindowMovedNotification:
        if let windowID = element.windowID { EventLoop.post(.windowMoved(windowID: windowID)) }
    case kAXWindowResizedNotification:
        if let windowID = element.windowID { EventLoop.post(.windowResized(windowID: windowID)) }
    case kAXTitleChangedNotification:
        if let windowID = element.windowID { EventLoop.post(.windowTitleChanged(windowID: windowID)) }
    case kAXMenuOpenedNotification:
        EventLoop.post(.menuOpened(windowID: element.windowID))
    case kAXMenuClosedNotification:
        EventLoop.post(.menuClosed)
    case kAXWindowMiniaturizedNotification:
        if let windowID = WindowID(notificationContext: context) { EventLoop.post(.windowMinimized(windowID: windowID)) }
    case kAXWindowDeminiaturizedNotification:
        if let windowID = WindowID(notificationContext: context) { EventLoop.post(.windowDeminimized(windowID: windowID)) }
    case kAXUIElementDestroyedNotification:
        if let windowID = WindowID(notificationContext: context) { EventLoop.post(.windowDestroyed(windowID: windowID)) }
    default:
        break
    }
}
