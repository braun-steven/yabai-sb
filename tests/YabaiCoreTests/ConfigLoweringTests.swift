import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: Tests of the lowering of a ConfigDocument (`ConfigLowering.swift`): the words of each setting are the words of
// the yabai message that sets it, and the document's messages follow the apply order.
//

/// One `[config]` option of the samples: its TOML value, and the words that `config <name>` takes for it.
private struct OptionSample {
  let name: ConfigCommand.Name
  let toml: String
  let words: [String]
}

/// Every option, with a valid value. The exhaustiveness test fails for an option missing here.
private let optionSamples: [OptionSample] = [
  OptionSample(name: .debugOutput, toml: "true", words: ["on"]),
  OptionSample(name: .mouseFollowsFocus, toml: "false", words: ["off"]),
  OptionSample(name: .focusFollowsMouse, toml: "\"autoraise\"", words: ["autoraise"]),
  OptionSample(name: .displayArrangementOrder, toml: "\"vertical\"", words: ["vertical"]),
  OptionSample(name: .builtinDisplayLast, toml: "true", words: ["on"]),
  OptionSample(name: .windowOriginDisplay, toml: "\"cursor\"", words: ["cursor"]),
  OptionSample(name: .windowOpacity, toml: "true", words: ["on"]),
  OptionSample(name: .windowOpacityDuration, toml: "0.5", words: ["0.5"]),
  OptionSample(name: .windowAnimationDuration, toml: "0.25", words: ["0.25"]),
  OptionSample(name: .windowAnimationEasing, toml: "\"ease_out_quad\"", words: ["ease_out_quad"]),
  OptionSample(name: .windowShadow, toml: "\"float\"", words: ["float"]),
  OptionSample(name: .menubarOpacity, toml: "0.5", words: ["0.5"]),
  OptionSample(name: .activeWindowOpacity, toml: "1.0", words: ["1.0"]),
  OptionSample(name: .normalWindowOpacity, toml: "0.9", words: ["0.9"]),
  OptionSample(name: .insertFeedbackColor, toml: "0xff00ff00", words: ["0xff00ff00"]),
  OptionSample(name: .windowBorder, toml: "true", words: ["on"]),
  OptionSample(name: .windowBorderWidth, toml: "4.0", words: ["4.0"]),
  OptionSample(name: .windowBorderHideSingle, toml: "false", words: ["off"]),
  OptionSample(name: .activeWindowBorderColor, toml: "0xff51afef", words: ["0xff51afef"]),
  OptionSample(name: .normalWindowBorderColor, toml: "0xff595959", words: ["0xff595959"]),
  OptionSample(name: .tabBar, toml: "true", words: ["on"]),
  OptionSample(name: .tabBarHeight, toml: "30", words: ["30"]),
  OptionSample(name: .tabBarOffset, toml: "0", words: ["0"]),
  OptionSample(name: .tabBarFont, toml: "\"system:12\"", words: ["system:12"]),
  OptionSample(name: .tabBarIcons, toml: "false", words: ["off"]),
  OptionSample(name: .tabBarStyle, toml: "\"i3\"", words: ["i3"]),
  OptionSample(name: .tabBarAppearance, toml: "\"system\"", words: ["system"]),
  OptionSample(name: .tabBarBackdrop, toml: "\"blur\"", words: ["blur"]),
  OptionSample(name: .tabBarCardPadding, toml: "6", words: ["6"]),
  OptionSample(name: .tabBarWindowRadius, toml: "10", words: ["10"]),
  OptionSample(name: .tabBarFocusedColor, toml: "0xff1e1e1e", words: ["0xff1e1e1e"]),
  OptionSample(name: .tabBarFocusedTextColor, toml: "0xffffffff", words: ["0xffffffff"]),
  OptionSample(name: .tabBarInactiveColor, toml: "0xff2a2a2a", words: ["0xff2a2a2a"]),
  OptionSample(name: .tabBarInactiveTextColor, toml: "0xff999999", words: ["0xff999999"]),
  OptionSample(name: .tabBarUnfocusedColor, toml: "0xff333333", words: ["0xff333333"]),
  OptionSample(name: .tabBarUnfocusedTextColor, toml: "0xffaaaaaa", words: ["0xffaaaaaa"]),
  OptionSample(name: .tabBarBackdropColor, toml: "0xff000000", words: ["0xff000000"]),
  OptionSample(name: .topPadding, toml: "1", words: ["1"]),
  OptionSample(name: .bottomPadding, toml: "2", words: ["2"]),
  OptionSample(name: .leftPadding, toml: "3", words: ["3"]),
  OptionSample(name: .rightPadding, toml: "4", words: ["4"]),
  OptionSample(name: .layout, toml: "\"tree\"", words: ["tree"]),
  OptionSample(name: .windowGap, toml: "10", words: ["10"]),
  OptionSample(name: .autoPadding, toml: "true", words: ["on"]),
  OptionSample(name: .treeDefaultOrientation, toml: "\"vertical\"", words: ["vertical"]),
  OptionSample(name: .treeWorkspaceLayout, toml: "\"tabbed\"", words: ["tabbed"]),
  OptionSample(name: .treeAutotiling, toml: "false", words: ["off"]),
  OptionSample(name: .focusWrapping, toml: "\"force\"", words: ["force"]),
  OptionSample(name: .spaceAutoBackAndForth, toml: "true", words: ["on"]),
  OptionSample(name: .mouseModifier, toml: "\"alt\"", words: ["alt"]),
  OptionSample(name: .mouseAction1, toml: "\"resize\"", words: ["resize"]),
  OptionSample(name: .mouseAction2, toml: "\"move\"", words: ["move"]),
  OptionSample(name: .mouseDropAction, toml: "\"stack\"", words: ["stack"]),
  OptionSample(name: .mouseDropPreview, toml: "\"ghost\"", words: ["ghost"]),
  OptionSample(name: .mouseDragSplit, toml: "true", words: ["on"]),
  OptionSample(name: .externalBar, toml: "\"all:0:0\"", words: ["all:0:0"]),
  OptionSample(name: .skipWindowFocusAnimation, toml: "true", words: ["on"]),
  OptionSample(name: .spaceLayout, toml: "[\"15\", \"10:5\"]", words: ["15", "10:5"]),
  OptionSample(name: .scratchpadExclusive, toml: "true", words: ["on"]),
  OptionSample(name: .scratchpadRaise, toml: "false", words: ["off"]),
  OptionSample(name: .scratchpadBelow, toml: "true", words: ["on"]),
  OptionSample(name: .scratchpadGrid, toml: "\"40:40:1:1:38:38\"", words: ["40:40:1:1:38:38"]),
]

