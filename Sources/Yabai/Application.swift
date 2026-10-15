import ApplicationServices
import CPrivate
import YabaiC

//
// NOTE: An application that yabai observes, a thin wrapper of its AX element and AX observer. struct application stays
// C while window*.c reads it. Ported from src/application.c.
//

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
// context is the struct application for the notifications of application_observe, and the struct window for those of
// window_observe (window.c), which uses the same observer. Both belong to the window manager: the event loop removes
// the notifications (application_unobserve, window_unobserve) before it frees them. A window can be destroyed while
// its events are queued, so WINDOW_DESTROYED is posted only by the caller whose window_invalidate succeeds; the
// handlers check window_is_valid before they use a window.
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
        EventLoop.post(.windowMinimized(Handoff(value: context!.assumingMemoryBound(to: window.self))))
    case kAXWindowDeminiaturizedNotification:
        EventLoop.post(.windowDeminimized(Handoff(value: context!.assumingMemoryBound(to: window.self))))
    case kAXUIElementDestroyedNotification:
        let target = context!.assumingMemoryBound(to: window.self)

        //
        // NOTE(asmvik): Flag events that are already queued, but not yet processed,
        // so that they will be ignored; the memory we allocated is still valid and will
        // be freed when this event is handled.
        //

        if !window_invalidate(target) { return }

        EventLoop.post(.windowDestroyed(Handoff(value: target)))
    default:
        break
    }
}

/// `application_observe`: true if every notification of AX_APPLICATION_ALL is registered. Sets ax_retry when the
/// application did not answer in time.
@_cdecl("application_observe")
func application_observe(_ target: UnsafeMutablePointer<application>) -> Bool
{
    var observerRef: AXObserver?
    if AXObserverCreate(target.pointee.pid, applicationNotificationHandler, &observerRef) == .success, let observerRef {
        target.pointee.observer_ref = Unmanaged.passRetained(observerRef)

        for (i, notification) in axApplicationNotifications.enumerated() {
            let result = AXObserverAddNotification(observerRef, target.pointee.ref.takeUnretainedValue(), notification.name as CFString, UnsafeMutableRawPointer(target))
            if result == .success || result == .notificationAlreadyRegistered {
                target.pointee.notification |= UInt8(1 << i)
            } else {
                debug("application_observe: error '\(axErrorName(result))' for application '\(cName(target.pointee.name))' and notification '\(notification.text)'\n")

                //
                // NOTE: The application did not respond within the accessibility timeout. Every other
                // notification would wait for the timeout as well, and the attempt has failed already.
                //

                if result == .cannotComplete {
                    target.pointee.ax_retry = true
                    break
                }
            }
        }

        target.pointee.is_observing = true
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observerRef), .defaultMode)
    }

    return (target.pointee.notification & axApplicationAll) == axApplicationAll
}

/// `application_unobserve`
@_cdecl("application_unobserve")
func application_unobserve(_ target: UnsafeMutablePointer<application>)
{
    guard target.pointee.is_observing else { return }

    let observerRef = target.pointee.observer_ref.takeUnretainedValue()

    for (i, notification) in axApplicationNotifications.enumerated() {
        if target.pointee.notification & UInt8(1 << i) == 0 { continue }

        AXObserverRemoveNotification(observerRef, target.pointee.ref.takeUnretainedValue(), notification.name as CFString)
        target.pointee.notification &= ~UInt8(1 << i)
    }

    target.pointee.is_observing = false
    CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observerRef))
    target.pointee.observer_ref.release()
}

/// `application_focused_window`: the id of the focused window of the application, or 0.
@_cdecl("application_focused_window")
func application_focused_window(_ target: UnsafeMutablePointer<application>) -> UInt32
{
    var windowRef: CFTypeRef?
    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXFocusedWindowAttribute as CFString, &windowRef)
    guard let windowRef else { return 0 }

    return ax_window_id(unsafeDowncast(windowRef, to: AXUIElement.self))
}

/// `application_is_frontmost`
func application_is_frontmost(_ target: UnsafeMutablePointer<application>) -> Bool
{
    var psn = SLS.frontProcess()
    return psn_equals(&psn, &target.pointee.psn)
}

/// `application_is_hidden`
func application_is_hidden(_ target: UnsafeMutablePointer<application>) -> Bool
{
    return !ProcessIsVisibleC(target.pointee.psn)
}

/// `application_window_list`: the AX windows of the application at +1 (the prototype is CF_RETURNS_RETAINED), or NULL.
@_cdecl("application_window_list")
func applicationWindowListRetained(_ target: UnsafeMutablePointer<application>) -> Unmanaged<CFArray>?
{
    var windowList: CFTypeRef?
    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXWindowsAttribute as CFString, &windowList)
    guard let windowList else { return nil }

    return Unmanaged.passRetained(unsafeDowncast(windowList, to: CFArray.self))
}

//
// NOTE: The struct holds ref (and icon, which tab_bar.c sets) at +1 until application_destroy. name is the name of the
// process, which the process owns.
//

/// `application_create`
@_cdecl("application_create")
func application_create(_ process: UnsafeMutablePointer<process>) -> UnsafeMutablePointer<application>
{
    let result = calloc(1, MemoryLayout<application>.size)!.bindMemory(to: application.self, capacity: 1)

    result.pointee.ref = Unmanaged.passRetained(AXUIElementCreateApplication(process.pointee.pid))
    result.pointee.psn = process.pointee.psn
    result.pointee.pid = process.pointee.pid
    result.pointee.name = process.pointee.name
    result.pointee.is_hidden = application_is_hidden(result)

    var psn = result.pointee.psn
    var connection: Int32 = 0
    SLSGetConnectionIDForPSN(connection_global(), &psn, &connection)
    result.pointee.connection = connection

    return result
}

/// `application_destroy`
@_cdecl("application_destroy")
func application_destroy(_ target: UnsafeMutablePointer<application>)
{
    target.pointee.ref.release()
    if let icon = target.pointee.icon { icon.release() }
    free(target)
}
