import CPrivate
import Observation
import Synchronization
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

// NOTE: The handler changes the global managers, so the tests are part of DaemonState.

/// Set when an observed config group changes.
private final class ChangeFlag: Sendable {
  let isSet = Atomic(false)
}

@WM private func runConfig(_ message: String) -> String {
  var response = Response()
  var source = Message(message)
  do {
    try handleDomainConfig(&response, Token(Domain.config), &source)
  } catch {
    response.fail(error)
  }
  return response.text
}

/// A row of the config round trip: a valid value, how the option prints it, and an invalid value with its failure (the
/// unknown-value failure when nil).
struct ConfigCase: CustomTestStringConvertible, Sendable {
  var option: String
  var value: String
  var printed: String
  var invalid: String
  var failure: String? = nil
  /// Whether value is the default (the other rows set a value other than the default).
  var isDefault = false

  var expectedFailure: String {
    if let failure { return failure }
    let expected = configExpectations[option] ?? "(no expectation recorded for \(option))"
    return
      "unknown value '\(invalid)' given to command '\(option)' for domain 'config'; expected \(expected)\n"
  }

  var testDescription: String { "\(option) \(value)" }
}

/// What each option of the config domain names as its valid values, the `; expected …` text of its unknown-value failure.
private let configExpectations: [String: String] = [
  "debug_output": "on or off",
  "mouse_follows_focus": "on or off",
  "focus_follows_mouse": "one of: off, autofocus, autoraise",
  "display_arrangement_order": "one of: default, horizontal, vertical",
  "builtin_display_last": "on or off",
  "window_origin_display": "one of: default, focused, cursor",
  "window_opacity": "on or off",
  "window_opacity_duration": "a number of seconds",
  "window_animation_duration": "a number of seconds (0 turns animations off)",
  "window_animation_easing":
    "one of: ease_in_sine, ease_out_sine, ease_in_out_sine, ease_in_quad, ease_out_quad, ease_in_out_quad, ease_in_cubic, ease_out_cubic, ease_in_out_cubic, ease_in_quart, ease_out_quart, ease_in_out_quart, ease_in_quint, ease_out_quint, ease_in_out_quint, ease_in_expo, ease_out_expo, ease_in_out_expo, ease_in_circ, ease_out_circ, ease_in_out_circ",
  "window_shadow": "one of: on, float, off",
  "menubar_opacity": "a number from 0.0 to 1.0",
  "active_window_opacity": "a number above 0.0 and at most 1.0",
  "normal_window_opacity": "a number above 0.0 and at most 1.0",
  "insert_feedback_color": "a non-zero hex color such as 0xffe1e3e4",
  "window_border": "on or off",
  "window_border_width": "a number above 0.0",
  "window_border_hide_single": "on or off",
  "active_window_border_color": "a hex color such as 0xffe1e3e4",
  "normal_window_border_color": "a hex color such as 0xffe1e3e4",
  "tab_bar": "on or off",
  "tab_bar_height": "a positive integer",
  "tab_bar_offset": "an integer",
  "tab_bar_font": "a font as family:size, e.g. system:12",
  "tab_bar_icons": "on or off",
  "tab_bar_style": "one of: glass, i3",
  "tab_bar_appearance": "one of: dark, system",
  "tab_bar_backdrop": "one of: off, glass, blur",
  "tab_bar_card_padding": "a non-negative integer",
  "tab_bar_window_radius": "a non-negative integer",
  "tab_bar_focused_color": "a hex color such as 0xffe1e3e4",
  "tab_bar_focused_text_color": "a hex color such as 0xffe1e3e4",
  "tab_bar_inactive_color": "a hex color such as 0xffe1e3e4",
  "tab_bar_inactive_text_color": "a hex color such as 0xffe1e3e4",
  "tab_bar_unfocused_color": "a hex color such as 0xffe1e3e4",
  "tab_bar_unfocused_text_color": "a hex color such as 0xffe1e3e4",
  "tab_bar_backdrop_color": "a hex color such as 0xffe1e3e4",
  "top_padding": "a non-negative integer",
  "bottom_padding": "a non-negative integer",
  "left_padding": "a non-negative integer",
  "right_padding": "a non-negative integer",
  "window_gap": "a non-negative integer",
  "layout": "one of: float, tree",
  "auto_padding": "on or off",
  "tree_default_orientation": "one of: auto, horizontal, vertical",
  "tree_workspace_layout": "one of: default, tabbed",
  "tree_autotiling": "on or off",
  "focus_wrapping": "one of: off, on, force",
  "mouse_modifier": "one of: alt, shift, cmd, ctrl, fn",
  "mouse_action1": "one of: move, resize",
  "mouse_action2": "one of: move, resize",
  "mouse_drop_action": "one of: swap, stack",
  "mouse_drop_preview": "one of: outline, ghost",
  "mouse_drag_split": "on or off",
  "skip_window_focus_animation": "on or off",
  "scratchpad_exclusive": "on or off",
  "scratchpad_raise": "on or off",
  "scratchpad_below": "on or off",
  "scratchpad_grid": "off or rows:columns:x:y:width:height, with rows and columns above 0",
  "space_layout": "off or one or more layouts such as 10:5 or 15 10:5:1b",
]

