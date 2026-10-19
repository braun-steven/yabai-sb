import Testing
@testable import YabaiCore

// NOTE: Ported from tests/src/message.c. Messages are null-separated tokens, as sent by the client.

/// The lookups of the selectors, on fixtures. Windows are their ids.
private struct FixtureContext: SelectorContext
{
    var activeDisplay: DisplayID? = nil
    var activeSpace: SpaceID? = nil
    var actingWindow: WindowID? = nil
    var displays: [DisplayID] = []
    var spaces: [SpaceID] = []
    var recentSpace: SpaceID? = nil
    var displayLabels: [String: DisplayID] = [:]
    var spaceLabels: [String: SpaceID] = [:]
    var windows: [WindowID] = []
    var stack: [WindowID] = []

    func display(_ query: DisplayQuery) -> DisplayID?
    {
        switch query {
        case .arrangement(let index): index >= 1 && Int(index) <= displays.count ? displays[Int(index) - 1] : nil
        case .first:                  displays.first
        case .last:                   displays.last
        default:                      nil
        }
    }

    func displayLabel(_ label: Token) -> DisplayID? { displayLabels[label.string] }

    func space(_ query: SpaceQuery) -> SpaceID?
    {
        switch query {
        case .missionControl(let index): index >= 1 && Int(index) <= spaces.count ? spaces[Int(index) - 1] : nil
        case .recent:                    recentSpace
        default:                         nil
        }
    }

    func spaceLabel(_ label: Token) -> SpaceID? { spaceLabels[label.string] }

    func window(_ query: WindowQuery<WindowID>) -> WindowID?
    {
        switch query {
        case .id(let id):                      windows.contains(id) ? id : nil
        case .first:                           windows.first
        case .stackPosition(_, let position):  Int(position) <= stack.count ? stack[Int(position) - 1] : nil
        default:                               nil
        }
    }
}

private let domain = Token("config")
private let command = Token("test")

/// The text of the failure that body throws, nil when it does not throw.
private func thrownText(_ body: () throws(CommandError) -> Void) -> String?
{
    do { try body() } catch { return error.description }
    return nil
}

/// The text of a selector's failure, empty when it has none.
private func failureText(_ failure: CommandError?) -> String
{
    failure?.description ?? ""
}

@Test func messageTokens()
{
    var message = Message("window\0--focus\0\0east\0\0")
    #expect(message.next().equals("window"))
    #expect(message.peek().equals("--focus"))
    #expect(message.next().equals("--focus"))

    // NOTE: an empty argument looks like the end of the message, so the daemon stops reading there
    #expect(!message.next().isValid)
    #expect(!message.next().isValid)

    var unterminated = Message("a\0b")
    #expect(unterminated.next().equals("a"))
    #expect(unterminated.next().equals("b"))
    #expect(!unterminated.next().isValid)
}

@Test func tokenValues()
{
    guard case .int(42) = Token("42").value else { Issue.record("42"); return }
    guard case .u32(0xff) = Token("0xFF").value else { Issue.record("0xFF"); return }
    guard case .float(0.5) = Token("0.5").value else { Issue.record("0.5"); return }
    guard case .float(100) = Token("1e2").value else { Issue.record("1e2"); return }
    guard case .string = Token("0x").value else { Issue.record("0x"); return }
    guard case .string = Token("-1x").value else { Issue.record("-1x"); return }
    guard case .invalid = Token("").value else { Issue.record("empty"); return }

    // NOTE: like the int of the C version, a long number wraps around
    #expect(Token("4294967297").positiveInteger == 1)
    #expect(Token("0x100000001").hexadecimal == 1)

    #expect(TokenValue.int(3).floatValue == 3)
    #expect(TokenValue.string(Token("x")).floatValue == nil)
    #expect(Token("é").equals("e\u{301}") == false)
}

