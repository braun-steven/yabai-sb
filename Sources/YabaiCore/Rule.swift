import CoreGraphics
import Darwin

//
// NOTE: The rules and signals of the messages of the client: their key-value arguments, and how the effects of the
// rules that match a window combine. Ported from parse_rule and parse_signal (src/message.c) and src/rule.c.
//

/// A POSIX extended regular expression (`regcomp` with `REG_EXTENDED`), freed with the last reference.
public final class POSIXRegex
{
    public let pointer: UnsafeMutablePointer<regex_t>

    public init?(_ pattern: String)
    {
        let regex = UnsafeMutablePointer<regex_t>.allocate(capacity: 1)
        guard regcomp(regex, pattern, REG_EXTENDED) == 0 else {
            regex.deallocate()
            return nil
        }

        pointer = regex
    }

    deinit
    {
        regfree(pointer)
        pointer.deallocate()
    }
}

/// The pattern of a rule or signal filter (`app`, `title`, `role`, `subrole`). regex is nil when the pattern is invalid.
public struct RulePattern
{
    public var text: String
    public var exclude: Bool
    public var regex: POSIXRegex?

    public init(_ value: Token, exclude: Bool)
    {
        self.text = value.string
        self.exclude = exclude
        self.regex = POSIXRegex(text)
    }

    /// Whether text passes the filter: it matches the pattern, or does not match an excluding one. An invalid pattern
    /// filters nothing.
    public func admits(_ text: String) -> Bool
    {
        guard let regex else { return true }
        return (regexec(regex.pointer, text, 0, nil, 0) == 0) != exclude
    }
}

/// Which optional effects a rule sets.
public struct RuleEffectsFlags: OptionSet, Sendable
{
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let followSpace = RuleEffectsFlags(rawValue: 0x01)
    public static let opacity     = RuleEffectsFlags(rawValue: 0x02)
    public static let layer       = RuleEffectsFlags(rawValue: 0x04)
}

/// A grid placement "rows:columns:x:y:width:height" (`unsigned grid[6]`). All 0 is no placement. The `%d` parser
/// accepts negative values and preserves their 32-bit bit pattern (so `-1` becomes `UInt32.max`), matching the grid
/// math's existing unsigned wrap behavior.
public struct Grid: Equatable, Sendable
{
    public var rows: UInt32 = 0
    public var columns: UInt32 = 0
    public var x: UInt32 = 0
    public var y: UInt32 = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0

    public init() {}

    public init(_ rows: UInt32, _ columns: UInt32, _ x: UInt32, _ y: UInt32, _ width: UInt32, _ height: UInt32)
    {
        (self.rows, self.columns, self.x, self.y, self.width, self.height) = (rows, columns, x, y, width, height)
    }

    //
    // NOTE: Keep `%d` and the UInt32 fields: negative input is accepted and its 32-bit bit pattern is used by the
    // grid math. Like sscanf, values assigned before a mismatch remain updated.
    //

    /// Scans six colon-separated `%d` values, preserving negative inputs as their UInt32 bit patterns; returns the
    /// number of values read. Values assigned before a mismatch remain updated.
    public mutating func scan(_ value: Token) -> Int
    {
        var values = [rows, columns, x, y, width, height]
        let count = values.withUnsafeMutableBufferPointer { v in
            value.scan("%d:%d:%d:%d:%d:%d", v.baseAddress!, v.baseAddress! + 1, v.baseAddress! + 2, v.baseAddress! + 3, v.baseAddress! + 4, v.baseAddress! + 5)
        }

        (rows, columns, x, y, width, height) = (values[0], values[1], values[2], values[3], values[4], values[5])
        return count
    }
}

extension Grid
{
    //
    // NOTE: The cell is clamped into the grid: x and y to the last column and row, width and height to at least one
    // cell and at most the rest of the grid. The arithmetic wraps like the unsigned C math, so a grid of 0 rows or
    // columns gives a frame that is not finite instead of trapping. The gap separates the cell from the neighboring
    // cells, not from the edges of bounds.
    //

