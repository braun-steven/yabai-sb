import Testing
import YabaiTestSupport

@testable import YabaiCore

// Parser fixtures use NUL separators for readability; transport uses argument arrays.

private let domain = Token("config")
private let command = Token("test")

@Test func emptyRuleAndSignalArgumentsCannotHideLaterFields() {
  var rule = Message(arguments: ["--add", "app=Safari", "", "bogus=1"])
  let ruleFailure = thrownText { () throws(CommandError) in
    _ = try RuleCommand.parse(&rule, FixtureContext())
  }
  #expect(ruleFailure?.contains("invalid key-value pair ''") == true)
  #expect(ruleFailure?.contains("unknown key 'bogus'") == true)

  var signal = Message(arguments: ["--add", "event=window_focused", "", "bogus=1"])
  let signalFailure = thrownText { () throws(CommandError) in
    _ = try SignalCommand.parse(&signal)
  }
  #expect(signalFailure?.contains("invalid key-value pair ''") == true)
  #expect(signalFailure?.contains("unknown key 'bogus'") == true)
}

/// The text of the failure that body throws, nil when it does not throw.
private func thrownText(_ body: () throws(CommandError) -> Void) -> String? {
  do { try body() } catch { return error.description }
  return nil
}

/// The text of a selector's failure, empty when it has none.
private func failureText(_ failure: CommandError?) -> String {
  failure?.description ?? ""
}

@Test func messageTokens() {
  var message = Message("window\0--focus\0\0east\0\0")
  #expect(message.next().equals("window"))
  #expect(message.peek().equals("--focus"))
  #expect(message.next().equals("--focus"))

  #expect(message.take() == Token(""))
  #expect(message.take() == Token("east"))
  #expect(message.take() == Token(""))
  #expect(message.take() == nil)

  var unterminated = Message("a\0b")
  #expect(unterminated.next().equals("a"))
  #expect(unterminated.next().equals("b"))
  #expect(!unterminated.next().isValid)
}

/// A token value as text, without the token of a string.
private func valueText(_ value: TokenValue) -> String {
  switch value {
  case .invalid: return "invalid"
  case .int(let value): return "int(\(value))"
  case .u32(let value): return "u32(\(value))"
  case .float(let value): return "float(\(value))"
  case .string: return "string"
  }
}

private let tokenValueRows: [(String, String)] = [
  ("42", "int(42)"),
  ("0xFF", "u32(255)"),
  ("2147483648", "float(2.1474836e+09)"),
  ("0x100000000", "float(4.2949673e+09)"),
  ("0.5", "float(0.5)"),
  ("1e2", "float(100.0)"),
  ("0x", "string"),
  ("-1x", "string"),
  ("", "invalid"),
]

@Test(arguments: tokenValueRows)
func tokenValue(_ text: String, _ value: String) {
  #expect(valueText(Token(text).value) == value)
}

@Test func tokenConversions() {
  // NOTE: a number beyond 32 bits is not a number, not a wrapped value
  #expect(Token("2147483647").positiveInteger == 2_147_483_647)
  #expect(Token("2147483648").positiveInteger == nil)
  #expect(Token("4294967297").positiveInteger == nil)
  #expect(Token("0xFFFFFFFF").hexadecimal == 0xFFFF_FFFF)
  #expect(Token("0x100000000").hexadecimal == nil)
  #expect(Token("0x100000001").hexadecimal == nil)
  #expect(Token("4294967295").unsignedInteger == 0xFFFF_FFFF)
  #expect(Token("4294967296").unsignedInteger == nil)
  #expect(Token("").unsignedInteger == nil)

  #expect(TokenValue.int(3).floatValue == 3)
  #expect(TokenValue.string(Token("x")).floatValue == nil)
  #expect(Token("nan").value.floatValue == nil)
  #expect(Token("-inf").value.floatValue == nil)
  #expect(Token("é").equals("e\u{301}"))
  #expect(Token("e\u{301}") == Token("é"))
}

// NOTE: a byte that is not UTF-8 is decoded once, as U+FFFD, also where the response echoes the token
@Test func responseEchoesInvalidUTF8AsReplacement() {
  var rsp = Response()
  rsp.fail(.unknownValue(domain, command, Token([0x66, 0xff] as [UInt8])))
  #expect(
    rsp.failures == ["unknown value 'f\u{fffd}' given to command 'test' for domain 'config'\n"])
}

@Test("Config command names cover the daemon options and preserve their CLI spellings")
func configCommandNames() {
  #expect(ConfigCommand.Name.allCases.count == 54)
  #expect(ConfigCommand.Name(token: Token("window_border")) == .windowBorder)
  #expect(ConfigCommand.Name(token: Token("tree_default_orientation")) == .treeDefaultOrientation)
  #expect(ConfigCommand.Name(token: Token("unknown_option")) == nil)
}

@Test("Config command parsing keeps a typed space scope and the following command token")
func configCommandScope() throws {
  var message = Message("3\0window_gap\0")
  let (selector, command) = try ConfigCommand.parseScope(Token("--space"), &message)
  #expect(selector == .missionControl(3))
  #expect(command.equals("window_gap"))
  #expect(try ConfigCommand.parseName(command) == .windowGap)

  var unscoped = Message("unused\0")
  let (noSelector, first) = try ConfigCommand.parseScope(Token("layout"), &unscoped)
  #expect(noSelector == nil)
  #expect(first.equals("layout"))
  #expect(unscoped.next().equals("unused"))
}

@Test("Unknown config command errors echo the token")
func configCommandUnknownName() {
  let token = Token([0x78, 0xff] as [UInt8])
  var rsp = Response()
  do {
    _ = try ConfigCommand.parseName(token)
  } catch {
    rsp.fail(error)
  }
  #expect(rsp.failures == ["unknown command 'x\u{fffd}' for domain 'config'\n"])
}

@Test("Config names parse one at a time without consuming the next command")
func configCommandChainedNames() throws {
  var message = Message("debug_output\0on\0window_gap\0" + "0\0")
  let first = try ConfigCommand.parseName(message.next())
  #expect(first == .debugOutput)
  #expect(message.next().equals("on"))
  let second = try ConfigCommand.parseName(message.next())
  #expect(second == .windowGap)
  #expect(message.next().equals("0"))
}

