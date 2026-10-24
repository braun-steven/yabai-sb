import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: Tests of the renderer of a ConfigDocument (`ConfigRender.swift`, `toml()`): the text it writes reads back as the same
// document. The keys are written in the document's order, and the decoder reads them in file order, so a document is
// written and read back as it is.
//

// MARK: - Samples

@Test func rendersEachSectionAndReadsItBack() throws {
  var document = ConfigDocument()
  document.daemon.loadScriptingAddition = true
  document.options = [
    ConfigOptionEntry(name: .windowGap, value: .integer(10), keyPath: "config.window_gap"),
    ConfigOptionEntry(
      name: .activeWindowBorderColor, value: .integer(0xff51_afef),
      keyPath: "config.active_window_border_color"),
    ConfigOptionEntry(
      name: .spaceLayout, value: .strings(["15", "10:5"]), keyPath: "config.space_layout"),
  ]
  document.spaces = [
    SpaceEntry(
      index: 2, label: "chat", pin: "1",
      options: [
        ConfigOptionEntry(name: .windowGap, value: .integer(0), keyPath: "space[0].window_gap")
      ],
      keyPath: "space[0]")
  ]
  document.rules = [
    RuleEntry(
      keys: [
        ConfigKey(
          name: "app", negated: false, value: .string("^Calendar$"), keyPath: "rule[0].app"),
        ConfigKey(name: "space", negated: false, value: .integer(9), keyPath: "rule[0].space"),
        ConfigKey(
          name: "title", negated: true, value: .string("^(Copy|Move)$"), keyPath: "rule[0].title"),
      ], oneShot: true, keyPath: "rule[0]")
  ]
  document.signals = [
    SignalEntry(
      keys: [
        ConfigKey(
          name: "event", negated: false, value: .string("window_focused"),
          keyPath: "signal[0].event"),
        ConfigKey(name: "active", negated: false, value: .bool(true), keyPath: "signal[0].active"),
        ConfigKey(
          name: "action", negated: false, value: .string("echo hi"), keyPath: "signal[0].action"),
      ], keyPath: "signal[0]")
  ]

  let text = document.toml(comments: ["config.window_gap": "default"])
  #expect(
    text == """
      [daemon]
      auto_reload = true
      load_scripting_addition = true

      [config]
      window_gap = 10 # default
      active_window_border_color = 0xff51afef
      space_layout = ["15", "10:5"]

      [[space]]
      index = 2
      label = "chat"
      pin = "1"
      window_gap = 0

      [[rule]]
      app = "^Calendar$"
      space = 9
      title = { not = "^(Copy|Move)$" }
      one_shot = true

      [[signal]]
      event = "window_focused"
      active = true
      action = "echo hi"

      """)

  let decoded = try ConfigDocument.decode(text)
  #expect(decoded == document)
}

@Test func writesColorsAsHexAndOtherIntegersAsDecimals() {
  var document = ConfigDocument()
  document.options = [
    ConfigOptionEntry(
      name: .insertFeedbackColor, value: .integer(0), keyPath: "config.insert_feedback_color"),
    ConfigOptionEntry(name: .windowGap, value: .integer(-3), keyPath: "config.window_gap"),
  ]
  #expect(document.toml().contains("insert_feedback_color = 0x00000000\n"))
  #expect(document.toml().contains("window_gap = -3\n"))
}

@Test func writesStringsWithTheEscapesTOMLNeeds() throws {
  let text = "a \"quoted\" \\ back\tslash\u{1}\u{7F} é"
  var document = ConfigDocument()
  document.signals = [
    SignalEntry(
      keys: [
        ConfigKey(
          name: "event", negated: false, value: .string("window_focused"),
          keyPath: "signal[0].event"),
        ConfigKey(
          name: "action", negated: false, value: .string(text), keyPath: "signal[0].action"),
      ], keyPath: "signal[0]")
  ]
  let rendered = document.toml()
  #expect(rendered.contains(#"action = "a \"quoted\" \\ back\tslash\u0001\u007F é""#))
  #expect(try ConfigDocument.decode(rendered) == document)
}

@Test func writesFloatsThatReadBackAsFloats() throws {
  var document = ConfigDocument()
  document.options = [
    ConfigOptionEntry(name: .windowOpacity, value: .float(0.5), keyPath: "config.window_opacity"),
    ConfigOptionEntry(
      name: .windowBorderWidth, value: .float(4), keyPath: "config.window_border_width"),
    ConfigOptionEntry(
      name: .windowOpacityDuration, value: .float(1e-7), keyPath: "config.window_opacity_duration"),
  ]
  #expect(try ConfigDocument.decode(document.toml()) == document)
}

// MARK: - Properties

