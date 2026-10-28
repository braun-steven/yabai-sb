import Carbon
import Darwin
import Logging
import YabaiCore

/// An event and the object it describes. Models are read synchronously when the event is pushed;
/// only the resulting value snapshot is retained until the handler's signals flush.
enum SignalEvent {
  case applicationLaunched(Application)
  case applicationTerminated(Application)
  case applicationFrontSwitched
  case applicationActivated(Application)
  case applicationDeactivated(Application)
  case applicationVisible(Application)
  case applicationHidden(Application)
  case windowCreated(Window)
  case windowDestroyed(Window)
  case windowFocused(Window)
  case windowMoved(Window)
  case windowResized(Window)
  case windowMinimized(Window)
  case windowDeminimized(Window)
  case windowTitleChanged(Window)
  case spaceCreated(SpaceID)
  case spaceDestroyed(SpaceID)
  case spaceChanged
  case displayAdded(DisplayID)
  case displayRemoved(DisplayID)
  case displayMoved(DisplayID)
  case displayResized(DisplayID)
  case displayChanged
  case missionControlEnter(MissionControlMode)
  case missionControlExit(MissionControlMode)
  case dockDidChangePref
  case dockDidRestart
  case menuBarHiddenChanged
  case systemWoke
  case configLoaded(file: String, changes: Int)

  var type: SignalType {
    switch self {
    case .applicationLaunched: .applicationLaunched
    case .applicationTerminated: .applicationTerminated
    case .applicationFrontSwitched: .applicationFrontSwitched
    case .applicationActivated: .applicationActivated
    case .applicationDeactivated: .applicationDeactivated
    case .applicationVisible: .applicationVisible
    case .applicationHidden: .applicationHidden
    case .windowCreated: .windowCreated
    case .windowDestroyed: .windowDestroyed
    case .windowFocused: .windowFocused
    case .windowMoved: .windowMoved
    case .windowResized: .windowResized
    case .windowMinimized: .windowMinimized
    case .windowDeminimized: .windowDeminimized
    case .windowTitleChanged: .windowTitleChanged
    case .spaceCreated: .spaceCreated
    case .spaceDestroyed: .spaceDestroyed
    case .spaceChanged: .spaceChanged
    case .displayAdded: .displayAdded
    case .displayRemoved: .displayRemoved
    case .displayMoved: .displayMoved
    case .displayResized: .displayResized
    case .displayChanged: .displayChanged
    case .missionControlEnter: .missionControlEnter
    case .missionControlExit: .missionControlExit
    case .dockDidChangePref: .dockDidChangePref
    case .dockDidRestart: .dockDidRestart
    case .menuBarHiddenChanged: .menuBarHiddenChanged
    case .systemWoke: .systemWoke
    case .configLoaded: .configLoaded
    }
  }

  @WM func snapshot() -> PendingSignal {
    var result = PendingSignal(type)
    switch self {
    case .applicationLaunched(let application), .applicationActivated(let application),
      .applicationDeactivated(let application), .applicationVisible(let application):
      result.addArgument("YABAI_PROCESS_ID", "\(application.pid)")
      result.app = application.name
    case .applicationTerminated(let application):
      let pm = ProcessManager.shared
      result.addArgument("YABAI_PROCESS_ID", "\(application.pid)")
      result.app = application.name
      result.active = Self.terminationWasActive(
        pid: application.pid, frontPID: pm.frontPID, lastFrontPID: pm.lastFrontPID,
        elapsed: GetCurrentEventTime() - pm.switchEventTime)
    case .applicationFrontSwitched:
      let pm = ProcessManager.shared
      result.addArgument("YABAI_PROCESS_ID", "\(pm.frontPID)")
      result.addArgument("YABAI_RECENT_PROCESS_ID", "\(pm.lastFrontPID)")
    case .applicationHidden(let application):
      result.addArgument("YABAI_PROCESS_ID", "\(application.pid)")
      result.app = application.name
      result.active = ProcessManager.shared.frontPID == application.pid
    case .windowCreated(let window), .windowFocused(let window), .windowDeminimized(let window):
      result.describeWindow(window)
    case .windowDestroyed(let window):
      result.addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: window.id.rawValue))")
      result.app = window.application.map { $0.name } ?? "<unknown>"
      result.active = WindowManager.shared.focus.focused == window.id
    case .windowMoved(let window), .windowResized(let window), .windowMinimized(let window),
      .windowTitleChanged(let window):
      result.describeWindow(window)
      result.active = WindowManager.shared.focus.focused == window.id
    case .spaceCreated(let sid):
      result.addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid.rawValue))")
      result.addArgument("YABAI_SPACE_INDEX", "\(sid.missionControlIndex ?? 0)")
    case .spaceDestroyed(let sid):
      result.addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid.rawValue))")
    case .spaceChanged:
      let sm = SpaceManager.shared
      let sid = sm.currentSpaceID
      let recentSid = sm.lastSpaceID
      result.addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid?.rawValue ?? 0))")
      result.addArgument("YABAI_RECENT_SPACE_ID", "\(Int64(bitPattern: recentSid?.rawValue ?? 0))")
      result.addArgument("YABAI_SPACE_INDEX", "\(sid.flatMap { $0.missionControlIndex } ?? 0)")
      result.addArgument(
        "YABAI_RECENT_SPACE_INDEX", "\(recentSid.flatMap { $0.missionControlIndex } ?? 0)")
    case .displayAdded(let did), .displayMoved(let did), .displayResized(let did):
      result.addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did.rawValue))")
      result.addArgument("YABAI_DISPLAY_INDEX", "\(did.arrangement ?? 0)")
    case .displayRemoved(let did):
      result.addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did.rawValue))")
    case .displayChanged:
      let dm = DisplayManager.shared
      let did = dm.currentDisplayID
      let recentDid = dm.lastDisplayID
      result.addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did?.rawValue ?? 0))")
      result.addArgument(
        "YABAI_RECENT_DISPLAY_ID", "\(Int32(bitPattern: recentDid?.rawValue ?? 0))")
      result.addArgument("YABAI_DISPLAY_INDEX", "\(did.flatMap { $0.arrangement } ?? 0)")
      result.addArgument(
        "YABAI_RECENT_DISPLAY_INDEX", "\(recentDid.flatMap { $0.arrangement } ?? 0)")
    case .missionControlEnter(let mode), .missionControlExit(let mode):
      result.addArgument("YABAI_MISSION_CONTROL_MODE", mode.name)
    case .configLoaded(let file, let changes):
      result.addArgument("YABAI_CONFIG_FILE", file)
      result.addArgument("YABAI_CONFIG_CHANGES", "\(changes)")
    case .dockDidChangePref, .dockDidRestart, .menuBarHiddenChanged, .systemWoke:
      break
    }
    return result
  }

  static func terminationWasActive(
    pid: pid_t, frontPID: pid_t, lastFrontPID: pid_t, elapsed: Double
  ) -> Bool {
    // NOTE: macOS sends application_front_switched before application_terminated. A termination
    // close to that switch describes the previous front process. The threshold is triple the
    // average observed interval, to distinguish it from a later user-initiated termination.
    elapsed >= Double(Float(0.05)) ? frontPID == pid : lastFrontPID == pid
  }
}