private enum TestAction: String, CaseIterable {
  case move
  case resize
  case swap
}

@Test("message_config_bool") func messageConfigBool() throws {
  #expect(try parseConfigBool(domain, command, Token("on")) == true)
  #expect(try parseConfigBool(domain, command, Token("off")) == false)

  let text = thrownText { () throws(CommandError) in
    _ = try parseConfigBool(domain, command, Token("yes"))
  }
  #expect(
    text == "unknown value 'yes' given to command 'test' for domain 'config'; expected on or off\n")
}

@Test(
  "A config choice is one of the accepted raw values, and the CaseIterable overload accepts every case"
)
func messageConfigChoice() throws {
  let choices: [TestAction] = [.move, .resize]
  #expect(try parseConfigChoice(domain, command, Token("move"), choices) == .move)
  #expect(try parseConfigChoice(domain, command, Token("resize"), choices) == .resize)

  // NOTE: values of the enum outside of the accepted choices are rejected
  let text = thrownText { () throws(CommandError) in
    _ = try parseConfigChoice(domain, command, Token("swap"), choices)
  }
  #expect(
    text
      == "unknown value 'swap' given to command 'test' for domain 'config'; expected one of: move, resize\n"
  )

  let chosen: TestAction = try parseConfigChoice(domain, command, Token("swap"))
  #expect(chosen == .swap)
}

@Test("message_window_toggle_lookup") func messageWindowToggleLookup() {
  #expect(WindowToggle(token: Token("float")) == .float)
  #expect(WindowToggle(token: Token("zoom-fullscreen")) == .zoomFullscreen)
  #expect(WindowToggle(token: Token("shadow")) == .shadow)

  // NOTE: anything else is a scratchpad label
  #expect(WindowToggle(token: Token("notes")) == nil)
  #expect(WindowToggle(token: Token("floa")) == nil)

  // NOTE: window_toggle_list in src/message_window.c keeps its functions in this order
  #expect(
    WindowToggle.allCases.map(\.rawValue) == [
      "float", "sticky", "shadow", "split", "zoom-parent", "zoom-fullscreen", "windowed-fullscreen",
      "native-fullscreen", "expose", "pip",
    ])
}

private func parseLabelText(_ text: String, _ kind: LabelKind) -> (response: String, label: String?)
{
  do {
    let label = try parseLabel(Token(text), kind)
    return ("", label?.string)
  } catch {
    return (error.description, nil)
  }
}

@Test("message_label_reserved") func messageLabelReserved() {
  // NOTE: directions only select displays, so they are valid space labels
  #expect(parseLabelText("west", .display).response.contains("cannot be used as a label"))
  let west = parseLabelText("west", .space)
  #expect(west.response == "")
  #expect(west.label == "west")

  let float = parseLabelText("float", .window)
  #expect(float.response.contains("cannot be used as a scratchpad"))
  #expect(float.label == nil)
  #expect(parseLabelText("recent", .space).response.contains("reserved keyword"))
  #expect(parseLabelText("recover", .window).response.contains("reserved keyword"))

  #expect(parseLabelText("12", .space).response == "'12' cannot be used as a label.\n")

  // NOTE: a window label may be a direction word of the display and space labels, but not a window selector word
  #expect(parseLabelText("term", .windowLabel).label == "term")
  #expect(parseLabelText("float", .windowLabel).label == "float")
  #expect(parseLabelText("north", .windowLabel).response.contains("reserved keyword"))
  #expect(parseLabelText("largest", .windowLabel).response.contains("reserved keyword"))
  #expect(parseLabelText("parent", .windowLabel).response.contains("reserved keyword"))
  #expect(parseLabelText("stack.1", .windowLabel).response.contains("reserved keyword"))

  // NOTE: a missing label is valid and removes the label
  let missing = parseLabelText("", .space)
  #expect(missing.response == "" && missing.label == nil)
}

private enum TestProperty: String, CaseIterable, Sendable {
  case id, frame, app
}

@Test func messageProperties() throws {
  let properties = try parseProperties(Token("id,app"), as: TestProperty.self)
  #expect(properties.didParse && properties.selection == [.id, .app])

  let option = try parseProperties(Token("--window"), as: TestProperty.self)
  #expect(!option.didParse && option.selection == Set(TestProperty.allCases))

  // NOTE: the last byte always belongs to the last property, even a comma; every invalid property is reported in one failure
  let text = thrownText { () throws(CommandError) in
    _ = try parseProperties(Token("id,,frame,"), as: TestProperty.self)
  }
  #expect(text == "'' is not a valid property.\n'frame,' is not a valid property.\n")
}

@Test func messageKeyValuePairs() {
  let pair = parseKeyValuePair(Token("app!=^Safari$"))
  #expect(pair?.key.string == "app" && pair?.value.string == "^Safari$" && pair?.exclusion == true)

  let title = parseKeyValuePair(Token("title=a=b"))
  #expect(title?.key.string == "title" && title?.value.string == "a=b" && title?.exclusion == false)

  #expect(parseKeyValuePair(Token("=x"))?.key.isValid == false)
  #expect(parseKeyValuePair(Token("app")) == nil)
  #expect(parseKeyValuePair(Token("app=")) == nil)
  #expect(parseKeyValuePair(Token("app!=")) == nil)
  #expect(parseKeyValuePair(Token("a!b=c"))?.key.string == "a!b")
}

@Test func messageValueParsers() throws {
  #expect(parseLayer(Token("above")) == .above)
  #expect(parseLayer(Token("top")) == nil)
  #expect(parseValueType(Token("rel")) == .rel)
  #expect(parseValueType(Token("relative")) == nil)
  #expect(parseResizeHandle(Token("top_left")) == [.top, .left])
  #expect(parseResizeHandle(Token("middle")) == [])

  let stack = try parseInsertSelector(Token("stack"))
  #expect(stack == .stack)
  let south = try parseInsertSelector(Token("south"))
  #expect(south == .south)
  let text = thrownText { () throws(CommandError) in _ = try parseInsertSelector(Token("up")) }
  #expect(text == "value 'up' is not a valid option for DIR_SEL\n")

  #expect(TreeFocus(Token("parent")) == .parent)
  #expect(TreeFocus(Token("east")) == .direction(.east))
  #expect(TreeFocus(Token("1")) == nil)
}