@Test func responseEchoesTokenBytes()
{
    var rsp = Response()
    rsp.fail(.unknownValue(domain, command, Token([0x66, 0xff])))
    #expect(rsp.bytes == [0x07] + Array("unknown value 'f".utf8) + [0xff] + Array("' given to command 'test' for domain 'config'\n".utf8))
}

private func parseBool(_ text: String, _ flag: inout Bool) -> (Bool, String)
{
    var rsp = Response()
    var message = Message(text)
    do {
        let result = try parseConfigBool(&rsp, domain, command, &message, &flag)
        return (result, rsp.text)
    } catch {
        return (false, error.description)
    }
}

@Test("message_config_bool") func messageConfigBool()
{
    var flag = false

    var (result, response) = parseBool("on\0", &flag)
    #expect(result == true)
    #expect(flag == true)
    #expect(response == "")

    (result, response) = parseBool("\0", &flag)
    #expect(result == false)
    #expect(response == "on\n")

    (result, response) = parseBool("off\0", &flag)
    #expect(result == true)
    #expect(flag == false)

    (result, response) = parseBool("yes\0", &flag)
    #expect(result == false)
    #expect(flag == false)
    #expect(response.contains("unknown value 'yes' given to command 'test'"))
}

private enum TestAction: String, CaseIterable
{
    case none
    case move
    case resize
    case swap
}

private func parseChoice(_ text: String, _ choices: [TestAction], current: TestAction) -> (TestAction?, String)
{
    var rsp = Response()
    var message = Message(text)
    do {
        let result = try parseConfigChoice(&rsp, domain, command, &message, choices, current: current)
        return (result, rsp.text)
    } catch {
        return (nil, error.description)
    }
}

@Test("A config choice is one of the accepted raw values, and prints the current one without a value")
func messageConfigChoice() throws
{
    #expect(parseChoice("move\0", [.move, .resize], current: .none).0 == .move)
    #expect(parseChoice("resize\0", [.move, .resize], current: .none).0 == .resize)

    // NOTE: values of the enum outside of the accepted choices are rejected
    let (result, response) = parseChoice("swap\0", [.move, .resize], current: .move)
    #expect(result == nil)
    #expect(response.contains("unknown value 'swap'"))

    #expect(parseChoice("\0", [.move, .resize], current: .none) == (nil, "none\n"))

    var rsp = Response()
    var message = Message("swap\0")
    let chosen = try parseConfigChoice(&rsp, domain, command, &message, current: TestAction.none)
    #expect(chosen == .swap)
}

