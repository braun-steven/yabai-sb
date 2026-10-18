//
// NOTE: The values, labels, properties and selectors of the messages of the client, and the responses they fail with.
// The selectors find displays, spaces and windows through a SelectorContext, which the daemon implements over its
// managers. Ported from src/message_parse.c.
//

/// The common values of the arguments (`ARGUMENT_COMMON_*`).
public enum Argument
{
    public static let on          = "on"
    public static let off         = "off"
    public static let prev        = "prev"
    public static let next        = "next"
    public static let first       = "first"
    public static let last        = "last"
    public static let recent      = "recent"
    public static let north       = "north"
    public static let east        = "east"
    public static let south       = "south"
    public static let west        = "west"
    public static let parent      = "parent"
    public static let child       = "child"
    public static let mouse       = "mouse"
    public static let stack       = "stack"
    public static let stackPrefix = "stack."
    public static let largest     = "largest"
    public static let smallest    = "smallest"
    public static let recover     = "recover"
}

/// `bool_str` (src/misc/helpers.h)
public func boolString(_ value: Bool) -> String
{
    value ? Argument.on : Argument.off
}

//
// NOTE: config options print their current value when no value is given. These return true when
// the next token of the message is a valid new value, so the caller can apply it.
//

/// `parse_config_bool`
public func parseConfigBool(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ flag: inout Bool) -> Bool
{
    let value = message.next()
    if !value.isValid {
        rsp.write("\(boolString(flag))\n")
    } else if value.equals(Argument.off) {
        flag = false
        return true
    } else if value.equals(Argument.on) {
        flag = true
        return true
    } else {
        rsp.failUnknownValue(domain, command, value)
    }

    return false
}

//
// NOTE: A setting whose values are the String raw values of an enum. Without a value, the current one is printed;
// only the given choices are accepted (e.g. mouse_action1 takes move and resize, not swap).
//

/// `parse_config_choice`: the selected value, or nil when the current one was printed or the value is unknown.
public func parseConfigChoice<Choice: RawRepresentable<String>>(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ choices: [Choice], current: Choice) -> Choice?
{
    let value = message.next()
    if !value.isValid {
        rsp.write("\(current.rawValue)\n")
        return nil
    }

    if let choice = choices.first(where: { value.equals($0.rawValue) }) { return choice }

    rsp.failUnknownValue(domain, command, value)
    return nil
}

/// `parse_config_choice` among every case of the enum.
public func parseConfigChoice<Choice: RawRepresentable<String> & CaseIterable>(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, current: Choice) -> Choice?
{
    parseConfigChoice(&rsp, domain, command, &message, Array(Choice.allCases), current: current)
}

/// An argument of a rule or signal: `key=value`, or `key!=value` for an exclusion.
public struct KeyValue: Sendable
{
    public var key: Token
    public var value: Token
    public var exclusion: Bool
}

//
// NOTE: The key ends at the first "!=" or "=". Without either, or without a value after it, the argument is not a
// key-value pair. The key may be empty.
//

/// `parse_key_value_pair`
public func parseKeyValuePair(_ token: Token) -> KeyValue?
{
    let bytes = token.bytes
    var at = bytes.startIndex

    while at < bytes.endIndex {
        if bytes[at] == UInt8(ascii: "!") && at + 1 < bytes.endIndex && bytes[at + 1] == UInt8(ascii: "=") { break }
        if bytes[at] == UInt8(ascii: "=") { break }
        at += 1
    }

    guard at < bytes.endIndex else { return nil }

    let exclusion = bytes[at] == UInt8(ascii: "!")
    let valueStart = at + (exclusion ? 2 : 1)
    guard valueStart < bytes.endIndex else { return nil }

    return KeyValue(key: Token(bytes[bytes.startIndex..<at]), value: Token(bytes[valueStart...]), exclusion: exclusion)
}

/// The sub-layers of a window (`LAYER_*`, src/misc/macros.h), named as in `layer_str`.
public enum WindowLayer: String, CaseIterable, Sendable
{
    case auto
    case below
    case normal
    case above
}