//
// NOTE: The typed selectors and commands of the window domain.
//

private let windowSelectorRows: [(String, WindowSelector?)] = [
  ("8", .id(8)),
  ("4294901769", .id(0xFFFF_0009)),
  ("4294967295", .id(0xFFFF_FFFF)),
  ("4294967297", nil),
  ("east", .direction(.east)),
  ("stack.2", .stack(.position(2))),
  ("stack.recent", .stack(.recent)),
  ("stack.0", nil),
  ("0x10", nil),
  ("", nil),
  ("term", .label(Token("term"))),
  ("--focus", nil),
  ("parent", nil),
  ("north", .direction(.north)),
]

@Test(arguments: windowSelectorRows)
func windowSelectorParsesWithoutLookups(_ text: String, _ selector: WindowSelector?) {
  #expect(WindowSelector(Token(text)) == selector)
}

private let spaceSelectorRows: [(String, SpaceSelector?)] = [
  ("3", .missionControl(3)),
  ("recent", .recent),
  ("1.5", nil),
  ("0x10", nil),
]

@Test(arguments: spaceSelectorRows)
func spaceSelectorParsesWithoutLookups(_ text: String, _ selector: SpaceSelector?) {
  #expect(SpaceSelector(Token(text)) == selector)
}

/// A row of `space --focus` back-and-forth: the selector, whether the option is on, the selected, focused and recent
/// spaces, and the space it focuses.
private let focusTargetRows: [(SpaceSelector, Bool, Int, Int?, Int?, Int)] = [
  (.missionControl(2), true, 2, 2, 1, 1),
  (.label(Token("code")), true, 2, 2, 1, 1),
  (.missionControl(2), false, 2, 2, 1, 2),
  (.missionControl(2), true, 2, 3, 1, 2),
  (.missionControl(2), true, 2, 2, nil, 2),
  (.missionControl(2), true, 2, 2, 2, 2),
  (.next, true, 2, 2, 1, 2),
  (.prev, true, 2, 2, 1, 2),
  (.first, true, 2, 2, 1, 2),
  (.last, true, 2, 2, 1, 2),
  (.recent, true, 2, 2, 1, 2),
  (.mouse, true, 2, 2, 1, 2),
]

// NOTE: Like sway's workspace_auto_back_and_forth, only an index or a label of the focused space goes back.
@Test(arguments: focusTargetRows)
func spaceFocusTargetGoesBackAndForth(
  _ row: (SpaceSelector, Bool, Int, Int?, Int?, Int)
) {
  let (selector, enabled, target, focused, recent, expected) = row
  #expect(
    selector.focusTarget(target, autoBackAndForth: enabled, focused: focused, recent: recent)
      == expected)
}

@Test func spaceFocusTargetReadsTheFocusedSpaceOnlyWhenOn() {
  var reads = 0
  func focused() -> Int? {
    reads += 1
    return 2
  }
  _ = SpaceSelector.missionControl(2).focusTarget(
    2, autoBackAndForth: false, focused: focused(), recent: 1)
  _ = SpaceSelector.next.focusTarget(2, autoBackAndForth: true, focused: focused(), recent: 1)
  #expect(reads == 0)
}

@Test func displaySelectorsParseWithoutLookups() {
  #expect(DisplaySelector(Token("west")) == .direction(.west))
  #expect(DisplaySelector(Token("main")) == .label(Token("main")))
}

// NOTE: `window <id> --display west` measures from the window's own display, like sway's `move container to output`;
// the window acted on without a selector keeps the active display.
@Test(arguments: [
  (selected: false, window: DisplayID?(3), want: DisplayID?(2)),
  (selected: true, window: DisplayID?(3), want: DisplayID?(3)),
  (selected: true, window: DisplayID?.none, want: DisplayID?(2)),
])
func windowDisplayOriginIsTheSelectedWindowsDisplay(
  selected: Bool, window: DisplayID?, want: DisplayID?
) {
  var windowReads = 0
  let origin = DisplaySelector.placementOrigin(
    selected: selected,
    windowDisplay: { () -> DisplayID? in
      windowReads += 1
      return window
    }, active: { DisplayID?(2) })
  #expect(origin == want)
  #expect(windowReads == (selected ? 1 : 0))
}

// NOTE: `space <sid> --display west` (and --create, --pin) measures from the selected space's display, like sway's
// `move workspace to output`; the space acted on without a selector, or a selector naming the active space, keeps the
// active display.
@Test(arguments: [
  (acting: SpaceID?(10), space: DisplayID?(1), want: DisplayID?(2)),
  (acting: SpaceID?(11), space: DisplayID?(3), want: DisplayID?(3)),
  (acting: SpaceID?(11), space: DisplayID?.none, want: DisplayID?(2)),
])
func spaceDisplayOriginIsTheSelectedSpacesDisplay(
  acting: SpaceID?, space: DisplayID?, want: DisplayID?
) {
  let focused = SpaceID?(10)
  let origin = DisplaySelector.placementOrigin(
    selected: acting != focused, windowDisplay: { space }, active: { DisplayID?(2) })
  #expect(origin == want)
}

