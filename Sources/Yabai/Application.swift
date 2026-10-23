import AppKit
import ApplicationServices
import CPrivate
import Logging
import Synchronization
import YabaiCore

// NOTE: An application that yabai observes, a thin wrapper of its AX element and observer.
@WM final class Application {
  // NOTE: Stays an implicitly unwrapped optional: `init(process:)` sets it and `destroy()` clears it, and its readers
  // (window frame writes, `WindowFrameGroup` in the animations) need the element; none has an obvious
  // result for a missing element. `init()` leaves it nil until a test or `init(process:)` sets it.
  var ref: AXUIElement!
  /// The window server connection of the process; nil until the window server knows it.
  var connection: Int32?
  var psn = ProcessSerialNumber()
  var pid: pid_t = 0
  var name = ""
  /// The bundle identifier of the process, nil for a process without one. It is read from AppKit on first use and kept
  /// (`space --save-layout` is the reader); tests set it.
  var bundleID: String? {
    get {
      if !bundleIDIsRead {
        bundleIDValue = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleIDIsRead = true
      }
      return bundleIDValue
    }
    set {
      bundleIDValue = newValue
      bundleIDIsRead = true
    }
  }
  private var bundleIDIsRead = false
  private var bundleIDValue: String?
  var icon: CGImage?
  /// The AX observer of the application; nil until `observe()` creates one, and again after `unobserve()`.
  var observerRef: AXObserver?
  var notifications: ApplicationNotifications = []
  var isObserving = false
  var isHidden = false
  var axRetry = false

  init() {}

  init(process: Process) {
    ref = AXUIElement.application(process.pid)
    // NOTE: 0.5 s, half the 1 s of the system-wide element (WindowManager+Startup), so one call to a frozen application
    // stalls the event loop for 0.5 s. Window elements keep the system default.
    ref.setMessagingTimeout(0.5)
    psn = process.psn
    pid = process.pid
    name = process.name
    isHidden = !ProcessIsVisibleC(psn)

    connection = SLS.connectionID(SLS.connection, forProcess: psn)
  }

  /// The AX notifications that `observe()` registered for this application.
  func observe() -> Bool {
    if let observer = AXObserver.create(pid: pid, callback: applicationNotificationHandler) {
      observerRef = observer

      for notification in axApplicationNotifications {
        let result = observer.add(
          notification.name, for: ref, context: Unmanaged.passUnretained(self).toOpaque())
        if result == .success || result == .notificationAlreadyRegistered {
          notifications.insert(notification.notification)
        } else {
          Logger.processes.debug(
            "\(name): observing \(notification.text) failed with \(result.name)")

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

  func unobserve() {
    guard isObserving, let observer = observerRef else { return }

    for notification in axApplicationNotifications
    where notifications.contains(notification.notification) {
      observer.remove(notification.name, for: ref)
      notifications.remove(notification.notification)
    }

    isObserving = false
    CFRunLoopSourceInvalidate(observer.runLoopSource)
    observerRef = nil
  }

  /// The id of this application's focused window, or nil.
  var focusedWindowID: WindowID? {
    return ref.elementAttribute(kAXFocusedWindowAttribute)?.windowID
  }

  var isFrontmost: Bool {
    let processSerialNumber = SLS.frontProcess()
    return processSerialNumber.isSame(as: psn)
  }

  /// The AX windows of this application, or nil.
  var windowList: CFArray? {
    return ref.arrayAttribute(kAXWindowsAttribute)
  }

  // NOTE: Keep the AX element and icon (which tab bars set) until `destroy()`.
  func destroy() {
    ref = nil
    icon = nil
  }
}

extension Application: Hashable {
  nonisolated static func == (a: Application, b: Application) -> Bool { a === b }
  nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The AX notifications that an application can observe.
struct ApplicationNotifications: OptionSet, Sendable {
  let rawValue: UInt8

  static let created = ApplicationNotifications(rawValue: 1 << 0)
  static let focusedWindowChanged = ApplicationNotifications(rawValue: 1 << 1)
  static let windowMoved = ApplicationNotifications(rawValue: 1 << 2)
  static let windowResized = ApplicationNotifications(rawValue: 1 << 3)
  static let titleChanged = ApplicationNotifications(rawValue: 1 << 4)
  static let menuOpened = ApplicationNotifications(rawValue: 1 << 5)
  static let menuClosed = ApplicationNotifications(rawValue: 1 << 6)

  /// The window notifications required for application observation; menu notifications are optional.
  static let required: ApplicationNotifications = [
    .created, .focusedWindowChanged, .windowMoved, .windowResized, .titleChanged,
  ]
}

private let axApplicationNotifications:
  [(notification: ApplicationNotifications, name: String, text: String)] =
    [
      (.created, kAXCreatedNotification, "kAXCreatedNotification"),
      (
        .focusedWindowChanged, kAXFocusedWindowChangedNotification,
        "kAXFocusedWindowChangedNotification"
      ),
      (.windowMoved, kAXWindowMovedNotification, "kAXWindowMovedNotification"),
      (.windowResized, kAXWindowResizedNotification, "kAXWindowResizedNotification"),
      (.titleChanged, kAXTitleChangedNotification, "kAXTitleChangedNotification"),
      (.menuOpened, kAXMenuOpenedNotification, "kAXMenuOpenedNotification"),
      (.menuClosed, kAXMenuClosedNotification, "kAXMenuClosedNotification"),
    ]

// NOTE: The callback runs on the main run loop and never touches a window; it only records and posts. The context is
// the application (unretained) for application notifications, which do not read it, and the window id for those of
// Window.observe(), which uses the same observer. An id is no pointer, so a callback that runs after its window is gone
// only posts the id: the handlers on @WM look the window up and ignore it when it is missing. The destroyed callback
// marks the id (`markAXDestroyed`), so `Window.isValid` is false at once and the events queued for that window before
// its destroyed event are ignored, as before. It posts `.windowDestroyed` only when the mark is new, so a repeated AX
// notification posts nothing. The handler of `.windowDestroyed` on @WM invalidates the window and tears it down once;
// a window destroyed twice (or destroyed after its application terminated) is torn down once.
private func applicationNotificationHandler(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ context: UnsafeMutableRawPointer?
) {
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
    if let windowID = WindowID(notificationContext: context) {
      EventLoop.post(.windowMinimized(windowID: windowID))
    }
  case kAXWindowDeminiaturizedNotification:
    if let windowID = WindowID(notificationContext: context) {
      EventLoop.post(.windowDeminimized(windowID: windowID))
    }
  case kAXUIElementDestroyedNotification:
    guard let windowID = WindowID(notificationContext: context), markAXDestroyed(windowID) else {
      return
    }
    EventLoop.post(.windowDestroyed(windowID: windowID))
  default:
    break
  }
}