/// `parse_layer`
public func parseLayer(_ value: Token) -> WindowLayer?
{
    WindowLayer.allCases.first { value.equals($0.rawValue) }
}

/// The types of a move or resize value, with the values of `TYPE_ABS` and `TYPE_REL` (src/misc/macros.h).
public enum ValueType: UInt8, Sendable
{
    case abs = 0x1
    case rel = 0x2
}

/// `parse_value_type`
public func parseValueType(_ type: Token) -> ValueType?
{
    if type.equals("abs") { return .abs }
    if type.equals("rel") { return .rel }
    return nil
}

/// The handles of a resize, with the values of `HANDLE_*` (src/misc/macros.h).
public struct ResizeHandle: OptionSet, Sendable
{
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let top    = ResizeHandle(rawValue: 0x01)
    public static let bottom = ResizeHandle(rawValue: 0x02)
    public static let left   = ResizeHandle(rawValue: 0x04)
    public static let right  = ResizeHandle(rawValue: 0x08)
    public static let abs    = ResizeHandle(rawValue: 0x10)
}

/// `parse_resize_handle`: empty for an unknown handle.
public func parseResizeHandle(_ handle: Token) -> ResizeHandle
{
    if handle.equals("top")          { return .top }
    if handle.equals("bottom")       { return .bottom }
    if handle.equals("left")         { return .left }
    if handle.equals("right")        { return .right }
    if handle.equals("top_left")     { return [.top, .left] }
    if handle.equals("top_right")    { return [.top, .right] }
    if handle.equals("bottom_left")  { return [.bottom, .left] }
    if handle.equals("bottom_right") { return [.bottom, .right] }
    if handle.equals("abs")          { return .abs }
    return []
}

/// The values of `window --toggle` that are window properties (`window_toggle_list` in src/message_window.c, which
/// keeps its functions in this order). Any other value is a scratchpad label.
public enum WindowToggle: String, CaseIterable, Sendable
{
    case float
    case sticky
    case shadow
    case split
    case zoomParent         = "zoom-parent"
    case zoomFullscreen     = "zoom-fullscreen"
    case windowedFullscreen = "windowed-fullscreen"
    case nativeFullscreen   = "native-fullscreen"
    case expose
    case pip

    /// `window_toggle_for_value`
    public init?(_ value: Token)
    {
        guard let toggle = WindowToggle.allCases.first(where: { value.equals($0.rawValue) }) else { return nil }
        self = toggle
    }
}

/// `enum label_type`: what a label names.
public enum LabelKind: Sendable
{
    case display
    case space
    case window

    /// `label_reserved`: the selector values that cannot be labels.
    public var reserved: [String]
    {
        switch self {
        case .display: [Argument.north, Argument.east, Argument.south, Argument.west, Argument.prev, Argument.next, Argument.first, Argument.last, Argument.recent, Argument.mouse]
        case .space:   [Argument.prev, Argument.next, Argument.first, Argument.last, Argument.recent, Argument.mouse]
        case .window:  WindowToggle.allCases.map(\.rawValue) + [Argument.recover]
        }
    }

    public var noun: String
    {
        self == .window ? "scratchpad" : "label"
    }

    /// `label_is_reserved`
    public func isReserved(_ token: Token) -> Bool
    {
        reserved.contains { token.equals($0) }
    }
}

/// `parse_label`: valid with a nil label when the token is missing (to remove a label).
public func parseLabel(_ rsp: inout Response, _ token: Token, _ kind: LabelKind) -> (valid: Bool, label: Token?)
{
    switch token.value {
    case .invalid:
        return (true, nil)
    case .string:
        if kind.isReserved(token) {
            rsp.fail("'\(token)' is a reserved keyword and cannot be used as a \(kind.noun).\n")
            return (false, nil)
        }
        return (true, token)
    default:
        rsp.fail("'\(token)' cannot be used as a label.\n")
        return (false, nil)
    }
}

/// `struct properties`: the properties a query selects, e.g. "id,frame".
public struct Properties: Sendable
{
    public var token: Token
    public var didParse: Bool
    public var didError = false
    public var flags: UInt64 = 0

