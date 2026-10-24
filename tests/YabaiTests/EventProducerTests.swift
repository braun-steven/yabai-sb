import AppKit
import ApplicationServices
import Carbon
import Darwin
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

private final class EventRecorder: @unchecked Sendable {
  private let storage = Mutex<[Event]>([])

  func post(_ event: Event) {
    storage.withLock { $0.append(event) }
  }

  var events: [Event] {
    storage.withLock { $0 }
  }
}

private struct ObserverID: Equatable {
  let value: Int
}

private struct SourceID: Equatable {
  let value: Int
}

private func eventLabels(_ events: [Event]) -> [String] {
  events.map { event in
    switch event {
    case .carbonProcessLaunched(let key): "carbon-launched:\(key.high):\(key.low)"
    case .carbonProcessTerminated(let key): "carbon-terminated:\(key.high):\(key.low)"
    case .carbonProcessFrontSwitched(let key): "carbon-front-switched:\(key.high):\(key.low)"
    case .applicationHidden(let pid): "application-hidden:\(pid)"
    case .applicationVisible(let pid): "application-visible:\(pid)"
    case .dockDidChangePref: "dock-pref-changed"
    case .dockDidRestart: "dock-restarted"
    case .displayChanged: "display-changed"
    case .menuBarHiddenChanged: "menu-bar-hidden-changed"
    case .spaceChanged: "space-changed"
    case .systemWoke: "system-woke"
    default: "unexpected"
    }
  }
}

extension DaemonState {
  @Suite
  @WM struct EventProducerTests {
    @Test func workspaceNotificationsPostInArrivalOrder() throws {
      let recorder = EventRecorder()
      let source = Yabai.Workspace(registerObservers: false, postEvent: recorder.post)
      let emptyNotification = Notification(name: Notification.Name("synthetic"))

      source.didHideApplication(emptyNotification)
      source.didUnhideApplication(emptyNotification)
      #expect(recorder.events.isEmpty)

      let runningApplication = try #require(
        NSRunningApplication(processIdentifier: getpid()))
      let applicationNotification = Notification(
        name: Notification.Name("synthetic"),
        userInfo: [NSWorkspace.applicationUserInfoKey: runningApplication])

      source.activeSpaceDidChange(emptyNotification)
      source.didHideApplication(applicationNotification)
      source.activeDisplayDidChange(emptyNotification)
      source.didUnhideApplication(applicationNotification)
      source.didWake(emptyNotification)
      source.didChangeMenuBarHiding(emptyNotification)
      source.didRestartDock(emptyNotification)
      source.didChangeDockPref(emptyNotification)

