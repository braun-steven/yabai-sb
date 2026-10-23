import ApplicationServices
import CPrivate
import Foundation
import Logging
import Synchronization
import YabaiCore

//
// NOTE: The notifications of the window server connection and the Mission Control notifications of the Dock. Both
// callbacks run on the main thread and only post events (and move or hide the borders, which Border.swift locks).
//

/// What Mission Control shows. The raw value is the context of the Mission Control signals.
enum MissionControlMode: Int, Sendable {
  case inactive
  case show
  case showAllWindows
  case showFrontWindows
  case showDesktop

  /// The value of `YABAI_MISSION_CONTROL_MODE` in the signals.
  var name: String {
    switch self {
    case .inactive: "inactive"
    case .show: "show"
    case .showAllWindows: "show-all-windows"
    case .showFrontWindows: "show-front-windows"
    case .showDesktop: "show-desktop"
    }
  }
}

/// Registered for each `SLSNotification` type by Daemon.run. A payload shorter than its type is logged and dropped.
func connectionNotificationHandler(
  _ type: UInt32, _ data: UnsafeMutableRawPointer?, _ dataLength: Int,
  _ context: UnsafeMutableRawPointer?, _ cid: Int32
) {
  guard let kind = SLSNotification(rawValue: type) else { return }

  switch kind {
  case .spaceCreated:
    guard let sid = SLSNotification.payload(data, dataLength, as: UInt64.self) else {
      return logShortPayload(kind, dataLength)
    }
    EventLoop.post(.slsSpaceCreated(spaceID: SpaceID(sid)))
  case .spaceDestroyed:
    guard let sid = SLSNotification.payload(data, dataLength, as: UInt64.self) else {
      return logShortPayload(kind, dataLength)
    }
    EventLoop.post(.slsSpaceDestroyed(spaceID: SpaceID(sid)))
  case .windowOrdered:
    guard let wid = SLSNotification.payload(data, dataLength, as: UInt32.self) else {
      return logShortPayload(kind, dataLength)
    }
    Border.windowOrdered(WindowID(wid))
    TabBar.windowOrderChanged()
    EventLoop.post(.slsWindowOrdered(windowID: WindowID(wid)))
  case .windowDestroyed:
    guard let wid = SLSNotification.payload(data, dataLength, as: UInt32.self) else {
      return logShortPayload(kind, dataLength)
    }
    Border.windowHidden(WindowID(wid))
    TabBar.windowOrderChanged()
    EventLoop.post(.slsWindowDestroyed(windowID: WindowID(wid)))
  case .windowMoved:
    guard let wid = SLSNotification.payload(data, dataLength, as: UInt32.self) else {
      return logShortPayload(kind, dataLength)
    }
    Border.windowMoved(WindowID(wid))
  case .windowResized:
    guard let wid = SLSNotification.payload(data, dataLength, as: UInt32.self) else {
      return logShortPayload(kind, dataLength)
    }
    Border.windowResized(WindowID(wid))
  case .windowChanged:
    guard let wid = SLSNotification.payload(data, dataLength, as: UInt32.self) else {
      return logShortPayload(kind, dataLength)
    }
    Border.windowChanged(WindowID(wid))
  case .windowHidden:
    guard let wid = SLSNotification.payload(data, dataLength, as: UInt32.self) else {
      return logShortPayload(kind, dataLength)
    }
    Border.windowHidden(WindowID(wid))
  case .cmdTab:
    lastCmdTabTime.store(OSTimer.now, ordering: .releasing)
  case .frontChanged:
    if MissionControl.overlayIsShown() {
      Border.setHiddenForMissionControl(true)
      EventLoop.post(.missionControlEnter)
    }
  }
}

private func logShortPayload(_ kind: SLSNotification, _ length: Int) {
  Logger.events.debug(
    "SLS notification \(kind.rawValue) has a payload of \(length) bytes, too short to decode")
}

private enum Expose {
  static let showAllWindows = "AXExposeShowAllWindows"
  static let showFrontWindows = "AXExposeShowFrontWindows"
  static let showDesktop = "AXExposeShowDesktop"
  static let exit = "AXExposeExit"

  static let all = [showAllWindows, showFrontWindows, showDesktop, exit]
}

private func missionControlNotificationHandler(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ context: UnsafeMutableRawPointer?
) {
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

// NOTE: @unchecked because the AX references are not Sendable. They are only read and written under
// MissionControl.stateLock, and unobserve() takes them out of it before it uses them. Without it, storing the
// references in observe() fails region checking.
private struct MissionControlState: @unchecked Sendable {
  var mode = MissionControlMode.inactive
  var ref: AXUIElement?
  var observerRef: AXObserver?
  var isObserving = false
}

/// Mission Control: its mode, and the observer of the Mission Control notifications of the Dock.
final class MissionControl: Sendable {
  // NOTE: Daemon.run calls observe() on the main thread during startup, while yabai.wm may already handle events.
  // After that, the yabai.wm handlers read and change mode, and dockDidRestart() calls unobserve() and observe().
  // The observe and unobserve calls never overlap. stateLock owns the mode and the AX references for both threads.
  // The AX, Workspace and CFRunLoop calls stay outside the lock, so a reentrant callback cannot deadlock. The AX
  // callback runs on the main run loop and only posts events.
  static let shared = MissionControl()

  private let stateLock = Mutex(MissionControlState())

  var mode: MissionControlMode
  {
    get { stateLock.withLock { $0.mode } }
    set { stateLock.withLock { $0.mode = newValue } }
  }

  var isActive: Bool { mode != .inactive }

  //
  // NOTE: On macOS 27 the Dock no longer posts its AXExpose notifications. While Mission Control is open, the Dock
  // shows an overlay window at layer 20 over each display, and it is already on screen when the window server sends
  // the front change notification of the opening. Its owner name is readable without Screen Recording; its window
  // name is not, so it is not checked. The Dock itself is at layer 20 too, but never covers a whole display.
  //

  /// Whether a window of the list is the Mission Control overlay: a Dock window at layer 20 that covers a display.
  static func containsOverlay(_ windowList: [[String: Any]], displays: [CGRect]) -> Bool {
    windowList.contains { info in
      guard info[kCGWindowOwnerName as String] as? String == "Dock",
        info[kCGWindowLayer as String] as? Int == 20,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
      else { return false }
      return displays.contains { bounds.contains($0) }
    }
  }

  /// Whether the Mission Control overlay is on screen.
  static func overlayIsShown() -> Bool {
    let windowList =
      CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
    return containsOverlay(windowList, displays: ids.prefix(Int(count)).map { CGDisplayBounds($0) })
  }

  func observe() {
    // NOTE: Headless mode (tests) never observes the Dock of the user's session.
    guard !Headless.isEnabled else { return }
    let alreadyObserving = stateLock.withLock { $0.isObserving }
    guard !alreadyObserving, let pid = Workspace.dockPID else { return }

    let ref = AXUIElement.application(pid)
    guard let observerRef = AXObserver.create(pid: pid, callback: missionControlNotificationHandler)
    else { return }

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

  func unobserve() {
    let observer = stateLock.withLock { state -> (AXObserver, AXUIElement)? in
      guard state.isObserving, let observerRef = state.observerRef, let ref = state.ref else {
        return nil
      }

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