@Test func typedSelectorsResolveThroughTheContext() throws {
  let context = FixtureContext(
    activeDisplay: 1, acting: 7, displays: [1, 2], spaces: [10, 11], displayLabels: ["main": 2],
    spaceLabels: ["code": 11], windows: [7, 8], stack: [7, 9])

  #expect(try WindowSelector.first.resolve(acting: nil, context) == 7)
  #expect(try WindowSelector.stack(.position(2)).resolve(acting: 7, context) == 9)
  #expect(try DisplaySelector.label(Token("main")).resolve(acting: 1, context) == 2)
  #expect(try SpaceSelector.recent.resolve(acting: 10, context) == nil)

  let relative = thrownText { () throws(CommandError) in
    _ = try WindowSelector.next.resolve(acting: nil, context)
  }
  #expect(relative == "could not locate the selected window.\n")
  let unknownLabel = thrownText { () throws(CommandError) in
    _ = try SpaceSelector.label(Token("mail")).resolve(acting: 10, context)
  }
  #expect(unknownLabel == "value 'mail' is not a valid option for SPACE_SEL\n")

  // NOTE: the lookups that the removed adaptors made, through the typed selectors
  let displayTwo = try #require(DisplaySelector(Token("2")))
  #expect(try displayTwo.resolve(acting: 1, context) == 2)
  let displayLast = try #require(DisplaySelector(Token("last")))
  #expect(try displayLast.resolve(acting: 1, context) == 2)
  let displayThree = try #require(DisplaySelector(Token("3")))
  let arrangement = thrownText { () throws(CommandError) in
    _ = try displayThree.resolve(acting: 1, context)
  }
  #expect(arrangement == "could not locate display with arrangement index '3'.\n")
  let displayWest = try #require(DisplaySelector(Token("west")))
  let westText = thrownText { () throws(CommandError) in
    _ = try displayWest.resolve(acting: 1, context)
  }
  #expect(westText == "could not locate a westward display.\n")

  let spaceCode = try #require(SpaceSelector(Token("code")))
  #expect(try spaceCode.resolve(acting: 10, context) == 11)

  let windowEight = try #require(WindowSelector(Token("8")))
  #expect(try windowEight.resolve(acting: 7, context) == 8)
  let stackThree = try #require(WindowSelector(Token("stack.3")))
  let stackText = thrownText { () throws(CommandError) in
    _ = try stackThree.resolve(acting: 7, context)
  }
  #expect(stackText == "could not locate the stacked window in position 3.\n")
  let windowNorth = try #require(WindowSelector(Token("north")))
  let northText = thrownText { () throws(CommandError) in
    _ = try windowNorth.resolve(acting: 7, context)
  }
  #expect(northText == "could not locate a northward managed window.\n")
  let windowNine = try #require(WindowSelector(Token("9")))
  let idText = thrownText { () throws(CommandError) in
    _ = try windowNine.resolve(acting: 7, context)
  }
  #expect(idText == "could not locate window with the specified id '9'.\n")
}

/// Parses one window command from text that starts with its name: the command, or the failure text and whether it
/// stops the message.
private func parseWindowCommand(_ text: String) -> (WindowCommand?, String, Bool) {
  var message = Message(text)
  guard let name = WindowCommand.Name(token: message.next()) else { return (nil, "no name", false) }

  do {
    return (try WindowCommand.parse(name, &message), "", false)
  } catch {
    return (nil, error.description, error.stopsMessage)
  }
}

@Test func windowCommandNames() {
  #expect(WindowCommand.Name(token: Token("--sub-layer")) == .subLayer)
  #expect(WindowCommand.Name(token: Token("--foo")) == nil)
  #expect(!WindowCommand.Name.toggle.needsWindow)
  #expect(!WindowCommand.Name.deminimize.needsWindow)
  #expect(WindowCommand.Name.swap.needsWindow)
}

private let windowCommandRows: [(String, WindowCommand)] = [
  ("--swap\0east\0", .swap(.direction(.east))),
  ("--focus\0parent\0", .focus(.container(.parent))),
  ("--focus\0", .focus(.window(nil))),
  ("--focus\0recent\0", .focus(.window(.recent))),
  ("--display\0main\0", .display(.label(Token("main")))),
  ("--move\0rel:10:-5\0", .move(.rel, dx: 10, dy: -5)),
  ("--move\0sideways:1:2\0", .move(nil, dx: 1, dy: 2)),
  ("--resize\0top_left:1:2\0", .resize([.top, .left], dx: 1, dy: 2)),
  ("--ratio\0abs:0.3\0", .ratio(.abs, 0.3)),
  ("--grid\04:4:1:1:2:2\0", .grid(Grid(4, 4, 1, 1, 2, 2))),
  ("--toggle\0float\0", .toggle(.float)),
  ("--toggle\0notes\0", .toggleScratchpad(Token("notes"))),
  ("--scratchpad\0recover\0", .scratchpad(.recover)),
  ("--scratchpad\0term\0", .scratchpad(.assign(label: "term"))),
  ("--scratchpad\0", .scratchpad(.remove)),
  ("--layout\0toggle-split\0", .layout(.toggleSplit)),
  ("--split\0vertical\0", .split(.fixed(.vertical))),
  ("--insert\0stack\0", .insert(.stack)),
  ("--label\0term\0", .label("term")),
  ("--label\0", .label(nil)),
]

@Test(arguments: windowCommandRows)
func windowCommandValue(_ text: String, _ command: WindowCommand) {
  let (parsed, failure, _) = parseWindowCommand(text)
  #expect(failure == "")
  #expect(parsed == command)
}

