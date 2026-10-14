import YabaiC
import YabaiCore

//
// NOTE: The C entry points of the message parsers (Sources/YabaiCore/Message.swift, MessageParse.swift, Rule.swift) while
// the handlers of message*.c are C (src/message_parse.h). The C handlers keep reading tokens with get_token; a parser that
// takes the next tokens reads them through CMessage, so it consumes exactly what the C version did. A parser writes its
// response into a Response, which the shim writes to rsp before it returns, so the order of the output is unchanged.
//

extension Token
{
    init(_ token: token)
    {
        guard let text = token.text, token.length > 0 else {
            self.init(ArraySlice<UInt8>())
            return
        }

        self.init(UnsafeRawBufferPointer(start: text, count: Int(token.length)))
    }

    init(cString: UnsafePointer<CChar>?)
    {
        guard let cString else {
            self.init(ArraySlice<UInt8>())
            return
        }

        self.init(UnsafeRawBufferPointer(start: cString, count: strlen(cString)))
    }
}

/// The cursor of a C message (`char **message`), read with get_token.
struct CMessage: TokenSource
{
    let cursor: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

    mutating func next() -> Token
    {
        Token(get_token(cursor))
    }
}

extension Response
{
    /// Writes the response to rsp like `daemon_fail` and `fprintf` did; nothing when rsp is NULL.
    func write(to rsp: UnsafeMutablePointer<FILE>?)
    {
        guard let rsp, !bytes.isEmpty else { return }
        _ = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, rsp) }
    }
}

/// A malloc'ed copy of bytes with a null terminator, which the C code frees.
func mallocString(_ bytes: some Collection<UInt8>) -> UnsafeMutablePointer<CChar>
{
    let result = malloc(bytes.count + 1)!.bindMemory(to: CChar.self, capacity: bytes.count + 1)
    for (i, byte) in bytes.enumerated() { result[i] = CChar(bitPattern: byte) }
    result[bytes.count] = 0
    return result
}

func mallocString(_ string: String?) -> UnsafeMutablePointer<CChar>?
{
    string.map { mallocString($0.utf8) }
}

/// The selectors look up displays, spaces and windows in the C managers.
struct CSelectorContext: SelectorContext
{
    typealias Window = UnsafeMutablePointer<window>

    var activeDisplay: UInt32 { display_manager_active_display_id() }
    var activeSpace: UInt64 { space_manager_active_space() }
    var actingWindow: Window? { window_manager_acting_window(window_manager_global()) }

    func display(_ query: DisplayQuery) -> UInt32
    {
        switch query {
        case .arrangement(let index):         display_manager_arrangement_display_id(index)
        case .inDirection(let direction, let did): display_manager_find_closest_display_in_direction(did, direction.rawValue)
        case .prev(let did):                  display_manager_prev_display_id(did)
        case .next(let did):                  display_manager_next_display_id(did)
        case .first:                          display_manager_first_display_id()
        case .last:                           display_manager_last_display_id()
        case .recent:                         display_manager_global().pointee.last_display_id
        case .cursor:                         display_manager_cursor_display_id()
        }
    }

    func displayLabel(_ label: Token) -> UInt64?
    {
        labelList(display_manager_global().pointee.labels)?.list.find(name: label.string)?.id
    }

    func space(_ query: SpaceQuery) -> UInt64
    {
        switch query {
        case .missionControl(let index): space_manager_mission_control_space(index)
        case .prev(let sid):             space_manager_prev_space(sid)
        case .next(let sid):             space_manager_next_space(sid)
        case .first:                     space_manager_first_space()
        case .last:                      space_manager_last_space()
        case .recent:                    space_manager_global().pointee.last_space_id
        case .cursor:                    space_manager_cursor_space()
        }
    }

    func spaceLabel(_ label: Token) -> UInt64?
    {
        labelList(space_manager_global().pointee.labels)?.list.find(name: label.string)?.id
    }