    /// The frame of the cell in bounds, inside padding (top, bottom, left, right) and the gap; nil leaves either out.
    public func frame(in bounds: CGRect, padding: (top: Int, bottom: Int, left: Int, right: Int)?, gap: Int?) -> Area
    {
        var x = self.x, y = self.y, width = self.width, height = self.height
        if x >= columns { x = columns &- 1 }
        if y >= rows { y = rows &- 1 }
        if width <= 0 { width = 1 }
        if height <= 0 { height = 1 }
        if width > columns &- x { width = columns &- x }
        if height > rows &- y { height = rows &- y }

        var bounds = bounds

        if let padding {
            bounds.origin.x    += CGFloat(padding.left)
            bounds.size.width  -= CGFloat(padding.left + padding.right)
            bounds.origin.y    += CGFloat(padding.top)
            bounds.size.height -= CGFloat(padding.top + padding.bottom)
        }

        if let gap {
            let gap = CGFloat(gap)

            if x > 0 {
                bounds.origin.x   += gap
                bounds.size.width -= gap
            }

            if y > 0 {
                bounds.origin.y    += gap
                bounds.size.height -= gap
            }

            if columns > x &+ width { bounds.size.width  -= gap }
            if rows > y &+ height { bounds.size.height -= gap }
        }

        let cellWidth = Float(bounds.size.width / CGFloat(columns))
        let cellHeight = Float(bounds.size.height / CGFloat(rows))
        return Area(x: Float(bounds.origin.x + bounds.size.width - CGFloat(cellWidth * Float(columns &- x))),
                    y: Float(bounds.origin.y + bounds.size.height - CGFloat(cellHeight * Float(rows &- y))),
                    w: cellWidth * Float(width),
                    h: cellHeight * Float(height))
    }
}

/// The effects of a rule on the windows it matches. manage, sticky, mouseFollowsFocus and fullscreen are nil when the
/// rule leaves them alone.
public struct RuleEffects: Sendable
{
    public var did: DisplayID?
    public var sid: SpaceID?
    public var opacity: Float = 0
    public var manage: Bool?
    public var sticky: Bool?
    public var mouseFollowsFocus: Bool?
    public var layer = WindowLayer.auto
    public var fullscreen: Bool?
    public var grid = Grid()
    public var scratchpad: String?
    public var flags: RuleEffectsFlags = []

    public init() {}

    /// `rule_combine_effects`: applies the effects of a later rule that matches the same window to self.
    public mutating func combine(_ effects: RuleEffects)
    {
        if let did = effects.did { self.did = did }
        if let sid = effects.sid { self.sid = sid }

        if effects.did != nil || effects.sid != nil {
            if effects.flags.contains(.followSpace) {
                flags.insert(.followSpace)
            } else {
                flags.remove(.followSpace)
            }
        }

        if effects.flags.contains(.opacity) && effects.opacity >= 0 && effects.opacity <= 1 {
            opacity = effects.opacity
            flags.insert(.opacity)
        }

        if effects.flags.contains(.layer) {
            layer = effects.layer
            flags.insert(.layer)
        }

        if let scratchpad = effects.scratchpad {
            self.scratchpad = scratchpad
        }

        if let manage = effects.manage                       { self.manage = manage }
        if let sticky = effects.sticky                       { self.sticky = sticky }
        if let mouseFollowsFocus = effects.mouseFollowsFocus { self.mouseFollowsFocus = mouseFollowsFocus }
        if let fullscreen = effects.fullscreen               { self.fullscreen = fullscreen }

        if effects.grid.rows != 0 && effects.grid.columns != 0 {
            grid = effects.grid
        }
    }
}

/// A rule: its filters and effects. A one-shot rule applies only to windows created after it was added, and is
/// removed once it matched one (matched).
public struct Rule
{
    public var label: String?
    public var app: RulePattern?
    public var title: RulePattern?
    public var role: RulePattern?
    public var subrole: RulePattern?
    public var effects = RuleEffects()
    public var oneShot = false
    public var matched = false

    public init() {}

    /// Whether the rule has a valid role or subrole pattern.
    public var hasRole: Bool { role?.regex != nil }
    public var hasSubrole: Bool { subrole?.regex != nil }

    /// Whether a window with these properties passes every filter of the rule.
    public func matches(app appName: String, title windowTitle: String, role windowRole: String, subrole windowSubrole: String) -> Bool
    {
        (app?.admits(appName) ?? true) && (title?.admits(windowTitle) ?? true) &&
            (role?.admits(windowRole) ?? true) && (subrole?.admits(windowSubrole) ?? true)
    }