@Test("message_window_toggle_lookup") func messageWindowToggleLookup()
{
    #expect(WindowToggle(Token("float")) == .float)
    #expect(WindowToggle(Token("zoom-fullscreen")) == .zoomFullscreen)
    #expect(WindowToggle(Token("shadow")) == .shadow)

    // NOTE: anything else is a scratchpad label
    #expect(WindowToggle(Token("notes")) == nil)
    #expect(WindowToggle(Token("floa")) == nil)

    // NOTE: window_toggle_list in src/message_window.c keeps its functions in this order
    #expect(WindowToggle.allCases.map(\.rawValue) == ["float", "sticky", "shadow", "split", "zoom-parent", "zoom-fullscreen", "windowed-fullscreen", "native-fullscreen", "expose", "pip"])
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

@Test("message_label_reserved") func messageLabelReserved()
{
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

    // NOTE: a missing label is valid and removes the label
    let missing = parseLabelText("", .space)
    #expect(missing.response == "" && missing.label == nil)
}

@Test func messageProperties() throws
{
    let names = ["id", "frame", "app"]
    let values: [UInt64] = [0x1, 0x2, 0x4]

    let properties = try parseProperties(Token("id,app"), names: names, values: values)
    #expect(properties.didParse && properties.flags == 0x5)

    let option = try parseProperties(Token("--window"), names: names, values: values)
    #expect(!option.didParse && option.flags == 0)

    // NOTE: the last byte always belongs to the last property, even a comma; every invalid property is reported in one failure
    let text = thrownText { () throws(CommandError) in _ = try parseProperties(Token("id,,frame,"), names: names, values: values) }
    #expect(text == "'' is not a valid property.\n'frame,' is not a valid property.\n")
}

@Test func messageKeyValuePairs()
{
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

@Test func messageValueParsers() throws
{
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

@Test("message_selectors") func messageSelectors()
{
    var context = FixtureContext()

    var window = parseWindowSelector(Token("east"), acting: nil, optional: false, context)
    #expect(window.didParse == true)
    #expect(window.value == nil)
    #expect(failureText(window.failure).contains("could not locate the selected window."))

    window = parseWindowSelector(Token("stack.bogus"), acting: nil, optional: false, context)
    #expect(window.didParse == false)
    #expect(failureText(window.failure) == "value 'stack.bogus' is not a valid option for WINDOW_SEL\n")

    window = parseWindowSelector(Token("bogus"), acting: nil, optional: false, context)
    #expect(window.didParse == false)
    #expect(failureText(window.failure).contains("value 'bogus' is not a valid option for WINDOW_SEL"))

    var display = parseDisplaySelector(Token("next"), acting: nil, optional: false, context)
    #expect(failureText(display.failure).contains("could not locate the selected display."))

    display = parseDisplaySelector(Token("unlabeled"), acting: nil, optional: false, context)
    #expect(display.didParse == false)
    #expect(failureText(display.failure).contains("is not a valid option for DISPLAY_SEL"))

    // NOTE: an optional selector that is missing does not report an error
    var space = parseSpaceSelector(Token(""), acting: nil, optional: true, context)
    #expect(space.didParse == false)
    #expect(space.failure == nil)

    context.recentSpace = 77
    space = parseSpaceSelector(Token("recent"), acting: nil, optional: true, context)
    #expect(space.value == 77)
    #expect(space.failure == nil)

    #expect(parseDirection(Token("west")) == .west)
    #expect(parseDirection(Token("up")) == nil)
}

@Test func messageSelectorLookups() throws
{
    let context = FixtureContext(activeDisplay: 1, actingWindow: 7, displays: [1, 2], spaces: [10, 11], displayLabels: ["main": 2], spaceLabels: ["code": 11], windows: [7, 8], stack: [7, 9])

    #expect(parseDisplaySelector(Token("2"), acting: 1, optional: false, context).value == 2)
    #expect(parseDisplaySelector(Token("main"), acting: 1, optional: false, context).value == 2)
    #expect(parseDisplaySelector(Token("last"), acting: 1, optional: false, context).value == 2)

    let third = parseDisplaySelector(Token("3"), acting: 1, optional: false, context)
    #expect(third.value == nil)
    #expect(failureText(third.failure) == "could not locate display with arrangement index '3'.\n")

    let west = parseDisplaySelector(Token("west"), acting: 1, optional: false, context)
    #expect(west.didParse)
    #expect(failureText(west.failure) == "could not locate a westward display.\n")

    #expect(parseSpaceSelector(Token("code"), acting: 10, optional: false, context).value == 11)
    let hex = parseSpaceSelector(Token("0x10"), acting: 10, optional: true, context)
    #expect(hex.didParse == false)
    #expect(failureText(hex.failure) == "value '0x10' is not a valid option for SPACE_SEL\n")

    #expect(parseWindowSelector(Token("8"), acting: 7, optional: false, context).value == 8)
    #expect(parseWindowSelector(Token("first"), acting: nil, optional: false, context).value == 7)
    #expect(parseWindowSelector(Token("stack.2"), acting: 7, optional: false, context).value == 9)

    let stackThree = parseWindowSelector(Token("stack.3"), acting: 7, optional: false, context)
    #expect(stackThree.value == nil)
    #expect(failureText(stackThree.failure) == "could not locate the stacked window in position 3.\n")

    let stackZero = parseWindowSelector(Token("stack.0"), acting: 7, optional: false, context)
    #expect(stackZero.didParse == false)
    #expect(failureText(stackZero.failure) == "value 'stack.0' is not a valid option for WINDOW_SEL\n")

    let north = parseWindowSelector(Token("north"), acting: 7, optional: false, context)
    #expect(north.value == nil)
    #expect(failureText(north.failure) == "could not locate a northward managed window.\n")

    var message = Message("9\0")
    var acting: WindowID? = 7
    let unknownId = thrownText { () throws(CommandError) in _ = try parseOptionalWindowSelector(&message, &acting, context) }
    #expect(unknownId == "could not locate window with the specified id '9'.\n")
    #expect(acting == 7)

    var sid: SpaceID? = 10
    message = Message("\0")
    let found = try parseOptionalSpaceSelector(&message, &sid, context)
    #expect(found == true)
    #expect(sid == 10)
}

//
// NOTE: The typed selectors and commands of the window domain.
//

@Test func typedSelectorsParseWithoutLookups()
{
    #expect(WindowSelector(Token("8")) == .id(8))
    #expect(WindowSelector(Token("east")) == .direction(.east))
    #expect(WindowSelector(Token("stack.2")) == .stack(.position(2)))
    #expect(WindowSelector(Token("stack.recent")) == .stack(.recent))
    #expect(WindowSelector(Token("stack.0")) == nil)
    #expect(WindowSelector(Token("0x10")) == nil)
    #expect(WindowSelector(Token("")) == nil)

    #expect(DisplaySelector(Token("west")) == .direction(.west))
    #expect(DisplaySelector(Token("main")) == .label(Token("main")))
    #expect(SpaceSelector(Token("3")) == .missionControl(3))
    #expect(SpaceSelector(Token("recent")) == .recent)
    #expect(SpaceSelector(Token("1.5")) == nil)
}

@Test func typedSelectorsResolveThroughTheContext() throws
{
    let context = FixtureContext(activeDisplay: 1, actingWindow: 7, displays: [1, 2], spaces: [10, 11], displayLabels: ["main": 2], spaceLabels: ["code": 11], windows: [7, 8], stack: [7, 9])

    #expect(try WindowSelector.first.resolve(acting: nil, context) == 7)
    #expect(try WindowSelector.stack(.position(2)).resolve(acting: 7, context) == 9)
    #expect(try DisplaySelector.label(Token("main")).resolve(acting: 1, context) == 2)
    #expect(try SpaceSelector.recent.resolve(acting: 10, context) == nil)

    let relative = thrownText { () throws(CommandError) in _ = try WindowSelector.next.resolve(acting: nil, context) }
    #expect(relative == "could not locate the selected window.\n")
    let unknownLabel = thrownText { () throws(CommandError) in _ = try SpaceSelector.label(Token("mail")).resolve(acting: 10, context) }
    #expect(unknownLabel == "value 'mail' is not a valid option for SPACE_SEL\n")
}

/// Parses one window command from text that starts with its name: the command, or the failure text and whether it
/// stops the message.
private func parseWindowCommand(_ text: String) -> (WindowCommand?, String, Bool)
{
    var message = Message(text)
    guard let name = WindowCommand.Name(message.next()) else { return (nil, "no name", false) }

    do {
        return (try WindowCommand.parse(name, &message), "", false)
    } catch {
        return (nil, error.description, error.stopsMessage)
    }
}

@Test func windowCommandNames()
{
    #expect(WindowCommand.Name(Token("--sub-layer")) == .subLayer)
    #expect(WindowCommand.Name(Token("--foo")) == nil)
    #expect(!WindowCommand.Name.toggle.needsWindow)
    #expect(!WindowCommand.Name.deminimize.needsWindow)
    #expect(WindowCommand.Name.swap.needsWindow)
}

@Test func windowCommandValues()
{
    #expect(parseWindowCommand("--swap\0east\0").0 == .swap(.direction(.east)))
    #expect(parseWindowCommand("--focus\0parent\0").0 == .focus(.container(.parent)))
    #expect(parseWindowCommand("--focus\0").0 == .focus(.window(nil)))
    #expect(parseWindowCommand("--focus\0recent\0").0 == .focus(.window(.recent)))
    #expect(parseWindowCommand("--display\0main\0").0 == .display(.label(Token("main"))))
    #expect(parseWindowCommand("--move\0rel:10:-5\0").0 == .move(.rel, dx: 10, dy: -5))
    #expect(parseWindowCommand("--move\0sideways:1:2\0").0 == .move(nil, dx: 1, dy: 2))
    #expect(parseWindowCommand("--resize\0top_left:1:2\0").0 == .resize([.top, .left], dx: 1, dy: 2))
    #expect(parseWindowCommand("--ratio\0abs:0.3\0").0 == .ratio(.abs, 0.3))
    #expect(parseWindowCommand("--grid\04:4:1:1:2:2\0").0 == .grid(Grid(4, 4, 1, 1, 2, 2)))
    #expect(parseWindowCommand("--opacity\01\0").0 == .opacity(1))
    #expect(parseWindowCommand("--toggle\0float\0").0 == .toggle(.float))
    #expect(parseWindowCommand("--toggle\0notes\0").0 == .toggleScratchpad(Token("notes")))
    #expect(parseWindowCommand("--scratchpad\0recover\0").0 == .scratchpad(.recover))
    #expect(parseWindowCommand("--scratchpad\0term\0").0 == .scratchpad(.assign(label: "term")))
    #expect(parseWindowCommand("--scratchpad\0").0 == .scratchpad(.remove))
    #expect(parseWindowCommand("--layout\0toggle-split\0").0 == .layout(.toggleSplit))
    #expect(parseWindowCommand("--split\0vertical\0").0 == .split(.fixed(.vertical)))
    #expect(parseWindowCommand("--insert\0stack\0").0 == .insert(.stack))
}

@Test func windowCommandFailures()
{
    // NOTE: an invalid optional selector stops the message, an invalid required one does not
    let focus = parseWindowCommand("--focus\0bogus\0")
    #expect(focus.1 == "value 'bogus' is not a valid option for WINDOW_SEL\n")
    #expect(focus.2)

    let swap = parseWindowCommand("--swap\0bogus\0")
    #expect(swap.1 == "value 'bogus' is not a valid option for WINDOW_SEL\n")
    #expect(!swap.2)

    let layout = parseWindowCommand("--layout\0stacked\0")
    #expect(layout.1 == "unknown value 'stacked' given to command '--layout' for domain 'window'\n")
    #expect(layout.2)

    let split = parseWindowCommand("--split\0diagonal\0")
    #expect(split.1 == "unknown value 'diagonal' given to command '--split' for domain 'window'\n")
    #expect(split.2)

    let opacity = parseWindowCommand("--opacity\01.5\0")
    #expect(opacity.1 == "unknown value '1.5' given to command '--opacity' for domain 'window'\n")
    #expect(!opacity.2)

    #expect(parseWindowCommand("--grid\0a\0").1 == "unknown value 'a' given to command '--grid' for domain 'window'\n")
    #expect(parseWindowCommand("--scratchpad\0float\0").1 == "'float' is a reserved keyword and cannot be used as a scratchpad.\n")
    #expect(parseWindowCommand("--space\0").1 == "value '' is not a valid option for SPACE_SEL\n")
}

@Test func windowFocusTargetWithoutTree() throws
{
    #expect(try WindowFocusTarget.container(.direction(.east)).windowSelector() == .direction(.east))
    #expect(try WindowFocusTarget.window(nil).windowSelector() == nil)

    let parent = thrownText { () throws(CommandError) in _ = try WindowFocusTarget.container(.parent).windowSelector() }
    #expect(parent == "value 'parent' is not a valid option for WINDOW_SEL\n")
}

@Test func windowLayoutValues()
{
    #expect(WindowLayout(Token("tabbed")) == .tabbed)
    #expect(WindowLayout(Token("toggle-split")) == .toggleSplit)
    #expect(WindowLayout(Token("stacked")) == nil)

    #expect(SplitOrientation(Token("vertical")) == .fixed(.vertical))
    #expect(SplitOrientation(Token("toggle")) == .toggle)
    #expect(SplitOrientation(Token("diagonal")) == nil)
}

private func parseQuery(_ option: String, _ context: FixtureContext = FixtureContext()) -> (QueryTarget<WindowID>?, String)
{
    var message = Message("\0")
    let properties = Properties(token: Token(option), didParse: false)
    do {
        let target = try parseQueryTarget(Token("query"), Token("--windows"), &message, properties, context)
        return (target, "")
    } catch {
        return (nil, error.description)
    }
}

@Test("message_query_target") func messageQueryTarget()
{
    guard case .all = parseQuery("").0 else { Issue.record("no option"); return }

    let (target, response) = parseQuery("--everything")
    #expect(target == nil)
    #expect(response.contains("unknown option '--everything' given to command '--windows'"))

    guard case .window(7) = parseQuery("--window", FixtureContext(actingWindow: 7)).0 else { Issue.record("--window"); return }

    // NOTE: without an active display or space there is nothing to query, which is reported as a failure
    let (noDisplay, noDisplayResponse) = parseQuery("--display")
    #expect(noDisplay == nil)
    #expect(noDisplayResponse == "could not locate the selected display.\n")

    let (noSpace, noSpaceResponse) = parseQuery("--space")
    #expect(noSpace == nil)
    #expect(noSpaceResponse == "could not locate the selected space.\n")
}

private func parseRuleText(_ text: String, _ context: FixtureContext = FixtureContext()) -> (Bool, Rule, String)
{
    var rule = Rule()
    var message = Message(text)
    let first = message.next()
    do {
        let result = try parseRule(&message, &rule, first, context)
        return (result, rule, "")
    } catch {
        return (false, rule, error.description)
    }
}

@Test("message_rule_parse") func messageRuleParse()
{
    var (result, rule, response) = parseRuleText("app=^Safari$\0title!=Preferences\0manage=off\0sticky=on\0sub-layer=above\0opacity=0.5\0")
    #expect(result == true)
    #expect(rule.app?.regex != nil)
    #expect(rule.app?.exclude == false)
    #expect(rule.title?.exclude == true)
    #expect(rule.effects.manage == false)
    #expect(rule.effects.sticky == true)
    #expect(rule.effects.mouseFollowsFocus == nil)
    #expect(rule.effects.layer == .above)
    #expect(rule.effects.flags.contains(.layer))
    #expect(rule.effects.flags.contains(.opacity))
    #expect(rule.app?.text == "^Safari$")
    #expect(response == "")

    (result, _, response) = parseRuleText("app=x\0manage=maybe\0")
    #expect(result == false)
    #expect(response.contains("invalid value 'maybe' for key 'manage'"))

    (result, _, response) = parseRuleText("app=(\0")
    #expect(result == false)
    #expect(response.contains("invalid regex pattern '(' for key 'app'"))

    (result, _, response) = parseRuleText("app=x\0label!=y\0")
    #expect(result == false)
    #expect(response.contains("unsupported token '!' (exclusion) given for key 'label'"))

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

    (result, _, response) = parseRuleText("manage=on\0colour=red\0")
    #expect(result == false)
    #expect(response.contains("unknown key 'colour'"))
    #expect(response.contains("missing required key-value pair"))
}

@Test func ruleMatchingAndListFlags()
{
    var (_, rule, _) = parseRuleText("app=^Safari$\0title!=Preferences\0subrole=(\0sub-layer=above\0")
    #expect(rule.matches(app: "Safari", title: "Downloads", role: "AXWindow", subrole: "AXDialog"))
    #expect(!rule.matches(app: "Safari", title: "Preferences", role: "AXWindow", subrole: "AXDialog"))
    #expect(!rule.matches(app: "Mail", title: "Downloads", role: "AXWindow", subrole: "AXDialog"))
    #expect(!rule.hasRole && !rule.hasSubrole)

    // NOTE: valid app and title, title excluded, the subrole pattern is invalid; the layer flag in the high half
    #expect(rule.listFlags == 0x0004_0023)

    rule.oneShot = true
    rule.matched = true
    #expect(rule.listFlags == 0x0004_0323)
}

@Test func messageRuleValues()
{
    let context = FixtureContext(activeDisplay: 1, displays: [1, 2], spaces: [10, 11])

    var (result, rule, response) = parseRuleText("app=x\0display=^2\0grid=4:4:1:1:2:2\0scratchpad=notes\0", context)
    #expect(result == true)
    #expect(rule.effects.did == 2)
    #expect(rule.effects.flags.contains(.followSpace))
    #expect(rule.effects.grid == Grid(4, 4, 1, 1, 2, 2))
    #expect(rule.effects.scratchpad == "notes")
    #expect(rule.effects.manage == false)
    #expect(response == "")

    (result, rule, response) = parseRuleText("app=x\0space=3\0opacity=1.5\0grid=2:2\0", context)
    #expect(result == false)
    #expect(response == "could not locate space with mission-control index '3'.\ninvalid value '1.5' for key 'opacity'\ninvalid value '2:2' for key 'grid'\n")

    (result, _, response) = parseRuleText("app=x\0space=^\0bogus\0", context)
    #expect(result == false)
    #expect(response == "value '' is not a valid option for SPACE_SEL\ninvalid key-value pair 'bogus'\n")
}

private func parseSignalText(_ text: String) -> (Bool, EventSignal, Int?, String)
{
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

@Test("message_signal_parse") func messageSignalParse()
{
    var (result, signal, event, response) = parseSignalText("event=window_focused\0app!=^Finder$\0action=echo hi\0active=yes\0")
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

private func spaceEffects(_ sid: SpaceID, _ follow: Bool) -> RuleEffects
{
    var effects = RuleEffects()
    effects.sid = sid
    effects.manage = false
    if follow { effects.flags.insert(.followSpace) }
    effects.grid = Grid(2, 2, 0, 0, 1, 1)
    return effects
}

@Test("rule_effects_combine") func ruleEffectsCombine()
{
    var combined = RuleEffects()
    combined.combine(spaceEffects(4, true))
    #expect(combined.sid == 4)
    #expect(combined.flags.contains(.followSpace))
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
    #expect(!combined.flags.contains(.followSpace))

    // NOTE: an opacity outside of 0..1 is ignored, a scratchpad replaces the earlier one
    var opacity = RuleEffects()
    opacity.opacity = 2
    opacity.flags.insert(.opacity)
    opacity.scratchpad = "notes"
    combined.combine(opacity)
    #expect(!combined.flags.contains(.opacity))
    #expect(combined.scratchpad == "notes")
}

@Test("message_client_encoding")
func messageClientEncoding()
{
    let message = ClientMessage.encode(["window", "--focus", "", "east"].map { Array($0.utf8) })

    let payloadLength = message.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    #expect(message.count == 4 + Int(payloadLength))
    #expect(payloadLength == 6 + 7 + 0 + 4 + 4 + 1)

    var tokens = Message(Array(message.dropFirst(4)))
    #expect(tokens.next().equals("window"))
    #expect(tokens.next().equals("--focus"))

    // NOTE: an empty argument looks like the end of the message, so the daemon stops reading there
    #expect(!tokens.next().isValid)
    #expect(!tokens.next().isValid)
    #expect(message.suffix(6) == Array("east\0\0".utf8))
}

@Test func cFormatMatchesPrintf()
{
    #expect(cFormat("%f", 0.25) == "0.250000")
    #expect(cFormat("%.4f", 1.0) == "1.0000")
    #expect(cFormat("%d:%u", Int32(-7), UInt32(7)) == "-7:7")
    #expect(cFormat("%100d", Int32(1)) == String(repeating: " ", count: 99) + "1")
}