    public init(token: Token, didParse: Bool)
    {
        self.token = token
        self.didParse = didParse
    }
}

//
// NOTE: The properties are separated by commas, but the last byte of the token always belongs to the last property,
// even when it is a comma.
//

/// `parse_properties`: names[i] selects values[i]. A token that starts with "--" is the next option, not properties.
public func parseProperties(_ rsp: inout Response, _ token: Token, names: [String], values: [UInt64]) -> Properties
{
    var result = Properties(token: token, didParse: token.isValid && !token.hasPrefix("--"))
    guard result.didParse else { return result }

    let bytes = token.bytes
    var cursor = bytes.startIndex

    for i in bytes.indices {
        let end: Int
        if i + 1 == bytes.endIndex {
            end = bytes.endIndex
        } else if bytes[i] == UInt8(ascii: ",") {
            end = i
        } else {
            continue
        }

        let property = Token(bytes[cursor..<end])
        if let index = names.firstIndex(where: { property.equals($0) }) {
            result.flags |= values[index]
        } else {
            rsp.fail("'\(property)' is not a valid property.\n")
            result.didError = true
        }

        cursor = end + 1
    }

    return result
}

/// `parse_direction`
public func parseDirection(_ token: Token) -> Direction?
{
    if token.equals(Argument.north) { return .north }
    if token.equals(Argument.east)  { return .east }
    if token.equals(Argument.south) { return .south }
    if token.equals(Argument.west)  { return .west }
    return nil
}

/// `direction_str`
public func directionDescription(_ direction: Direction) -> String
{
    switch direction {
    case .north: "a northward"
    case .east:  "an eastward"
    case .south: "a southward"
    case .west:  "a westward"
    }
}

/// The displays a display selector asks for. 0 is no display.
public enum DisplayQuery: Sendable
{
    case arrangement(Int32)
    case inDirection(Direction, from: DisplayID)
    case prev(DisplayID)
    case next(DisplayID)
    case first
    case last
    case recent
    case cursor
}

/// The spaces a space selector asks for. 0 is no space.
public enum SpaceQuery: Sendable
{
    case missionControl(Int32)
    case prev(SpaceID)
    case next(SpaceID)
    case first
    case last
    case recent
    case cursor
}

/// The windows a window selector asks for: managed windows, and the windows of the stack (tabbed container) of a window.
public enum WindowQuery<Window>
{
    case id(UInt32)
    case inDirection(Direction, from: Window)
    case belowCursor
    case largest
    case smallest
    case prev(Window)
    case next(Window)
    case first
    case last
    case recent
    case stackPrev(Window)
    case stackNext(Window)
    case stackFirst(Window)
    case stackLast(Window)
    case stackRecent(Window)
    case stackPosition(Window, Int32)
}

/// What the selectors look up: the daemon implements it over its managers, the tests with fixtures.
public protocol SelectorContext
{
    associatedtype Window

    /// `display_manager_active_display_id`
    var activeDisplay: DisplayID { get }
    /// `space_manager_active_space`
    var activeSpace: SpaceID { get }
    /// `window_manager_acting_window`
    var actingWindow: Window? { get }

    func display(_ query: DisplayQuery) -> DisplayID
    /// The id of a display label (`label_find_name` on the labels of the display manager).
    func displayLabel(_ label: Token) -> DisplayID?
    func space(_ query: SpaceQuery) -> SpaceID
    /// The id of a space label.
    func spaceLabel(_ label: Token) -> SpaceID?
    func window(_ query: WindowQuery<Window>) -> Window?
}

/// `struct selector`: didParse is false when the token is no valid selector. A valid selector may still find nothing
/// (0 or nil), and then the parser has reported why.
public struct Selection<Value>
{
    public var token: Token
    public var didParse: Bool
    public var value: Value
}

//
// NOTE: Reports that a selector found nothing, described by what, and passes the result through.
//