    func window(_ query: WindowQuery<Window>) -> Window?
    {
        switch query {
        case .id(let id):                          window_manager_find_window(window_manager_global(), id)
        case .inDirection(let direction, let from): window_manager_find_closest_managed_window_in_direction(window_manager_global(), from, direction.rawValue)
        case .belowCursor:                         window_manager_find_window_below_cursor(window_manager_global())
        case .largest:                             window_manager_find_largest_managed_window(space_manager_global(), window_manager_global())
        case .smallest:                            window_manager_find_smallest_managed_window(space_manager_global(), window_manager_global())
        case .prev(let window):                    window_manager_find_prev_managed_window(space_manager_global(), window_manager_global(), window)
        case .next(let window):                    window_manager_find_next_managed_window(space_manager_global(), window_manager_global(), window)
        case .first:                               window_manager_find_first_managed_window(space_manager_global(), window_manager_global())
        case .last:                                window_manager_find_last_managed_window(space_manager_global(), window_manager_global())
        case .recent:                              window_manager_find_recent_managed_window(window_manager_global())
        case .stackPrev(let window):               window_manager_find_prev_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackNext(let window):               window_manager_find_next_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackFirst(let window):              window_manager_find_first_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackLast(let window):               window_manager_find_last_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackRecent(let window):             window_manager_find_recent_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackPosition(let window, let index): window_manager_find_window_in_stack(space_manager_global(), window_manager_global(), window, index)
        }
    }
}

@_cdecl("token_to_value")
func token_to_value(_ token: token) -> token_value
{
    var result = token_value()
    result.token = token

    switch Token(token).value {
    case .invalid:          result.type = TOKEN_TYPE_INVALID
    case .int(let value):   result.type = TOKEN_TYPE_INT;    result.int_value = value
    case .u32(let value):   result.type = TOKEN_TYPE_U32;    result.u32_value = value
    case .float(let value): result.type = TOKEN_TYPE_FLOAT;  result.float_value = value
    case .string:           result.type = TOKEN_TYPE_STRING; result.string_value = token.text
    }

    return result
}

private func tokenValue(_ value: token_value) -> TokenValue
{
    switch value.type {
    case TOKEN_TYPE_INT:    .int(value.int_value)
    case TOKEN_TYPE_U32:    .u32(value.u32_value)
    case TOKEN_TYPE_FLOAT:  .float(value.float_value)
    case TOKEN_TYPE_STRING: .string(Token(value.token))
    default:                .invalid
    }
}

@_cdecl("token_value_float")
func token_value_float(_ value: token_value, _ result: UnsafeMutablePointer<Float>) -> Bool
{
    guard let float = tokenValue(value).floatValue else { return false }

    result.pointee = float
    return true
}

@_cdecl("daemon_fail_unknown_command")
func daemon_fail_unknown_command(_ rsp: UnsafeMutablePointer<FILE>?, _ domain: token, _ command: token)
{
    var response = Response()
    response.failUnknownCommand(Token(domain), Token(command))
    response.write(to: rsp)
}

@_cdecl("daemon_fail_unknown_option")
func daemon_fail_unknown_option(_ rsp: UnsafeMutablePointer<FILE>?, _ domain: token, _ command: token, _ option: token)
{
    var response = Response()
    response.failUnknownOption(Token(domain), Token(command), Token(option))
    response.write(to: rsp)
}

@_cdecl("daemon_fail_unknown_value")
func daemon_fail_unknown_value(_ rsp: UnsafeMutablePointer<FILE>?, _ domain: token, _ command: token, _ value: token)
{
    var response = Response()
    response.failUnknownValue(Token(domain), Token(command), Token(value))
    response.write(to: rsp)
}

@_cdecl("parse_config_bool")
func parse_config_bool(_ rsp: UnsafeMutablePointer<FILE>?, _ domain: token, _ command: token, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ flag: UnsafeMutablePointer<Bool>) -> Bool
{
    var response = Response()
    var source = CMessage(cursor: message)
    defer { response.write(to: rsp) }
    return parseConfigBool(&response, Token(domain), Token(command), &source, &flag.pointee)
}

@_cdecl("parse_config_choice")
func parse_config_choice(_ rsp: UnsafeMutablePointer<FILE>?, _ domain: token, _ command: token, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ names: UnsafeMutablePointer<UnsafePointer<CChar>?>, _ first: Int32, _ last: Int32, _ current: Int32, _ choice: UnsafeMutablePointer<Int32>) -> Bool
{
    let count = Int(max(last, current)) + 1
    let names = (0..<count).map { names[$0].map { String(cString: $0) } }

    var response = Response()
    var source = CMessage(cursor: message)
    var selected = Int(choice.pointee)
    defer { response.write(to: rsp) }

    guard parseConfigChoice(&response, Token(domain), Token(command), &source, names: names, first: Int(first), last: Int(last), current: Int(current), &selected) else { return false }

    choice.pointee = Int32(selected)
    return true
}

