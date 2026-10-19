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
// NOTE: config options print their current value to the response when no value is given. These return true when
// the next token of the message is a valid new value, so the caller can apply it, and throw when it is an invalid one.
//

/// `parse_config_bool`
public func parseConfigBool(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ flag: inout Bool) throws(CommandError) -> Bool
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
        throw CommandError.unknownValue(domain, command, value)
    }

    return false
}

//
// NOTE: A setting whose values are the String raw values of an enum. Without a value, the current one is printed;
// only the given choices are accepted (e.g. mouse_action1 takes move and resize, not swap).
//

/// `parse_config_choice`: the selected value, or nil when the current one was printed. Throws for an unknown value.
public func parseConfigChoice<Choice: RawRepresentable<String>>(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ choices: [Choice], current: Choice) throws(CommandError) -> Choice?
{
    let value = message.next()
    if !value.isValid {
        rsp.write("\(current.rawValue)\n")
        return nil
    }

    if let choice = choices.first(where: { value.equals($0.rawValue) }) { return choice }

    throw CommandError.unknownValue(domain, command, value)
}

/// `parse_config_choice` among every case of the enum.
public func parseConfigChoice<Choice: RawRepresentable<String> & CaseIterable>(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, current: Choice) throws(CommandError) -> Choice?
{
    try parseConfigChoice(&rsp, domain, command, &message, Array(Choice.allCases), current: current)
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

/// `parse_label`: nil when the token is missing (to remove a label), the token when it is a valid label, and throws
/// the failure of an invalid one.
public func parseLabel(_ token: Token, _ kind: LabelKind) throws(CommandError) -> Token?
{
    switch token.value {
    case .invalid:
        return nil
    case .string:
        if kind.isReserved(token) {
            throw CommandError("'\(token)' is a reserved keyword and cannot be used as a \(kind.noun).\n")
        }
        return token
    default:
        throw CommandError("'\(token)' cannot be used as a label.\n")
    }
}

/// `struct properties`: the properties a query selects, e.g. "id,frame".
public struct Properties: Sendable
{
    public var token: Token
    public var didParse: Bool
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
/// Every invalid property is reported in one failure.
public func parseProperties(_ token: Token, names: [String], values: [UInt64]) throws(CommandError) -> Properties
{
    var result = Properties(token: token, didParse: token.isValid && !token.hasPrefix("--"))
    guard result.didParse else { return result }

    var failures: [CommandError] = []
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
            failures.append(CommandError("'\(property)' is not a valid property.\n"))
        }

        cursor = end + 1
    }

    if !failures.isEmpty { throw CommandError(combining: failures) }
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

/// The displays a display selector asks for.
public enum DisplayQuery: Sendable
{
    case arrangement(Int)
    case inDirection(Direction, from: DisplayID)
    case prev(DisplayID)
    case next(DisplayID)
    case first
    case last
    case recent
    case cursor
}

/// The spaces a space selector asks for.
public enum SpaceQuery: Sendable
{
    case missionControl(Int)
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
    case id(WindowID)
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
    case stackPosition(Window, Int)
}

/// What the selectors look up: the daemon implements it over its managers, the tests with fixtures.
public protocol SelectorContext
{
    associatedtype Window

    var activeDisplay: DisplayID? { get }
    var activeSpace: SpaceID? { get }
    /// The window that commands act on, including a pending focus request.
    var actingWindow: Window? { get }

    func display(_ query: DisplayQuery) -> DisplayID?
    /// The id of a display label (`label_find_name` on the labels of the display manager).
    func displayLabel(_ label: Token) -> DisplayID?
    func space(_ query: SpaceQuery) -> SpaceID?
    /// The id of a space label.
    func spaceLabel(_ label: Token) -> SpaceID?
    func window(_ query: WindowQuery<Window>) -> Window?
}

/// `struct selector`: didParse is false when the token is no valid selector. A valid selector may still find nothing
/// (nil); then `failure` says why, except for 'recent'.
public struct Selection<Value>
{
    public var token: Token
    public var didParse: Bool
    public var value: Value
    /// Why the selector failed: an invalid token, or a valid one that found nothing. nil for a selector that found its value, an omitted optional one, or one that may find nothing (recent).
    public var failure: CommandError? = nil

    /// The selection, or its failure thrown.
    public func checked() throws(CommandError) -> Selection
    {
        if let failure { throw failure }
        return self
    }
}

//
// NOTE: Records that a selector found nothing, described by what, as its failure, and passes the result through.
//

private func require<Value>(_ value: Value?, _ what: String, _ failure: inout CommandError?) -> Value?
{
    if value == nil { failure = CommandError("could not locate \(what).\n") }
    return value
}

/// `parse_display_selector`
public func parseDisplaySelector<C: SelectorContext>(_ token: Token, acting: DisplayID?, optional: Bool, _ context: C) -> Selection<DisplayID?>
{
    var result = Selection<DisplayID?>(token: token, didParse: true, value: nil)

    switch token.value {
    case .int(let index):
        result.value = context.display(.arrangement(index))
        if result.value == nil { result.failure = CommandError("could not locate display with arrangement index '\(index)'.\n") }
    case .string:
        let direction = parseDirection(token)
        let relative = direction != nil || token.equals(Argument.prev) || token.equals(Argument.next)

        if relative && acting == nil {
            result.failure = CommandError("could not locate the selected display.\n")
        } else if let direction, let acting {
            result.value = require(context.display(.inDirection(direction, from: acting)), "\(directionDescription(direction)) display", &result.failure)
        } else if token.equals(Argument.prev), let acting {
            result.value = require(context.display(.prev(acting)), "the previous display", &result.failure)
        } else if token.equals(Argument.next), let acting {
            result.value = require(context.display(.next(acting)), "the next display", &result.failure)
        } else if token.equals(Argument.first) {
            result.value = require(context.display(.first), "the first display", &result.failure)
        } else if token.equals(Argument.last) {
            result.value = require(context.display(.last), "the last display", &result.failure)
        } else if token.equals(Argument.recent) {
            result.value = context.display(.recent)
        } else if token.equals(Argument.mouse) {
            result.value = require(context.display(.cursor), "display containing cursor", &result.failure)
        } else if let id = context.displayLabel(token) {
            result.value = id
        } else {
            result.didParse = false
            result.failure = CommandError("value '\(token)' is not a valid option for DISPLAY_SEL\n")
        }
    default:
        result.didParse = false
        if token.isValid || !optional {
            result.failure = CommandError("value '\(token)' is not a valid option for DISPLAY_SEL\n")
        }
    }

    return result
}

/// `parse_space_selector`
public func parseSpaceSelector<C: SelectorContext>(_ token: Token, acting: SpaceID?, optional: Bool, _ context: C) -> Selection<SpaceID?>
{
    var result = Selection<SpaceID?>(token: token, didParse: true, value: nil)

    switch token.value {
    case .int(let index):
        result.value = context.space(.missionControl(index))
        if result.value == nil { result.failure = CommandError("could not locate space with mission-control index '\(index)'.\n") }
    case .string:
        let relative = token.equals(Argument.prev) || token.equals(Argument.next)

        if relative && acting == nil {
            result.failure = CommandError("could not locate the selected space.\n")
        } else if token.equals(Argument.prev), let acting {
            result.value = require(context.space(.prev(acting)), "the previous space", &result.failure)
        } else if token.equals(Argument.next), let acting {
            result.value = require(context.space(.next(acting)), "the next space", &result.failure)
        } else if token.equals(Argument.first) {
            result.value = require(context.space(.first), "the first space", &result.failure)
        } else if token.equals(Argument.last) {
            result.value = require(context.space(.last), "the last space", &result.failure)
        } else if token.equals(Argument.recent) {
            result.value = context.space(.recent)
        } else if token.equals(Argument.mouse) {
            result.value = require(context.space(.cursor), "space containing cursor", &result.failure)
        } else if let id = context.spaceLabel(token) {
            result.value = id
        } else {
            result.didParse = false
            result.failure = CommandError("value '\(token)' is not a valid option for SPACE_SEL\n")
        }
    default:
        result.didParse = false
        if token.isValid || !optional {
            result.failure = CommandError("value '\(token)' is not a valid option for SPACE_SEL\n")
        }
    }

    return result
}

/// `parse_stack_window_selector`: token is the part after "stack.".
private func parseStackWindowSelector<C: SelectorContext>(_ token: Token, _ acting: C.Window, _ didParse: inout Bool, _ failure: inout CommandError?, _ context: C) -> C.Window?
{
    if token.equals(Argument.prev)   { return require(context.window(.stackPrev(acting)), "the prev stacked window", &failure) }
    if token.equals(Argument.next)   { return require(context.window(.stackNext(acting)), "the next stacked window", &failure) }
    if token.equals(Argument.first)  { return require(context.window(.stackFirst(acting)), "the first stacked window", &failure) }
    if token.equals(Argument.last)   { return require(context.window(.stackLast(acting)), "the last stacked window", &failure) }
    if token.equals(Argument.recent) { return require(context.window(.stackRecent(acting)), "the recent stacked window", &failure) }

    if token.isValid, let index = token.positiveInteger, index > 0 {
        let window = context.window(.stackPosition(acting, index))
        if window == nil { failure = CommandError("could not locate the stacked window in position \(index).\n") }
        return window
    }

    didParse = false
    failure = CommandError("value '\(Argument.stackPrefix)\(token)' is not a valid option for WINDOW_SEL\n")
    return nil
}

//
// NOTE: The relative selectors (directions, stack, prev and next) fail when there is no acting window, so the branches
// after the first one always have one when they need it.
//

/// `parse_window_selector`
public func parseWindowSelector<C: SelectorContext>(_ token: Token, acting: C.Window?, optional: Bool, _ context: C) -> Selection<C.Window?>
{
    var result = Selection<C.Window?>(token: token, didParse: true, value: nil)

    switch token.value {
    case .int(let id):
        result.value = context.window(.id(WindowID(UInt32(truncatingIfNeeded: id))))
        if result.value == nil { result.failure = CommandError("could not locate window with the specified id '\(id)'.\n") }
    case .string:
        let direction = parseDirection(token)
        let stack = token.hasPrefix(Argument.stackPrefix)
        let relative = direction != nil || stack || token.equals(Argument.prev) || token.equals(Argument.next)

        if relative && acting == nil {
            result.failure = CommandError("could not locate the selected window.\n")
        } else if let direction, let acting {
            result.value = require(context.window(.inDirection(direction, from: acting)), "\(directionDescription(direction)) managed window", &result.failure)
        } else if token.equals(Argument.mouse) {
            result.value = require(context.window(.belowCursor), "a window below the cursor", &result.failure)
        } else if token.equals(Argument.largest) {
            result.value = require(context.window(.largest), "window with the largest area", &result.failure)
        } else if token.equals(Argument.smallest) {
            result.value = require(context.window(.smallest), "window with the smallest area", &result.failure)
        } else if token.equals(Argument.prev), let acting {
            result.value = require(context.window(.prev(acting)), "the prev managed window", &result.failure)
        } else if token.equals(Argument.next), let acting {
            result.value = require(context.window(.next(acting)), "the next managed window", &result.failure)
        } else if token.equals(Argument.first) {
            result.value = require(context.window(.first), "the first managed window", &result.failure)
        } else if token.equals(Argument.last) {
            result.value = require(context.window(.last), "the last managed window", &result.failure)
        } else if token.equals(Argument.recent) {
            result.value = require(context.window(.recent), "the most recently focused window", &result.failure)
        } else if stack, let acting {
            result.value = parseStackWindowSelector(token.dropFirst(Argument.stackPrefix.utf8.count), acting, &result.didParse, &result.failure, context)
        } else {
            result.didParse = false
            result.failure = CommandError("value '\(token)' is not a valid option for WINDOW_SEL\n")
        }
    default:
        result.didParse = false
        if token.isValid || !optional {
            result.failure = CommandError("value '\(token)' is not a valid option for WINDOW_SEL\n")
        }
    }

    return result
}

//
// NOTE: An optional selector replaces the acting display, space or window when one is given. These throw the failure
// of the given selector when it is invalid. They return false, without a failure, when a valid selector found nothing
// ('recent'); the rest of the message is then skipped silently.
//

/// `parse_optional_display_selector`
public func parseOptionalDisplaySelector<C: SelectorContext>(_ message: inout some TokenSource, _ did: inout DisplayID?, _ context: C) throws(CommandError) -> Bool
{
    let selector = try parseDisplaySelector(message.next(), acting: did, optional: true, context).checked()
    if !selector.token.isValid { return true }
    guard selector.didParse, let selected = selector.value else { return false }

    did = selected
    return true
}

/// `parse_optional_space_selector`
public func parseOptionalSpaceSelector<C: SelectorContext>(_ message: inout some TokenSource, _ sid: inout SpaceID?, _ context: C) throws(CommandError) -> Bool
{
    let selector = try parseSpaceSelector(message.next(), acting: sid, optional: true, context).checked()
    if !selector.token.isValid { return true }
    guard selector.didParse, let selected = selector.value else { return false }

    sid = selected
    return true
}

/// `parse_optional_window_selector`
public func parseOptionalWindowSelector<C: SelectorContext>(_ message: inout some TokenSource, _ window: inout C.Window?, _ context: C) throws(CommandError) -> Bool
{
    let selector = try parseWindowSelector(message.next(), acting: window, optional: true, context).checked()
    if !selector.token.isValid { return true }
    guard selector.didParse, let selected = selector.value else { return false }

    window = selected
    return true
}

/// Where `window --insert` or a mouse drop puts a window: on one side of the target, or into its tabbed container.
public enum InsertDirection: Int, Sendable
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

/// `parse_insert_selector`: throws when the token is neither a direction nor stack.
public func parseInsertSelector(_ token: Token) throws(CommandError) -> InsertDirection
{
    if let direction = parseDirection(token) { return InsertDirection(direction) }
    if token.equals(Argument.stack) { return .stack }

    throw CommandError("value '\(token)' is not a valid option for DIR_SEL\n")
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
// Without the option a query covers everything. Throws when the option or its selector is invalid, and returns nil
// without a failure when the selector found nothing ('recent'), so the query is skipped silently.
//

/// `parse_query_target` (src/message.c)
public func parseQueryTarget<C: SelectorContext>(_ domain: Token, _ command: Token, _ message: inout some TokenSource, _ properties: Properties, _ context: C) throws(CommandError) -> QueryTarget<C.Window>?
{
    let option = properties.didParse ? message.next() : properties.token

    if option.equals("--display") {
        var did = context.activeDisplay
        guard try parseOptionalDisplaySelector(&message, &did, context) else { return nil }
        guard let did else { throw CommandError("could not locate the selected display.\n") }
        return .display(did)
    }

    if option.equals("--space") {
        var sid = context.activeSpace
        guard try parseOptionalSpaceSelector(&message, &sid, context) else { return nil }
        guard let sid else { throw CommandError("could not locate the selected space.\n") }
        return .space(sid)
    }

    if option.equals("--window") {
        var window = context.actingWindow
        return try parseOptionalWindowSelector(&message, &window, context) ? .window(window) : nil
    }

    if option.isValid {
        throw CommandError.unknownOption(domain, command, option)
    }

    return .all
}