/// Random picks, read in order. Each pick is taken modulo the number of choices at its point, and zero once the picks
/// run out, so a shrunk input gives a smaller document.
private struct RenderPicks {
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

// NOTE: The strings include the characters that need an escape, and an empty-looking value that is not empty.
private let renderStrings = [
  "x", "^Finder$", "sketchybar --trigger \"window_focus\"", "a\\b", "tab\there", "é",
]

private func randomScalar(_ picks: inout RenderPicks) -> ConfigValue {
  switch picks.next(4) {
  case 0: return .bool(picks.bool())
  case 1: return .integer(picks.next(100_000) - 500)
  case 2: return .float(Double(picks.next(1000)) / 8)
  default: return .string(renderStrings[picks.next(renderStrings.count)])
  }
}

/// A random document: options, spaces, rules and signals with random values.
private func randomNormalizedDocument(_ picks: inout RenderPicks) -> ConfigDocument {
  var document = ConfigDocument()
  document.daemon.autoReload = picks.bool()
  document.daemon.loadScriptingAddition = picks.bool()

  var options: [ConfigOptionEntry] = []
  for name in ConfigCommand.Name.allCases where !ConfigCommand.Name.spaceScoped.contains(name) {
    guard picks.bool() else { continue }
    let value: ConfigValue
    if name == .spaceLayout {
      var layouts: [String] = []
      for _ in 0..<picks.next(3) { layouts.append(String(picks.next(20))) }
      value = .strings(layouts)
    } else {
      value = randomScalar(&picks)
    }
    options.append(ConfigOptionEntry(name: name, value: value, keyPath: "config.\(name.rawValue)"))
  }
  document.options = options

  let scoped = ConfigCommand.Name.spaceScoped.sorted { $0.rawValue < $1.rawValue }
  for position in 0..<picks.next(3) {
    var space = SpaceEntry(
      index: position + 1, label: nil, pin: nil, options: [], keyPath: "space[\(position)]")
    if picks.bool() { space.label = renderStrings[picks.next(renderStrings.count)] }
    if picks.bool() { space.pin = "\(picks.next(3) + 1)" }
    for name in scoped where picks.bool() {
      space.options.append(
        ConfigOptionEntry(
          name: name, value: randomScalar(&picks), keyPath: "space[\(position)].\(name.rawValue)"))
    }
    document.spaces.append(space)
  }

  let ruleNames = ConfigTableKeys.rule.sorted()
  for position in 0..<picks.next(3) {
    var keys: [ConfigKey] = []
    for name in ruleNames where picks.bool() {
      let negated = ConfigTableKeys.ruleNegatable.contains(name) && picks.bool()
      let value: ConfigValue =
        negated ? .string(renderStrings[picks.next(renderStrings.count)]) : randomScalar(&picks)
      keys.append(
        ConfigKey(name: name, negated: negated, value: value, keyPath: "rule[\(position)].\(name)"))
    }
    keys = keys.filter { !$0.negated } + keys.filter { $0.negated }
    document.rules.append(
      RuleEntry(keys: keys, oneShot: picks.bool(), keyPath: "rule[\(position)]"))
  }

  for position in 0..<picks.next(3) {
    var keys = [
      ConfigKey(
        name: "event", negated: false, value: .string("window_focused"),
        keyPath: "signal[\(position)].event"),
      ConfigKey(
        name: "action", negated: false,
        value: .string(renderStrings[picks.next(renderStrings.count)]),
        keyPath: "signal[\(position)].action"),
    ]
    if picks.bool() {
      keys.append(
        ConfigKey(
          name: "label", negated: false,
          value: .string(renderStrings[picks.next(renderStrings.count)]),
          keyPath: "signal[\(position)].label"))
    }
    if picks.bool() {
      keys.append(
        ConfigKey(
          name: "active", negated: false, value: .bool(picks.bool()),
          keyPath: "signal[\(position)].active"))
    }
    for name in ["app", "title"] where picks.bool() {
      let negated = picks.bool()
      keys.append(
        ConfigKey(
          name: name, negated: negated,
          value: .string(renderStrings[picks.next(renderStrings.count)]),
          keyPath: "signal[\(position)].\(name)"))
    }
    keys = keys.filter { !$0.negated } + keys.filter { $0.negated }
    document.signals.append(SignalEntry(keys: keys, keyPath: "signal[\(position)]"))
  }
  return document
}

// NOTE: Every document in the apply order reads back as the same document: the text of toml() decodes to it.
@Test func renderedDocumentsReadBackAsTheSameDocument() async {
  await propertyCheck(count: 300, input: Gen<Int>.int(in: 0...1_000_000).array(of: 0...160)) {
    values in
    var picks = RenderPicks(values)
    let document = randomNormalizedDocument(&picks)
    let text = document.toml()
    let decoded = try ConfigDocument.decode(text)
    #expect(decoded == document, "\(text)")
  }
}
