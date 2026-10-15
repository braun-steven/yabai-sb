import YabaiC
import YabaiCore

//
// NOTE: What the Swift handlers of the IPC domains (Sources/Yabai/IPC/) need from the C managers while those are C: the
// selectors look up displays, spaces and windows in them, and rules are parsed into their C struct. Also
// the C entry point of RuleEffects.combine.
//

extension Token
{
    init(cString: UnsafePointer<CChar>?)
    {
        guard let cString else {
            self.init(ArraySlice<UInt8>())
            return
        }

        self.init(UnsafeRawBufferPointer(start: cString, count: strlen(cString)))
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

    /// Appends what body writes into the FILE it is given: the response of a handler that is still C.
    mutating func appendWritten(by body: (UnsafeMutablePointer<FILE>) -> Void)
    {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
        let size = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        buffer.initialize(to: nil)
        size.initialize(to: 0)
        defer {
            free(buffer.pointee)
            buffer.deallocate()
            size.deallocate()
        }

        guard let file = open_memstream(buffer, size) else { return }
        body(file)
        fclose(file)

        if let written = buffer.pointee {
            bytes += UnsafeRawBufferPointer(start: written, count: size.pointee)
        }
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
    typealias Window = Yabai.Window

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
        case .recent:                         display_manager_global().last_display_id
        case .cursor:                         display_manager_cursor_display_id()
        }
    }

    func displayLabel(_ label: Token) -> UInt64?
    {
        labelList(display_manager_global().labels)?.list.find(name: label.string)?.id
    }

    func space(_ query: SpaceQuery) -> UInt64
    {
        switch query {
        case .missionControl(let index): space_manager_mission_control_space(index)
        case .prev(let sid):             space_manager_prev_space(sid)
        case .next(let sid):             space_manager_next_space(sid)
        case .first:                     space_manager_first_space()
        case .last:                      space_manager_last_space()
        case .recent:                    space_manager_global().last_space_id
        case .cursor:                    space_manager_cursor_space()
        }
    }

    func spaceLabel(_ label: Token) -> UInt64?
    {
        labelList(space_manager_global().labels)?.list.find(name: label.string)?.id
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

//
// NOTE: The values of LAYER_* (src/misc/macros.h). Swift does not import the macros that name the CGWindowLevelKey
// constants.
//

func layerValue(_ layer: WindowLayer) -> Int32
{
    switch layer {
    case .auto:   Int32(LAYER_AUTO)
    case .below:  CGWindowLevelKey.backstopMenu.rawValue
    case .normal: CGWindowLevelKey.normalWindow.rawValue
    case .above:  CGWindowLevelKey.floatingWindow.rawValue
    }
}

func windowLayer(_ layer: Int32) -> WindowLayer
{
    WindowLayer.allCases.first { layerValue($0) == layer } ?? .auto
}

//
// NOTE: struct rule stays C until the rules are Swift (P11). The shim fills it from the parsed Rule: the strings are
// malloc'ed copies and the patterns compiled again into the C regex_t, so that rule_destroy frees them as before. A
// pattern that does not compile has no VALID flag. The caller sets RULE_ONE_SHOT, which parse_rule keeps.
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

/// `rule_combine_effects`
func rule_combine_effects(_ effects: UnsafeMutablePointer<rule_effects>, _ result: UnsafeMutablePointer<rule_effects>)
{
    var combined = RuleEffects(result.pointee)
    combined.combine(RuleEffects(effects.pointee))
    combined.write(to: &result.pointee)
}

/// `parse_rule` into a C rule.
func parseCRule(_ rsp: inout Response, _ message: inout some TokenSource, _ result: UnsafeMutablePointer<rule>, _ first: Token) -> Bool
{
    var parsed = Rule()
    let didParse = parseRule(&rsp, &message, &parsed, first, CSelectorContext())

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
