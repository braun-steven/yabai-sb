import ApplicationServices
import CPrivate
import AppKit

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
    var notification: UInt8 = 0
    var is_observing = false
    var is_hidden = false
    var ax_retry = false
}

extension Application: Equatable
{
    static func == (a: Application, b: Application) -> Bool { a === b }
}

// the notifications of application_observe, in the order of the bits of application->notification
private let axApplicationNotifications: [(name: String, text: String)] =
[
    (kAXCreatedNotification,              "kAXCreatedNotification"),
    (kAXFocusedWindowChangedNotification, "kAXFocusedWindowChangedNotification"),
    (kAXWindowMovedNotification,          "kAXWindowMovedNotification"),
    (kAXWindowResizedNotification,        "kAXWindowResizedNotification"),
    (kAXTitleChangedNotification,         "kAXTitleChangedNotification"),
    (kAXMenuOpenedNotification,           "kAXMenuOpenedNotification"),
    (kAXMenuClosedNotification,           "kAXMenuClosedNotification"),
]

// AX_APPLICATION_ALL (application.h, which Swift does not import): the window notifications, not the menu ones
private let axApplicationAll: UInt8 = 0b11111

//
// NOTE: The callback of the observer of each application. It runs on the main run loop and only posts events. Its
// context is the application (unretained) for the notifications of application_observe, and the window for those of
// window_observe (Window.swift), which uses the same observer. Both belong to the window manager: the event loop removes
// the notifications (application_unobserve, window_unobserve) before it releases them. A window can be destroyed while
// its events are queued (they keep it alive), so WINDOW_DESTROYED is posted only by the caller whose window_invalidate
// succeeds; the handlers check window_is_valid before they use a window.
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
        EventLoop.post(.windowMoved(windowID: ax_window_id(element)))
    case kAXWindowResizedNotification:
        EventLoop.post(.windowResized(windowID: ax_window_id(element)))
    case kAXTitleChangedNotification:
        EventLoop.post(.windowTitleChanged(windowID: ax_window_id(element)))
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

        if !window_invalidate(target) { return }

        EventLoop.post(.windowDestroyed(Handoff(value: target)))
    default:
        break
    }
}

/// `application_observe`: true if every notification of AX_APPLICATION_ALL is registered. Sets ax_retry when the
/// application did not answer in time.
func application_observe(_ target: Application) -> Bool
{
    var observerRef: AXObserver?
    if AXObserverCreate(target.pid, applicationNotificationHandler, &observerRef) == .success, let observerRef {
        target.observer_ref = observerRef

        for (i, notification) in axApplicationNotifications.enumerated() {
            let result = AXObserverAddNotification(observerRef, target.ref, notification.name as CFString, Unmanaged.passUnretained(target).toOpaque())
            if result == .success || result == .notificationAlreadyRegistered {
                target.notification |= UInt8(1 << i)
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

    return (target.notification & axApplicationAll) == axApplicationAll
}

/// `application_unobserve`
func application_unobserve(_ target: Application)
{
    guard target.is_observing else { return }

    let observerRef = target.observer_ref!

    for (i, notification) in axApplicationNotifications.enumerated() {
        if target.notification & UInt8(1 << i) == 0 { continue }

        AXObserverRemoveNotification(observerRef, target.ref, notification.name as CFString)
        target.notification &= ~UInt8(1 << i)
    }

    target.is_observing = false
    CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observerRef))
    target.observer_ref = nil
}

/// `application_focused_window`: the id of the focused window of the application, or 0.
func application_focused_window(_ target: Application) -> UInt32
{
    var windowRef: CFTypeRef?
    AXUIElementCopyAttributeValue(target.ref, kAXFocusedWindowAttribute as CFString, &windowRef)
    guard let windowRef else { return 0 }

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