// NOTE: an invalid optional selector stops the message, an invalid required one does not
private let windowCommandFailureRows: [(String, String, Bool)] = [
  ("--focus\0--bogus\0", "value '--bogus' is not a valid option for WINDOW_SEL\n", true),
  ("--swap\0--bogus\0", "value '--bogus' is not a valid option for WINDOW_SEL\n", false),
  (
    "--layout\0stacked\0",
    "unknown value 'stacked' given to command '--layout' for domain 'window'; expected one of: tabbed, split, toggle, splith, splitv, toggle-split\n",
    true
  ),
  (
    "--split\0diagonal\0",
    "unknown value 'diagonal' given to command '--split' for domain 'window'; expected one of: horizontal, vertical, toggle\n",
    true
  ),
  (
    "--grid\0a\0",
    "unknown value 'a' given to command '--grid' for domain 'window'; expected six integers as rows:columns:x:y:width:height\n",
    false
  ),
  (
    "--move\0rel:nan:0\0",
    "unknown value 'rel:nan:0' given to command '--move' for domain 'window'; expected abs or rel, then two numbers, e.g. rel:10:-5\n",
    false
  ),
  (
    "--move\0abs:0:-inf\0",
    "unknown value 'abs:0:-inf' given to command '--move' for domain 'window'; expected abs or rel, then two numbers, e.g. rel:10:-5\n",
    false
  ),
  (
    "--resize\0right:nan:0\0",
    "unknown value 'right:nan:0' given to command '--resize' for domain 'window'; expected a handle (top, bottom, left, right, top_left, top_right, bottom_left, bottom_right or abs), then two numbers, e.g. top_left:10:-5\n",
    false
  ),
  (
    "--resize\0right:inf:0\0",
    "unknown value 'right:inf:0' given to command '--resize' for domain 'window'; expected a handle (top, bottom, left, right, top_left, top_right, bottom_left, bottom_right or abs), then two numbers, e.g. top_left:10:-5\n",
    false
  ),
  (
    "--ratio\0abs:nan\0",
    "unknown value 'abs:nan' given to command '--ratio' for domain 'window'; expected abs or rel, then a number, e.g. abs:0.5\n",
    false
  ),
  (
    "--ratio\0rel:-inf\0",
    "unknown value 'rel:-inf' given to command '--ratio' for domain 'window'; expected abs or rel, then a number, e.g. abs:0.5\n",
    false
  ),
  (
    "--scratchpad\0float\0", "'float' is a reserved keyword and cannot be used as a scratchpad.\n",
    false
  ),
  ("--label\0north\0", "'north' is a reserved keyword and cannot be used as a label.\n", false),
  ("--label\0--focus\0", "'--focus' is a reserved keyword and cannot be used as a label.\n", false),
  ("--label\0stack.2\0", "'stack.2' is a reserved keyword and cannot be used as a label.\n", false),
  ("--label\012\0", "'12' cannot be used as a label.\n", false),
  ("--space\0", "value '' is not a valid option for SPACE_SEL\n", false),
]

@Test(arguments: windowCommandFailureRows)
func windowCommandFailure(_ text: String, _ failure: String, _ stopsMessage: Bool) {
  let (parsed, response, stops) = parseWindowCommand(text)
  #expect(parsed == nil)
  #expect(response == failure)
  #expect(stops == stopsMessage)
}

@Test func windowFocusTargetWithoutTree() throws {
  #expect(try WindowFocusTarget.container(.direction(.east)).windowSelector() == .direction(.east))
  #expect(try WindowFocusTarget.window(nil).windowSelector() == nil)

  let parent = thrownText { () throws(CommandError) in
    _ = try WindowFocusTarget.container(.parent).windowSelector()
  }
  #expect(parent == "value 'parent' is not a valid option for WINDOW_SEL\n")
}

@Test func windowLayoutValues() {
  #expect(WindowLayout(token: Token("tabbed")) == .tabbed)
  #expect(WindowLayout(token: Token("toggle-split")) == .toggleSplit)
  #expect(WindowLayout(token: Token("stacked")) == nil)

  #expect(SplitOrientation(Token("vertical")) == .fixed(.vertical))
  #expect(SplitOrientation(Token("toggle")) == .toggle)
  #expect(SplitOrientation(Token("diagonal")) == nil)
}

private func parseSpaceCommand(_ text: String) -> (SpaceCommand?, String, Bool) {
  var message = Message(text)
  guard let name = SpaceCommand.Name(token: message.next()) else { return (nil, "no name", false) }
  do { return (try SpaceCommand.parse(name, &message), "", false) } catch {
    return (nil, error.description, error.stopsMessage)
  }
}

private let spaceCommandRows: [(String, SpaceCommand)] = [
  ("--focus\0next\0", .focus(.next)),
  ("--create\0west\0", .create(.direction(.west))),
  ("--destroy\0", .destroy(nil)),
  ("--mirror\0x-axis\0", .mirror(.xAxis)),
  ("--rotate\0" + "180\0", .rotate(180)),
  ("--padding\0abs:1:2:3:4\0", .padding(.abs, top: 1, bottom: 2, left: 3, right: 4)),
  ("--gap\0rel:5\0", .gap(.rel, 5)),
  ("--toggle\0mission-control\0", .toggle(.missionControl)),
  ("--layout\0tree\0", .layout(.tree)),
  ("--pin\0", .pin(nil)),
  ("--pin\02\0", .pin(.arrangement(2))),
  ("--pin\0next\0", .pin(.next)),
  ("--undo\0", .undo),
  ("--save-layout\0work\0", .saveLayout("work")),
  ("--save-layout\0a.b-c_1\0", .saveLayout("a.b-c_1")),
  ("--restore-layout\0work\0", .restoreLayout("work")),
  ("--restore-layout\0a.b-c_1\0", .restoreLayout("a.b-c_1")),
]

@Test(arguments: spaceCommandRows)
func spaceCommandValue(_ text: String, _ command: SpaceCommand) {
  let (parsed, failure, _) = parseSpaceCommand(text)
  #expect(failure == "")
  #expect(parsed == command)
}

@Test func typedDisplayCommands() throws {
  var message = Message("main\0")
  #expect(try DisplayCommand.parse(.focus, &message) == .focus(.label(Token("main"))))
  message = Message("3\0")
  #expect(try DisplayCommand.parse(.space, &message) == .space(.missionControl(3)))
}

private let spaceCommandFailureRows: [(String, String, Bool)] = [
  (
    "--rotate\0" + "45\0",
    "unknown value '45' given to command '--rotate' for domain 'space'; expected one of: 90, 180, 270\n",
    false
  ),
  ("--destroy\01.2\0", "value '1.2' is not a valid option for SPACE_SEL\n", true),
  (
    "--save-layout\0",
    "missing value for '--save-layout'; expected a layout name of the characters A-Z, a-z, 0-9, '.', '_' and '-'\n",
    false
  ),
  (
    "--save-layout\0a/b\0",
    "unknown value 'a/b' given to command '--save-layout' for domain 'space'; expected a layout name of the characters A-Z, a-z, 0-9, '.', '_' and '-'\n",
    false
  ),
  (
    "--save-layout\0..\0",
    "unknown value '..' given to command '--save-layout' for domain 'space'; expected a layout name of the characters A-Z, a-z, 0-9, '.', '_' and '-'\n",
    false
  ),
  (
    "--restore-layout\0",
    "missing value for '--restore-layout'; expected a layout name of the characters A-Z, a-z, 0-9, '.', '_' and '-'\n",
    false
  ),
  (
    "--restore-layout\0a/b\0",
    "unknown value 'a/b' given to command '--restore-layout' for domain 'space'; expected a layout name of the characters A-Z, a-z, 0-9, '.', '_' and '-'\n",
    false
  ),
]