/// A config message from words separated by spaces.
@WM private func runConfigLine(_ words: String) -> String {
  runConfig(words.split(separator: " ").map { "\($0)\0" }.joined())
}

extension DaemonState {
  @Suite
  @WM struct MessageConfigTests {
    //
    // NOTE: Every option takes a value other than its default and prints it normalized; an invalid value fails and
    // leaves the option as it was. window_animation_duration only takes 0 here: other values check the SIP
    // configuration and ask for Screen Recording permission. In headless mode focus_follows_mouse installs no event
    // tap and external_bar only marks the seeded views.
    //

    nonisolated static let configCases: [ConfigCase] = [
      ConfigCase(option: "debug_output", value: "on", printed: "on", invalid: "1"),
      ConfigCase(option: "mouse_follows_focus", value: "on", printed: "on", invalid: "yes"),
      ConfigCase(
        option: "focus_follows_mouse", value: "autoraise", printed: "autoraise", invalid: "on"),
      ConfigCase(
        option: "focus_follows_mouse", value: "off", printed: "disabled", invalid: "disabled",
        isDefault: true),
      ConfigCase(
        option: "display_arrangement_order", value: "vertical", printed: "vertical",
        invalid: "diagonal"),
      ConfigCase(option: "builtin_display_last", value: "on", printed: "on", invalid: "true"),
      ConfigCase(
        option: "window_origin_display", value: "cursor", printed: "cursor", invalid: "mouse"),
      ConfigCase(option: "window_opacity", value: "on", printed: "on", invalid: "ON"),
      ConfigCase(
        option: "window_opacity_duration", value: "0.5", printed: "0.500000", invalid: "fast"),
      ConfigCase(
        option: "window_animation_duration", value: "0.0", printed: "0.000000", invalid: "0.5s",
        isDefault: true),
      ConfigCase(
        option: "window_animation_easing", value: "ease_in_out_quad", printed: "ease_in_out_quad",
        invalid: "linear"),
      ConfigCase(option: "window_shadow", value: "float", printed: "float", invalid: "managed"),
      ConfigCase(option: "menubar_opacity", value: "0", printed: "0.0000", invalid: "1.5"),
      ConfigCase(option: "active_window_opacity", value: "0.5", printed: "0.5000", invalid: "0"),
      ConfigCase(
        option: "normal_window_opacity", value: "0.25", printed: "0.2500", invalid: "1.01"),
      ConfigCase(
        option: "insert_feedback_color", value: "0xff123456", printed: "0xff123456", invalid: "0"),
      ConfigCase(option: "window_border", value: "on", printed: "on", invalid: "enabled"),
      ConfigCase(option: "window_border_width", value: "2.5", printed: "2.5000", invalid: "0"),
      ConfigCase(option: "window_border_hide_single", value: "on", printed: "on", invalid: "x"),
      ConfigCase(
        option: "active_window_border_color", value: "0x0", printed: "0x0", invalid: "red"),
      ConfigCase(
        option: "normal_window_border_color", value: "0x80FFFFFF", printed: "0x80ffffff",
        invalid: "#ffffff"),
      ConfigCase(option: "tab_bar", value: "off", printed: "off", invalid: "hidden"),
      ConfigCase(option: "tab_bar_height", value: "30", printed: "30", invalid: "0"),
      ConfigCase(option: "tab_bar_offset", value: "-8", printed: "-8", invalid: "1.5"),
      ConfigCase(option: "tab_bar_offset", value: "4.0", printed: "4", invalid: "four"),
      ConfigCase(option: "tab_bar_font", value: "Menlo:14", printed: "Menlo:14", invalid: "Menlo"),
      ConfigCase(
        option: "tab_bar_font", value: "system:9.5", printed: "system:9.5", invalid: "system:0"),
      ConfigCase(option: "tab_bar_icons", value: "off", printed: "off", invalid: "none"),
      ConfigCase(option: "tab_bar_style", value: "i3", printed: "i3", invalid: "flat"),
      ConfigCase(
        option: "tab_bar_appearance", value: "system", printed: "system", invalid: "light"),
      ConfigCase(option: "tab_bar_backdrop", value: "glass", printed: "glass", invalid: "frosted"),
      ConfigCase(option: "tab_bar_card_padding", value: "0", printed: "0", invalid: "-1"),
      ConfigCase(option: "tab_bar_window_radius", value: "8", printed: "8", invalid: "8px"),
      ConfigCase(
        option: "tab_bar_focused_color", value: "0xff010203", printed: "0xff010203", invalid: "blue"
      ),
      ConfigCase(
        option: "tab_bar_focused_text_color", value: "0xff010203", printed: "0xff010203",
        invalid: "blue"),
      ConfigCase(
        option: "tab_bar_inactive_color", value: "0xff010203", printed: "0xff010203",
        invalid: "blue"),
      ConfigCase(
        option: "tab_bar_inactive_text_color", value: "0xff010203", printed: "0xff010203",
        invalid: "blue"),
      ConfigCase(
        option: "tab_bar_unfocused_color", value: "0xff010203", printed: "0xff010203",
        invalid: "blue"),
      ConfigCase(
        option: "tab_bar_unfocused_text_color", value: "0xff010203", printed: "0xff010203",
        invalid: "blue"),
      ConfigCase(
        option: "tab_bar_backdrop_color", value: "0xff010203", printed: "0xff010203",
        invalid: "blue"),
      ConfigCase(option: "top_padding", value: "10", printed: "10", invalid: "-1"),
      ConfigCase(option: "bottom_padding", value: "11", printed: "11", invalid: "1.5"),
      ConfigCase(option: "left_padding", value: "12", printed: "12", invalid: "x"),
      ConfigCase(option: "right_padding", value: "13", printed: "13", invalid: "0x10"),
      ConfigCase(option: "window_gap", value: "8", printed: "8", invalid: "abc"),
      ConfigCase(option: "layout", value: "float", printed: "float", invalid: "bsp"),
      ConfigCase(option: "auto_padding", value: "on", printed: "on", invalid: "auto"),
      ConfigCase(
        option: "tree_default_orientation", value: "horizontal", printed: "horizontal",
        invalid: "diagonal"),
      ConfigCase(
        option: "tree_workspace_layout", value: "tabbed", printed: "tabbed", invalid: "stacked"),
      ConfigCase(option: "tree_autotiling", value: "on", printed: "on", invalid: "x"),
      ConfigCase(option: "focus_wrapping", value: "off", printed: "off", invalid: "wrap"),
      ConfigCase(option: "mouse_modifier", value: "cmd", printed: "cmd", invalid: "hyper"),
      ConfigCase(option: "mouse_action1", value: "resize", printed: "resize", invalid: "swap"),
      ConfigCase(option: "mouse_action2", value: "move", printed: "move", invalid: "stack"),
      ConfigCase(
        option: "mouse_drop_action", value: "stack", printed: "stack", invalid: "warp_top"),
      ConfigCase(
        option: "mouse_drop_preview", value: "ghost", printed: "ghost", invalid: "blur"),
      ConfigCase(option: "mouse_drag_split", value: "on", printed: "on", invalid: "x"),
      ConfigCase(
        option: "external_bar", value: "main:20:0", printed: "main:20:0", invalid: "some:1:2",
        failure:
          "unknown mode 'some' specified in value 'some:1:2' given to command 'external_bar' for domain 'config'\n"
      ),
      ConfigCase(
        option: "external_bar", value: "all:-4:30", printed: "all:-4:30", invalid: "top:0:0",
        failure:
          "unknown mode 'top' specified in value 'top:0:0' given to command 'external_bar' for domain 'config'\n"
      ),
      ConfigCase(option: "skip_window_focus_animation", value: "on", printed: "on", invalid: "x"),
      ConfigCase(
        option: "space_layout", value: "15 10:5 1b:9:3", printed: "15 10:5 1b:9:3", invalid: "x"),
      ConfigCase(
        option: "space_layout", value: "2", printed: "2", invalid: "2 3:1 2",
        failure:
          "value '2' given to command 'space_layout' for domain 'config' repeats a layout for 1 display(s)\n"
      ),
      ConfigCase(
        option: "space_layout", value: "1", printed: "1", invalid: "0",
        failure: "invalid value '0' given to command 'space_layout' for domain 'config'\n"),
      ConfigCase(option: "scratchpad_exclusive", value: "on", printed: "on", invalid: "x"),
      ConfigCase(option: "scratchpad_raise", value: "on", printed: "on", invalid: "x"),
      ConfigCase(option: "scratchpad_below", value: "on", printed: "on", invalid: "x"),
      ConfigCase(
        option: "scratchpad_grid", value: "4:4:1:1:2:2", printed: "4:4:1:1:2:2",
        invalid: "0:4:1:1:2:2"),
    ]

