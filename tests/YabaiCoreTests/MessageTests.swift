import Testing
@testable import YabaiCore

// NOTE: Ported from tests/src/message.c. Messages are null-separated tokens, as sent by the client.

/// The lookups of the selectors, on fixtures. Windows are their ids.
private struct FixtureContext: SelectorContext
{
    var activeDisplay: DisplayID = 0
    var activeSpace: UInt64 = 0
    var actingWindow: UInt32? = nil
    var displays: [DisplayID] = []
    var spaces: [UInt64] = []
    var recentSpace: UInt64 = 0
    var displayLabels: [String: DisplayID] = [:]
    var spaceLabels: [String: UInt64] = [:]
    var windows: [UInt32] = []
    var stack: [UInt32] = []

    func display(_ query: DisplayQuery) -> DisplayID
    {
        switch query {
        case .arrangement(let index): index >= 1 && Int(index) <= displays.count ? displays[Int(index) - 1] : 0
        case .first:                  displays.first ?? 0
        case .last:                   displays.last ?? 0
        default:                      0
        }
    }

    func displayLabel(_ label: Token) -> DisplayID? { displayLabels[label.string] }

    func space(_ query: SpaceQuery) -> UInt64
    {
        switch query {
        case .missionControl(let index): index >= 1 && Int(index) <= spaces.count ? spaces[Int(index) - 1] : 0
        case .recent:                    recentSpace
        default:                         0
        }
    }

    func spaceLabel(_ label: Token) -> UInt64? { spaceLabels[label.string] }

    func window(_ query: WindowQuery<UInt32>) -> UInt32?
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
    rsp.failUnknownValue(domain, command, Token([0x66, 0xff]))
    #expect(rsp.bytes == [0x07] + Array("unknown value 'f".utf8) + [0xff] + Array("' given to command 'test' for domain 'config'\n".utf8))
}

private func parseBool(_ text: String, _ flag: inout Bool) -> (Bool, String)
{
    var rsp = Response()
    var message = Message(text)
    let result = parseConfigBool(&rsp, domain, command, &message, &flag)
    return (result, rsp.text)
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
    let result = parseConfigChoice(&rsp, domain, command, &message, choices, current: current)
    return (result, rsp.text)
}

@Test("A config choice is one of the accepted raw values, and prints the current one without a value")
func messageConfigChoice()
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
    #expect(parseConfigChoice(&rsp, domain, command, &message, current: TestAction.none) == .swap)
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
    var rsp = Response()
    let result = parseLabel(&rsp, Token(text), kind)
    return (rsp.text, result.valid ? result.label?.string : nil)
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

    #expect(parseLabelText("12", .space).response == "\u{07}'12' cannot be used as a label.\n")

    var rsp = Response()
    let missing = parseLabel(&rsp, Token(""), .space)
    #expect(missing.valid == true && missing.label == nil && rsp.bytes.isEmpty)
}