extension PendingSignal {
  @WM fileprivate mutating func describeWindow(_ window: Window) {
    addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: window.id.rawValue))")
    app = window.application.name
    title = window.ax.title ?? ""
  }
}

/// Captures events while a handler runs, then dispatches their shell actions and publications.
@WM final class EventSignals {
  static let shared = EventSignals()

  private let runCommand: @WM (String, [(name: String, value: String)]) -> Void
  private let publish: @WM (SignalType, [(name: String, value: String)]) -> Void
  private let subscriberInterest: @WM (SignalType) -> Bool

  convenience init() {
    self.init(
      runCommand: { command, arguments in Self.spawn(command, arguments) },
      publish: { type, arguments in EventSubscribers.shared.publish(type, arguments: arguments) },
      subscriberInterest: { EventSubscribers.shared.wants($0) })
  }

  /// Injects both subscription boundaries, so capture and dispatch can run without global registries.
  init(
    runCommand: @escaping @WM (String, [(name: String, value: String)]) -> Void,
    publish: @escaping @WM (SignalType, [(name: String, value: String)]) -> Void,
    subscriberInterest: @escaping @WM (SignalType) -> Bool
  ) {
    self.runCommand = runCommand
    self.publish = publish
    self.subscriberInterest = subscriberInterest
  }

  var table = SignalTable()
  private(set) var pending: [PendingSignal] = []

  /// Drops captured events without running them, for tests resetting daemon state.
  func discardPending() { pending.removeAll() }

  func push(_ event: SignalEvent) {
    guard !table.signals(for: event.type).isEmpty || subscriberInterest(event.type) else { return }
    pending.append(event.snapshot())
  }

  func flush() {
    guard !pending.isEmpty else { return }
    let batch = pending
    pending.removeAll(keepingCapacity: true)

    for snapshot in batch {
      let signals = table.signals(for: snapshot.type)
      Logger.signals.debug("transmitting \(snapshot.type.name) to \(signals.count) signal(s)")
      for signal in signals where snapshot.matches(signal) {
        runCommand(signal.command, snapshot.arguments)
      }
      // NOTE: Socket subscribers receive every event of their types, independently of signal filters.
      publish(snapshot.type, snapshot.arguments)
    }
  }

  private static func spawn(_ command: String, _ arguments: [(name: String, value: String)]) {
    // NOTE: Swift cannot call fork, and only async-signal-safe code may run between fork and exec.
    // Filter in the daemon, then posix_spawn env to set the event variables and execute the shell.
    let argv =
      ["/usr/bin/env"] + arguments.map { "\($0.name)=\($0.value)" } + ["sh", "-c", command]
    var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer {
      for argument in cArguments { free(argument) }
    }
    var pid: pid_t = 0
    _ = posix_spawn(&pid, cArguments[0], nil, nil, &cArguments, environ)
  }
}