@Test(arguments: spaceCommandFailureRows)
func spaceCommandFailure(_ text: String, _ failure: String, _ stopsMessage: Bool) {
  let (parsed, response, stops) = parseSpaceCommand(text)
  #expect(parsed == nil)
  #expect(response == failure)
  #expect(stops == stopsMessage)
}

@Test(arguments: SpaceCommand.Name.allCases)
func spaceCommandNeedsAnActingSpace(_ name: SpaceCommand.Name) {
  switch name {
  case .focus, .switch, .create, .destroy, .move, .swap, .display: #expect(!name.needsActingSpace)
  default: #expect(name.needsActingSpace)
  }
}

@Test func spaceUndoTakesNoValue() throws {
  var message = Message("--undo\0--balance\0")
  _ = message.next()
  #expect(try SpaceCommand.parse(.undo, &message) == .undo)
  #expect(message.next().string == "--balance")
}

@Test func spaceCommandNames() {
  #expect(SpaceCommand.Name(token: Token("--rotate")) == .rotate)
  #expect(SpaceCommand.Name(token: Token("--bogus")) == nil)
}

private func parseRuleText(_ text: String, _ context: FixtureContext = FixtureContext()) -> (
  Bool, Rule, String
) {
  var rule = Rule()
  var message = Message(text)
  let first = message.take()
  do {
    let result = try parseRule(&message, &rule, first, context)
    return (result, rule, "")
  } catch {
    return (false, rule, error.description)
  }
}

@Test("message_rule_parse") func messageRuleParse() {
  var (result, rule, response) = parseRuleText(
    "app=^Safari$\0title!=Preferences\0manage=off\0sticky=on\0sub-layer=above\0")
  #expect(result == true)
  #expect(rule.app?.regex != nil)
  #expect(rule.app?.exclude == false)
  #expect(rule.title?.exclude == true)
  #expect(rule.effects.manage == false)
  #expect(rule.effects.sticky == true)
  #expect(rule.effects.mouseFollowsFocus == nil)
  #expect(rule.effects.layer == .above)
  #expect(rule.effects.layer != nil)
  #expect(rule.app?.text == "^Safari$")
  #expect(response == "")

  // NOTE: a repeated key replaces the earlier value, including its exclusion
  (result, rule, _) = parseRuleText("app!=a\0app=^b$\0label=x\0label=y\0")
  #expect(result == true)
  #expect(rule.app?.text == "^b$")
  #expect(rule.app?.regex != nil)
  #expect(rule.app?.exclude == false)
  #expect(rule.label == "y")

  (result, rule, response) = parseRuleText("app=x\0scratchpad=float\0")
  #expect(result == false)
  #expect(response.contains("invalid value 'float' for key 'scratchpad'"))
  #expect(rule.effects.scratchpad == nil)

  (result, rule, _) = parseRuleText("app=x\0app=(\0")
  #expect(result == false)
  #expect(rule.app?.regex == nil)
}

private let ruleFailureRows: [(String, [String])] = [
  ("app=x\0manage=maybe\0", ["invalid value 'maybe' for key 'manage'"]),
  ("app=(\0", ["invalid regex pattern '(' for key 'app'"]),
  ("app=x\0label!=y\0", ["unsupported token '!' (exclusion) given for key 'label'"]),
  ("manage=on\0colour=red\0", ["unknown key 'colour'", "missing required key-value pair"]),
]

@Test(arguments: ruleFailureRows)
func ruleParseFailure(_ text: String, _ failures: [String]) {
  let (result, _, response) = parseRuleText(text)
  #expect(result == false)
  for failure in failures {
    #expect(response.contains(failure))
  }
}

// NOTE: the exact failure text of every rule failure path, and the order the failures come in. Empty text: a display or
// space 'recent' with nothing recent, which is not parsed and reports nothing.
private let ruleExactFailures: [(String, String)] = [
  ("app=x\0manage=maybe\0", "invalid value 'maybe' for key 'manage'\n"),
  (
    "manage=maybe\0app=(\0",
    "invalid value 'maybe' for key 'manage'\ninvalid regex pattern '(' for key 'app'\n"
  ),
  ("app=(\0", "invalid regex pattern '(' for key 'app'\n"),
  ("title=[\0", "invalid regex pattern '[' for key 'title'\n"),
  ("role=[\0", "invalid regex pattern '[' for key 'role'\n"),
  ("subrole=[\0", "invalid regex pattern '[' for key 'subrole'\n"),
  ("app=x\0label!=y\0", "unsupported token '!' (exclusion) given for key 'label'\n"),
  ("app=x\0sticky!=on\0", "unsupported token '!' (exclusion) given for key 'sticky'\n"),
  ("app=x\0sticky!=on\0label!=y\0", "unsupported token '!' (exclusion) given for key 'label'\n"),
  (
    "app=(\0label!=y\0",
    "invalid regex pattern '(' for key 'app'\nunsupported token '!' (exclusion) given for key 'label'\n"
  ),
  ("app=x\0colour=red\0", "unknown key 'colour'\n"),
  (
    "manage=on\0colour=red\0",
    "unknown key 'colour'\nmissing required key-value pair 'app[!]=..' or 'title[!]=..'\n"
  ),
  ("app=x\0bogus\0", "invalid key-value pair 'bogus'\n"),
  ("app=x\0label=\0", "invalid key-value pair 'label='\n"),
  (
    "bogus\0",
    "invalid key-value pair 'bogus'\nmissing required key-value pair 'app[!]=..' or 'title[!]=..'\n"
  ),
  ("label=x\0", "missing required key-value pair 'app[!]=..' or 'title[!]=..'\n"),
  ("app=x\0display=bogus\0", "value 'bogus' is not a valid option for DISPLAY_SEL\n"),
  ("app=x\0space=bogus\0", "value 'bogus' is not a valid option for SPACE_SEL\n"),
  ("app=x\0display=recent\0", ""),
  ("app=x\0space=recent\0", ""),
  ("app=x\0opacity=0.5\0", "unknown key 'opacity'\n"),
  ("app=x\0grid=2:2\0", "invalid value '2:2' for key 'grid'\n"),
  ("app=x\0sub-layer=bogus\0", "invalid value 'bogus' for key 'sub-layer'\n"),
  ("app=x\0sticky=maybe\0", "invalid value 'maybe' for key 'sticky'\n"),
  ("app=x\0mouse_follows_focus=maybe\0", "invalid value 'maybe' for key 'mouse_follows_focus'\n"),
  ("app=x\0native-fullscreen=maybe\0", "invalid value 'maybe' for key 'native-fullscreen'\n"),
  ("app=x\0scratchpad=float\0", "invalid value 'float' for key 'scratchpad'\n"),
]

