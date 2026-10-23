import Testing

@testable import YabaiCore

/// The "Target format" document of doc/config-refactor/overview.md.
private let targetFormat = """
  #:schema ./yabai.schema.json

  [daemon]
  auto_reload = true
  load_scripting_addition = true

  [config]
  mouse_follows_focus = false
  window_shadow = "float"            # also true / false
  window_gap = 10
  active_window_border_color = 0xff51afef
  tab_bar_font = "system:12"
  space_layout = ["15", "10:5", "10:5:1b"]
  scratchpad_grid = "40:40:1:1:38:38"
  external_bar = "all:0:0"

  [[space]]                          # per-space settings, labels and pins
  index = 11
  label = "chat"
  pin = "1"                          # DISPLAY_SEL
  window_gap = 0

  [[rule]]                           # the keys of `rule --add`; order is kept
  app = "^Calendar$"
  space = 9
  insert = "stack"

  [[rule]]
  label = "Finder"
  app = "^Finder$"
  title = { not = "^(Copy|Move)$" }  # title!=…
  manage = false

  [[signal]]
  event = "window_focused"
  action = "sketchybar --trigger window_focus"
  """

private func decodeErrors(_ source: String) -> [ConfigDocumentError] {
  do {
    _ = try ConfigDocument.decode(source)
    return []
  } catch {
    return error.errors
  }
}

private func key(_ name: String, _ value: ConfigValue, _ keyPath: String, negated: Bool = false)
  -> ConfigKey
{
  ConfigKey(name: name, negated: negated, value: value, keyPath: keyPath)
}

@Test func targetFormatDocumentDecodesToItsValues() throws {
  var expected = ConfigDocument()
  expected.daemon.loadScriptingAddition = true
  expected.options = [
    ConfigOptionEntry(
      name: .mouseFollowsFocus, value: .bool(false), keyPath: "config.mouse_follows_focus"),
    ConfigOptionEntry(
      name: .windowShadow, value: .string("float"), keyPath: "config.window_shadow"),
    ConfigOptionEntry(name: .windowGap, value: .integer(10), keyPath: "config.window_gap"),
    ConfigOptionEntry(
      name: .activeWindowBorderColor, value: .integer(0xff51_afef),
      keyPath: "config.active_window_border_color"),
    ConfigOptionEntry(
      name: .tabBarFont, value: .string("system:12"), keyPath: "config.tab_bar_font"),
    ConfigOptionEntry(
      name: .scratchpadGrid, value: .string("40:40:1:1:38:38"), keyPath: "config.scratchpad_grid"),
    ConfigOptionEntry(
      name: .externalBar, value: .string("all:0:0"), keyPath: "config.external_bar"),
    // the array comes after the plain values (see the key order in ConfigDocumentDecoding.swift)
    ConfigOptionEntry(
      name: .spaceLayout, value: .strings(["15", "10:5", "10:5:1b"]), keyPath: "config.space_layout"
    ),
  ]
  expected.spaces = [
    SpaceEntry(
      index: 11, label: "chat", pin: "1",
      options: [
        ConfigOptionEntry(name: .windowGap, value: .integer(0), keyPath: "space[0].window_gap")
      ],
      keyPath: "space[0]")
  ]
  expected.rules = [
    RuleEntry(
      keys: [
        key("app", .string("^Calendar$"), "rule[0].app"),
        key("space", .integer(9), "rule[0].space"),
        key("insert", .string("stack"), "rule[0].insert"),
      ],
      oneShot: false, keyPath: "rule[0]"),
    RuleEntry(
      keys: [
        key("label", .string("Finder"), "rule[1].label"),
        key("app", .string("^Finder$"), "rule[1].app"),
        key("manage", .bool(false), "rule[1].manage"),
        // the inline table comes after the plain values
        key("title", .string("^(Copy|Move)$"), "rule[1].title", negated: true),
      ],
      oneShot: false, keyPath: "rule[1]"),
  ]
  expected.signals = [
    SignalEntry(
      keys: [
        key("event", .string("window_focused"), "signal[0].event"),
        key("action", .string("sketchybar --trigger window_focus"), "signal[0].action"),
      ],
      keyPath: "signal[0]")
  ]

  #expect(try ConfigDocument.decode(targetFormat) == expected)
}

@Test func emptyFileIsTheDefaultDocument() throws {
  #expect(try ConfigDocument.decode("") == ConfigDocument())
  #expect(ConfigDocument().daemon.autoReload)
  #expect(!ConfigDocument().daemon.loadScriptingAddition)
}

@Test func ruleAndSignalExclusionsAndOneShotDecode() throws {
  let document = try ConfigDocument.decode(
    """
    [[rule]]
    one_shot = true
    title = { not = "^Copy$" }
    label = "once"

    [[signal]]
    event = "window_focused"
    app = { not = "^Finder$" }
    active = true
    action = "echo"
    """)
  #expect(document.rules.map(\.oneShot) == [true])
  // NOTE: The inline tables (`title`, `app`) come after the plain values in the key order.
  #expect(
    document.rules[0].keys == [
      key("label", .string("once"), "rule[0].label"),
      key("title", .string("^Copy$"), "rule[0].title", negated: true),
    ])
  #expect(
    document.signals[0].keys == [
      key("event", .string("window_focused"), "signal[0].event"),
      key("active", .bool(true), "signal[0].active"),
      key("action", .string("echo"), "signal[0].action"),
      key("app", .string("^Finder$"), "signal[0].app", negated: true),
    ])
}

