import ApplicationServices
import CPrivate
import AppKit
import YabaiCore

//
// NOTE: An application that yabai observes, a thin wrapper of its AX element and AX observer. Ported from
// src/application.c.
//

/// `struct application`: name is the name of the process. The tab bars load icon.
final class Application
{
    var ref: AXUIElement!
    var connection: Int32 = 0
    var psn = ProcessSerialNumber()
    var pid: pid_t = 0
    var name = ""
    var icon: CGImage?
    var observer_ref: AXObserver!
    var notifications: ApplicationNotifications = []
    var is_observing = false
    var is_hidden = false
    var ax_retry = false
}

extension Application: Equatable
{
    static func == (a: Application, b: Application) -> Bool { a === b }
}

/// The AX notifications that application_observe registered for an application.
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

    /// The window notifications, which application_observe needs; the menu ones are optional.
    static let required: ApplicationNotifications = [.created, .focusedWindowChanged, .windowMoved, .windowResized, .titleChanged]
}

// the notifications of application_observe, with their names for the debug output
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

//
// NOTE: The callback of the observer of each application. It runs on the main run loop and only posts events. Its
// context is the application (unretained) for the notifications of application_observe, and the window for those of
// Window.observe(), which uses the same observer. Both belong to the window manager: the event loop removes the
// notifications (application.unobserve(), window.unobserve()) before it releases them. A window can be destroyed while
// its events are queued (they keep it alive), so WINDOW_DESTROYED is posted only by the caller whose invalidate()
// succeeds; the handlers check isValid before they use a window.
//

private func applicationNotificationHandler(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?)
{
    switch notification as String {
    case kAXCreatedNotification:
        EventLoop.post(.windowCreated(Handoff(value: Unmanaged.passRetained(element))))
    case kAXFocusedWindowChangedNotification:
        pending_window_focus_set(true)
        EventLoop.post(.windowFocused(windowID: ax_window_id(element)))
    case kAXWindowMovedNotification:
        if let windowID = ax_window_id(element) { EventLoop.post(.windowMoved(windowID: windowID)) }
    case kAXWindowResizedNotification:
        if let windowID = ax_window_id(element) { EventLoop.post(.windowResized(windowID: windowID)) }
    case kAXTitleChangedNotification:
        if let windowID = ax_window_id(element) { EventLoop.post(.windowTitleChanged(windowID: windowID)) }
    case kAXMenuOpenedNotification:
        EventLoop.post(.menuOpened(windowID: ax_window_id(element)))
    case kAXMenuClosedNotification:
        EventLoop.post(.menuClosed)
    case kAXWindowMiniaturizedNotification:
        EventLoop.post(.windowMinimized(Handoff(value: Unmanaged<Window>.fromOpaque(context!).takeUnretainedValue())))
    case kAXWindowDeminiaturizedNotification:
        EventLoop.post(.windowDeminimized(Handoff(value: Unmanaged<Window>.fromOpaque(context!).takeUnretainedValue())))
    case kAXUIElementDestroyedNotification:
        let target = Unmanaged<Window>.fromOpaque(context!).takeUnretainedValue()

        //
        // NOTE(asmvik): Flag events that are already queued, but not yet processed,
        // so that they will be ignored; the window stays alive until this event
        // is handled.
        //

        if !target.invalidate() { return }

        EventLoop.post(.windowDestroyed(Handoff(value: target)))
    default:
        break
    }
}

/// `application_observe`: true if every notification of ApplicationNotifications.required is registered. Sets ax_retry when the
/// application did not answer in time.
func application_observe(_ target: Application) -> Bool
{
    var observerRef: AXObserver?
    if AXObserverCreate(target.pid, applicationNotificationHandler, &observerRef) == .success, let observerRef {
        target.observer_ref = observerRef

        for notification in axApplicationNotifications {
            let result = AXObserverAddNotification(observerRef, target.ref, notification.name as CFString, Unmanaged.passUnretained(target).toOpaque())
            if result == .success || result == .notificationAlreadyRegistered {
                target.notifications.insert(notification.notification)
            } else {
                debug("application_observe: error '\(axErrorName(result))' for application '\(target.name)' and notification '\(notification.text)'\n")

                //
                // NOTE: The application did not respond within the accessibility timeout. Every other
                // notification would wait for the timeout as well, and the attempt has failed already.
                //

                if result == .cannotComplete {
                    target.ax_retry = true
                    break
                }
            }
        }

        target.is_observing = true
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observerRef), .defaultMode)
    }

    return target.notifications.isSuperset(of: .required)
}

/// `application_unobserve`
func application_unobserve(_ target: Application)
{
    guard target.is_observing else { return }

    let observerRef = target.observer_ref!

    for notification in axApplicationNotifications where target.notifications.contains(notification.notification) {
        AXObserverRemoveNotification(observerRef, target.ref, notification.name as CFString)
        target.notifications.remove(notification.notification)
    }

    target.is_observing = false
    CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observerRef))
    target.observer_ref = nil
}

/// `application_focused_window`: the id of the focused window of the application, or nil.
func application_focused_window(_ target: Application) -> WindowID?
{
    var windowRef: CFTypeRef?
    AXUIElementCopyAttributeValue(target.ref, kAXFocusedWindowAttribute as CFString, &windowRef)
    guard let windowRef else { return nil }

    return ax_window_id(unsafeDowncast(windowRef, to: AXUIElement.self))
}

/// `application_is_frontmost`
func application_is_frontmost(_ target: Application) -> Bool
{
    var psn = SLS.frontProcess()
    return psn_equals(&psn, &target.psn)
}

/// `application_is_hidden`
func application_is_hidden(_ target: Application) -> Bool
{
    return !ProcessIsVisibleC(target.psn)
}

/// `application_window_list`: the AX windows of the application, or nil.
func application_window_list(_ target: Application) -> CFArray?
{
    var windowList: CFTypeRef?
    AXUIElementCopyAttributeValue(target.ref, kAXWindowsAttribute as CFString, &windowList)
    guard let windowList else { return nil }

    return unsafeDowncast(windowList, to: CFArray.self)
}

//
// NOTE: The application holds ref (and icon, which the tab bars set) until application_destroy.
//

/// `application_create`
func application_create(_ process: Process) -> Application
{
    let result = Application()

    result.ref = AXUIElementCreateApplication(process.pid)
    result.psn = process.psn
    result.pid = process.pid
    result.name = process.name
    result.is_hidden = application_is_hidden(result)

    var psn = result.psn
    var connection: Int32 = 0
    SLSGetConnectionIDForPSN(connection_global(), &psn, &connection)
    result.connection = connection

    return result
}

/// `application_destroy`
func application_destroy(_ target: Application)
{
    target.ref = nil
    target.icon = nil
}
