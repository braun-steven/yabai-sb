import Testing
import YabaiCore
import YabaiTestSupport

// NOTE: Ported from tests/src/event_signal.c.

private func filters(_ type: SignalType, _ app: String?, _ title: String?, _ active: Bool, _ signal: EventSignal) -> Bool
{
    var es = PendingSignal(type)
    es.app = app
    es.title = title
    es.active = active
    return es.filters(signal)
}

@Test("event_signal_filter_properties") func eventSignalFilterProperties()
{
    var signal = EventSignal()
    signal.app = RulePattern(Token("^Safari$"), exclude: false)
    #expect(signal.app?.regex != nil)

    #expect(filters(.windowFocused, "Safari", "x", false, signal) == false)
    #expect(filters(.windowFocused, "Mail", "x", false, signal) == true)

    // NOTE: events without an application are never filtered
    #expect(filters(.spaceChanged, nil, nil, false, signal) == false)

    signal.app?.exclude = true
    #expect(filters(.windowFocused, "Safari", "x", false, signal) == true)
    #expect(filters(.windowFocused, "Mail", "x", false, signal) == false)

    signal.app?.exclude = false
    signal.active = true
    #expect(filters(.windowMoved, "Safari", "x", true, signal) == false)
    #expect(filters(.windowMoved, "Safari", "x", false, signal) == true)

    // NOTE: focused windows have no active property to filter on
    #expect(filters(.windowFocused, "Safari", "x", false, signal) == false)

    signal.active = false
    #expect(filters(.applicationHidden, "Safari", nil, false, signal) == false)
    #expect(filters(.applicationHidden, "Safari", nil, true, signal) == true)
}

@Test("event_signal_args") func eventSignalArgs()
{
    var es = PendingSignal(.spaceCreated)
    es.addArgument("YABAI_SPACE_ID", "\(42 as UInt64)")
    es.addArgument("YABAI_SPACE_INDEX", "\(3 as Int32)")

    #expect(es.arguments.count == 2)
    #expect(es.arguments[0].name == "YABAI_SPACE_ID")
    #expect(es.arguments[0].value == "42")
    #expect(es.arguments[1].name == "YABAI_SPACE_INDEX")
    #expect(es.arguments[1].value == "3")
}

@Test func signalTypeNames()
{
    #expect(SignalType.allCases.count == 29)
    #expect(SignalType.applicationLaunched.rawValue == 1)
    #expect(SignalType.systemWoke.rawValue == 29)

    for type in SignalType.allCases {
        #expect(SignalType(name: Token(type.name)) == type)
    }

    #expect(SignalType(name: Token("signal_type_unknown")) == nil)
    #expect(SignalType(name: Token("signal_type_count")) == nil)
    #expect(SignalType(name: Token("window_focused ")) == nil)
}

private func signal(_ label: String?, _ command: String) -> EventSignal
{
    var signal = EventSignal()
    signal.label = label
    signal.command = command
    return signal
}

@Test func signalTableAddsRemovesAndLists()
{
    var table = SignalTable()
    #expect(table.list().isEmpty)

    table.add(signal("a", "echo a"), .windowFocused)
    table.add(signal(nil, "echo b"), .applicationLaunched)
    table.add(signal("c", "echo \"c\""), .windowFocused)
    #expect(table.subscribers(.windowFocused).map(\.command) == ["echo a", "echo \"c\""])

    // NOTE: the index counts in the order of the event types, not in the order the signals were added
    var titled = signal(nil, "x")
    titled.title = RulePattern(Token("^T$"), exclude: true)
    titled.active = false
    table.add(titled, .applicationLaunched)
    // NOTE: SignalInfo's memberwise init is internal, so the entries are compared as their json.
    #expect(String(decoding: JSON.encode(table.list()), as: UTF8.self) == "[{\"action\":\"echo b\",\"active\":null,\"app\":\"\",\"event\":\"application_launched\",\"index\":0,\"label\":\"\",\"title\":\"\"},"
                          + "{\"action\":\"x\",\"active\":false,\"app\":\"\",\"event\":\"application_launched\",\"index\":1,\"label\":\"\",\"title\":\"^T$\"},"
                          + "{\"action\":\"echo a\",\"active\":null,\"app\":\"\",\"event\":\"window_focused\",\"index\":2,\"label\":\"a\",\"title\":\"\"},"
                          + "{\"action\":\"echo \\\"c\\\"\",\"active\":null,\"app\":\"\",\"event\":\"window_focused\",\"index\":3,\"label\":\"c\",\"title\":\"\"}]")
    #expect(String(decoding: JSON.encode(table.list()), as: UTF8.self).hasPrefix("[{\"action\":\"echo b\",\"active\":null,\"app\":\"\",\"event\":\"application_launched\",\"index\":0,\"label\":\"\",\"title\":\"\"}"))

    // NOTE: a signal replaces the signal with its label, also of another event type
    table.add(signal("a", "echo moved"), .spaceChanged)
    #expect(table.subscribers(.windowFocused).map(\.command) == ["echo \"c\""])
    #expect(table.subscribers(.spaceChanged).map(\.command) == ["echo moved"])

    #expect(table.remove(at: 1) == true)
    #expect(table.subscribers(.applicationLaunched).map(\.command) == ["echo b"])
    #expect(table.remove(at: 3) == false)
    #expect(table.remove(label: "c") == true)
    #expect(table.remove(label: "c") == false)
    #expect(table.remove(label: "") == false)
    #expect(table.subscribers(.windowFocused).isEmpty)

    // NOTE: labels compare by canonical equivalence
    table.add(signal("\u{e9}", "echo e"), .windowFocused)
    #expect(table.remove(label: "e\u{301}") == true)
    #expect(table.subscribers(.windowFocused).isEmpty)
}
