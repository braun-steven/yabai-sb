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
  private var observerLifecycle = ApplicationObserverLifecycle<AXObserver, CFRunLoopSource>()
  /// The AX observer of the application; nil until `observe()` creates one, and again after `unobserve()`.
  var observerRef: AXObserver? { observerLifecycle.observer }
  var notifications: ApplicationNotifications { observerLifecycle.notifications }
  var isObserving: Bool { observerLifecycle.isObserving }
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
    guard let observer = AXObserver.create(pid: pid, callback: applicationNotificationHandler)
    else {
      return false
    }

    let reference = ref!
    let context = Unmanaged.passUnretained(self).toOpaque()
    let failures = observerLifecycle.begin(
      observer: observer,
      registrations: axApplicationNotifications,
      add: { observer, name in observer.add(name, for: reference, context: context) },
      makeSource: { $0.runLoopSource },
      installSource: { CFRunLoopAddSource(CFRunLoopGetMain(), $0, .defaultMode) })

    for failure in failures {
      let notification = failure.registration
      Logger.processes.debug(
        "\(name): observing \(notification.text) failed with \(failure.error.name)")

      // NOTE: Once an application times out, each remaining AX notification would wait for the same timeout.
      if failure.error == .cannotComplete {
        axRetry = true
      }
    }

    return notifications.isSuperset(of: .required)
  }

  func unobserve() {
    guard isObserving, observerRef != nil else { return }

    let reference = ref!
    observerLifecycle.end(
      registrations: axApplicationNotifications,
      remove: { observer, name in _ = observer.remove(name, for: reference) },
      invalidateSource: { CFRunLoopSourceInvalidate($0) })
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

struct ApplicationObserverRegistration: Sendable {
  let notification: ApplicationNotifications
  let name: String
  let text: String
}

let axApplicationNotifications: [ApplicationObserverRegistration] = [
  ApplicationObserverRegistration(
    notification: .created, name: kAXCreatedNotification, text: "kAXCreatedNotification"),
  ApplicationObserverRegistration(
    notification: .focusedWindowChanged,
    name: kAXFocusedWindowChangedNotification,
    text: "kAXFocusedWindowChangedNotification"),
  ApplicationObserverRegistration(
    notification: .windowMoved, name: kAXWindowMovedNotification, text: "kAXWindowMovedNotification"
  ),
  ApplicationObserverRegistration(
    notification: .windowResized, name: kAXWindowResizedNotification,
    text: "kAXWindowResizedNotification"),
  ApplicationObserverRegistration(
    notification: .titleChanged, name: kAXTitleChangedNotification,
    text: "kAXTitleChangedNotification"),
  ApplicationObserverRegistration(
    notification: .menuOpened, name: kAXMenuOpenedNotification, text: "kAXMenuOpenedNotification"),
  ApplicationObserverRegistration(
    notification: .menuClosed, name: kAXMenuClosedNotification, text: "kAXMenuClosedNotification"),
]

struct ApplicationObserverFailure {
  let registration: ApplicationObserverRegistration
  let error: AXError
}

/// The registration and run-loop source state shared by the live observer and deterministic lifecycle tests.
@WM struct ApplicationObserverLifecycle<Observer, Source> {
  private(set) var observer: Observer? = nil
  private(set) var source: Source? = nil
  private(set) var notifications: ApplicationNotifications = []
  private(set) var isObserving = false

  init() {}

  mutating func begin(
    observer: Observer,
    registrations: [ApplicationObserverRegistration],
    add: (Observer, String) -> AXError,
    makeSource: (Observer) -> Source,
    installSource: (Source) -> Void
  ) -> [ApplicationObserverFailure] {
    guard case .none = self.observer, !isObserving else { return [] }

    self.observer = observer
    var failures: [ApplicationObserverFailure] = []

    for registration in registrations {
      let error = add(observer, registration.name)
      if error == .success || error == .notificationAlreadyRegistered {
        notifications.insert(registration.notification)
      } else {
        failures.append(ApplicationObserverFailure(registration: registration, error: error))

        // NOTE: Once an application times out, every remaining AX notification can wait for the same timeout.
        if error == .cannotComplete { break }
      }
    }

    let source = makeSource(observer)
    self.source = source
    isObserving = true
    installSource(source)
    return failures
  }

  mutating func end(
    registrations: [ApplicationObserverRegistration],
    remove: (Observer, String) -> Void,
    invalidateSource: (Source) -> Void
  ) {
    guard isObserving, let observer else { return }

    for registration in registrations where notifications.contains(registration.notification) {
      remove(observer, registration.name)
      notifications.remove(registration.notification)
    }

    isObserving = false
    if let source {
      invalidateSource(source)
      self.source = nil
    }
    self.observer = nil
  }
}

enum AXApplicationEvent: Equatable, Sendable {
  case windowCreated
  case windowFocused(WindowID?)
  case windowMoved(WindowID)
  case windowResized(WindowID)
  case windowTitleChanged(WindowID)
  case menuOpened(WindowID?)
  case menuClosed
  case windowMinimized(WindowID)
  case windowDeminimized(WindowID)
  case windowDestroyed(WindowID)
}

/// Maps an AX notification snapshot into its event-loop value. `windowID` is lazy because several notifications carry
/// their id in the observer context or do not need a window id at all.
func axApplicationEvent(
  _ notification: String,
  contextWindowID: WindowID?,
  windowID: () -> WindowID?
) -> AXApplicationEvent? {
  switch notification {
  case kAXCreatedNotification:
    return .windowCreated
  case kAXFocusedWindowChangedNotification:
    return .windowFocused(windowID())
  case kAXWindowMovedNotification:
    return windowID().map(AXApplicationEvent.windowMoved)
  case kAXWindowResizedNotification:
    return windowID().map(AXApplicationEvent.windowResized)
  case kAXTitleChangedNotification:
    return windowID().map(AXApplicationEvent.windowTitleChanged)
  case kAXMenuOpenedNotification:
    return .menuOpened(windowID())
  case kAXMenuClosedNotification:
    return .menuClosed
  case kAXWindowMiniaturizedNotification:
    return contextWindowID.map(AXApplicationEvent.windowMinimized)
  case kAXWindowDeminiaturizedNotification:
    return contextWindowID.map(AXApplicationEvent.windowDeminimized)
  case kAXUIElementDestroyedNotification:
    return contextWindowID.map(AXApplicationEvent.windowDestroyed)
  default:
    return nil
  }
}

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
  let notification = notification as String
  let contextWindowID = WindowID(notificationContext: context)
  guard
    let event = axApplicationEvent(
      notification, contextWindowID: contextWindowID, windowID: { element.windowID })
  else { return }

  switch event {
  case .windowCreated:
    EventLoop.post(.windowCreated(Handoff(value: Unmanaged.passRetained(element))))
  case .windowFocused(let windowID):
    pendingWindowFocus.store(true, ordering: .releasing)
    EventLoop.post(.windowFocused(windowID: windowID))
  case .windowMoved(let windowID):
    EventLoop.post(.windowMoved(windowID: windowID))
  case .windowResized(let windowID):
    EventLoop.post(.windowResized(windowID: windowID))
  case .windowTitleChanged(let windowID):
    EventLoop.post(.windowTitleChanged(windowID: windowID))
  case .menuOpened(let windowID):
    EventLoop.post(.menuOpened(windowID: windowID))
  case .menuClosed:
    EventLoop.post(.menuClosed)
  case .windowMinimized(let windowID):
    EventLoop.post(.windowMinimized(windowID: windowID))
  case .windowDeminimized(let windowID):
    EventLoop.post(.windowDeminimized(windowID: windowID))
  case .windowDestroyed(let windowID):
    guard markAXDestroyed(windowID) else {
      return
    }
    EventLoop.post(.windowDestroyed(windowID: windowID))
  }
}