    //
    // NOTE: The "flags" of `rule --list` keep the bits of the C struct rule: the effects flags in the high half, and
    // 0x1/0x2/0x4/0x8 for a valid app/title/role/subrole pattern, 0x10 to 0x80 for their exclusion, 0x100 for one-shot
    // and 0x200 for a matched one-shot rule.
    //

    public var listFlags: UInt32
    {
        var flags: UInt32 = 0
        for (bit, pattern) in [app, title, role, subrole].enumerated() {
            guard let pattern else { continue }
            if pattern.regex != nil { flags |= 0x01 << bit }
            if pattern.exclude      { flags |= 0x10 << bit }
        }

        if oneShot { flags |= 0x100 }
        if matched { flags |= 0x200 }
        return UInt32(effects.flags.rawValue) << 16 | flags
    }
}

/// A rule in `rule --list`. Text that is nil is written as "", a property the rule leaves alone as null.
public struct RuleInfo: Encodable, Sendable
{
    private enum CodingKeys: String, CodingKey
    {
        case index, label, app, title, role, subrole, display, space
        case followSpace = "follow_space"
        case opacity, manage, sticky
        case mouseFollowsFocus = "mouse_follows_focus"
        case subLayer = "sub-layer"
        case fullscreen = "native-fullscreen"
        case grid, scratchpad
        case oneShot = "one-shot"
        case flags
    }

    public var index: Int
    public var label: String
    public var app: String
    public var title: String
    public var role: String
    public var subrole: String
    /// The arrangement index of the display of the rule, 0 without one.
    public var display: Int
    /// The Mission Control index of the space of the rule, 0 without one.
    public var space: Int
    public var followSpace: Bool
    public var opacity: Float
    public var manage: Bool?
    public var sticky: Bool?
    public var mouseFollowsFocus: Bool?
    public var subLayer: String
    public var fullscreen: Bool?
    public var grid: String
    public var scratchpad: String
    public var oneShot: Bool
    public var flags: String

    public func encode(to encoder: any Encoder) throws
    {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(label, forKey: .label)
        try container.encode(app, forKey: .app)
        try container.encode(title, forKey: .title)
        try container.encode(role, forKey: .role)
        try container.encode(subrole, forKey: .subrole)
        try container.encode(display, forKey: .display)
        try container.encode(space, forKey: .space)
        try container.encode(followSpace, forKey: .followSpace)
        try container.encode(opacity, forKey: .opacity)
        // NOTE: nil is written as null.
        try container.encode(manage, forKey: .manage)
        try container.encode(sticky, forKey: .sticky)
        try container.encode(mouseFollowsFocus, forKey: .mouseFollowsFocus)
        try container.encode(subLayer, forKey: .subLayer)
        try container.encode(fullscreen, forKey: .fullscreen)
        try container.encode(grid, forKey: .grid)
        try container.encode(scratchpad, forKey: .scratchpad)
        try container.encode(oneShot, forKey: .oneShot)
        try container.encode(flags, forKey: .flags)
    }
}

extension Rule
{
    /// The rule for `rule --list`, at index in the rule list; display and space are the indices of its effects.
    public func info(index: Int, display: Int, space: Int) -> RuleInfo
    {
        let grid = effects.grid
        let gridText = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height].map { String(Int32(bitPattern: $0)) }.joined(separator: ":")

        return RuleInfo(
            index: index,
            label: label ?? "",
            app: app?.text ?? "",
            title: title?.text ?? "",
            role: role?.text ?? "",
            subrole: subrole?.text ?? "",
            display: display,
            space: space,
            followSpace: effects.flags.contains(.followSpace),
            opacity: effects.opacity,
            manage: effects.manage,
            sticky: effects.sticky,
            mouseFollowsFocus: effects.mouseFollowsFocus,
            subLayer: effects.flags.contains(.layer) ? effects.layer.rawValue : "",
            fullscreen: effects.fullscreen,
            grid: gridText,
            scratchpad: effects.scratchpad ?? "",
            oneShot: oneShot,
            flags: cFormat("0x%08x", listFlags))
    }
}

