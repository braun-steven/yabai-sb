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

/// A grid placement "rows:columns:x:y:width:height" (`unsigned grid[6]`). All 0 is no placement.
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
    // NOTE: "%d" writes each value as an int into the unsigned field, as the C version's sscanf did, and the fields
    // before a mismatch keep what was read.
    //

    /// sscanf with "%d:%d:%d:%d:%d:%d"; returns the number of values read.
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

/// The effects of a rule on the windows it matches. manage, sticky, mouseFollowsFocus and fullscreen are nil when the
/// rule leaves them alone.
public struct RuleEffects: Sendable
{
    public var did: DisplayID = 0
    public var sid: SpaceID = 0
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
        if effects.did != 0 { did = effects.did }
        if effects.sid != 0 { sid = effects.sid }

        if effects.did != 0 || effects.sid != 0 {
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
    guard value.bytes.first == UInt8(ascii: "^") else { return value }

    effects.flags.insert(.followSpace)
    return value.dropFirst(1)
}

//
// NOTE: When a key is given more than once, the last value wins, a pattern with its exclusion.
//

/// `parse_rule`: the key-value pairs of a rule, from token to the end of the message.
public func parseRule<C: SelectorContext>(_ rsp: inout Response, _ message: inout some TokenSource, _ rule: inout Rule, _ first: Token, _ context: C) -> Bool
{
    var unsupportedExclusion: Token?
    var didParse = true
    var hasFilter = false

    var token = first
    while token.isValid {
        defer { token = message.next() }

        guard let pair = parseKeyValuePair(token) else {
            rsp.fail("invalid key-value pair '\(token)'\n")
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
            let selector = parseDisplaySelector(&rsp, value, acting: context.activeDisplay, optional: false, context)
            if selector.didParse && selector.value != 0 {
                rule.effects.did = selector.value
            } else {
                didParse = false
            }
        } else if key.equals("space") {
            value = parseRuleFollowPrefix(&rule.effects, value)
            let selector = parseSpaceSelector(&rsp, value, acting: context.activeSpace, optional: false, context)
            if selector.didParse && selector.value != 0 {
                rule.effects.sid = selector.value
            } else {
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
            rsp.fail("unknown key '\(key)'\n")
            didParse = false
            continue
        }

        hasFilter = hasFilter || isFilter
        if pair.exclusion && !isFilter { unsupportedExclusion = key }

        if !validValue {
            rsp.fail("invalid value '\(value)' for key '\(key)'\n")
            didParse = false
        }

        if !validPattern {
            rsp.fail("invalid regex pattern '\(value)' for key '\(key)'\n")
            didParse = false
        }
    }

    if !hasFilter {
        rsp.fail("missing required key-value pair 'app[!]=..' or 'title[!]=..'\n")
        didParse = false
    }

    if let unsupportedExclusion {
        rsp.fail("unsupported token '!' (exclusion) given for key '\(unsupportedExclusion)'\n")
        didParse = false
    }

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
/// (`signal_type_from_string`).
public func parseSignal<Event>(_ rsp: inout Response, _ message: inout some TokenSource, _ signal: inout EventSignal, _ event: inout Event?, eventType: (Token) -> Event?) -> Bool
{
    var unsupportedExclusion: Token?
    var didParse = true
    var hasSignalType = false
    event = nil

    var token = message.next()
    while token.isValid {
        defer { token = message.next() }

        guard let pair = parseKeyValuePair(token) else {
            rsp.fail("invalid key-value pair '\(token)'\n")
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
            rsp.fail("unknown key '\(key)'\n")
            didParse = false
            continue
        }

        if pair.exclusion && !isFilter { unsupportedExclusion = key }

        if !validValue {
            rsp.fail("invalid value '\(value)' for key '\(key)'\n")
            didParse = false
        }

        if !validPattern {
            rsp.fail("invalid regex pattern '\(value)' for key '\(key)'\n")
            didParse = false
        }
    }

    if !hasSignalType {
        rsp.fail("missing required key-value pair 'event=..'\n")
        didParse = false
    }

    if signal.command == nil {
        rsp.fail("missing required key-value pair 'action=..'\n")
        didParse = false
    }

    if let unsupportedExclusion {
        rsp.fail("unsupported token '!' (exclusion) given for key '\(unsupportedExclusion)'\n")
        didParse = false
    }

    return didParse
}