// The lines come from the locator of the same source; without one, no entry has a line.
@Test func loweredEntriesCarryTheLineOfTheirKeyPath() throws {
  let document = try ConfigDocument.decode(targetFormat)
  let entries = document.lowered(locator: TOMLKeyLocator(source: targetFormat))
  #expect(
    entries.map(\.keyPath) == [
      "config.mouse_follows_focus", "config.window_shadow", "config.window_gap",
      "config.active_window_border_color", "config.tab_bar_font", "config.scratchpad_grid",
      "config.external_bar", "config.space_layout", "space[0].label", "space[0].pin",
      "space[0].window_gap", "rule[0]", "rule[1]", "signal[0]",
    ])
  #expect(entries.map(\.line) == [8, 9, 10, 11, 12, 14, 15, 13, 19, 20, 21, 23, 28, 34])
  #expect(document.lowered().allSatisfy { $0.line == nil })
}

/// Lowers a document text, failing the test when it does not decode.
private func lowered(_ source: String) throws -> [ConfigEntry] {
  try ConfigDocument.decode(source).lowered()
}

@Test func everyOptionLowersToItsMessage() throws {
  // NOTE: Fails for a new option without a sample, since the samples must cover every case.
  #expect(optionSamples.count == ConfigCommand.Name.allCases.count)
  #expect(Set(optionSamples.map(\.name)) == Set(ConfigCommand.Name.allCases))

  var configLines = ""
  var spaceLines = ""
  var expected: [String: [String]] = [:]
  for sample in optionSamples {
    let raw = sample.name.rawValue
    if ConfigCommand.Name.spaceScoped.contains(sample.name) {
      spaceLines += "\(raw) = \(sample.toml)\n"
      expected["space[0].\(raw)"] = ["config", "--space", "2", raw] + sample.words
    } else {
      configLines += "\(raw) = \(sample.toml)\n"
      expected["config.\(raw)"] = ["config", raw] + sample.words
    }
  }

  let entries = try lowered("[config]\n\(configLines)\n[[space]]\nindex = 2\n\(spaceLines)")
  #expect(entries.count == optionSamples.count)
  #expect(
    Dictionary(entries.map { ($0.keyPath, $0.arguments) }, uniquingKeysWith: { $1 }) == expected)
}

