import CoreGraphics
import Darwin
import Foundation
import Logging
import SortedCollections
import Synchronization
import YabaiCore

//
// NOTE: The topology log is always on, without --verbose, because the failures it explains come from a long sleep or an
// unplugged dock: nobody turns on a debug log before those. It records the raw display changes, sleep and lock changes,
// the spaces the window server creates and destroys, and what yabai does in reply, and an observation of every display,
// space and window (TopologySnapshotReason says when). The producers record from their own threads as soon as they
// are called, because the event loop can run seconds behind while displays change. One line is
// `<time> <kind> <detail>`; a `snapshot` line has the reason and the JSON of a TopologyObservation as its detail. The
// log is $XDG_STATE_HOME/yabai/topology.log or ~/.local/state/yabai/topology.log; it holds about 8 MiB in two files.
//

/// An append-only file that moves aside as `<path>.1` when it reaches `limit` bytes, replacing the older `<path>.1`.
struct RotatingLogFile {
  let path: String
  let limit: Int
  private var descriptor: Int32 = -1
  private var size = 0

  init(path: String, limit: Int) {
    self.path = path
    self.limit = limit
  }

  /// Opens the file; false when it can not be opened.
  private mutating func open() -> Bool {
    descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    if descriptor < 0 { return false }

    var status = stat()
    size = fstat(descriptor, &status) == 0 ? Int(status.st_size) : 0
    return true
  }

  /// Appends one line in one write, so the file never holds half a line of a live daemon. A failed write loses the line:
  /// the log must never get in the way of the daemon.
  mutating func append(_ line: String) {
    if descriptor < 0 && !open() { return }

    if size >= limit {
      close(descriptor)
      rename(path, path + ".1")
      if !open() { return }
    }

    let written = line.withCString { write(descriptor, $0, strlen($0)) }
    if written > 0 { size += written }
  }
}

enum TopologyLog {
  /// The size at which the file moves aside.
  private static let fileLimit = 4 * 1024 * 1024

  /// Nil until `begin()`, so that the tests write nothing.
  private static let file = Mutex<RotatingLogFile?>(nil)

  /// The JSON of the last observation, which a `periodic` one must differ from to be recorded. On the event loop.
  @WM private static var lastObservation: [UInt8] = []

  /// Called by Daemon.run on the main thread, before the first producer starts.
  static func begin() {
    let environment = ProcessInfo.processInfo.environment
    let state =
      environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? NSHomeDirectory() + "/.local/state"
    let directory = state + "/yabai"

    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    } catch {
      Logger.daemon.warning("topology log: could not create \(directory): \(error)")
      return
    }

    file.withLock { $0 = RotatingLogFile(path: directory + "/topology.log", limit: fileLimit) }
    record("start", Daemon.version)
    EventLoop.post(.topologySnapshot(.start), after: .seconds(2), key: .topologySnapshot)
  }

  /// Appends a line. Callable from any thread.
  static func record(_ kind: String, _ detail: @autoclosure () -> String = "") {
    file.withLock { log in
      guard log != nil else { return }

      let text = detail()
      log?.append(
        StandardLogHandler.timestamp() + " " + kind + (text.isEmpty ? "" : " " + text) + "\n")
    }
  }

  /// Appends a line about a change of the topology, and observes the result once the changes are quiet. Callable from
  /// any thread.
  static func recordChange(_ kind: String, _ detail: @autoclosure () -> String = "") {
    guard file.withLock({ $0 != nil }) else { return }

    record(kind, detail())
    EventLoop.post(
      .topologySnapshot(.settle), after: .seconds(TopologySnapshotReason.settleSeconds),
      key: .topologySnapshot)
  }

  /// Appends a line about the coming sleep, and observes everything before it. Callable from any thread.
  static func recordSleep(_ kind: String) {
    guard file.withLock({ $0 != nil }) else { return }

    record(kind)
    EventLoop.post(.topologySnapshot(.sleep), after: .zero, key: .topologySnapshot)
  }

  /// The names of the flags of a display reconfiguration, in the order of their bits.
  static func text(of flags: CGDisplayChangeSummaryFlags) -> String {
    let names: [(CGDisplayChangeSummaryFlags, String)] = [
      (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "main"),
      (.setModeFlag, "mode"), (.addFlag, "add"), (.removeFlag, "remove"),
      (.enabledFlag, "enabled"), (.disabledFlag, "disabled"), (.mirrorFlag, "mirror"),
      (.unMirrorFlag, "unmirror"), (.desktopShapeChangedFlag, "shape"),
    ]

    return names.filter { flags.contains($0.0) }.map(\.1).joined(separator: ",")
  }

  /// Records an observation and schedules the next one.
  @WM static func snapshot(_ reason: TopologySnapshotReason) {
    guard file.withLock({ $0 != nil }) else { return }

    if let json = try? JSON.encode(SpaceManager.shared.topologyObservation()),
      reason != .periodic || json != lastObservation
    {
      lastObservation = json
      record("snapshot", "\(reason.rawValue) \(String(decoding: json, as: UTF8.self))")
    }

    let next = reason.next
    EventLoop.post(
      .topologySnapshot(next.reason), after: .seconds(next.seconds), key: .topologySnapshot)
  }
}

extension SpaceManager {
  /// The displays, spaces and windows now. The window server is asked directly, without the cached lists.
  func topologyObservation() -> TopologyObservation {
    let displays = DisplayManager.orderedBuiltinLast(
      SLS.managedDisplaySpaces(SLS.connection), enabled: Config.current.display.builtinDisplayLast
    ) {
      DisplayManager.isBuiltin(uuid: $0["Display Identifier"])
    }

    return TopologyObservation(
      displays: displays.map { display in
        let spaces = display["Spaces"] as? [NSDictionary] ?? []
        let current = (display["Current Space"] as? NSDictionary)?["id64"] as? NSNumber

        return TopologyObservation.Display(
          uuid: display["Display Identifier"] as? String ?? "",
          current: current?.uint64Value,
          spaces: spaces.compactMap(topologySpace))
      })
  }

  private func topologySpace(_ space: NSDictionary) -> TopologyObservation.Space? {
    guard let sid = (space["id64"] as? NSNumber).flatMap({ SpaceID(nonzero: $0.uint64Value) })
    else { return nil }

    return TopologyObservation.Space(
      id: sid.rawValue,
      uuid: space["uuid"] as? String ?? "",
      type: (space["type"] as? NSNumber)?.intValue ?? 0,
      windows: sid.windows(includingMinimized: true)?.map(\.rawValue) ?? [],
      tree: views[sid]?.windowIDs.map(\.rawValue))
  }
}