@Test func valuesOfEveryScalarKindDecodeWithoutRange() throws {
  // NOTE: Ranges and choices belong to the handlers (C2.2); the decoder only types the values.
  let document = try ConfigDocument.decode(
    """
    [config]
    window_gap = -4
    window_opacity_duration = 0.25
    window_shadow = "float"
    """)
  #expect(
    document.options == [
      ConfigOptionEntry(name: .windowGap, value: .integer(-4), keyPath: "config.window_gap"),
      ConfigOptionEntry(
        name: .windowOpacityDuration, value: .float(0.25), keyPath: "config.window_opacity_duration"
      ),
      ConfigOptionEntry(
        name: .windowShadow, value: .string("float"), keyPath: "config.window_shadow"),
    ])
}

@Test(arguments: ConfigCommand.Name.spaceScoped.sorted { $0.rawValue < $1.rawValue })
func everySpaceScopedOptionDecodesInASpace(_ name: ConfigCommand.Name) throws {
  let document = try ConfigDocument.decode("[[space]]\nindex = 1\n\(name.rawValue) = 1\n")
  #expect(document.spaces.first?.options.map(\.name) == [name])
}

@Test func spaceScopedOptionsAreTheOnesThatReadTheSpaceSelector() {
  #expect(
    ConfigCommand.Name.spaceScoped == [
      .topPadding, .bottomPadding, .leftPadding, .rightPadding, .windowGap, .layout, .autoPadding,
    ])
}

// One problem per row: the key path of the problem is the only one reported.
@Test(
  arguments: [
    // unknown table or top-level key
    ("[bogus]\nwindow_gap = 1\n", "bogus"),
    ("foo = 1\n", "foo"),
    // unknown option in [config] and [daemon]
    ("[config]\nwindow_gapp = 1\n", "config.window_gapp"),
    ("[daemon]\nauto_reloads = true\n", "daemon.auto_reloads"),
    // wrong type: a table where a table belongs, an array where a scalar belongs
    ("config = 1\n", "config"),
    ("[config]\nwindow_gap = [1, 2]\n", "config.window_gap"),
    ("[daemon]\nauto_reload = \"yes\"\n", "daemon.auto_reload"),
    ("[config]\nspace_layout = \"15\"\n", "config.space_layout"),
    ("[config]\nspace_layout = [\"15\", 2]\n", "config.space_layout[1]"),
    ("space = 1\n", "space"),
    // unknown key in [[space]], an option that does not take --space, a missing or invalid index
    ("[[space]]\nindex = 1\nbogus = 1\n", "space[0].bogus"),
    ("[[space]]\nindex = 1\nmouse_follows_focus = true\n", "space[0].mouse_follows_focus"),
    ("[[space]]\nindex = 1\nspace_layout = [\"15\"]\n", "space[0].space_layout"),
    ("[[space]]\nlabel = \"chat\"\n", "space[0].index"),
    ("[[space]]\nindex = 0\n", "space[0].index"),
    ("[[space]]\nindex = \"1\"\n", "space[0].index"),
    // duplicate space index, reported at the later table
    ("[[space]]\nindex = 1\n[[space]]\nindex = 1\n", "space[1].index"),
    // unknown key in [[rule]], not on a key that cannot be negated, wrong value shapes
    ("[[rule]]\napp = \"x\"\nbogus = 1\n", "rule[0].bogus"),
    ("[[rule]]\napp = \"x\"\nspace = { not = \"1\" }\n", "rule[0].space.not"),
    ("[[rule]]\ntitle = { not = 5 }\n", "rule[0].title.not"),
    ("[[rule]]\napp = { exclude = \"x\" }\n", "rule[0].app"),
    ("[[rule]]\napp = \"x\"\nspace = [1]\n", "rule[0].space"),
    ("[[rule]]\napp = \"x\"\none_shot = \"yes\"\n", "rule[0].one_shot"),
    // signal: unknown key, missing event or action, not on a key that cannot be negated
    ("[[signal]]\nevent = \"window_focused\"\nbogus = 1\naction = \"x\"\n", "signal[0].bogus"),
    ("[[signal]]\nevent = \"window_focused\"\n", "signal[0].action"),
    ("[[signal]]\naction = \"x\"\n", "signal[0].event"),
    ("[[signal]]\nevent = { not = \"x\" }\naction = \"y\"\n", "signal[0].event.not"),
  ] as [(String, String)])
func oneProblemIsReportedAtItsKeyPath(_ source: String, _ keyPath: String) {
  #expect(decodeErrors(source).map(\.keyPath) == [keyPath])
}

@Test func everyProblemOfTheFileIsReported() {
  let errors = decodeErrors(
    """
    [bogus]
    [daemon]
    auto_reload = 1
    [config]
    window_gapp = 1
    [[space]]
    label = "no index"
    """)
  #expect(errors.count == 4)
  #expect(
    Set(errors.map(\.keyPath)) == [
      "bogus", "daemon.auto_reload", "config.window_gapp", "space[0].index",
    ])
}

@Test func syntaxErrorKeepsItsLineAndIsReportedForTheWholeFile() {
  let errors = decodeErrors("a = 1\nb = \n")
  #expect(errors.count == 1)
  #expect(errors.first?.keyPath == "")
  #expect(errors.first?.line == 2)
}