@Test(arguments: ruleExactFailures)
func ruleParseFailureText(_ text: String, _ expected: String) {
  let (result, _, response) = parseRuleText(text)
  #expect(result == false)
  #expect(response == expected)
}

@Test func ruleMatchingAndListFlags() {
  var (_, rule, _) = parseRuleText("app=^Safari$\0title!=Preferences\0subrole=(\0sub-layer=above\0")
  #expect(rule.matches(app: "Safari", title: "Downloads", role: "AXWindow", subrole: "AXDialog"))
  #expect(!rule.matches(app: "Safari", title: "Preferences", role: "AXWindow", subrole: "AXDialog"))
  #expect(!rule.matches(app: "Mail", title: "Downloads", role: "AXWindow", subrole: "AXDialog"))
  #expect(!rule.hasRole && !rule.hasSubrole)

  // NOTE: valid app and title, title excluded, the subrole pattern is invalid; the layer flag in the high half
  #expect(rule.listFlags() == 0x0004_0023)

  rule.oneShot = true
  #expect(rule.listFlags(matched: true) == 0x0004_0323)
}

@Test func messageRuleValues() {
  let context = FixtureContext(activeDisplay: 1, displays: [1, 2], spaces: [10, 11])

  var (result, rule, response) = parseRuleText(
    "app=x\0display=^2\0grid=4:4:1:1:2:2\0scratchpad=notes\0", context)
  #expect(result == true)
  #expect(rule.effects.did == 2)
  #expect(rule.effects.followSpace)
  #expect(rule.effects.grid == Grid(4, 4, 1, 1, 2, 2))
  #expect(rule.effects.scratchpad == "notes")
  #expect(rule.effects.manage == false)
  #expect(response == "")

  (result, rule, response) = parseRuleText("app=x\0space=3\0sticky=maybe\0grid=2:2\0", context)
  #expect(result == false)
  #expect(
    response
      == "could not locate space with mission-control index '3'.\ninvalid value 'maybe' for key 'sticky'\ninvalid value '2:2' for key 'grid'\n"
  )

  (result, _, response) = parseRuleText("app=x\0space=^\0bogus\0", context)
  #expect(result == false)
  #expect(
    response == "value '' is not a valid option for SPACE_SEL\ninvalid key-value pair 'bogus'\n")
}

@Test func gridParseKeepsNegativeBitsAndIsAllOrNothing() {
  var grid = Grid(1, 2, 3, 4, 5, 6)

  let rejected = grid.parse(Token("-1:2:bad:4:5:6"))
  #expect(!rejected)
  #expect(grid == Grid(1, 2, 3, 4, 5, 6))
  #expect(Token("-1:2:bad:4:5:6").scanIntegers(count: 6).assigned == 2)

  let accepted = grid.parse(Token("-1:2:3:4:5:6"))
  #expect(accepted)
  #expect(grid.rows == UInt32.max)
  #expect(grid.columns == 2)
  #expect(grid.x == 3 && grid.y == 4 && grid.width == 5 && grid.height == 6)
}

@Test func ruleCommandsParseOperationsAndPayloads() throws(CommandError) {
  var add = Message("--add\0--one-shot\0app=^Safari$\0display=2\0")
  guard
    case .add(let rule) = try RuleCommand.parse(
      &add, FixtureContext(activeDisplay: 1, displays: [1, 2]))
  else {
    Issue.record("expected a parsed add command")
    return
  }
  #expect(rule.oneShot)
  #expect(rule.app?.text == "^Safari$")
  #expect(rule.effects.did == 2)

  var applyIndex = Message("--apply\0" + "7\0")
  guard case .apply(.index(7)) = try RuleCommand.parse(&applyIndex, FixtureContext()) else {
    Issue.record("expected an index apply selector")
    return
  }

  var applyFallback = Message("--apply\0app=Finder\0")
  guard
    case .apply(.labelOrInline(let label, .success(let inline))) = try RuleCommand.parse(
      &applyFallback, FixtureContext())
  else {
    Issue.record("expected an inline apply fallback")
    return
  }
  #expect(label.equals("app=Finder"))
  #expect(inline?.app?.text == "Finder")

  var applyInvalid = Message("--apply\0missing-label\0")
  guard
    case .apply(.labelOrInline(_, .failure(let error))) = try RuleCommand.parse(
      &applyInvalid, FixtureContext())
  else {
    Issue.record("expected the invalid inline fallback error to be retained")
    return
  }
  #expect(error.description.contains("invalid key-value pair 'missing-label'"))

  var applyAll = Message("--apply\0")
  guard case .apply(.all) = try RuleCommand.parse(&applyAll, FixtureContext()) else {
    Issue.record("expected an empty apply selector to reapply all rules")
    return
  }

  var remove = Message("--remove\0label-name\0")
  guard case .remove(.label(let removed)) = try RuleCommand.parse(&remove, FixtureContext()) else {
    Issue.record("expected a label remove selector")
    return
  }
  #expect(removed.equals("label-name"))
}