//
// NOTE: The values of LAYER_* (src/misc/macros.h). Swift does not import the macros that name the CGWindowLevelKey
// constants.
//

private func layerValue(_ layer: WindowLayer) -> Int32
{
    switch layer {
    case .auto:   Int32(LAYER_AUTO)
    case .below:  CGWindowLevelKey.backstopMenu.rawValue
    case .normal: CGWindowLevelKey.normalWindow.rawValue
    case .above:  CGWindowLevelKey.floatingWindow.rawValue
    }
}

private func windowLayer(_ layer: Int32) -> WindowLayer
{
    WindowLayer.allCases.first { layerValue($0) == layer } ?? .auto
}

@_cdecl("parse_layer")
func parse_layer(_ value: UnsafeMutablePointer<CChar>?) -> Int32
{
    parseLayer(Token(cString: value)).map(layerValue) ?? -1
}

@_cdecl("parse_value_type")
func parse_value_type(_ type: UnsafeMutablePointer<CChar>?) -> UInt8
{
    parseValueType(Token(cString: type))?.rawValue ?? 0
}

@_cdecl("parse_resize_handle")
func parse_resize_handle(_ handle: UnsafeMutablePointer<CChar>?) -> UInt8
{
    parseResizeHandle(Token(cString: handle)).rawValue
}

@_cdecl("window_toggle_index")
func window_toggle_index(_ value: token) -> Int32
{
    guard let toggle = WindowToggle(Token(value)) else { return -1 }
    return Int32(WindowToggle.allCases.firstIndex(of: toggle)!)
}

private func labelKind(_ type: label_type) -> LabelKind
{
    switch type {
    case LABEL_DISPLAY: .display
    case LABEL_SPACE:   .space
    default:            .window
    }
}

@_cdecl("parse_label")
func parse_label(_ rsp: UnsafeMutablePointer<FILE>?, _ token: token, _ type: label_type, _ label: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Bool
{
    var response = Response()
    defer { response.write(to: rsp) }

    let result = parseLabel(&response, Token(token), labelKind(type))
    label.pointee = result.label.map { mallocString($0.bytes) }
    return result.valid
}

@_cdecl("parse_properties")
func parse_properties(_ rsp: UnsafeMutablePointer<FILE>?, _ token: token, _ propertyVal: UnsafeMutablePointer<UInt64>, _ propertyStr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ propertyCount: Int32) -> properties
{
    let names = (0..<Int(propertyCount)).map { String(cString: propertyStr[$0]!) }
    let values = Array(UnsafeBufferPointer(start: propertyVal, count: Int(propertyCount)))

    var response = Response()
    defer { response.write(to: rsp) }

    let parsed = parseProperties(&response, Token(token), names: names, values: values)
    return properties(token: token, did_parse: parsed.didParse, did_error: parsed.didError, flags: parsed.flags)
}

@_cdecl("parse_display_selector")
func parse_display_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ actingDid: UInt32, _ optional: Bool) -> selector
{
    let token = get_token(message)

    var response = Response()
    defer { response.write(to: rsp) }

    let parsed = parseDisplaySelector(&response, Token(token), acting: actingDid, optional: optional, CSelectorContext())
    var result = selector()
    result.token = token
    result.did_parse = parsed.didParse
    result.did = parsed.value
    return result
}

@_cdecl("parse_space_selector")
func parse_space_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ actingSid: UInt64, _ optional: Bool) -> selector
{
    let token = get_token(message)

    var response = Response()
    defer { response.write(to: rsp) }

    let parsed = parseSpaceSelector(&response, Token(token), acting: actingSid, optional: optional, CSelectorContext())
    var result = selector()
    result.token = token
    result.did_parse = parsed.didParse
    result.sid = parsed.value
    return result
}

@_cdecl("parse_window_selector")
func parse_window_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ actingWindow: UnsafeMutablePointer<window>?, _ optional: Bool) -> selector
{
    let token = get_token(message)

    var response = Response()
    defer { response.write(to: rsp) }

    let parsed = parseWindowSelector(&response, Token(token), acting: actingWindow, optional: optional, CSelectorContext())
    var result = selector()
    result.token = token
    result.did_parse = parsed.didParse
    result.window = parsed.value
    return result
}

