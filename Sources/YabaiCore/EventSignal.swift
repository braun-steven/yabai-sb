import Darwin

//
// NOTE: The signals of the daemon: the commands that a user runs on events (`yabai -m signal --add`). The event
// handlers push a PendingSignal for each event that has signals, and after the handler the event loop runs the command
// of every signal whose filters match it. The part that reads the managers and runs the commands is
// Sources/Yabai/EventSignal.swift.
//

/// `enum signal_type` (the former src/event_signal.h) with the names of `signal_type_str`, and the raw values of the
/// C enum.
public enum SignalType: Int, CaseIterable, Sendable {
  case applicationLaunched = 1
  case applicationTerminated
  case applicationFrontSwitched
  case applicationActivated
  case applicationDeactivated
  case applicationVisible
  case applicationHidden

  case windowCreated
  case windowDestroyed
  case windowFocused
  case windowMoved
  case windowResized
  case windowMinimized
  case windowDeminimized
  case windowTitleChanged

  case spaceCreated
  case spaceDestroyed
  case spaceChanged

  case displayAdded
  case displayRemoved
  case displayMoved
  case displayResized
  case displayChanged

  case missionControlEnter
  case missionControlExit

  case dockDidChangePref
  case dockDidRestart

  case menuBarHiddenChanged
  case systemWoke

  public var name: String {
    switch self {
    case .applicationLaunched: "application_launched"
    case .applicationTerminated: "application_terminated"
    case .applicationFrontSwitched: "application_front_switched"
    case .applicationActivated: "application_activated"
    case .applicationDeactivated: "application_deactivated"
    case .applicationVisible: "application_visible"
    case .applicationHidden: "application_hidden"
    case .windowCreated: "window_created"
    case .windowDestroyed: "window_destroyed"
    case .windowFocused: "window_focused"
    case .windowMoved: "window_moved"
    case .windowResized: "window_resized"
    case .windowMinimized: "window_minimized"
    case .windowDeminimized: "window_deminimized"
    case .windowTitleChanged: "window_title_changed"
    case .spaceCreated: "space_created"
    case .spaceDestroyed: "space_destroyed"
    case .spaceChanged: "space_changed"
    case .displayAdded: "display_added"
    case .displayRemoved: "display_removed"
    case .displayMoved: "display_moved"
    case .displayResized: "display_resized"
    case .displayChanged: "display_changed"
    case .missionControlEnter: "mission_control_enter"
    case .missionControlExit: "mission_control_exit"
    case .dockDidChangePref: "dock_did_change_pref"
    case .dockDidRestart: "dock_did_restart"
    case .menuBarHiddenChanged: "menu_bar_hidden_changed"
    case .systemWoke: "system_woke"
    }
  }

  /// `signal_type_from_string`
  public init?(name: Token) {
    guard let type = SignalType.allCases.first(where: { name.equals($0.name) }) else { return nil }
    self = type
  }
}

/// `struct event_signal`: a signal pushed while an event is handled. It holds the environment variables of the
/// commands and the properties (app, title, active) that the signals of its type can filter on.
public struct PendingSignal {
  public let type: SignalType
  public private(set) var arguments: [(name: String, value: String)] = []
  public var app: String?
  public var title: String?
  public var active = false

  public init(_ type: SignalType) {
    self.type = type
  }

  /// `event_signal_add_arg`
  public mutating func addArgument(_ name: String, _ value: String) {
    assert(arguments.count < 4)
    arguments.append((name, value))
  }

  private static func regexMismatch(_ pattern: RulePattern?, _ text: String?) -> Bool {
    guard let pattern, let regex = pattern.regex else { return false }
    let matched = regex.matches(text ?? "")
    return matched == pattern.exclude
  }

  private func activeMismatch(_ signal: EventSignal) -> Bool {
    signal.active.map { $0 != active } ?? false
  }

  //
  // NOTE: Returns true when the signal does not apply to the event. Each event type only reports the
  // properties (app, title, active) that its signals can filter on.
  //

