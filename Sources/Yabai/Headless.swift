import CoreGraphics
import Synchronization
import YabaiCore

//
// NOTE: Headless mode is for the tests only; the daemon never turns it on. The tests run in a process that shares the
// window server and the scripting addition of the user's session, so in headless mode the code paths that end in them
// record what they would do instead: a view's flush applies the frames of its tree to the window models (no AX, tab
// bars, feedback windows or borders), and the messages to the payload are kept rather than sent to Dock.
//

/// The frame a window was given in headless mode.
struct RecordedPlacement: Equatable, Sendable, CustomStringConvertible {
  var windowID: WindowID
  var x: Float, y: Float, w: Float, h: Float

  var description: String { "\(windowID.rawValue): \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))" }
}

/// What the window server and the payload would have received in headless mode.
struct HeadlessLog: Sendable {
  var placements: [RecordedPlacement] = []
  /// The messages to the payload: two length bytes, the opcode, then the packed arguments (`SAPayload`).
  var messages: [[UInt8]] = []
  /// The config files that the daemon would run (`Daemon.execConfigFile`), in order.
  var configFiles: [String] = []
  /// The messages of a yabai.toml that the startup applied (`ConfigStep.apply`), in the order they ran.
  var configEntries: [ConfigEntry] = []
  /// The user notifications that the daemon would show, as `subtitle: text`, in order (`notify`).
  var notifications: [String] = []
}

enum Headless {
  private static let enabled = Atomic<Bool>(false)
  private static let log = Mutex(HeadlessLog())

  static var isEnabled: Bool { enabled.load(ordering: .relaxed) }

  static let defaultDisplayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

  /// The display frame of every space in headless mode, which `View.update` lays out in instead of asking SkyLight.
  @WM static var displayFrame = defaultDisplayFrame

  /// The active space of the window selectors that look in its tree (`first`, `stack.next`, …) in headless mode,
  /// instead of asking SkyLight; nil when no test sets it.
  @WM static var activeSpace: SpaceID?

  /// Turns headless mode on for the rest of the process and clears the log.
  static func enable() {
    enabled.store(true, ordering: .relaxed)
    _ = drain()
  }

  /// Returns the log and clears it.
  static func drain() -> HeadlessLog {
    log.withLock { current in
      let result = current
      current = HeadlessLog()
      return result
    }
  }

  static func record(message: [UInt8]) {
    log.withLock { $0.messages.append(message) }
  }

  static func record(configFile: String) {
    log.withLock { $0.configFiles.append(configFile) }
  }

  static func record(configEntries: [ConfigEntry]) {
    log.withLock { $0.configEntries += configEntries }
  }

  static func record(notification: String) {
    log.withLock { $0.notifications.append(notification) }
  }

  /// Applies placements as the window server would at once: the frames that differ from the last request are
  /// recorded and become the frame and the request of their window.
  @WM static func apply(_ list: [WindowPlacement]) {
    var applied: [RecordedPlacement] = []
    for placement in list {
      guard let target = placement.window,
        !target.frameRequest.isClose(x: placement.x, y: placement.y, w: placement.w, h: placement.h)
      else { continue }
      let frame = CGRect(
        x: CGFloat(placement.x), y: CGFloat(placement.y), width: CGFloat(placement.w),
        height: CGFloat(placement.h))
      target.frameRequest = frame
      target.frame = frame
      applied.append(
        RecordedPlacement(
          windowID: target.id, x: placement.x, y: placement.y, w: placement.w, h: placement.h))
    }
    if !applied.isEmpty { log.withLock { $0.placements += applied } }
  }
}
