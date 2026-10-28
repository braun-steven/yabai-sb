//
// NOTE: The signals of the daemon: the commands that a user runs on events (`yabai -m signal --add`). The event
// handlers push a PendingSignal for each event that has signals, and after the handler the event loop runs the command
// of every signal whose filters match it. The part that reads the managers and runs the commands is
// Sources/Yabai/EventSignal.swift.
//

/// Public event names, in the order used by signal indices and subscription acknowledgements.
public enum SignalType: String, CaseIterable, Sendable {
  case applicationLaunched = "application_launched"
  case applicationTerminated = "application_terminated"
  case applicationFrontSwitched = "application_front_switched"
  case applicationActivated = "application_activated"
  case applicationDeactivated = "application_deactivated"
  case applicationVisible = "application_visible"
  case applicationHidden = "application_hidden"

  case windowCreated = "window_created"
  case windowDestroyed = "window_destroyed"
  case windowFocused = "window_focused"
  case windowMoved = "window_moved"
  case windowResized = "window_resized"
  case windowMinimized = "window_minimized"
  case windowDeminimized = "window_deminimized"
  case windowTitleChanged = "window_title_changed"

  case spaceCreated = "space_created"
  case spaceDestroyed = "space_destroyed"
  case spaceChanged = "space_changed"

  case displayAdded = "display_added"
  case displayRemoved = "display_removed"
  case displayMoved = "display_moved"
  case displayResized = "display_resized"
  case displayChanged = "display_changed"

  case missionControlEnter = "mission_control_enter"
  case missionControlExit = "mission_control_exit"

  case dockDidChangePref = "dock_did_change_pref"
  case dockDidRestart = "dock_did_restart"

  case menuBarHiddenChanged = "menu_bar_hidden_changed"
  case systemWoke = "system_woke"
  case configLoaded = "config_loaded"

  public var name: String { rawValue }

  /// The properties that the signals of this type can filter on. `signal --add` rejects any other filter.
  public var filters: SignalFilters {
    switch self {
    case .applicationLaunched, .applicationActivated, .applicationDeactivated, .applicationVisible:
      [.app]
    case .applicationTerminated, .applicationHidden, .windowDestroyed:
      [.app, .active]
    case .windowCreated, .windowFocused, .windowDeminimized:
      [.app, .title]
    case .windowMoved, .windowResized, .windowMinimized, .windowTitleChanged:
      [.app, .title, .active]
    default:
      []
    }
  }

  public init?(name: Token) {
    self.init(rawValue: name.string)
  }
}

/// The properties of an event that a signal can filter on.
public struct SignalFilters: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let app = SignalFilters(rawValue: 1 << 0)
  public static let title = SignalFilters(rawValue: 1 << 1)
  public static let active = SignalFilters(rawValue: 1 << 2)
}

/// A signal pushed while an event is handled. It holds the environment variables of the
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

  public mutating func addArgument(_ name: String, _ value: String) {
    assert(arguments.count < 4)
    arguments.append((name, value))
  }

  /// Whether the signal applies, considering only the properties this event type reports.
  public func matches(_ signal: EventSignal) -> Bool {
    let supported = type.filters

    if supported.contains(.app), let pattern = signal.app, !pattern.admits(app ?? "") {
      return false
    }
    if supported.contains(.title), let pattern = signal.title, !pattern.admits(title ?? "") {
      return false
    }
    if supported.contains(.active), let required = signal.active, required != active {
      return false
    }

    return true
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

/// The signals of each event type, in the order they were added. A signal's index counts across the
/// event types, in the order of SignalType.
public struct SignalTable: Equatable {
  private var entriesByType: [SignalType: [EventSignal]] = [:]

  public init() {}

  public func signals(for type: SignalType) -> [EventSignal] {
    entriesByType[type] ?? []
  }

  /// A signal replaces the signal with its label, appending to the destination event type.
  public mutating func add(_ signal: EventSignal, _ type: SignalType) {
    if let label = signal.label { remove(label: label) }
    entriesByType[type, default: []].append(signal)
  }

  @discardableResult
  public mutating func remove(at index: Int) -> Bool {
    var signalIndex = 0
    for type in SignalType.allCases {
      for j in signals(for: type).indices {
        if signalIndex == index {
          remove(at: j, from: type)
          return true
        }
        signalIndex += 1
      }
    }

    return false
  }

  @discardableResult
  public mutating func remove(label: String) -> Bool {
    for type in SignalType.allCases {
      if let j = signals(for: type).firstIndex(where: { $0.label == label }) {
        remove(at: j, from: type)
        return true
      }
    }

    return false
  }

  private mutating func remove(at index: Int, from type: SignalType) {
    entriesByType[type]?.remove(at: index)
    if entriesByType[type]?.isEmpty == true { entriesByType[type] = nil }
  }

  /// The signals of `signal --list`, in the order of the event types.
  public func list() -> [SignalInfo] {
    var entries: [SignalInfo] = []
    for type in SignalType.allCases {
      for signal in signals(for: type) {
        entries.append(
          SignalInfo(
            index: entries.count, label: signal.label ?? "", app: signal.app?.text ?? "",
            title: signal.title?.text ?? "", active: signal.active, event: type.name,
            action: signal.command))
      }
    }

    return entries
  }
}

//
// NOTE: Event objects keep the event name and its environment values. Keys are lowercase without YABAI_;
// values remain strings. Transport wraps the object in an event frame; the CLI renders it as a JSON line.
//

/// The event data shared by framed subscriptions and CLI JSON lines.
public func eventObject(type: String, arguments: [(name: String, value: String)]) -> [String:
  String]
{
  var object = ["event": type]
  for argument in arguments {
    let prefix = "YABAI_"
    let name =
      argument.name.hasPrefix(prefix)
      ? String(argument.name.dropFirst(prefix.count)) : argument.name
    object[name.lowercased()] = argument.value
  }

  return object
}

/// The filters and action of a signal.
public struct EventSignal: Equatable {
  public var label: String?
  public var app: RulePattern?
  public var title: RulePattern?
  /// Whether the application or window of the event must be active (focused); nil when it does not matter.
  public var active: Bool?
  public let command: String

  public init(command: String) {
    self.command = command
  }
}
