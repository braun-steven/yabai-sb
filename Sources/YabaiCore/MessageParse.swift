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
// NOTE: config options print their current value when no value is given, so these parse a valid value token; any
// other value throws an unknown-value failure.
//

/// `on` or `off`.
public func parseConfigBool(_ domain: Token, _ command: Token, _ value: Token) throws(CommandError) -> Bool
{
    if value.equals(Argument.on) { return true }
    if value.equals(Argument.off) { return false }
    throw CommandError.unknownValue(domain, command, value)
}

//
// NOTE: A setting whose values are the String raw values of an enum; only the given choices are accepted (e.g.
// mouse_action1 takes move and resize, not swap).
//

/// One of the choices, by its raw value.
public func parseConfigChoice<Choice: RawRepresentable<String>>(_ domain: Token, _ command: Token, _ value: Token, _ choices: [Choice]) throws(CommandError) -> Choice
{
    if let choice = choices.first(where: { value.equals($0.rawValue) }) { return choice }
    throw CommandError.unknownValue(domain, command, value)
}

/// One of every case of the enum, by its raw value.
public func parseConfigChoice<Choice: RawRepresentable<String> & CaseIterable>(_ domain: Token, _ command: Token, _ value: Token) throws(CommandError) -> Choice
{
    try parseConfigChoice(domain, command, value, Array(Choice.allCases))
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
public struct Properties<Key: Hashable & Sendable>: Sendable
{
    public var token: Token
    public var didParse: Bool
    /// The selected keys; every key when the token selects none.
    public var selection: Set<Key> = []

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

/// `parse_properties`: the keys named by a comma-separated token, by their raw values; every key when it names none. A
/// token that starts with "--" is the next option, not properties. Every invalid property is reported in one failure.
public func parseProperties<Key: CaseIterable & RawRepresentable<String> & Hashable & Sendable>(_ token: Token, as _: Key.Type) throws(CommandError) -> Properties<Key>
{
    var result = Properties<Key>(token: token, didParse: token.isValid && !token.hasPrefix("--"))
    guard result.didParse else {
        result.selection = Set(Key.allCases)
        return result
    }

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
        if let key = Key.allCases.first(where: { property.equals($0.rawValue) }) {
            result.selection.insert(key)
        } else {
            failures.append(CommandError("'\(property)' is not a valid property.\n"))
        }

        cursor = end + 1
    }

    if !failures.isEmpty { throw CommandError(combining: failures) }
    if result.selection.isEmpty { result.selection = Set(Key.allCases) }
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

    /// nil when the token is no direction, parent or child.
    public init?(_ token: Token)
    {
        if let direction = parseDirection(token) { self = .direction(direction) }
        else if token.equals(Argument.parent)   { self = .parent }
        else if token.equals(Argument.child)    { self = .child }
        else                                    { return nil }
    }
}
