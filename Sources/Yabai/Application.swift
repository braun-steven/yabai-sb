import ApplicationServices
import CPrivate
import AppKit
import YabaiCore

// NOTE: An application that yabai observes, a thin wrapper of its AX element and observer.
final class Application
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
        ref = AXUIElementCreateApplication(process.pid)
        psn = process.psn
        pid = process.pid
        name = process.name
        isHidden = !ProcessIsVisibleC(psn)

        var processSerialNumber = psn
        SLSGetConnectionIDForPSN(SLS.connection, &processSerialNumber, &connection)
    }

    /// The AX notifications that `observe()` registered for this application.
    func observe() -> Bool
    {
        var observer: AXObserver?
        if AXObserverCreate(pid, applicationNotificationHandler, &observer) == .success, let observer {
            observerRef = observer

            for notification in axApplicationNotifications {
                let result = AXObserverAddNotification(observer, ref, notification.name as CFString, Unmanaged.passUnretained(self).toOpaque())
                if result == .success || result == .notificationAlreadyRegistered {
                    notifications.insert(notification.notification)
                } else {
                    debug("application_observe: error '\(axErrorName(result))' for application '\(name)' and notification '\(notification.text)'\n")

                    // NOTE: Once an application times out, each remaining AX notification would wait for the same timeout.
                    if result == .cannotComplete {
                        axRetry = true
                        break
                    }
                }
            }

            isObserving = true
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }

        return notifications.isSuperset(of: .required)
    }

    func unobserve()
    {
        guard isObserving else { return }

        let observer = observerRef!
        for notification in axApplicationNotifications where notifications.contains(notification.notification) {
            AXObserverRemoveNotification(observer, ref, notification.name as CFString)
            notifications.remove(notification.notification)
        }

        isObserving = false
        CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observer))
        observerRef = nil
    }

    /// The id of this application's focused window, or nil.
    var focusedWindowID: WindowID?
    {
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let windowRef else { return nil }

        return unsafeDowncast(windowRef, to: AXUIElement.self).windowID
    }

    var isFrontmost: Bool
    {
        let processSerialNumber = SLS.frontProcess()
        return processSerialNumber.isSame(as: psn)
    }

    /// The AX windows of this application, or nil.
    var windowList: CFArray?
    {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXWindowsAttribute as CFString, &value)
        guard let value else { return nil }

        return unsafeDowncast(value, to: CFArray.self)
    }

    // NOTE: Keep the AX element and icon (which tab bars set) until `destroy()`.
    func destroy()
    {
        ref = nil
        icon = nil
    }
}

extension Application: Equatable
{
    static func == (a: Application, b: Application) -> Bool { a === b }
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

// NOTE: The callback runs on the main run loop and only posts events. Its context is the application (unretained) for
// application notifications, and the window for those of Window.observe(), which uses the same observer. Both belong
// to the window manager: the event loop removes notifications before releasing them. A window can be destroyed while
// its events are queued (they keep it alive), so `.windowDestroyed` is posted only by the caller whose invalidate()
// succeeds; the handlers check isValid before using a window.
private func applicationNotificationHandler(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?)
{
    switch notification as String {
    case kAXCreatedNotification:
        EventLoop.post(.windowCreated(Handoff(value: Unmanaged.passRetained(element))))
    case kAXFocusedWindowChangedNotification:
        pending_window_focus_set(true)
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
        EventLoop.post(.windowMinimized(Handoff(value: Unmanaged<Window>.fromOpaque(context!).takeUnretainedValue())))
    case kAXWindowDeminiaturizedNotification:
        EventLoop.post(.windowDeminimized(Handoff(value: Unmanaged<Window>.fromOpaque(context!).takeUnretainedValue())))
    case kAXUIElementDestroyedNotification:
        let target = Unmanaged<Window>.fromOpaque(context!).takeUnretainedValue()

        // NOTE: Ignore queued events after invalidation; only the caller that invalidates the window posts destruction.
        if !target.invalidate() { return }

        EventLoop.post(.windowDestroyed(Handoff(value: target)))
    default:
        break
    }
}