private func require(_ rsp: inout Response, _ id: DisplayID, _ what: String) -> DisplayID
{
    if id == 0 { rsp.fail("could not locate \(what).\n") }
    return id
}

private func require(_ rsp: inout Response, _ id: SpaceID, _ what: String) -> SpaceID
{
    if id == 0 { rsp.fail("could not locate \(what).\n") }
    return id
}

private func require<Window>(_ rsp: inout Response, _ window: Window?, _ what: String) -> Window?
{
    if window == nil { rsp.fail("could not locate \(what).\n") }
    return window
}

/// `parse_display_selector`
public func parseDisplaySelector<C: SelectorContext>(_ rsp: inout Response, _ token: Token, acting: DisplayID, optional: Bool, _ context: C) -> Selection<DisplayID>
{
    var result = Selection(token: token, didParse: true, value: DisplayID(0))

    switch token.value {
    case .int(let index):
        result.value = context.display(.arrangement(index))
        if result.value == 0 { rsp.fail("could not locate display with arrangement index '\(index)'.\n") }
    case .string:
        let direction = parseDirection(token)
        let relative = direction != nil || token.equals(Argument.prev) || token.equals(Argument.next)

        if relative && acting == 0 {
            rsp.fail("could not locate the selected display.\n")
        } else if let direction {
            result.value = require(&rsp, context.display(.inDirection(direction, from: acting)), "\(directionDescription(direction)) display")
        } else if token.equals(Argument.prev) {
            result.value = require(&rsp, context.display(.prev(acting)), "the previous display")
        } else if token.equals(Argument.next) {
            result.value = require(&rsp, context.display(.next(acting)), "the next display")
        } else if token.equals(Argument.first) {
            result.value = require(&rsp, context.display(.first), "the first display")
        } else if token.equals(Argument.last) {
            result.value = require(&rsp, context.display(.last), "the last display")
        } else if token.equals(Argument.recent) {
            result.value = context.display(.recent)
        } else if token.equals(Argument.mouse) {
            result.value = require(&rsp, context.display(.cursor), "display containing cursor")
        } else if let id = context.displayLabel(token) {
            result.value = id
        } else {
            result.didParse = false
            rsp.fail("value '\(token)' is not a valid option for DISPLAY_SEL\n")
        }
    default:
        result.didParse = false
        if token.isValid || !optional {
            rsp.fail("value '\(token)' is not a valid option for DISPLAY_SEL\n")
        }
    }

    return result
}

/// `parse_space_selector`
public func parseSpaceSelector<C: SelectorContext>(_ rsp: inout Response, _ token: Token, acting: SpaceID, optional: Bool, _ context: C) -> Selection<SpaceID>
{
    var result = Selection(token: token, didParse: true, value: SpaceID(0))

    switch token.value {
    case .int(let index):
        result.value = context.space(.missionControl(index))
        if result.value == 0 { rsp.fail("could not locate space with mission-control index '\(index)'.\n") }
    case .string:
        let relative = token.equals(Argument.prev) || token.equals(Argument.next)

        if relative && acting == 0 {
            rsp.fail("could not locate the selected space.\n")
        } else if token.equals(Argument.prev) {
            result.value = require(&rsp, context.space(.prev(acting)), "the previous space")
        } else if token.equals(Argument.next) {
            result.value = require(&rsp, context.space(.next(acting)), "the next space")
        } else if token.equals(Argument.first) {
            result.value = require(&rsp, context.space(.first), "the first space")
        } else if token.equals(Argument.last) {
            result.value = require(&rsp, context.space(.last), "the last space")
        } else if token.equals(Argument.recent) {
            result.value = context.space(.recent)
        } else if token.equals(Argument.mouse) {
            result.value = require(&rsp, context.space(.cursor), "space containing cursor")
        } else if let id = context.spaceLabel(token) {
            result.value = id
        } else {
            result.didParse = false
            rsp.fail("value '\(token)' is not a valid option for SPACE_SEL\n")
        }
    default:
        result.didParse = false
        if token.isValid || !optional {
            rsp.fail("value '\(token)' is not a valid option for SPACE_SEL\n")
        }
    }

    return result
}