    @Test func externalBarScansThreeFields() {
      // NOTE: fewer than three fields (or a mode longer than 5 bytes) print the value, using up the token; text after the
      // third field is ignored
      #expect(runConfigLine("external_bar main") == "off:0:0\n")
      #expect(runConfigLine("external_bar main:10:x") == "off:0:0\n")
      #expect(runConfigLine("external_bar mainbar:10:0") == "off:0:0\n")
      #expect(runConfigLine("external_bar main:10:5px") == "")
      #expect(runConfigLine("external_bar") == "main:10:5\n")
      #expect(runConfigLine("external_bar main:1:2:3") == "")
      #expect(runConfigLine("external_bar") == "main:1:2\n")
    }

    @Test func spacingOfASpaceOverridesTheDefault() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2)
      // NOTE: View(sid:) leaves gaps and padding off; View.create turns them on
      space.view.isGapEnabled = true
      space.view.isPaddingEnabled = true
      space.view.updateAndFlush()
      _ = Headless.drain()
      SpaceManager.shared.labels.set(id: Workspace.sid, name: "ws")

      #expect(runConfigLine("--space ws window_gap 10") == "")
      #expect(runConfigLine("--space ws window_gap") == "10\n")
      #expect(drainPlacements().map(\.description) == ["w1: 0,0 715x900", "w2: 725,0 715x900"])

