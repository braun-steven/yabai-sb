import CPrivate
import Darwin
import Logging
import Synchronization
import YabaiCore

//
// NOTE: The daemon logs through swift-log. Each component has its own Logger (Logger.events, Logger.windows, …), and
// LoggingSystem.bootstrap in main.swift gives them all a StandardLogHandler. Levels up to notice go to stdout,
// warning and above to stderr: the launchd service writes them to /tmp/yabai_$USER.out.log and .err.log.
//
// The level is global: info, or debug while --verbose or debug_output is on. Messages are autoclosures, so a debug line
// costs one atomic load while verbose is off.
//

enum Log {
  /// Set by --verbose and debug_output, before the threads start or on the event loop; read anywhere.
  static let verbose = Atomic<Bool>(false)

  /// The value of `verbose` that the daemon started with (--verbose). `resetConfigToStartupDefaults` restores it for
  /// debug_output; the yabairc reload no longer calls that.
  static let verboseAtStartup = Atomic<Bool>(false)

  /// Sends every Logger to the StandardLogHandler; called once, before the first message.
  static func bootstrap() {
    LoggingSystem.bootstrap { StandardLogHandler(label: $0) }
  }
}

extension Logger {
  /// Startup, configuration, the launchd service and the scripting addition.
  static let daemon = Logger(label: "yabai")
  /// The handlers of the event loop.
  static let events = Logger(label: "yabai.event")
  /// Window discovery, observation and frame changes.
  static let windows = Logger(label: "yabai.window")
  /// Spaces and the space layout.
  static let spaces = Logger(label: "yabai.space")
  /// Processes and applications.
  static let processes = Logger(label: "yabai.process")
  /// Messages received on the socket.
  static let ipc = Logger(label: "yabai.ipc")
  /// Signals sent to their subscribers.
  static let signals = Logger(label: "yabai.signal")
  /// The container trees of the views: an invariant that a tree operation finds broken.
  static let tree = Logger(label: "yabai.tree")

  /// Logs the message as critical and exits. launchd restarts the service after EXIT_FAILURE, not after EXIT_SUCCESS.
  func fatal(
    _ message: @autoclosure () -> Logger.Message, exitCode: Int32 = EXIT_FAILURE,
    file: String = #fileID, function: String = #function, line: UInt = #line
  ) -> Never {
    critical(message(), file: file, function: function, line: line)
    exit(exitCode)
  }
}

/// Writes one line per message, e.g. `2026-10-20 14:03:12.345 debug yabai.event: window moved: Safari 1234`.
struct StandardLogHandler: LogHandler {
  let label: String
  var metadata: Logger.Metadata = [:]

  /// The global level of Log.verbose; a Logger cannot change it.
  var logLevel: Logger.Level
  {
    get { Log.verbose.load(ordering: .relaxed) ? .debug : .info }
    set {}
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value?
  {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    var line = "\(Self.timestamp()) \(event.level) \(label): \(event.message)"

    let merged = event.metadata.map { metadata.merging($0) { $1 } } ?? metadata
    for (key, value) in merged.sorted(by: { $0.key < $1.key }) {
      line += " \(key)=\(value)"
    }
    line += "\n"

    // one fputs per line, so the lines of concurrent threads do not interleave
    let stream = event.level >= .warning ? stderr_global() : stdout_global()
    fputs(line, stream)
    fflush(stream)
  }

  /// The local time with milliseconds.
  private static func timestamp() -> String {
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)

    var local = tm()
    localtime_r(&now.tv_sec, &local)

    var buffer = [CChar](repeating: 0, count: 32)
    let length = strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &local)
    let date = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return date + cFormat(".%03d", Int32(now.tv_nsec / 1_000_000))
  }
}

/// A user notification titled yabai (NotifyC in Sources/CPrivate/Notify.m). In headless mode it is recorded instead
/// (Headless.notifications), so a test never shows one.
func notify(_ subtitle: String, _ text: String) {
  if Headless.isEnabled {
    Headless.record(notification: "\(subtitle): \(text)")
    return
  }
  NotifyC(subtitle, text)
}