@Test func entriesFollowTheApplyOrder() throws {
  let entries = try lowered(
    """
    [config]
    window_gap = 10
    space_layout = ["15"]

    [[space]]
    index = 3
    label = "a"
    pin = "1"
    top_padding = 2

    [[rule]]
    app = "x"

    [[signal]]
    event = "window_focused"
    action = "y"
    """)
  #expect(entries.map(\.kind) == [.option, .spaceLayout, .space, .space, .space, .rule, .signal])
  #expect(
    entries.map(\.arguments) == [
      ["config", "window_gap", "10"],
      ["config", "space_layout", "15"],
      ["space", "3", "--label", "a"],
      ["space", "a", "--pin", "1"],
      ["config", "--space", "3", "top_padding", "2"],
      ["rule", "--add", "app=x"],
      ["signal", "--add", "event=window_focused", "action=y"],
    ])
  #expect(
    entries.map(\.keyPath) == [
      "config.window_gap", "config.space_layout", "space[0].label", "space[0].pin",
      "space[0].top_padding", "rule[0]", "signal[0]",
    ])
}

/// A `[config]` line and the words it lowers to: booleans, colors, floats, the empty list of space_layout, and
/// out-of-range values that the handlers reject.
private let optionValueRows: [(line: String, words: [String])] = [
  ("window_gap = -4", ["config", "window_gap", "-4"]),
  ("window_gap = 10.0", ["config", "window_gap", "10.0"]),
  ("window_border_width = 4.0", ["config", "window_border_width", "4.0"]),
  ("window_opacity_duration = 0.25", ["config", "window_opacity_duration", "0.25"]),
  ("window_shadow = true", ["config", "window_shadow", "on"]),
  ("window_shadow = false", ["config", "window_shadow", "off"]),
  ("window_shadow = \"float\"", ["config", "window_shadow", "float"]),
  (
    "active_window_border_color = 0xff51afef",
    ["config", "active_window_border_color", "0xff51afef"]
  ),
  ("normal_window_border_color = 0x1", ["config", "normal_window_border_color", "0x00000001"]),
  (
    "active_window_border_color = \"rgba(81, 175, 239, 0.8)\"",
    ["config", "active_window_border_color", "0xcc51afef"]
  ),
  (
    "active_window_border_color = \"0xff51afef\"",
    ["config", "active_window_border_color", "0xff51afef"]
  ),
  // NOTE: A color outside 32 bits is written in decimal, and the handler rejects it.
  ("insert_feedback_color = -1", ["config", "insert_feedback_color", "-1"]),
  ("space_layout = []", ["config", "space_layout", "off"]),
  ("space_layout = [\"15\"]", ["config", "space_layout", "15"]),
]

@Test(arguments: optionValueRows)
func optionValuesLowerToTheirWords(_ row: (line: String, words: [String])) throws {
  let entries = try lowered("[config]\n\(row.line)\n")
  #expect(entries.map(\.arguments) == [row.words])
}