  /// `event_signal_filter`
  public func filters(_ signal: EventSignal) -> Bool {
    var app = false
    var title = false
    var active = false

    switch type {
    case .applicationLaunched, .applicationActivated, .applicationDeactivated, .applicationVisible:
      app = true
    case .applicationTerminated, .applicationHidden, .windowDestroyed:
      app = true
      active = true
    case .windowCreated, .windowFocused, .windowDeminimized:
      app = true
      title = true
    case .windowMoved, .windowResized, .windowMinimized, .windowTitleChanged:
      app = true
      title = true
      active = true
    default:
      return false
    }

    if app && PendingSignal.regexMismatch(signal.app, self.app) { return true }
    if title && PendingSignal.regexMismatch(signal.title, self.title) { return true }
    if active && activeMismatch(signal) { return true }

    return false
  }
}

/// A signal in `signal --list`. Text that is nil is written as "", active as null when it does not matter.
public struct SignalInfo: Encodable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case index, label, app, title, active, event, action
  }

  public var index: Int
  public var label: String
  public var app: String
  public var title: String
  public var active: Bool?
  public var event: String
  public var action: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(index, forKey: .index)
    try container.encode(label, forKey: .label)
    try container.encode(app, forKey: .app)
    try container.encode(title, forKey: .title)
    // NOTE: nil is written as null.
    try container.encode(active, forKey: .active)
    try container.encode(event, forKey: .event)
    try container.encode(action, forKey: .action)
  }
}

/// `g_signal_event`: the signals of each event type, in the order they were added. A signal's index counts across the
/// event types, in the order of SignalType.
public struct SignalTable {
  private var signals = [[EventSignal]](repeating: [], count: SignalType.allCases.count + 1)

  public init() {}

  public func subscribers(_ type: SignalType) -> [EventSignal] {
    signals[type.rawValue]
  }

  /// `event_signal_add`: a signal replaces the signal with its label.
  public mutating func add(_ signal: EventSignal, _ type: SignalType) {
    if let label = signal.label { remove(label: label) }
    signals[type.rawValue].append(signal)
  }

  /// `event_signal_remove_by_index`
  @discardableResult
  public mutating func remove(at index: Int) -> Bool {
    var signalIndex = 0
    for type in SignalType.allCases {
      for j in signals[type.rawValue].indices {
        if signalIndex == index {
          signals[type.rawValue].remove(at: j)
          return true
        }
        signalIndex += 1
      }
    }

    return false
  }

  /// `event_signal_remove`
  @discardableResult
  public mutating func remove(label: String) -> Bool {
    for type in SignalType.allCases {
      if let j = signals[type.rawValue].firstIndex(where: { $0.label == label }) {
        signals[type.rawValue].remove(at: j)
        return true
      }
    }

    return false
  }

  /// `event_signal_list`: the signals of `signal --list`, in the order of the event types.
  public func list() -> [SignalInfo] {
    var entries: [SignalInfo] = []
    for type in SignalType.allCases {
      for signal in signals[type.rawValue] {
        entries.append(
          SignalInfo(
            index: entries.count, label: signal.label ?? "", app: signal.app?.text ?? "",
            title: signal.title?.text ?? "", active: signal.active, event: type.name,
            action: signal.command ?? ""))
      }
    }

    return entries
  }
}

//
// NOTE: The json line that an event subscriber (`yabai -m subscribe`) receives: the event name, then one key per
// environment variable of the event, lowercase and without the YABAI_ prefix (YABAI_WINDOW_ID -> window_id). The values
// stay strings, as in the environment. JSON.encode sorts the keys, so "event" is not always the first key, and escapes
// control characters, so one event is one line. A dictionary of strings cannot fail to encode; the empty line that the
// guard returns is never written.
//

/// The json line of an event for its subscribers: `{"event":"…","window_id":"…",…}` followed by a newline.
public func eventJSONLine(type: String, arguments: [(name: String, value: String)]) -> [UInt8] {
  var object = ["event": type]
  for argument in arguments {
    let prefix = "YABAI_"
    let name =
      argument.name.hasPrefix(prefix)
      ? String(argument.name.dropFirst(prefix.count)) : argument.name
    object[name.lowercased()] = argument.value
  }

  guard let json = try? JSON.encode(object) else { return [] }
  return json + [UInt8(ascii: "\n")]
}