      // NOTE: the default reaches the views without an override of their own
      #expect(runConfigLine("window_gap 20 top_padding 30") == "")
      #expect(runConfigLine("--space ws window_gap") == "10\n")
      #expect(runConfigLine("--space ws top_padding") == "30\n")
      #expect(runConfigLine("window_gap") == "20\n")
      #expect(drainPlacements().map(\.description) == ["w1: 0,30 715x870", "w2: 725,30 715x870"])

      #expect(runConfigLine("--space ws auto_padding on") == "")
      #expect(runConfigLine("--space ws auto_padding") == "on\n")
      #expect(runConfigLine("auto_padding") == "off\n")
      #expect(runConfigLine("--space ws layout") == "tree\n")
      #expect(
        runConfigLine("--space ws space_layout 1")
          == "\u{07}command 'space_layout' for domain 'config' does not support the '--space' selector\n"
      )
      #expect(
        runConfigLine("--space nolabel window_gap")
          == "\u{07}value 'nolabel' is not a valid option for SPACE_SEL\n")
    }

    @Test func layoutOfAllSpacesKeepsTheOverride() {
      let space = Workspace()
      space.open(1, focus: true)
      space.view.overrides.insert(.layout)

      #expect(runConfigLine("layout float") == "")
      #expect(space.view.layout == .tree)
      #expect(Config.current.space.layout == .float)
    }

    @Test func externalBarMarksTheSeededViews() {
      let space = Workspace()
      space.open(1, focus: true)
      space.view.isValid = true

      #expect(runConfigLine("external_bar main:20:0") == "")
      #expect(!space.view.isValid)

      Headless.activeSpace = Workspace.sid
      _ = Headless.drain()
      #expect(runConfigLine("external_bar all:20:0") == "")
      #expect(!drainPlacements().isEmpty)
    }

    @Test(arguments: [
      ("window_gap 2147483648", "window_gap"),
      ("window_gap 4294967306", "window_gap"),
      ("tab_bar_height 99999999999", "tab_bar_height"),
    ])
    func integerValuesOutOfRangeFail(_ command: String, _ option: String) {
      let before = runConfigLine(option)
      let response = runConfigLine(command)

      #expect(response.hasPrefix("\u{07}unknown value"))
      #expect(runConfigLine(option) == before)
    }

    // NOTE: window_animation_duration is left out: a value it accepted would check SIP and request Screen Recording
    @Test(arguments: [
      ("window_opacity_duration nan", "window_opacity_duration"),
      ("window_opacity_duration inf", "window_opacity_duration"),
      ("window_border_width inf", "window_border_width"),
      ("active_window_opacity nan", "active_window_opacity"),
    ])
    func nonFiniteFloatValuesFail(_ command: String, _ option: String) {
      let before = runConfigLine(option)
      let response = runConfigLine(command)

      #expect(response.hasPrefix("\u{07}unknown value"))
      #expect(runConfigLine(option) == before)
    }

    @Test func configCasesCoverEveryOption() {
      #expect(Set(Self.configCases.map(\.option)) == Set(configOptionNames.map(\.rawValue)))
    }

    //
    // NOTE: Setting an option to the value it has changes nothing: the second set leaves the tree and records no flush,
    // animation or payload message. The first set may change the seeded space; its result is the reference.
    //
    @Test(arguments: configCases)
    func settingTheCurrentValueChangesNothing(_ row: ConfigCase) {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2)
      _ = runConfigLine("\(row.option) \(row.value)")
      let tree = space.dump
      _ = Headless.drain()

      #expect(runConfigLine("\(row.option) \(row.value)") == "")
      #expect(space.dump == tree)
      let log = Headless.drain()
      #expect(log.placements.isEmpty)
      #expect(log.messages.isEmpty)
    }

    @Test func settingTheCurrentLayoutKeepsATabbedContainer() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2)
      space.open(3)
      space.node(2).setLayout(.tabbed)
      let tree = space.dump

      SpaceManager.shared.setLayout(.tree, for: Workspace.sid)
      #expect(space.view.layout == .tree)
      #expect(space.dump == tree)
      #expect(runConfigLine("layout tree") == "")
      #expect(space.dump == tree)

      SpaceManager.shared.setLayout(.float, for: Workspace.sid)
      #expect(space.view.layout == .float)
    }

    @Test func settingTheCurrentExternalBarKeepsTheViews() {
      let space = Workspace()
      space.open(1, focus: true)
      #expect(runConfigLine("external_bar main:20:0") == "")

      space.view.isValid = true
      #expect(runConfigLine("external_bar main:20:0") == "")
      #expect(space.view.isValid)
    }

    @Test func settingATabBarColorToItsDefaultStillSetsItsCustomFlag() {
      #expect(!Config.current.tabBar.focusedColorIsCustom)
      #expect(runConfigLine("tab_bar_focused_color 0xff285577") == "")
      #expect(Config.current.tabBar.focusedColorIsCustom)
    }

    // NOTE: The font is nil until tab_bar_font sets it, and a nil font draws no classic titles, so the default name still
    // sets the font.
    @Test func settingTheDefaultTabBarFontStillSetsTheFont() {
      WindowManager.shared.tabBarFont = nil
      #expect(runConfigLine("tab_bar_font system:12") == "")
      #expect(WindowManager.shared.tabBarFont != nil)
    }

    // NOTE: A loaded font with its current name is skipped, so the same font object stays and no group is notified.
    @Test func settingTheCurrentTabBarFontNotifiesNothingAndKeepsTheFont() {
      #expect(runConfigLine("tab_bar_font system:12") == "")
      let font = WindowManager.shared.tabBarFont
      #expect(font != nil)
      let flag = ChangeFlag()
      withObservationTracking {
        ConfigObserver.read(.tabBar)
      } onChange: {
        flag.isSet.store(true, ordering: .relaxed)
      }
      #expect(runConfigLine("tab_bar_font system:12") == "")
      let isSet = flag.isSet.load(ordering: .relaxed)
      #expect(!isSet)
      #expect(WindowManager.shared.tabBarFont === font)
    }

    @Test(arguments: [
      ("menubar_opacity 1", ConfigGroup.menuBar),
      ("window_border off", .border),
      ("tab_bar_height 24", .tabBar),
      ("window_opacity off", .opacity),
      ("active_window_opacity 1", .windowOpacity),
      ("window_shadow on", .shadow),
    ])
    func settingTheCurrentValueNotifiesNothing(_ line: String, _ group: ConfigGroup) {
      let flag = ChangeFlag()
      withObservationTracking {
        ConfigObserver.read(group)
      } onChange: {
        flag.isSet.store(true, ordering: .relaxed)
      }
      #expect(runConfigLine(line) == "")
      let isSet = flag.isSet.load(ordering: .relaxed)
      #expect(!isSet, "\(line)")
    }

    @Test(arguments: configCases)
    func valueRoundTrip(_ row: ConfigCase) {
      #expect((runConfigLine(row.option) == "\(row.printed)\n") == row.isDefault)

      #expect(runConfigLine("\(row.option) \(row.value)") == "")
      #expect(runConfigLine(row.option) == "\(row.printed)\n")

      #expect(runConfigLine("\(row.option) \(row.invalid)") == "\u{07}\(row.expectedFailure)")
      #expect(runConfigLine(row.option) == "\(row.printed)\n")
    }

    @Test("config_option_table_is_complete")
    func optionTableCoversNames() {
      let expected: Set<String> = [
        "debug_output", "mouse_follows_focus", "focus_follows_mouse", "display_arrangement_order",
        "builtin_display_last", "window_origin_display", "window_opacity",
        "window_opacity_duration",
        "window_animation_duration", "window_animation_easing", "window_shadow", "menubar_opacity",
        "active_window_opacity", "normal_window_opacity", "insert_feedback_color", "window_border",
        "window_border_width", "window_border_hide_single", "active_window_border_color",
        "normal_window_border_color", "tab_bar", "tab_bar_height", "tab_bar_offset", "tab_bar_font",
        "tab_bar_icons", "tab_bar_style", "tab_bar_appearance", "tab_bar_backdrop",
        "tab_bar_card_padding",
        "tab_bar_window_radius", "tab_bar_focused_color", "tab_bar_focused_text_color",
        "tab_bar_inactive_color", "tab_bar_inactive_text_color", "tab_bar_unfocused_color",
        "tab_bar_unfocused_text_color", "tab_bar_backdrop_color", "top_padding", "bottom_padding",
        "left_padding", "right_padding", "window_gap", "layout", "auto_padding",
        "tree_default_orientation",
        "tree_workspace_layout", "tree_autotiling", "focus_wrapping", "mouse_modifier",
        "mouse_action1",
        "mouse_action2", "mouse_drop_action", "mouse_drop_preview", "mouse_drag_split",
        "external_bar",
        "skip_window_focus_animation",
        "space_layout",
        "scratchpad_exclusive", "scratchpad_raise", "scratchpad_below", "scratchpad_grid",
      ]
      let actual = configOptionNames.map(\.rawValue)

      #expect(configOptionTableIsComplete)
      #expect(ConfigName.allCases.count == 61)
      #expect(actual.count == 61)
      #expect(Set(actual).count == actual.count)
      #expect(Set(actual) == expected)
    }

    @Test("tab_bar_appearance_config")
    func tabBarAppearanceConfig() {
      let appearance = Config.current.tabBar.appearance
      defer { Config.current.tabBar.appearance = appearance }
      Config.current.tabBar.appearance = .dark
      #expect(runConfig("tab_bar_appearance\0") == "dark\n")
      #expect(runConfig("tab_bar_appearance\0system\0").isEmpty)
      #expect(Config.current.tabBar.appearance == .system)
      #expect(runConfig("tab_bar_appearance\0") == "system\n")
      #expect(runConfig("tab_bar_appearance\0light\0").contains("unknown value 'light'"))
      #expect(Config.current.tabBar.appearance == .system)
      #expect(runConfig("tab_bar_appearance\0dark\0").isEmpty)
      #expect(Config.current.tabBar.appearance == .dark)
    }

    @Test("message_config_options")
    func messageConfigOptions() {
      let mouse = Config.current.mouse
      let tap = MouseState.shared.tap

      let mff = Config.current.window.mouseFollowsFocus
      let modifier = mouse.modifier
      let wrapping = Config.current.window.focusWrapping
      let topPadding = Config.current.space.topPadding
      defer {
        Config.current.window.mouseFollowsFocus = mff
        Config.current.mouse.modifier = modifier
        tap.modifier = modifier
        Config.current.window.focusWrapping = wrapping
        Config.current.space.topPadding = topPadding
      }

      _ = runConfig("mouse_follows_focus\0on\0mouse_modifier\0ctrl\0focus_wrapping\0force\0")
      #expect(Config.current.window.mouseFollowsFocus)
      #expect(Config.current.mouse.modifier == .ctrl)
      #expect(tap.modifier == .ctrl)
      #expect(Config.current.window.focusWrapping == .force)

      #expect(runConfig("mouse_modifier\0") == "ctrl\n")
      #expect(runConfig("focus_wrapping\0") == "force\n")

      Config.current.space.topPadding = 7
      #expect(runConfig("top_padding\0") == "7\n")
      #expect(runConfig("top_padding\0-1\0").contains("unknown value '-1'"))
      #expect(Config.current.space.topPadding == 7)

      #expect(runConfig("not_an_option\0").contains("unknown command 'not_an_option'"))

      // NOTE: a failing option writes its failure and the next option still runs; an invalid space_layout stops
      // the message, since its layouts cannot be told apart from the next option
      #expect(
        runConfig("top_padding\0x\0top_padding\0")
          == "\u{07}unknown value 'x' given to command 'top_padding' for domain 'config'; expected a non-negative integer\n7\n"
      )
      #expect(
        runConfig("space_layout\0x\0top_padding\0")
          == "\u{07}unknown value 'x' given to command 'space_layout' for domain 'config'; expected off or one or more layouts such as 10:5 or 15 10:5:1b\n"
      )
    }

    @Test("message_config_values")
    func messageConfigValues() {
      let grid = Config.current.scratchpad.grid
      let duration = Config.current.animation.duration
      let opacityDuration = Config.current.window.opacityDuration
      let workspaceTabbed = Config.current.space.treeWorkspaceTabbed
      defer {
        Config.current.scratchpad.grid = grid
        Config.current.animation.duration = duration
        Config.current.window.opacityDuration = opacityDuration
        Config.current.space.treeWorkspaceTabbed = workspaceTabbed
      }

      #expect(runConfig("scratchpad_grid\0off\0scratchpad_grid\0") == "off\n")
      #expect(runConfig("scratchpad_grid\04:4:1:1:2:2\0scratchpad_grid\0") == "4:4:1:1:2:2\n")
      #expect(runConfig("scratchpad_grid\00:4:1:1:2:2\0").contains("unknown value '0:4:1:1:2:2'"))
      #expect(
        runConfig("scratchpad_grid\0-1:4:1:1:2:2\0scratchpad_grid\0") == "4294967295:4:1:1:2:2\n")

      #expect(
        runConfig("window_animation_duration\00\0window_animation_duration\0") == "0.000000\n")
      #expect(runConfig("window_animation_duration\0fast\0").contains("unknown value 'fast'"))

      #expect(runConfig("layout\0bsp\0").contains("unknown value 'bsp'"))
      #expect(runConfig("external_bar\0some:1:2\0").contains("unknown mode 'some'"))

      // NOTE: float options also take integers
      #expect(runConfig("window_opacity_duration\01\0window_opacity_duration\0") == "1.000000\n")

      // NOTE: only the menubar accepts an opacity of 0
      #expect(runConfig("active_window_opacity\00\0").contains("unknown value '0'"))
      #expect(runConfig("menubar_opacity\01.5\0").contains("unknown value '1.5'"))
      #expect(runConfig("normal_window_opacity\0half\0").contains("unknown value 'half'"))

      #expect(runConfig("tree_workspace_layout\0tabbed\0tree_workspace_layout\0") == "tabbed\n")
      #expect(runConfig("tree_workspace_layout\0default\0tree_workspace_layout\0") == "default\n")
      #expect(runConfig("tree_workspace_layout\0stacked\0").contains("unknown value 'stacked'"))
    }

    @Test("numeric_and_color_config_values_validate_before_applying")
    func numericAndColorConfigValuesValidateBeforeApplying() {
      let duration = Config.current.window.opacityDuration
      let insertionColor = Config.current.window.insertionFeedbackColor
      let focusedColor = Config.current.tabBar.focusedColor
      let focusedColorIsCustom = Config.current.tabBar.focusedColorIsCustom
      defer {
        Config.current.window.opacityDuration = duration
        Config.current.window.insertionFeedbackColor = insertionColor
        Config.current.tabBar.focusedColor = focusedColor
        Config.current.tabBar.focusedColorIsCustom = focusedColorIsCustom
      }

      #expect(runConfig("window_opacity_duration\00.25\0window_opacity_duration\0") == "0.250000\n")
      #expect(Config.current.window.opacityDuration == 0.25)
      #expect(runConfig("window_opacity_duration\0fast\0").contains("unknown value 'fast'"))
      #expect(Config.current.window.opacityDuration == 0.25)

      #expect(
        runConfig("insert_feedback_color\00xff123456\0insert_feedback_color\0") == "0xff123456\n")
      #expect(Config.current.window.insertionFeedbackColor.argb == 0xff12_3456)
      #expect(runConfig("insert_feedback_color\00\0").contains("unknown value '0'"))
      #expect(Config.current.window.insertionFeedbackColor.argb == 0xff12_3456)

      Config.current.tabBar.focusedColorIsCustom = false
      #expect(
        runConfig("tab_bar_focused_color\00xffabcdef\0tab_bar_focused_color\0") == "0xffabcdef\n")
      #expect(Config.current.tabBar.focusedColor.argb == 0xffab_cdef)
      #expect(Config.current.tabBar.focusedColorIsCustom)
    }
  }
}