@Test func signalCommandsParseOperationsAndPayloads() throws(CommandError) {
  var add = Message("--add\0event=window_moved\0app=Finder\0active=yes\0action=echo hi\0")
  guard case .add(let signal, let event) = try SignalCommand.parse(&add) else {
    Issue.record("expected a parsed add command")
    return
  }
  #expect(event == .windowMoved)
  #expect(signal.app?.text == "Finder")
  #expect(signal.active == true)
  #expect(signal.command == "echo hi")

  var remove = Message("--remove\0signal-label\0")
  guard case .remove(.label(let label)) = try SignalCommand.parse(&remove) else {
    Issue.record("expected a label remove selector")
    return
  }
  #expect(label.equals("signal-label"))

  var list = Message("--list\0")
  guard case .list = try SignalCommand.parse(&list) else {
    Issue.record("expected a list command")
    return
  }
}

@Test(
  "signal --add rejects a filter that the event does not report",
  arguments: [
    ("config_loaded", "app=Finder", "event 'config_loaded' does not support the 'app' filter\n"),
    ("system_woke", "title=x", "event 'system_woke' does not support the 'title' filter\n"),
    ("space_changed", "active=no", "event 'space_changed' does not support the 'active' filter\n"),
    (
      "window_focused", "active=yes",
      "event 'window_focused' does not support the 'active' filter\n"
    ),
    (
      "application_launched", "title!=x",
      "event 'application_launched' does not support the 'title' filter\n"
    ),
    ("window_moved", "app=A\0title=B\0active=yes", nil),
    ("application_hidden", "app=A\0active=no", nil),
    ("config_loaded", "label=x", nil),
  ] as [(String, String, String?)])
func signalFiltersMustBeReportedByTheEvent(event: String, filters: String, expected: String?) {
  var message = Message("--add\0event=\(event)\0\(filters)\0action=true\0")
  #expect(
    thrownText { () throws(CommandError) in _ = try SignalCommand.parse(&message) } == expected)
}

private func parseSignalText(_ text: String) -> (Bool, EventSignal, Int?, String) {
  var signal = EventSignal()
  var event: Int?
  var message = Message(text)
  do {
    try parseSignal(&message, &signal, &event) { ["window_focused": 7][$0.string] }
    return (true, signal, event, "")
  } catch {
    return (false, signal, event, error.description)
  }
}

@Test("message_signal_parse") func messageSignalParse() {
  var (result, signal, event, response) = parseSignalText(
    "event=window_focused\0app!=^Finder$\0action=echo hi\0active=yes\0")
  #expect(result == true)
  #expect(event == 7)
  #expect(signal.app?.regex != nil)
  #expect(signal.app?.exclude == true)
  #expect(signal.active == true)
  #expect(signal.command == "echo hi")
  #expect(response == "")

  (result, _, _, response) = parseSignalText("event=nope\0action=x\0")
  #expect(result == false)
  #expect(response.contains("invalid value 'nope' for key 'event'"))
  #expect(!response.contains("missing required"))

  (result, _, _, response) = parseSignalText("label!=x\0")
  #expect(result == false)
  #expect(response.contains("missing required key-value pair 'event=..'"))
  #expect(response.contains("missing required key-value pair 'action=..'"))
  #expect(response.contains("unsupported token '!' (exclusion) given for key 'label'"))
}

// NOTE: the exact failure text of every signal failure path, and the order the failures come in.
private let signalExactFailures: [(String, String)] = [
  ("event=window_focused\0action=x\0active=maybe\0", "invalid value 'maybe' for key 'active'\n"),
  ("event=window_focused\0action=x\0app=(\0", "invalid regex pattern '(' for key 'app'\n"),
  ("event=window_focused\0action=x\0title=[\0", "invalid regex pattern '[' for key 'title'\n"),
  ("event=window_focused\0action=x\0colour=red\0", "unknown key 'colour'\n"),
  ("event=window_focused\0action=x\0bogus\0", "invalid key-value pair 'bogus'\n"),
  ("event=window_focused\0action=x\0label=\0", "invalid key-value pair 'label='\n"),
  ("event=bogus\0action=x\0", "invalid value 'bogus' for key 'event'\n"),
  ("action=x\0", "missing required key-value pair 'event=..'\n"),
  ("event=window_focused\0", "missing required key-value pair 'action=..'\n"),
  (
    "event=window_focused\0action=x\0label!=y\0",
    "unsupported token '!' (exclusion) given for key 'label'\n"
  ),
  (
    "event=window_focused\0action=x\0active!=yes\0",
    "unsupported token '!' (exclusion) given for key 'active'\n"
  ),
  (
    "bogus\0",
    "invalid key-value pair 'bogus'\nmissing required key-value pair 'event=..'\nmissing required key-value pair 'action=..'\n"
  ),
  (
    "event=bogus\0bogus\0colour=red\0label!=y\0",
    "invalid value 'bogus' for key 'event'\ninvalid key-value pair 'bogus'\nunknown key 'colour'\nmissing required key-value pair 'action=..'\nunsupported token '!' (exclusion) given for key 'label'\n"
  ),
]

@Test(arguments: signalExactFailures)
func signalParseFailureText(_ text: String, _ expected: String) {
  let (result, _, _, response) = parseSignalText(text)
  #expect(result == false)
  #expect(response == expected)
}

private func spaceEffects(_ sid: SpaceID, _ follow: Bool) -> RuleEffects {
  var effects = RuleEffects()
  effects.sid = sid
  effects.manage = false
  effects.followSpace = follow
  effects.grid = Grid(2, 2, 0, 0, 1, 1)
  return effects
}

@Test("rule_effects_combine") func ruleEffectsCombine() {
  var combined = RuleEffects()
  combined.combine(spaceEffects(4, true))
  #expect(combined.sid == 4)
  #expect(combined.followSpace)
  #expect(combined.manage == false)
  #expect(combined.grid.width == 1)

  // NOTE: a later rule that does not set a property keeps the earlier value
  var second = RuleEffects()
  second.sticky = true
  combined.combine(second)
  #expect(combined.sid == 4)
  #expect(combined.manage == false)
  #expect(combined.sticky == true)

  combined.combine(spaceEffects(6, false))
  #expect(combined.sid == 6)
  #expect(!combined.followSpace)

  // NOTE: a scratchpad replaces the earlier one
  var scratchpad = RuleEffects()
  scratchpad.scratchpad = "notes"
  combined.combine(scratchpad)
  #expect(combined.scratchpad == "notes")
}