/// A rule or signal and the words it lowers to. The keys of a table come in the order of the document, see
/// `ConfigDocumentDecoding.swift`; a signal's `active` is yes or no, the boolean keys of rules are on or off.
private let ruleAndSignalRows: [(source: String, words: [String])] = [
  (
    "[[rule]]\nmanage = false\nsticky = true\nmouse_follows_focus = false\nnative-fullscreen = true\napp = \"^Finder$\"",
    [
      "rule", "--add", "manage=off", "sticky=on", "mouse_follows_focus=off", "native-fullscreen=on",
      "app=^Finder$",
    ]
  ),
  (
    "[[rule]]\none_shot = true\ntitle = { not = \"^Copy$\" }\nlabel = \"once\"",
    ["rule", "--add", "--one-shot", "title!=^Copy$", "label=once"]
  ),
  (
    "[[rule]]\nspace = 9\nopacity = 0.5\nsub-layer = \"above\"\ngrid = \"4:4:0:0:1:1\"",
    ["rule", "--add", "space=9", "opacity=0.5", "sub-layer=above", "grid=4:4:0:0:1:1"]
  ),
  (
    "[[signal]]\nevent = \"window_focused\"\nactive = true\naction = \"echo hi\"\napp = { not = \"^Finder$\" }",
    ["signal", "--add", "event=window_focused", "active=yes", "action=echo hi", "app!=^Finder$"]
  ),
  (
    "[[signal]]\nevent = \"window_focused\"\nactive = false\naction = \"echo\"",
    ["signal", "--add", "event=window_focused", "active=no", "action=echo"]
  ),
]

@Test(arguments: ruleAndSignalRows)
func ruleAndSignalKeysLowerToTheirWords(_ row: (source: String, words: [String])) throws {
  let entries = try lowered(row.source)
  #expect(entries.map(\.arguments) == [row.words])
}

@Test func spaceEntriesLowerToTheirSelectors() throws {
  let entries = try lowered(
    """
    [[space]]
    index = 4
    pin = "2"
    window_gap = 0
    auto_padding = false
    """)
  // NOTE: The pin comes first; the options follow in file order.
  #expect(
    entries.map(\.arguments) == [
      ["space", "4", "--pin", "2"],
      ["config", "--space", "4", "window_gap", "0"],
      ["config", "--space", "4", "auto_padding", "off"],
    ])
}

// MARK: - Properties

/// Random picks, read in order. Each pick is taken modulo the number of choices at its point, and zero once the picks
/// run out, so a shrunk input gives a smaller document.
struct Picks {
  var values: [Int]
  var index = 0

  init(_ values: [Int]) { self.values = values }

  mutating func next(_ choices: Int) -> Int {
    guard index < values.count else { return 0 }
    defer { index += 1 }
    return values[index] % choices
  }

  mutating func bool() -> Bool { next(2) == 1 }
}

// NOTE: No empty string: `label=` is not a key-value pair for the parser, so the handler rejects it as it should.
private let stringPicks = ["x", "^Finder$", "sketchybar --trigger window_focus", "a=b"]
private let ruleKeyNames = ["label", "app", "title", "manage", "space", "opacity", "sticky"]
private let negatableNames: Set<String> = ["app", "title", "role", "subrole"]

private func scalar(_ picks: inout Picks) -> ConfigValue {
  switch picks.next(4) {
  case 0: return .bool(picks.bool())
  case 1: return .integer(picks.next(100_000) - 500)
  case 2: return .float(Double(picks.next(1000)) / 8)
  default: return .string(stringPicks[picks.next(stringPicks.count)])
  }
}