/// Parses "on" or "off" into prop; false for any other value, which leaves prop as it was.
private func parseRuleProp(_ value: Token, _ prop: inout Bool?) -> Bool
{
    if value.equals(Argument.on) {
        prop = true
    } else if value.equals(Argument.off) {
        prop = false
    } else {
        return false
    }

    return true
}

//
// NOTE: A display or space value that starts with '^' also makes the window's space follow (focus) it.
//

/// `parse_rule_follow_prefix`
private func parseRuleFollowPrefix(_ effects: inout RuleEffects, _ value: Token) -> Token
{
    guard value.hasPrefix("^") else { return value }

    effects.flags.insert(.followSpace)
    return value.dropFirst(1)
}

//
// NOTE: When a key is given more than once, the last value wins, a pattern with its exclusion.
//

/// `parse_rule`: the key-value pairs of a rule, from token to the end of the message. Throws the problems of all the
/// pairs together in one failure when the rule is invalid. Returns false, without a failure, when a display or space
/// selector found nothing ('recent'): the rule is then not used either.
public func parseRule<C: SelectorContext>(_ message: inout some TokenSource, _ rule: inout Rule, _ first: Token, _ context: C) throws(CommandError) -> Bool
{
    var unsupportedExclusion: Token?
    var didParse = true
    var hasFilter = false
    var failures: [CommandError] = []

    var token = first
    while token.isValid {
        defer { token = message.next() }

        guard let pair = parseKeyValuePair(token) else {
            failures.append(CommandError("invalid key-value pair '\(token)'\n"))
            didParse = false
            continue
        }

        let key = pair.key
        var value = pair.value
        var isFilter = false
        var validValue = true
        var validPattern = true

        if key.equals("label") {
            rule.label = value.string
        } else if key.equals("scratchpad") {
            validValue = !LabelKind.window.isReserved(value)
            if validValue {
                rule.effects.scratchpad = value.string
                rule.effects.manage = false
            }
        } else if key.equals("app") {
            isFilter = true
            rule.app = RulePattern(value, exclude: pair.exclusion)
            validPattern = rule.app?.regex != nil
        } else if key.equals("title") {
            isFilter = true
            rule.title = RulePattern(value, exclude: pair.exclusion)
            validPattern = rule.title?.regex != nil
        } else if key.equals("role") {
            isFilter = true
            rule.role = RulePattern(value, exclude: pair.exclusion)
            validPattern = rule.role?.regex != nil
        } else if key.equals("subrole") {
            isFilter = true
            rule.subrole = RulePattern(value, exclude: pair.exclusion)
            validPattern = rule.subrole?.regex != nil
        } else if key.equals("display") {
            value = parseRuleFollowPrefix(&rule.effects, value)
            if let selector = DisplaySelector(value) {
                do {
                    if let did = try selector.resolve(acting: context.activeDisplay, context) { rule.effects.did = did }
                    else { didParse = false }
                } catch {
                    failures.append(error)
                    if case .label = selector { didParse = false }
                }
            } else {
                failures.append(DisplaySelector.invalid(value))
                didParse = false
            }
        } else if key.equals("space") {
            value = parseRuleFollowPrefix(&rule.effects, value)
            if let selector = SpaceSelector(value) {
                do {
                    if let sid = try selector.resolve(acting: context.activeSpace, context) { rule.effects.sid = sid }
                    else { didParse = false }
                } catch {
                    failures.append(error)
                    if case .label = selector { didParse = false }
                }
            } else {
                failures.append(SpaceSelector.invalid(value))
                didParse = false
            }
        } else if key.equals("grid") {
            validValue = rule.effects.grid.scan(value) == 6
        } else if key.equals("opacity") {
            validValue = withUnsafeMutablePointer(to: &rule.effects.opacity) { value.scan("%f", $0) } == 1 && rule.effects.opacity >= 0 && rule.effects.opacity <= 1
            if validValue { rule.effects.flags.insert(.opacity) }
        } else if key.equals("manage") {
            validValue = parseRuleProp(value, &rule.effects.manage)
        } else if key.equals("sticky") {
            validValue = parseRuleProp(value, &rule.effects.sticky)
        } else if key.equals("mouse_follows_focus") {
            validValue = parseRuleProp(value, &rule.effects.mouseFollowsFocus)
        } else if key.equals("native-fullscreen") {
            validValue = parseRuleProp(value, &rule.effects.fullscreen)
        } else if key.equals("sub-layer") {
            let layer = parseLayer(value)
            validValue = layer != nil
            if let layer {
                rule.effects.layer = layer
                rule.effects.flags.insert(.layer)
            }
        } else {
            failures.append(CommandError("unknown key '\(key)'\n"))
            didParse = false
            continue
        }

        hasFilter = hasFilter || isFilter
        if pair.exclusion && !isFilter { unsupportedExclusion = key }

        if !validValue {
            failures.append(CommandError("invalid value '\(value)' for key '\(key)'\n"))
            didParse = false
        }

        if !validPattern {
            failures.append(CommandError("invalid regex pattern '\(value)' for key '\(key)'\n"))
            didParse = false
        }
    }

    if !hasFilter {
        failures.append(CommandError("missing required key-value pair 'app[!]=..' or 'title[!]=..'\n"))
        didParse = false
    }

    if let unsupportedExclusion {
        failures.append(CommandError("unsupported token '!' (exclusion) given for key '\(unsupportedExclusion)'\n"))
        didParse = false
    }

    if !failures.isEmpty { throw CommandError(combining: failures) }
    return didParse
}

