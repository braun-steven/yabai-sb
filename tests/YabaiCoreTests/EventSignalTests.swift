import Testing
import YabaiCore
import YabaiTestSupport

private func matches(
  _ type: SignalType, _ app: String?, _ title: String?, _ active: Bool, _ signal: EventSignal
) -> Bool {
  var es = PendingSignal(type)
  es.app = app
  es.title = title
  es.active = active
  return es.matches(signal)
}

@Test("event_signal_filter_properties") func eventSignalFilterProperties() {
  var signal = EventSignal(command: "true")
  signal.app = RulePattern(Token("^Safari$"), exclude: false)
  #expect(signal.app?.regex != nil)

  #expect(matches(.windowFocused, "Safari", "x", false, signal))
  #expect(!matches(.windowFocused, "Mail", "x", false, signal))

  // NOTE: events without an application are never filtered
  #expect(matches(.spaceChanged, nil, nil, false, signal))

  signal.app = RulePattern(Token("^Safari$"), exclude: true)
  #expect(!matches(.windowFocused, "Safari", "x", false, signal))
  #expect(matches(.windowFocused, "Mail", "x", false, signal))

  signal.app = RulePattern(Token("^Safari$"), exclude: false)
  signal.active = true
  #expect(matches(.windowMoved, "Safari", "x", true, signal))
  #expect(!matches(.windowMoved, "Safari", "x", false, signal))

  // NOTE: focused windows have no active property to filter on
  #expect(matches(.windowFocused, "Safari", "x", false, signal))

  signal.active = false
  #expect(matches(.applicationHidden, "Safari", nil, false, signal))
  #expect(!matches(.applicationHidden, "Safari", nil, true, signal))
}

@Test("event_signal_args") func eventSignalArgs() {
  var es = PendingSignal(.spaceCreated)
  es.addArgument("YABAI_SPACE_ID", "\(42 as UInt64)")
  es.addArgument("YABAI_SPACE_INDEX", "\(3 as Int32)")

  #expect(es.arguments.count == 2)
  #expect(es.arguments[0].name == "YABAI_SPACE_ID")
  #expect(es.arguments[0].value == "42")
  #expect(es.arguments[1].name == "YABAI_SPACE_INDEX")
  #expect(es.arguments[1].value == "3")
}

@Test func signalTypeNames() {
  #expect(SignalType.allCases.count == 30)
  #expect(SignalType.applicationLaunched.rawValue == "application_launched")
  #expect(SignalType.systemWoke.rawValue == "system_woke")
  #expect(SignalType.configLoaded.rawValue == "config_loaded")
  #expect(SignalType.configLoaded.name == "config_loaded")
  #expect(
    SignalType.allCases.map(\.name) == [
      "application_launched", "application_terminated", "application_front_switched",
      "application_activated", "application_deactivated", "application_visible",
      "application_hidden",
      "window_created", "window_destroyed", "window_focused", "window_moved", "window_resized",
      "window_minimized", "window_deminimized", "window_title_changed", "space_created",
      "space_destroyed", "space_changed", "display_added", "display_removed", "display_moved",
      "display_resized", "display_changed", "mission_control_enter", "mission_control_exit",
      "dock_did_change_pref", "dock_did_restart", "menu_bar_hidden_changed", "system_woke",
      "config_loaded",
    ])

  for type in SignalType.allCases {
    #expect(SignalType(name: Token(type.name)) == type)
  }

  #expect(SignalType(name: Token("signal_type_unknown")) == nil)
  #expect(SignalType(name: Token("signal_type_count")) == nil)
  #expect(SignalType(name: Token("window_focused ")) == nil)
}

private func signal(_ label: String?, _ command: String) -> EventSignal {
  var signal = EventSignal(command: command)
  signal.label = label
  return signal
}

