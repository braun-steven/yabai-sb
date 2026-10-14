import Darwin

//
// NOTE: The signals of the daemon: the commands that a user runs on events (`yabai -m signal --add`). The event
// handlers push a PendingSignal for each event that has signals, and after the handler the event loop runs the command
// of every signal whose filters match it. Ported from src/event_signal.c; the part that reads the C managers and runs
// the commands is Sources/Yabai/EventSignal.swift.
//

/// `enum signal_type` (src/event_signal.h) with the names of `signal_type_str`. The raw values are those of the C
/// enum, which the C event handlers pass to `event_signal_push`.
public enum SignalType: Int, CaseIterable, Sendable
{
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

    public var name: String
    {
        switch self {
        case .applicationLaunched:      "application_launched"
        case .applicationTerminated:    "application_terminated"
        case .applicationFrontSwitched: "application_front_switched"
        case .applicationActivated:     "application_activated"
        case .applicationDeactivated:   "application_deactivated"
        case .applicationVisible:       "application_visible"
        case .applicationHidden:        "application_hidden"
        case .windowCreated:            "window_created"
        case .windowDestroyed:          "window_destroyed"
        case .windowFocused:            "window_focused"
        case .windowMoved:              "window_moved"
        case .windowResized:            "window_resized"
        case .windowMinimized:          "window_minimized"
        case .windowDeminimized:        "window_deminimized"
        case .windowTitleChanged:       "window_title_changed"
        case .spaceCreated:             "space_created"
        case .spaceDestroyed:           "space_destroyed"
        case .spaceChanged:             "space_changed"
        case .displayAdded:             "display_added"
        case .displayRemoved:           "display_removed"
        case .displayMoved:             "display_moved"
        case .displayResized:           "display_resized"
        case .displayChanged:           "display_changed"
        case .missionControlEnter:      "mission_control_enter"
        case .missionControlExit:       "mission_control_exit"
        case .dockDidChangePref:        "dock_did_change_pref"
        case .dockDidRestart:           "dock_did_restart"
        case .menuBarHiddenChanged:     "menu_bar_hidden_changed"
        case .systemWoke:               "system_woke"
        }
    }

    /// `signal_type_from_string`
    public init?(name: Token)
    {
        guard let type = SignalType.allCases.first(where: { name.equals($0.name) }) else { return nil }
        self = type
    }
}

/// `struct event_signal`: a signal pushed while an event is handled. It holds the environment variables of the
/// commands and the properties (app, title, active) that the signals of its type can filter on.
public struct PendingSignal
{
    public let type: SignalType
    public private(set) var arguments: [(name: String, value: String)] = []
    public var app: String?
    public var title: String?
    public var active = false

    public init(_ type: SignalType)
    {
        self.type = type
    }

    /// `event_signal_add_arg`
    public mutating func addArgument(_ name: String, _ value: String)
    {
        assert(arguments.count < 4)
        arguments.append((name, value))
    }

    private static func regexMismatch(_ pattern: RulePattern?, _ text: String?) -> Bool
    {
        guard let pattern, let regex = pattern.regex else { return false }
        let matched = regexec(regex.pointer, text ?? "", 0, nil, 0) == 0
        return matched == pattern.exclude
    }

    private func activeMismatch(_ signal: EventSignal) -> Bool
    {
        signal.active != .undefined && active != (signal.active == .yes)
    }

    //
    // NOTE: Returns true when the signal does not apply to the event. Each event type only reports the
    // properties (app, title, active) that its signals can filter on.
    //

    /// `event_signal_filter`
    public func filters(_ signal: EventSignal) -> Bool
    {
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

        if app && PendingSignal.regexMismatch(signal.app, self.app)       { return true }
        if title && PendingSignal.regexMismatch(signal.title, self.title) { return true }
        if active && activeMismatch(signal)                               { return true }

        return false
    }
}

/// `g_signal_event`: the signals of each event type, in the order they were added. A signal's index counts across the
/// event types, in the order of SignalType.
public struct SignalTable
{
    private var signals = [[EventSignal]](repeating: [], count: SignalType.allCases.count + 1)

    public init() {}

    public func subscribers(_ type: SignalType) -> [EventSignal]
    {
        signals[type.rawValue]
    }

    /// `event_signal_add`: a signal replaces the signal with its label.
    public mutating func add(_ signal: EventSignal, _ type: SignalType)
    {
        if let label = signal.label { remove(label: label) }
        signals[type.rawValue].append(signal)
    }

    /// `event_signal_remove_by_index`
    @discardableResult
    public mutating func remove(at index: Int) -> Bool
    {
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
    public mutating func remove(label: String) -> Bool
    {
        for type in SignalType.allCases {
            if let j = signals[type.rawValue].firstIndex(where: { $0.label?.utf8.elementsEqual(label.utf8) ?? false }) {
                signals[type.rawValue].remove(at: j)
                return true
            }
        }

        return false
    }

    /// `event_signal_serialize`
    private static func serialize(_ signal: EventSignal, _ type: SignalType, _ index: Int) -> String
    {
        let active = switch signal.active {
        case .undefined: "null"
        case .yes:       "true"
        case .no:        "false"
        }

        return "{\n"
             + "\t\"index\":\(index),\n"
             + "\t\"label\":\"\(JSON.string(signal.label))\",\n"
             + "\t\"app\":\"\(JSON.string(signal.app?.text))\",\n"
             + "\t\"title\":\"\(JSON.string(signal.title?.text))\",\n"
             + "\t\"active\":\(active),\n"
             + "\t\"event\":\"\(type.name)\",\n"
             + "\t\"action\":\"\(JSON.string(signal.command))\"\n"
             + "}"
    }

    /// `event_signal_list`: the json of `signal --list`.
    public func list() -> String
    {
        var entries: [String] = []
        for type in SignalType.allCases {
            for signal in signals[type.rawValue] {
                entries.append(SignalTable.serialize(signal, type, entries.count))
            }
        }

        return "[" + entries.joined(separator: ",") + "]\n"
    }
}