/// `struct signal` (the former src/event_signal.h): the filters and the action of a signal.
public struct EventSignal
{
    public var label: String?
    public var app: RulePattern?
    public var title: RulePattern?
    /// Whether the application or window of the event must be active (focused); nil when it does not matter.
    public var active: Bool?
    public var command: String?

    public init() {}
}

/// `parse_signal`: the key-value pairs of a signal, to the end of the message. eventType looks up the name of an event
/// (`signal_type_from_string`). Throws the problems of all the pairs together in one failure when the signal is invalid.
public func parseSignal<Event>(_ message: inout some TokenSource, _ signal: inout EventSignal, _ event: inout Event?, eventType: (Token) -> Event?) throws(CommandError)
{
    var unsupportedExclusion: Token?
    var didParse = true
    var hasSignalType = false
    var failures: [CommandError] = []
    event = nil

    var token = message.next()
    while token.isValid {
        defer { token = message.next() }

        guard let pair = parseKeyValuePair(token) else {
            failures.append(CommandError("invalid key-value pair '\(token)'\n"))
            didParse = false
            continue
        }

        let key = pair.key
        let value = pair.value
        var isFilter = false
        var validValue = true
        var validPattern = true

        if key.equals("label") {
            signal.label = value.string
        } else if key.equals("app") {
            isFilter = true
            signal.app = RulePattern(value, exclude: pair.exclusion)
            validPattern = signal.app?.regex != nil
        } else if key.equals("title") {
            isFilter = true
            signal.title = RulePattern(value, exclude: pair.exclusion)
            validPattern = signal.title?.regex != nil
        } else if key.equals("active") {
            if value.equals("yes") {
                signal.active = true
            } else if value.equals("no") {
                signal.active = false
            } else {
                validValue = false
            }
        } else if key.equals("action") {
            signal.command = value.string
        } else if key.equals("event") {
            hasSignalType = true
            event = eventType(value)
            validValue = event != nil
        } else {
            failures.append(CommandError("unknown key '\(key)'\n"))
            didParse = false
            continue
        }

        if pair.exclusion && !isFilter { unsupportedExclusion = key }

        if !validValue {
            failures.append(CommandError("invalid value '\(value)' for key '\(key)'\n"))
            didParse = false
        }

        if !validPattern {
            failures.append(CommandError("invalid regex pattern '\(value)' for key '\(key)'\n"))
            didParse = false
        }
    }

    if !hasSignalType {
        failures.append(CommandError("missing required key-value pair 'event=..'\n"))
        didParse = false
    }

    if signal.command == nil {
        failures.append(CommandError("missing required key-value pair 'action=..'\n"))
        didParse = false
    }

    if let unsupportedExclusion {
        failures.append(CommandError("unsupported token '!' (exclusion) given for key '\(unsupportedExclusion)'\n"))
        didParse = false
    }

    if !didParse { throw CommandError(combining: failures) }
}