@Test func signalTableAddsRemovesAndLists() throws {
  var table = SignalTable()
  #expect(table.list().isEmpty)

  table.add(signal("a", "echo a"), .windowFocused)
  table.add(signal(nil, "echo b"), .applicationLaunched)
  table.add(signal("c", "echo \"c\""), .windowFocused)
  #expect(table.signals(for: .windowFocused).map(\.command) == ["echo a", "echo \"c\""])

  // NOTE: the index counts in the order of the event types, not in the order the signals were added
  var titled = signal(nil, "x")
  titled.title = RulePattern(Token("^T$"), exclude: true)
  titled.active = false
  table.add(titled, .applicationLaunched)
  // NOTE: SignalInfo's memberwise init is internal, so the entries are compared as their json.
  #expect(
    String(decoding: try JSON.encode(table.list()), as: UTF8.self)
      == "[{\"action\":\"echo b\",\"active\":null,\"app\":\"\",\"event\":\"application_launched\",\"index\":0,\"label\":\"\",\"title\":\"\"},"
      + "{\"action\":\"x\",\"active\":false,\"app\":\"\",\"event\":\"application_launched\",\"index\":1,\"label\":\"\",\"title\":\"^T$\"},"
      + "{\"action\":\"echo a\",\"active\":null,\"app\":\"\",\"event\":\"window_focused\",\"index\":2,\"label\":\"a\",\"title\":\"\"},"
      + "{\"action\":\"echo \\\"c\\\"\",\"active\":null,\"app\":\"\",\"event\":\"window_focused\",\"index\":3,\"label\":\"c\",\"title\":\"\"}]"
  )
  #expect(
    String(decoding: try JSON.encode(table.list()), as: UTF8.self).hasPrefix(
      "[{\"action\":\"echo b\",\"active\":null,\"app\":\"\",\"event\":\"application_launched\",\"index\":0,\"label\":\"\",\"title\":\"\"}"
    ))

  // NOTE: a signal replaces the signal with its label, also of another event type
  table.add(signal("a", "echo moved"), .spaceChanged)
  #expect(table.signals(for: .windowFocused).map(\.command) == ["echo \"c\""])
  #expect(table.signals(for: .spaceChanged).map(\.command) == ["echo moved"])

  #expect(table.remove(at: 1) == true)
  #expect(table.signals(for: .applicationLaunched).map(\.command) == ["echo b"])
  #expect(table.remove(at: 3) == false)
  #expect(table.remove(label: "c") == true)
  #expect(table.remove(label: "c") == false)
  #expect(table.remove(label: "") == false)
  #expect(table.signals(for: .windowFocused).isEmpty)

  // NOTE: labels compare by canonical equivalence
  table.add(signal("\u{e9}", "echo e"), .windowFocused)
  #expect(table.remove(label: "e\u{301}") == true)
  #expect(table.signals(for: .windowFocused).isEmpty)
}

@Test(arguments: [false, true])
func signalInvalidPatternsAdmitAndNilTextMatchesEmpty(exclude: Bool) {
  var definition = EventSignal(command: "true")
  definition.app = RulePattern(Token("("), exclude: exclude)
  definition.title = RulePattern(Token("["), exclude: exclude)
  #expect(matches(.windowMoved, nil, nil, false, definition))
  definition.app = RulePattern(Token("^$"), exclude: exclude)
  definition.title = nil
  #expect(matches(.windowMoved, nil, nil, false, definition) == !exclude)
}

@Test func signalTableNormalizesEmptyBucketsAndPreservesReplacementOrder() {
  var table = SignalTable()
  table.add(signal("first", "a"), .windowFocused)
  table.add(signal("second", "b"), .windowFocused)
  table.add(signal("first", "replacement"), .windowFocused)
  #expect(table.signals(for: .windowFocused).map(\.command) == ["b", "replacement"])
  #expect(table.remove(label: "second") == true)
  #expect(table.remove(at: 0) == true)
  #expect(table == SignalTable())
  #expect(table.remove(at: -1) == false)
  table.add(signal("move", "a"), .windowFocused)
  table.add(signal("move", "b"), .spaceChanged)
  var expected = SignalTable()
  expected.add(signal("move", "b"), .spaceChanged)
  #expect(table == expected)
}