      let pid = runningApplication.processIdentifier
      #expect(
        eventLabels(recorder.events) == [
          "space-changed",
          "application-hidden:\(pid)",
          "display-changed",
          "application-visible:\(pid)",
          "system-woke",
          "menu-bar-hidden-changed",
          "dock-restarted",
          "dock-pref-changed",
        ])
    }

    @Test func carbonProcessKindsMapToOrderedEvents() {
      let psn = ProcessSerialNumber(highLongOfPSN: 4, lowLongOfPSN: 9)
      let key = ProcessKey(psn)
      let kinds = [kEventAppLaunched, kEventAppFrontSwitched, kEventAppTerminated]
      let events = kinds.compactMap { carbonProcessEvent(kind: Int($0), key: key) }

      #expect(
        eventLabels(events) == [
          "carbon-launched:4:9",
          "carbon-front-switched:4:9",
          "carbon-terminated:4:9",
        ])
      #expect(carbonProcessEvent(kind: -1, key: key) == nil)
    }

    @Test func accessibilitySnapshotsMapToOrderedEvents() {
      let windowID = wid(40)
      let notifications: [String] = [
        kAXCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
      ]
      var windowIDLookups = 0

      let events = notifications.compactMap { notification in
        axApplicationEvent(notification, contextWindowID: windowID) {
          windowIDLookups += 1
          return windowID
        }
      }

      #expect(
        events == [
          .windowCreated,
          .windowFocused(windowID),
          .windowMoved(windowID),
          .windowResized(windowID),
          .windowTitleChanged(windowID),
          .menuOpened(windowID),
          .menuClosed,
          .windowMinimized(windowID),
          .windowDeminimized(windowID),
          .windowDestroyed(windowID),
        ])
      #expect(windowIDLookups == 5)
    }

    @Test func optionalAccessibilityRegistrationFailureKeepsRequiredObserverUsable() {
      let registrations = axApplicationNotifications
      let unsupported: ApplicationNotifications = [.menuOpened, .menuClosed]
      let supported = registrations.filter { !unsupported.contains($0.notification) }
      var results = registrations.map {
        unsupported.contains($0.notification) ? AXError.notificationUnsupported : .success
      }
      var attempts: [String] = []
      var addedSources: [SourceID] = []
      var removed: [String] = []
      var invalidated: [SourceID] = []
      var lifecycle = ApplicationObserverLifecycle<ObserverID, SourceID>()

      let failures = lifecycle.begin(
        observer: ObserverID(value: 1),
        registrations: registrations,
        add: { _, name in
          attempts.append(name)
          return results.removeFirst()
        },
        makeSource: { _ in SourceID(value: 7) },
        installSource: { addedSources.append($0) })

      #expect(attempts == registrations.map(\.name))
      #expect(
        failures.map(\.registration.notification) == [
          .menuOpened, .menuClosed,
        ])
      #expect(lifecycle.notifications.isSuperset(of: .required))
      #expect(lifecycle.isObserving)
      #expect(lifecycle.observer == ObserverID(value: 1))
      #expect(addedSources == [SourceID(value: 7)])

      lifecycle.end(
        registrations: registrations,
        remove: { _, name in removed.append(name) },
        invalidateSource: { invalidated.append($0) })
      lifecycle.end(
        registrations: registrations,
        remove: { _, name in removed.append(name) },
        invalidateSource: { invalidated.append($0) })

      #expect(removed == supported.map(\.name))
      #expect(invalidated == [SourceID(value: 7)])
      #expect(lifecycle.notifications.isEmpty)
      #expect(!lifecycle.isObserving)
      #expect(lifecycle.observer == nil)
      #expect(lifecycle.source == nil)
    }

    @Test func requiredAccessibilityRegistrationFailureRollsBackExactlyOnce() {
      let registrations = axApplicationNotifications
      let failedRegistration = ApplicationNotifications.windowMoved
      let successful = registrations.filter { $0.notification != failedRegistration }
      var results = registrations.map {
        $0.notification == failedRegistration ? AXError.notificationUnsupported : .success
      }
      var removed: [String] = []
      var invalidated: [SourceID] = []
      var lifecycle = ApplicationObserverLifecycle<ObserverID, SourceID>()

      let failures = lifecycle.begin(
        observer: ObserverID(value: 2),
        registrations: registrations,
        add: { _, _ in results.removeFirst() },
        makeSource: { _ in SourceID(value: 8) },
        installSource: { _ in })

      #expect(failures.map(\.registration.notification) == [failedRegistration])
      #expect(!lifecycle.notifications.isSuperset(of: .required))
      #expect(lifecycle.isObserving)

      // The application launch handler calls this rollback when a required registration is missing.
      lifecycle.end(
        registrations: registrations,
        remove: { _, name in removed.append(name) },
        invalidateSource: { invalidated.append($0) })
      lifecycle.end(
        registrations: registrations,
        remove: { _, name in removed.append(name) },
        invalidateSource: { invalidated.append($0) })

      #expect(removed == successful.map(\.name))
      #expect(invalidated == [SourceID(value: 8)])
      #expect(lifecycle.notifications.isEmpty)
      #expect(!lifecycle.isObserving)
    }

    @Test func accessibilityTimeoutStopsRemainingRegistrations() throws {
      let registrations = axApplicationNotifications
      let timeoutIndex = try #require(
        registrations.firstIndex { $0.notification == .windowMoved })
      var attempts: [String] = []
      var lifecycle = ApplicationObserverLifecycle<ObserverID, SourceID>()

      let failures = lifecycle.begin(
        observer: ObserverID(value: 3),
        registrations: registrations,
        add: { _, name in
          attempts.append(name)
          return attempts.count == timeoutIndex + 1 ? .cannotComplete : .success
        },
        makeSource: { _ in SourceID(value: 9) },
        installSource: { _ in })

      #expect(attempts == registrations.prefix(timeoutIndex + 1).map(\.name))
      #expect(failures.map { $0.error.rawValue } == [AXError.cannotComplete.rawValue])
      lifecycle.end(
        registrations: registrations,
        remove: { _, _ in },
        invalidateSource: { _ in })
    }
  }
}