@_cdecl("parse_optional_display_selector")
func parse_optional_display_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ did: UnsafeMutablePointer<UInt32>) -> Bool
{
    var response = Response()
    var source = CMessage(cursor: message)
    defer { response.write(to: rsp) }
    return parseOptionalDisplaySelector(&response, &source, &did.pointee, CSelectorContext())
}

@_cdecl("parse_optional_space_selector")
func parse_optional_space_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ sid: UnsafeMutablePointer<UInt64>) -> Bool
{
    var response = Response()
    var source = CMessage(cursor: message)
    defer { response.write(to: rsp) }
    return parseOptionalSpaceSelector(&response, &source, &sid.pointee, CSelectorContext())
}

@_cdecl("parse_optional_window_selector")
func parse_optional_window_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ window: UnsafeMutablePointer<UnsafeMutablePointer<window>?>) -> Bool
{
    var response = Response()
    var source = CMessage(cursor: message)
    defer { response.write(to: rsp) }
    return parseOptionalWindowSelector(&response, &source, &window.pointee, CSelectorContext())
}

@_cdecl("parse_insert_selector")
func parse_insert_selector(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> selector
{
    let token = get_token(message)

    var response = Response()
    defer { response.write(to: rsp) }

    let parsed = parseInsertSelector(&response, Token(token))
    var result = selector()
    result.token = token
    result.did_parse = parsed.didParse
    result.dir = parsed.value?.rawValue ?? 0
    return result
}

@_cdecl("peek_tree_direction")
func peek_tree_direction(_ message: UnsafeMutablePointer<CChar>?) -> Int32
{
    var cursor = message
    switch parseTreeFocus(Token(get_token(&cursor))) {
    case .direction(let direction): return direction.rawValue
    case .parent:                   return TREE_FOCUS_PARENT
    case .child:                    return TREE_FOCUS_CHILD
    case nil:                       return 0
    }
}

@_cdecl("parse_query_target")
func parse_query_target(_ rsp: UnsafeMutablePointer<FILE>?, _ domain: token, _ command: token, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ properties: properties, _ target: UnsafeMutablePointer<query_target>) -> Bool
{
    var parsedProperties = Properties(token: Token(properties.token), didParse: properties.did_parse)
    parsedProperties.didError = properties.did_error
    parsedProperties.flags = properties.flags

    var response = Response()
    var source = CMessage(cursor: message)
    defer { response.write(to: rsp) }

    target.pointee = query_target()
    guard let parsed = parseQueryTarget(&response, Token(domain), Token(command), &source, parsedProperties, CSelectorContext()) else { return false }

    switch parsed {
    case .all:                 target.pointee.type = QUERY_TARGET_ALL
    case .display(let did):    target.pointee.type = QUERY_TARGET_DISPLAY; target.pointee.did = did
    case .space(let sid):      target.pointee.type = QUERY_TARGET_SPACE;   target.pointee.sid = sid
    case .window(let window):  target.pointee.type = QUERY_TARGET_WINDOW;  target.pointee.window = window
    }

    return true
}

//
// NOTE: struct rule and struct signal stay C until the rules and signals are Swift (P7, P11). The shims fill them from
// the parsed Rule and EventSignal: the strings are malloc'ed copies and the patterns compiled again into the C regex_t,
// so that rule_destroy and event_signal_destroy free them as before. A pattern that does not compile has no VALID flag.
// The caller sets RULE_ONE_SHOT, which parse_rule keeps.
//

private func compile(_ regex: inout regex_t, _ pattern: UnsafeMutablePointer<CChar>?) -> Bool
{
    regcomp(&regex, pattern, REG_EXTENDED) == 0
}


extension RuleEffects
{
    init(_ effects: rule_effects)
    {
        self.init()
        did = effects.did
        sid = effects.sid
        opacity = effects.opacity
        manage = RuleProp(rawValue: effects.manage) ?? .undefined
        sticky = RuleProp(rawValue: effects.sticky) ?? .undefined
        mff = RuleProp(rawValue: effects.mff) ?? .undefined
        layer = windowLayer(effects.layer)
        fullscreen = RuleProp(rawValue: effects.fullscreen) ?? .undefined
        grid = Grid(effects.grid.0, effects.grid.1, effects.grid.2, effects.grid.3, effects.grid.4, effects.grid.5)
        scratchpad = effects.scratchpad.map { String(cString: $0) }
        flags = RuleEffectsFlags(rawValue: effects.flags)
    }

    /// Writes the effects into a C struct. Its scratchpad is replaced with a copy of this one.
    func write(to effects: inout rule_effects)
    {
        effects.did = did
        effects.sid = sid
        effects.opacity = opacity
        effects.manage = manage.rawValue
        effects.sticky = sticky.rawValue
        effects.mff = mff.rawValue
        effects.layer = layerValue(layer)
        effects.fullscreen = fullscreen.rawValue
        effects.grid = (grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height)
        effects.flags = flags.rawValue

        if let old = effects.scratchpad { free(old) }
        effects.scratchpad = mallocString(scratchpad)
    }
}

@_cdecl("rule_combine_effects")
func rule_combine_effects(_ effects: UnsafeMutablePointer<rule_effects>, _ result: UnsafeMutablePointer<rule_effects>)
{
    var combined = RuleEffects(result.pointee)
    combined.combine(RuleEffects(effects.pointee))
    combined.write(to: &result.pointee)
}

@_cdecl("parse_rule")
func parse_rule(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ result: UnsafeMutablePointer<rule>, _ first: token) -> Bool
{
    var parsed = Rule()

    var response = Response()
    var source = CMessage(cursor: message)
    let didParse = parseRule(&response, &source, &parsed, Token(first), CSelectorContext())
    response.write(to: rsp)

    var flags = result.pointee.flags
    let patterns: [(RulePattern?, rule_flag, rule_flag, WritableKeyPath<rule, UnsafeMutablePointer<CChar>?>, WritableKeyPath<rule, regex_t>)] = [
        (parsed.app,     RULE_APP_VALID,     RULE_APP_EXCLUDE,     \.app,     \.app_regex),
        (parsed.title,   RULE_TITLE_VALID,   RULE_TITLE_EXCLUDE,   \.title,   \.title_regex),
        (parsed.role,    RULE_ROLE_VALID,    RULE_ROLE_EXCLUDE,    \.role,    \.role_regex),
        (parsed.subrole, RULE_SUBROLE_VALID, RULE_SUBROLE_EXCLUDE, \.subrole, \.subrole_regex)
    ]

    for (pattern, valid, exclude, text, regex) in patterns {
        guard let pattern else { continue }

        if pattern.exclude { flags |= UInt16(exclude.rawValue) }
        result.pointee[keyPath: text] = mallocString(pattern.text)
        if compile(&result.pointee[keyPath: regex], result.pointee[keyPath: text]) { flags |= UInt16(valid.rawValue) }
    }

    result.pointee.flags = flags
    result.pointee.label = mallocString(parsed.label)
    parsed.effects.write(to: &result.pointee.effects)
    return didParse
}

@_cdecl("parse_signal")
func parse_signal(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ result: UnsafeMutablePointer<signal>, _ signalType: UnsafeMutablePointer<signal_type>) -> Bool
{
    var parsed = EventSignal()
    var event: signal_type?

    var response = Response()
    var source = CMessage(cursor: message)
    let didParse = parseSignal(&response, &source, &parsed, &event) { name in
        let type = name.withCString { signal_type_from_string($0) }
        return type == SIGNAL_TYPE_UNKNOWN ? nil : type
    }
    response.write(to: rsp)

    signalType.pointee = event ?? SIGNAL_TYPE_UNKNOWN

    if let app = parsed.app {
        result.pointee.app = mallocString(app.text)
        result.pointee.app_regex_exclude = app.exclude
        result.pointee.app_regex_valid = compile(&result.pointee.app_regex, result.pointee.app)
    }

    if let title = parsed.title {
        result.pointee.title = mallocString(title.text)
        result.pointee.title_regex_exclude = title.exclude
        result.pointee.title_regex_valid = compile(&result.pointee.title_regex, result.pointee.title)
    }

    result.pointee.active = parsed.active.rawValue
    result.pointee.command = mallocString(parsed.command)
    result.pointee.label = mallocString(parsed.label)
    return didParse
}