/// A document built from the picks: some options, up to two spaces, rules and signals.
private func randomDocument(_ picks: inout Picks) -> ConfigDocument {
  var document = ConfigDocument()
  for name in ConfigCommand.Name.allCases where !ConfigCommand.Name.spaceScoped.contains(name) {
    if picks.bool() {
      let value: ConfigValue
      if name == .spaceLayout {
        var layouts: [String] = []
        for _ in 0..<picks.next(3) { layouts.append(String(picks.next(20))) }
        value = .strings(layouts)
      } else {
        value = scalar(&picks)
      }
      document.options.append(
        ConfigOptionEntry(name: name, value: value, keyPath: "config.\(name.rawValue)"))
    }
  }

  let scoped = ConfigCommand.Name.spaceScoped.sorted { $0.rawValue < $1.rawValue }
  for position in 0..<picks.next(3) {
    var space = SpaceEntry(
      index: position + 1, label: nil, pin: nil, options: [], keyPath: "space[\(position)]")
    if picks.bool() { space.label = stringPicks[picks.next(stringPicks.count)] }
    if picks.bool() { space.pin = "\(picks.next(3) + 1)" }
    for name in scoped {
      if picks.bool() {
        space.options.append(
          ConfigOptionEntry(
            name: name, value: scalar(&picks), keyPath: "space[\(position)].\(name.rawValue)"))
      }
    }
    document.spaces.append(space)
  }

  for position in 0..<picks.next(3) {
    var keys: [ConfigKey] = []
    for name in ruleKeyNames {
      guard picks.bool() else { continue }
      let negated = negatableNames.contains(name) && picks.bool()
      let value: ConfigValue =
        negated ? .string(stringPicks[picks.next(stringPicks.count)]) : scalar(&picks)
      keys.append(
        ConfigKey(
          name: name, negated: negated, value: value, keyPath: "rule[\(position)].\(name)"))
    }
    document.rules.append(
      RuleEntry(keys: keys, oneShot: picks.bool(), keyPath: "rule[\(position)]"))
  }

  for position in 0..<picks.next(3) {
    let keys = [
      ConfigKey(
        name: "event", negated: false, value: .string("window_focused"),
        keyPath: "signal[\(position)].event"),
      ConfigKey(
        name: "action", negated: false, value: .string(stringPicks[picks.next(stringPicks.count)]),
        keyPath: "signal[\(position)].action"),
    ]
    document.signals.append(SignalEntry(keys: keys, keyPath: "signal[\(position)]"))
  }
  return document
}

// NOTE: Every lowered entry has words, the entries are the settings one by one, they follow the apply order, and each
// key word of a rule or signal is read back by the key-value parser with its key and its exclusion.
@Test func lowerKeepsOneEntryPerSettingInApplyOrder() async {
  await propertyCheck(count: 300, input: Gen<Int>.int(in: 0...1_000_000).array(of: 0...160)) {
    values in
    var picks = Picks(values)
    let document = randomDocument(&picks)
    let entries = document.lowered()

    let settings =
      document.options.count + document.rules.count + document.signals.count
      + document.spaces.reduce(0) {
        $0 + ($1.label == nil ? 0 : 1) + ($1.pin == nil ? 0 : 1) + $1.options.count
      }
    #expect(entries.count == settings)
    #expect(entries.allSatisfy { !$0.arguments.isEmpty })
    #expect(entries.map(\.kind.rawValue) == entries.map(\.kind.rawValue).sorted())

    for (entry, rule) in zip(entries.filter { $0.kind == .rule }, document.rules) {
      let keyWords = entry.arguments.filter { $0 != "--one-shot" }.dropFirst(2)
      #expect(keyWords.count == rule.keys.count)
      for (word, key) in zip(keyWords, rule.keys) {
        let pair = parseKeyValuePair(Token(word))
        #expect(pair?.key.string == key.name)
        #expect(pair?.exclusion == key.negated)
      }
    }
    for (entry, signal) in zip(entries.filter { $0.kind == .signal }, document.signals) {
      let keyWords = entry.arguments.dropFirst(2)
      #expect(keyWords.count == signal.keys.count)
      for (word, key) in zip(keyWords, signal.keys) {
        let pair = parseKeyValuePair(Token(word))
        #expect(pair?.key.string == key.name)
        #expect(pair?.exclusion == key.negated)
      }
    }
  }
}