/// `parse_stack_window_selector`: token is the part after "stack.".
private func parseStackWindowSelector<C: SelectorContext>(_ rsp: inout Response, _ token: Token, _ acting: C.Window, _ didParse: inout Bool, _ context: C) -> C.Window?
{
    if token.equals(Argument.prev)   { return require(&rsp, context.window(.stackPrev(acting)), "the prev stacked window") }
    if token.equals(Argument.next)   { return require(&rsp, context.window(.stackNext(acting)), "the next stacked window") }
    if token.equals(Argument.first)  { return require(&rsp, context.window(.stackFirst(acting)), "the first stacked window") }
    if token.equals(Argument.last)   { return require(&rsp, context.window(.stackLast(acting)), "the last stacked window") }
    if token.equals(Argument.recent) { return require(&rsp, context.window(.stackRecent(acting)), "the recent stacked window") }

    if token.isValid, let index = token.positiveInteger, index > 0 {
        let window = context.window(.stackPosition(acting, index))
        if window == nil { rsp.fail("could not locate the stacked window in position \(index).\n") }
        return window
    }

    didParse = false
    rsp.fail("value '\(Argument.stackPrefix)\(token)' is not a valid option for WINDOW_SEL\n")
    return nil
}

//
// NOTE: The relative selectors (directions, stack, prev and next) fail when there is no acting window, so the branches
// after the first one always have one when they need it.
//

/// `parse_window_selector`
public func parseWindowSelector<C: SelectorContext>(_ rsp: inout Response, _ token: Token, acting: C.Window?, optional: Bool, _ context: C) -> Selection<C.Window?>
{
    var result = Selection<C.Window?>(token: token, didParse: true, value: nil)

    switch token.value {
    case .int(let id):
        result.value = context.window(.id(UInt32(bitPattern: id)))
        if result.value == nil { rsp.fail("could not locate window with the specified id '\(id)'.\n") }
    case .string:
        let direction = parseDirection(token)
        let stack = token.hasPrefix(Argument.stackPrefix)
        let relative = direction != nil || stack || token.equals(Argument.prev) || token.equals(Argument.next)

        if relative && acting == nil {
            rsp.fail("could not locate the selected window.\n")
        } else if let direction, let acting {
            result.value = require(&rsp, context.window(.inDirection(direction, from: acting)), "\(directionDescription(direction)) managed window")
        } else if token.equals(Argument.mouse) {
            result.value = require(&rsp, context.window(.belowCursor), "a window below the cursor")
        } else if token.equals(Argument.largest) {
            result.value = require(&rsp, context.window(.largest), "window with the largest area")
        } else if token.equals(Argument.smallest) {
            result.value = require(&rsp, context.window(.smallest), "window with the smallest area")
        } else if token.equals(Argument.prev), let acting {
            result.value = require(&rsp, context.window(.prev(acting)), "the prev managed window")
        } else if token.equals(Argument.next), let acting {
            result.value = require(&rsp, context.window(.next(acting)), "the next managed window")
        } else if token.equals(Argument.first) {
            result.value = require(&rsp, context.window(.first), "the first managed window")
        } else if token.equals(Argument.last) {
            result.value = require(&rsp, context.window(.last), "the last managed window")
        } else if token.equals(Argument.recent) {
            result.value = require(&rsp, context.window(.recent), "the most recently focused window")
        } else if stack, let acting {
            result.value = parseStackWindowSelector(&rsp, token.dropFirst(Argument.stackPrefix.utf8.count), acting, &result.didParse, context)
        } else {
            result.didParse = false
            rsp.fail("value '\(token)' is not a valid option for WINDOW_SEL\n")
        }
    default:
        result.didParse = false
        if token.isValid || !optional {
            rsp.fail("value '\(token)' is not a valid option for WINDOW_SEL\n")
        }
    }

    return result
}

//
// NOTE: An optional selector replaces the acting display, space or window when one is given. These
// return false when the given selector does not select anything (the parser has reported why).
//