@Test func messageProperties()
{
    let names = ["id", "frame", "app"]
    let values: [UInt64] = [0x1, 0x2, 0x4]

    var rsp = Response()
    var properties = parseProperties(&rsp, Token("id,app"), names: names, values: values)
    #expect(properties.didParse && !properties.didError && properties.flags == 0x5)

    properties = parseProperties(&rsp, Token("--window"), names: names, values: values)
    #expect(!properties.didParse && properties.flags == 0)
    #expect(rsp.bytes.isEmpty)

    // NOTE: the last byte always belongs to the last property, even a comma
    properties = parseProperties(&rsp, Token("id,,frame,"), names: names, values: values)
    #expect(properties.didError && properties.flags == 0x1)
    #expect(rsp.text == "\u{07}'' is not a valid property.\n\u{07}'frame,' is not a valid property.\n")
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

@Test func messageValueParsers()
{
    #expect(parseLayer(Token("above")) == .above)
    #expect(parseLayer(Token("top")) == nil)
    #expect(parseValueType(Token("rel")) == .rel)
    #expect(parseValueType(Token("relative")) == nil)
    #expect(parseResizeHandle(Token("top_left")) == [.top, .left])
    #expect(parseResizeHandle(Token("middle")) == [])

    var rsp = Response()
    #expect(parseInsertSelector(&rsp, Token("stack")).value == .stack)
    #expect(parseInsertSelector(&rsp, Token("south")).value == .south)
    let invalid = parseInsertSelector(&rsp, Token("up"))
    #expect(!invalid.didParse && rsp.text == "\u{07}value 'up' is not a valid option for DIR_SEL\n")

    #expect(parseTreeFocus(Token("parent")) == .parent)
    #expect(parseTreeFocus(Token("east")) == .direction(.east))
    #expect(parseTreeFocus(Token("1")) == nil)
}

@Test("message_selectors") func messageSelectors()
{
    var context = FixtureContext()
    var rsp = Response()

    var window = parseWindowSelector(&rsp, Token("east"), acting: nil, optional: false, context)
    #expect(window.didParse == true)
    #expect(window.value == nil)
    #expect(rsp.text.contains("could not locate the selected window."))

    rsp = Response()
    window = parseWindowSelector(&rsp, Token("stack.bogus"), acting: nil, optional: false, context)
    #expect(rsp.text.contains("could not locate the selected window."))

    rsp = Response()
    window = parseWindowSelector(&rsp, Token("bogus"), acting: nil, optional: false, context)
    #expect(window.didParse == false)
    #expect(rsp.text.contains("value 'bogus' is not a valid option for WINDOW_SEL"))

    rsp = Response()
    var display = parseDisplaySelector(&rsp, Token("next"), acting: 0, optional: false, context)
    #expect(rsp.text.contains("could not locate the selected display."))

    rsp = Response()
    display = parseDisplaySelector(&rsp, Token("unlabeled"), acting: 0, optional: false, context)
    #expect(display.didParse == false)
    #expect(rsp.text.contains("is not a valid option for DISPLAY_SEL"))

    // NOTE: an optional selector that is missing does not report an error
    rsp = Response()
    var space = parseSpaceSelector(&rsp, Token(""), acting: 0, optional: true, context)
    #expect(space.didParse == false)
    #expect(rsp.bytes.isEmpty)

    context.recentSpace = 77
    space = parseSpaceSelector(&rsp, Token("recent"), acting: 0, optional: true, context)
    #expect(space.value == 77)

    #expect(parseDirection(Token("west")) == .west)
    #expect(parseDirection(Token("up")) == nil)
}

@Test func messageSelectorLookups()
{
    let context = FixtureContext(activeDisplay: 1, actingWindow: 7, displays: [1, 2], spaces: [10, 11], displayLabels: ["main": 2], spaceLabels: ["code": 11], windows: [7, 8], stack: [7, 9])
    var rsp = Response()

    #expect(parseDisplaySelector(&rsp, Token("2"), acting: 1, optional: false, context).value == 2)
    #expect(parseDisplaySelector(&rsp, Token("main"), acting: 1, optional: false, context).value == 2)
    #expect(parseDisplaySelector(&rsp, Token("last"), acting: 1, optional: false, context).value == 2)
    #expect(rsp.bytes.isEmpty)

    #expect(parseDisplaySelector(&rsp, Token("3"), acting: 1, optional: false, context).value == 0)
    #expect(rsp.text == "\u{07}could not locate display with arrangement index '3'.\n")

    rsp = Response()
    #expect(parseDisplaySelector(&rsp, Token("west"), acting: 1, optional: false, context).didParse)
    #expect(rsp.text == "\u{07}could not locate a westward display.\n")

    rsp = Response()
    #expect(parseSpaceSelector(&rsp, Token("code"), acting: 10, optional: false, context).value == 11)
    #expect(parseSpaceSelector(&rsp, Token("0x10"), acting: 10, optional: true, context).didParse == false)
    #expect(rsp.text == "\u{07}value '0x10' is not a valid option for SPACE_SEL\n")

    rsp = Response()
    #expect(parseWindowSelector(&rsp, Token("8"), acting: 7, optional: false, context).value == 8)
    #expect(parseWindowSelector(&rsp, Token("first"), acting: nil, optional: false, context).value == 7)
    #expect(parseWindowSelector(&rsp, Token("stack.2"), acting: 7, optional: false, context).value == 9)
    #expect(rsp.bytes.isEmpty)

    #expect(parseWindowSelector(&rsp, Token("stack.3"), acting: 7, optional: false, context).value == nil)
    #expect(rsp.text == "\u{07}could not locate the stacked window in position 3.\n")

    rsp = Response()
    let stack = parseWindowSelector(&rsp, Token("stack.0"), acting: 7, optional: false, context)
    #expect(stack.didParse == false)
    #expect(rsp.text == "\u{07}value 'stack.0' is not a valid option for WINDOW_SEL\n")

    rsp = Response()
    #expect(parseWindowSelector(&rsp, Token("north"), acting: 7, optional: false, context).value == nil)
    #expect(rsp.text == "\u{07}could not locate a northward managed window.\n")

    rsp = Response()
    var message = Message("9\0")
    var acting: UInt32? = 7
    #expect(parseOptionalWindowSelector(&rsp, &message, &acting, context) == false)
    #expect(acting == 7)
    #expect(rsp.text == "\u{07}could not locate window with the specified id '9'.\n")

    var sid: UInt64 = 10
    message = Message("\0")
    #expect(parseOptionalSpaceSelector(&rsp, &message, &sid, context) == true)
    #expect(sid == 10)
}

private func parseQuery(_ option: String, _ context: FixtureContext = FixtureContext()) -> (QueryTarget<UInt32>?, String)
{
    var rsp = Response()
    var message = Message("\0")
    let properties = Properties(token: Token(option), didParse: false)
    let target = parseQueryTarget(&rsp, Token("query"), Token("--windows"), &message, properties, context)
    return (target, rsp.text)
}

@Test("message_query_target") func messageQueryTarget()
{
    guard case .all = parseQuery("").0 else { Issue.record("no option"); return }

    let (target, response) = parseQuery("--everything")
    #expect(target == nil)
    #expect(response.contains("unknown option '--everything' given to command '--windows'"))

    guard case .window(7) = parseQuery("--window", FixtureContext(actingWindow: 7)).0 else { Issue.record("--window"); return }
}

private func parseRuleText(_ text: String, _ context: FixtureContext = FixtureContext()) -> (Bool, Rule, String)
{
    var rsp = Response()
    var rule = Rule()
    var message = Message(text)
    let first = message.next()
    let result = parseRule(&rsp, &message, &rule, first, context)
    return (result, rule, rsp.text)
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
    #expect(response == "\u{07}could not locate space with mission-control index '3'.\n\u{07}invalid value '1.5' for key 'opacity'\n\u{07}invalid value '2:2' for key 'grid'\n")

    (result, _, response) = parseRuleText("app=x\0space=^\0bogus\0", context)
    #expect(result == false)
    #expect(response == "\u{07}value '' is not a valid option for SPACE_SEL\n\u{07}invalid key-value pair 'bogus'\n")
}

private func parseSignalText(_ text: String) -> (Bool, EventSignal, Int?, String)
{
    var rsp = Response()
    var signal = EventSignal()
    var event: Int?
    var message = Message(text)
    let result = parseSignal(&rsp, &message, &signal, &event) { ["window_focused": 7][$0.string] }
    return (result, signal, event, rsp.text)
}

@Test("message_signal_parse") func messageSignalParse()
{
    var (result, signal, event, response) = parseSignalText("event=window_focused\0app!=^Finder$\0action=echo hi\0active=yes\0")
    #expect(result == true)
    #expect(event == 7)
    #expect(signal.app?.regex != nil)
    #expect(signal.app?.exclude == true)
    #expect(signal.active == .yes)
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

private func spaceEffects(_ sid: UInt64, _ follow: Bool) -> RuleEffects
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
