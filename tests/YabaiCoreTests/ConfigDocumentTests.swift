import Testing

@testable import YabaiCore

/// The "Target format" document of doc/config-refactor/overview.md.
let targetFormat = """
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
      name: .spaceLayout, value: .strings(["15", "10:5", "10:5:1b"]), keyPath: "config.space_layout"
    ),
    ConfigOptionEntry(
      name: .scratchpadGrid, value: .string("40:40:1:1:38:38"), keyPath: "config.scratchpad_grid"),
    ConfigOptionEntry(
      name: .externalBar, value: .string("all:0:0"), keyPath: "config.external_bar"),
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
        key("title", .string("^(Copy|Move)$"), "rule[1].title", negated: true),
        key("manage", .bool(false), "rule[1].manage"),
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
  // NOTE: The keys keep the file order, the inline tables (`title`, `app`) included.
  #expect(
    document.rules[0].keys == [
      key("title", .string("^Copy$"), "rule[0].title", negated: true),
      key("label", .string("once"), "rule[0].label"),
    ])
  #expect(
    document.signals[0].keys == [
      key("event", .string("window_focused"), "signal[0].event"),
      key("app", .string("^Finder$"), "signal[0].app", negated: true),
      key("active", .bool(true), "signal[0].active"),
      key("action", .string("echo"), "signal[0].action"),
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

@Test(
  arguments: [
    ("rgb(81, 175, 239)", 0xff51_afef),
    ("rgba(81,175,239,0.5)", 0x8051_afef),
    ("RGBA( 0 , 0 , 0 , 0 )", 0x0000_0000),
    ("rgba(255, 255, 255, 1)", 0xffff_ffff),
  ] as [(String, Int)])
func rgbColorStringsDecodeToTheirInteger(_ text: String, _ color: Int) throws {
  let document = try ConfigDocument.decode("[config]\nactive_window_border_color = \"\(text)\"\n")
  #expect(document.options.map(\.value) == [.integer(color)])
}

@Test func hexColorStringAndRGBStringOfAnotherOptionStayStrings() throws {
  let document = try ConfigDocument.decode(
    """
    [config]
    active_window_border_color = "0xff51afef"
    tab_bar_font = "rgb(1, 2, 3)"
    """)
  #expect(document.options.map(\.value) == [.string("0xff51afef"), .string("rgb(1, 2, 3)")])
}

@Test(
  arguments: [
    "rgb(256, 0, 0)", "rgb(1, 2)", "rgb(1, 2, 3, 4)", "rgba(1, 2, 3)", "rgba(1, 2, 3, 1.5)",
    "rgba(1, 2, 3, nan)", "rgb(-1, 0, 0)", "rgb(1.5, 0, 0)", "rgb(1, 2, 3", "rgbx(1, 2, 3)",
    "rgb(1, , 3)",
  ])
func malformedRGBColorIsAProblemOfItsKey(_ text: String) {
  let errors = decodeErrors("[config]\nnormal_window_border_color = \"\(text)\"\n")
  #expect(errors.map(\.keyPath) == ["config.normal_window_border_color"])
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

// The line of a problem found after parsing is the line of its key path (`TOMLKeyLocator`).
@Test(
  arguments: [
    ("[config]\n\nwindow_gapp = 1\n", "config.window_gapp", 3),
    ("[daemon]\nauto_reload = 1\n", "daemon.auto_reload", 2),
    ("[bogus]\n", "bogus", 1),
    ("[[space]]\nlabel = \"chat\"\n", "space[0].index", 1),
    ("[[space]]\nindex = 1\n\n[[space]]\nindex = 1\n", "space[1].index", 5),
    ("[[rule]]\napp = \"x\"\nspace = { not = \"1\" }\n", "rule[0].space.not", 3),
    ("[config]\nspace_layout = [\n  \"15\",\n  2,\n]\n", "config.space_layout[1]", 2),
  ] as [(String, String, Int)])
func semanticProblemCarriesTheLineOfItsKey(_ source: String, _ keyPath: String, _ line: Int) {
  let errors = decodeErrors(source)
  #expect(errors.map(\.keyPath) == [keyPath])
  #expect(errors.first?.line == line)
}

@Test func syntaxErrorKeepsItsLineAndIsReportedForTheWholeFile() {
  let errors = decodeErrors("a = 1\nb = \n")
  #expect(errors.count == 1)
  #expect(errors.first?.keyPath == "")
  #expect(errors.first?.line == 2)
}