/// `parse_optional_display_selector`
public func parseOptionalDisplaySelector<C: SelectorContext>(_ rsp: inout Response, _ message: inout some TokenSource, _ did: inout DisplayID, _ context: C) -> Bool
{
    let selector = parseDisplaySelector(&rsp, message.next(), acting: did, optional: true, context)
    if !selector.token.isValid { return true }
    if !selector.didParse || selector.value == 0 { return false }

    did = selector.value
    return true
}

/// `parse_optional_space_selector`
public func parseOptionalSpaceSelector<C: SelectorContext>(_ rsp: inout Response, _ message: inout some TokenSource, _ sid: inout SpaceID, _ context: C) -> Bool
{
    let selector = parseSpaceSelector(&rsp, message.next(), acting: sid, optional: true, context)
    if !selector.token.isValid { return true }
    if !selector.didParse || selector.value == 0 { return false }

    sid = selector.value
    return true
}

/// `parse_optional_window_selector`
public func parseOptionalWindowSelector<C: SelectorContext>(_ rsp: inout Response, _ message: inout some TokenSource, _ window: inout C.Window?, _ context: C) -> Bool
{
    let selector = parseWindowSelector(&rsp, message.next(), acting: window, optional: true, context)
    if !selector.token.isValid { return true }
    guard selector.didParse, let selected = selector.value else { return false }

    window = selected
    return true
}

/// Where `window --insert` or a mouse drop puts a window: on one side of the target, or into its tabbed container.
public enum InsertDirection: Int32, Sendable
{
    case north = 360
    case east  = 90
    case south = 180
    case west  = 270
    case stack = 111

    public init(_ direction: Direction)
    {
        self.init(rawValue: direction.rawValue)!
    }

    /// The side, nil for stack.
    public var direction: Direction? { Direction(rawValue: rawValue) }
}

/// `parse_insert_selector`
public func parseInsertSelector(_ rsp: inout Response, _ token: Token) -> Selection<InsertDirection?>
{
    var result = Selection<InsertDirection?>(token: token, didParse: true, value: nil)

    if let direction = parseDirection(token) {
        result.value = InsertDirection(direction)
    } else if token.equals(Argument.stack) {
        result.value = .stack
    } else {
        result.didParse = false
        rsp.fail("value '\(token)' is not a valid option for DIR_SEL\n")
    }

    return result
}

/// What `window --focus` focuses in a tree: a container in a direction, the parent or a child.
public enum TreeFocus: Equatable, Sendable
{
    case direction(Direction)
    case parent
    case child
}

/// `peek_tree_direction`: the caller peeks at the token, which this does not consume.
public func parseTreeFocus(_ token: Token) -> TreeFocus?
{
    if let direction = parseDirection(token) { return .direction(direction) }
    if token.equals(Argument.parent) { return .parent }
    if token.equals(Argument.child)  { return .child }
    return nil
}

/// `struct query_target`: what a query covers.
public enum QueryTarget<Window>
{
    case all
    case display(DisplayID)
    case space(SpaceID)
    case window(Window?)
}

//
// NOTE: The optional '--display|--space|--window [SEL]' of a query, which defaults to the active one.
// Without the option a query covers everything. Returns nil when the option or its selector is invalid.
//

/// `parse_query_target` (src/message.c)
public func parseQueryTarget<C: SelectorContext>(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ properties: Properties, _ context: C) -> QueryTarget<C.Window>?
{
    let option = properties.didParse ? message.next() : properties.token

    if option.equals("--display") {
        var did = context.activeDisplay
        return parseOptionalDisplaySelector(&rsp, &message, &did, context) ? .display(did) : nil
    }

    if option.equals("--space") {
        var sid = context.activeSpace
        return parseOptionalSpaceSelector(&rsp, &message, &sid, context) ? .space(sid) : nil
    }

    if option.equals("--window") {
        var window = context.actingWindow
        return parseOptionalWindowSelector(&rsp, &message, &window, context) ? .window(window) : nil
    }

    if option.isValid {
        rsp.failUnknownOption(domain, command, option)
        return nil
    }

    return .all
}
