import CoreGraphics
import Darwin
import YabaiC
import YabaiCore

//
// NOTE: The handler of the config domain. Options print their value when none is given. The options are fields of the
// C managers until those are Swift (P9, P11). Ported from src/message_config.c.
//

/// The commands, selector and arguments of the config domain (`COMMAND_CONFIG_*`, `SELECTOR_CONFIG_SPACE` and
/// `ARGUMENT_CONFIG_*`, src/message_parse.c).
private enum Config
{
    static let debugOutput              = "debug_output"
    static let mff                      = "mouse_follows_focus"
    static let ffm                      = "focus_follows_mouse"
    static let displayOrder             = "display_arrangement_order"
    static let builtinLast              = "builtin_display_last"
    static let windowOrigin             = "window_origin_display"
    static let opacity                  = "window_opacity"
    static let opacityDuration          = "window_opacity_duration"
    static let animationDuration        = "window_animation_duration"
    static let animationEasing          = "window_animation_easing"
    static let shadow                   = "window_shadow"
    static let menubarOpacity           = "menubar_opacity"
    static let activeWindowOpacity      = "active_window_opacity"
    static let normalWindowOpacity      = "normal_window_opacity"
    static let insertFeedbackColor      = "insert_feedback_color"
    static let border                   = "window_border"
    static let borderWidth              = "window_border_width"
    static let borderHideSingle         = "window_border_hide_single"
    static let activeBorderColor        = "active_window_border_color"
    static let normalBorderColor        = "normal_window_border_color"
    static let tabBar                   = "tab_bar"
    static let tabBarHeight             = "tab_bar_height"
    static let tabBarOffset             = "tab_bar_offset"
    static let tabBarFont               = "tab_bar_font"
    static let tabBarIcons              = "tab_bar_icons"
    static let tabBarStyle              = "tab_bar_style"
    static let tabBarBackdrop           = "tab_bar_backdrop"
    static let tabBarCardPadding        = "tab_bar_card_padding"
    static let tabBarWindowRadius       = "tab_bar_window_radius"
    static let tabBarFocusedColor       = "tab_bar_focused_color"
    static let tabBarFocusedTextColor   = "tab_bar_focused_text_color"
    static let tabBarInactiveColor      = "tab_bar_inactive_color"
    static let tabBarInactiveTextColor  = "tab_bar_inactive_text_color"
    static let tabBarUnfocusedColor     = "tab_bar_unfocused_color"
    static let tabBarUnfocusedTextColor = "tab_bar_unfocused_text_color"
    static let tabBarBackdropColor      = "tab_bar_backdrop_color"
    static let topPadding               = "top_padding"
    static let bottomPadding            = "bottom_padding"
    static let leftPadding              = "left_padding"
    static let rightPadding             = "right_padding"
    static let layout                   = "layout"
    static let windowGap                = "window_gap"
    static let autoPadding              = "auto_padding"
    static let treeOrientation          = "tree_default_orientation"
    static let treeWorkspaceLayout      = "tree_workspace_layout"
    static let treeAutotiling           = "tree_autotiling"
    static let focusWrapping            = "focus_wrapping"
    static let mouseModifier            = "mouse_modifier"
    static let mouseAction1             = "mouse_action1"
    static let mouseAction2             = "mouse_action2"
    static let mouseDropAction          = "mouse_drop_action"
    static let externalBar              = "external_bar"
    static let skipSpaceAnimation       = "skip_window_focus_animation"
    static let spaceLayout              = "space_layout"
    static let scratchpadExclusive      = "scratchpad_exclusive"
    static let scratchpadRaise          = "scratchpad_raise"
    static let scratchpadBelow          = "scratchpad_below"
    static let scratchpadGrid           = "scratchpad_grid"

    static let spaceSelector            = "--space"

    static let ffmAutofocus             = "autofocus"
    static let ffmAutoraise             = "autoraise"
    static let layoutFloat              = "float"
    static let layoutTree               = "tree"
}

//
// NOTE: The names of the values, from the `*_str` tables of the C headers (static, so Swift cannot read them). An index
// is the value of the C enum; nil entries are the gaps of a bitmask enum (mouse_mod).
//

private let ffmModeNames: [String] = ["disabled", "autofocus", "autoraise"]
private let viewTypeNames: [String] = ["default", "float", "tree"]
private let externalBarModeNames: [String] = ["off", "main", "all"]
private let displayArrangementOrderNames: [String?] = ["default", "horizontal", "vertical"]
private let windowOriginModeNames: [String?] = ["default", "focused", "cursor"]
private let purifyModeNames: [String?] = ["on", "float", "off"]
private let treeOrientationNames: [String?] = ["auto", "horizontal", "vertical"]
private let workspaceLayoutNames: [String?] = ["default", "tabbed"]
private let focusWrappingNames: [String?] = ["off", "on", "force"]
private let mouseModeNames: [String?] = ["none", "move", "resize", "swap", "stack"]
private let tabBarStyleNames: [String] = ["glass", "i3"]
private let tabBarBackdropNames: [String] = ["off", "glass", "blur"]

private let animationEasingNames: [String?] = ["sine", "quad", "cubic", "quart", "quint", "expo", "circ"].flatMap { curve in
    ["ease_in_\(curve)", "ease_out_\(curve)", "ease_in_out_\(curve)"]
}

private let mouseModNames: [String?] = {
    var names = [String?](repeating: nil, count: Int(MOUSE_MOD_FN.rawValue) + 1)
    names[Int(MOUSE_MOD_NONE.rawValue)]  = "none"
    names[Int(MOUSE_MOD_ALT.rawValue)]   = "alt"
    names[Int(MOUSE_MOD_SHIFT.rawValue)] = "shift"
    names[Int(MOUSE_MOD_CMD.rawValue)]   = "cmd"
    names[Int(MOUSE_MOD_CTRL.rawValue)]  = "ctrl"
    names[Int(MOUSE_MOD_FN.rawValue)]    = "fn"
    return names
}()

/// `parse_config_choice` for a C enum: the selected value, or nil when none was selected.
private func parseChoice(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ names: [String?], first: UInt32, last: UInt32, current: some BinaryInteger) -> UInt32?
{
    var choice = 0
    guard parseConfigChoice(&rsp, domain, command, &message, names: names, first: Int(first), last: Int(last), current: Int(current), &choice) else { return nil }
    return UInt32(choice)
}

private func tabBarColor(for command: Token) -> WritableKeyPath<window_manager, rgba_color>?
{
    if command.equals(Config.tabBarFocusedColor)       { return \.tab_bar_focused_color }
    if command.equals(Config.tabBarFocusedTextColor)   { return \.tab_bar_focused_text_color }
    if command.equals(Config.tabBarInactiveColor)      { return \.tab_bar_inactive_color }
    if command.equals(Config.tabBarInactiveTextColor)  { return \.tab_bar_inactive_text_color }
    if command.equals(Config.tabBarUnfocusedColor)     { return \.tab_bar_unfocused_color }
    if command.equals(Config.tabBarUnfocusedTextColor) { return \.tab_bar_unfocused_text_color }
    if command.equals(Config.tabBarBackdropColor)      { return \.tab_bar_backdrop_color }
    return nil
}

private func tabBarColorCustom(for command: Token) -> WritableKeyPath<window_manager, Bool>?
{
    if command.equals(Config.tabBarFocusedColor)   { return \.tab_bar_focused_color_custom }
    if command.equals(Config.tabBarInactiveColor)  { return \.tab_bar_inactive_color_custom }
    if command.equals(Config.tabBarUnfocusedColor) { return \.tab_bar_unfocused_color_custom }
    if command.equals(Config.tabBarBackdropColor)  { return \.tab_bar_backdrop_color_custom }
    return nil
}

private func configScratchpadGrid(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource)
{
    let wm = window_manager_global()!
    let value = message.next()

    if !value.isValid {
        let grid = withUnsafeBytes(of: wm.pointee.scratchpad_grid) { Array($0.bindMemory(to: UInt32.self)) }
        if grid[0] == 0 || grid[1] == 0 {
            rsp.write("\(Argument.off)\n")
        } else {
            rsp.write("\(grid.map { String($0) }.joined(separator: ":"))\n")
        }
    } else if value.equals(Argument.off) {
        wm.pointee.scratchpad_grid = (0, 0, 0, 0, 0, 0)
    } else {
        // NOTE: like the C version, "%d" writes into unsigned values, so a negative row or column count passes the check
        var grid = [UInt32](repeating: 0, count: 6)
        let count = grid.withUnsafeMutableBufferPointer { g in
            value.scan("%d:%d:%d:%d:%d:%d", g.baseAddress!, g.baseAddress! + 1, g.baseAddress! + 2, g.baseAddress! + 3, g.baseAddress! + 4, g.baseAddress! + 5)
        }

        if count == 6 && grid[0] > 0 && grid[1] > 0 {
            wm.pointee.scratchpad_grid = (grid[0], grid[1], grid[2], grid[3], grid[4], grid[5])
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    }
}

//
// NOTE: space_layout takes one layout per display count, e.g. '15 10:5 10:5:1b'. The layouts are the
// tokens that start with a digit, so the next command can follow them. Returns false when the message
// is invalid and the remaining commands must not be run.
//

private func configSpaceLayout(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ selSid: UInt64) -> Bool
{
    let sm = space_manager_global()!

    if selSid != 0 {
        rsp.fail("command '\(command)' for domain '\(domain)' does not support the '\(Config.spaceSelector)' selector\n")
        return false
    }

    var value = message.next()

    if !value.isValid {
        if let spec = sm.pointee.space_layout_spec {
            rsp.write("\(Token(cString: spec))\n")
        } else {
            rsp.write("\(Argument.off)\n")
        }
        return true
    }

    if value.equals(Argument.off) {
        free(sm.pointee.space_layout_spec)
        sm.pointee.space_layout_spec = nil
        sm.pointee.space_layout_count = 0
        return true
    }

    func isLayout(_ token: Token) -> Bool
    {
        guard let first = token.bytes.first else { return false }
        return first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")
    }

    var layoutList: [space_layout] = []
    var spec: [UInt8] = []

    while isLayout(value) {
        var layout = space_layout()
        let parsed = value.withCString { space_layout_parse(UnsafeMutablePointer(mutating: $0), Int32(value.bytes.count), &layout) }
        if layoutList.count == Int(SPACE_LAYOUT_MAX) || !parsed {
            rsp.fail("invalid value '\(value)' given to command '\(command)' for domain '\(domain)'\n")
            return false
        }

        if let repeated = layoutList.first(where: { $0.count == layout.count }) {
            rsp.fail("value '\(value)' given to command '\(command)' for domain '\(domain)' repeats a layout for \(repeated.count) display(s)\n")
            return false
        }

        // NOTE: the C version built the spec in a buffer of 256 bytes, including the null terminator
        if !layoutList.isEmpty { spec.append(UInt8(ascii: " ")) }
        spec += value.bytes
        if spec.count >= 256 {
            rsp.fail("value given to command '\(command)' for domain '\(domain)' is too long\n")
            return false
        }

        layoutList.append(layout)

        guard isLayout(message.peek()) else { break }
        value = message.next()
    }

    if layoutList.isEmpty {
        rsp.failUnknownValue(domain, command, value)
        return false
    }

    withUnsafeMutableBytes(of: &sm.pointee.space_layout) { bytes in
        let layouts = bytes.bindMemory(to: space_layout.self)
        for (i, layout) in layoutList.enumerated() { layouts[i] = layout }
    }
    sm.pointee.space_layout_count = Int32(layoutList.count)
    free(sm.pointee.space_layout_spec)
    sm.pointee.space_layout_spec = mallocString(spec)
    space_layout_schedule(0.0, true)
    return true
}

//
// NOTE: Animations need the scripting addition and Screen Recording permission; 0 turns them off.
//

//
// NOTE: An opacity is printed with 4 decimals. Only the menubar accepts 0 (allowZero), windows need an
// opacity above 0.
//

private func configOpacity(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, current: Float, allowZero: Bool) -> Float?
{
    let token = message.next()
    let value = token.value
    if case .invalid = value {
        rsp.write("\(cFormat("%.4f", Double(current)))\n")
        return nil
    }

    if let opacity = value.floatValue, allowZero ? (opacity >= 0.0 && opacity <= 1.0) : (opacity > 0.0 && opacity <= 1.0) {
        return opacity
    }

    rsp.failUnknownValue(domain, command, token)
    return nil
}

private func configAnimationDuration(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource)
{
    let wm = window_manager_global()!
    let token = message.next()
    let value = token.value

    if case .invalid = value {
        rsp.write("\(cFormat("%f", Double(wm.pointee.window_animation_duration)))\n")
    } else if let duration = value.floatValue {
        if duration == 0.0 {
            wm.pointee.window_animation_duration = duration
        } else if !scripting_addition_is_sip_friendly() {
            rsp.fail("command '\(command)' for domain '\(domain)' requires System Integrity Protection to be partially disabled! ignoring request..\n")
        } else if CGPreflightScreenCaptureAccess() {
            wm.pointee.window_animation_duration = duration
        } else {
            rsp.fail("command '\(command)' for domain '\(domain)' requires Screen Recording permissions! ignoring request..\n")
            CGRequestScreenCaptureAccess()
        }
    } else {
        rsp.failUnknownValue(domain, command, token)
    }
}

private func configLayout(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ selSid: UInt64)
{
    let sm = space_manager_global()!
    let value = message.next()

    if !value.isValid {
        let layout = selSid != 0 ? space_manager_find_view(sm, selSid)!.pointee.layout : sm.pointee.layout
        rsp.write("\(viewTypeNames[Int(layout.rawValue)])\n")
        return
    }

    let layout = value.equals(Config.layoutFloat) ? VIEW_FLOAT
               : value.equals(Config.layoutTree)  ? VIEW_TREE
               : VIEW_DEFAULT

    if layout == VIEW_DEFAULT {
        rsp.failUnknownValue(domain, command, value)
    } else if selSid == 0 {
        space_manager_set_layout_for_all_spaces(sm, layout)
    } else if !space_is_user(selSid) {
        rsp.fail("cannot set layout for a macOS fullscreen space!\n")
    } else {
        space_manager_find_view(sm, selSid)!.pointee.flags |= UInt64(VIEW_LAYOUT.rawValue)
        space_manager_set_layout_for_space(sm, selSid, layout)
    }
}

private func configExternalBar(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource)
{
    let dm = display_manager_global()!
    let value = message.next()

    var mode = [CChar](repeating: 0, count: 6)
    var top: Int32 = 0
    var bottom: Int32 = 0
    let count = mode.withUnsafeMutableBufferPointer { m in
        withUnsafeMutablePointer(to: &top) { t in
            withUnsafeMutablePointer(to: &bottom) { b in value.scan("%5[^:]:%d:%d", m.baseAddress!, t, b) }
        }
    }

    if count != 3 {
        rsp.write("\(externalBarModeNames[Int(dm.pointee.mode.rawValue)]):\(dm.pointee.top_padding):\(dm.pointee.bottom_padding)\n")
        return
    }

    let modeToken = mode.withUnsafeBufferPointer { Token(cString: $0.baseAddress) }
    for (i, name) in externalBarModeNames.enumerated() where modeToken.equals(name) {
        dm.pointee.mode = external_bar_mode(rawValue: UInt32(i))
        dm.pointee.top_padding = top
        dm.pointee.bottom_padding = bottom
        space_manager_mark_spaces_invalid(space_manager_global())
        return
    }

    rsp.fail("unknown mode '\(modeToken)' specified in value '\(value)' given to command '\(command)' for domain '\(domain)'\n")
}

private func spacing(for command: Token) -> view_flag?
{
    if command.equals(Config.topPadding)    { return VIEW_TOP_PADDING }
    if command.equals(Config.bottomPadding) { return VIEW_BOTTOM_PADDING }
    if command.equals(Config.leftPadding)   { return VIEW_LEFT_PADDING }
    if command.equals(Config.rightPadding)  { return VIEW_RIGHT_PADDING }
    if command.equals(Config.windowGap)     { return VIEW_WINDOW_GAP }
    return nil
}

//
// NOTE: The C version converted with (int), which on arm64 saturates at the limits of int and turns NaN into 0.
//

private func cInt(_ value: Float) -> Int32
{
    if value.isNaN { return 0 }
    if value >= Float(Int32.max) { return .max }
    if value <= Float(Int32.min) { return .min }
    return Int32(value)
}

/// A color option: prints it as "0x%x", or sets it from a hexadecimal value. Returns true when it was set.
private func configColor(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ color: inout rgba_color, allowZero: Bool = true) -> Bool
{
    let token = message.next()
    switch token.value {
    case .invalid:
        rsp.write("0x\(String(color.p, radix: 16))\n")
    case .u32(let hex) where allowZero || hex != 0:
        color = rgba_color_from_hex(hex)
        return true
    default:
        rsp.failUnknownValue(domain, command, token)
    }
    return false
}

//
// NOTE: The window_border options. Returns false when command is not one of them.
//

private func configBorder(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) -> Bool
{
    let wm = window_manager_global()!

    if command.equals(Config.border) {
        if parseConfigBool(&rsp, domain, command, &message, &wm.pointee.enable_window_border) { border_refresh_all() }
    } else if command.equals(Config.borderHideSingle) {
        if parseConfigBool(&rsp, domain, command, &message, &wm.pointee.window_border_hide_single) { border_refresh_all() }
    } else if command.equals(Config.borderWidth) {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%.4f", Double(wm.pointee.window_border_width)))\n")
        } else if let width = value.floatValue, width > 0.0 {
            wm.pointee.window_border_width = width
            border_refresh_all()
        } else {
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.activeBorderColor) {
        if configColor(&rsp, domain, command, &message, &wm.pointee.active_window_border_color) { border_refresh_all() }
    } else if command.equals(Config.normalBorderColor) {
        if configColor(&rsp, domain, command, &message, &wm.pointee.normal_window_border_color) { border_refresh_all() }
    } else {
        return false
    }

    return true
}

//
// NOTE: The tab_bar options. Returns false when command is not one of them.
//

private func configTabBar(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) -> Bool
{
    let wm = window_manager_global()!

    if command.equals(Config.tabBar) {
        if parseConfigBool(&rsp, domain, command, &message, &wm.pointee.enable_tab_bar) { tab_bar_refresh_all() }
    } else if command.equals(Config.tabBarHeight) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.pointee.tab_bar_height)\n")
        case .int(let height) where height > 0:
            wm.pointee.tab_bar_height = height
            tab_bar_refresh_all()
        default:
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarOffset) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.pointee.tab_bar_offset)\n")
        case .int(let offset):
            wm.pointee.tab_bar_offset = offset
            tab_bar_refresh_all()
        case .float(let offset) where offset == Float(cInt(offset)):
            wm.pointee.tab_bar_offset = cInt(offset)
            tab_bar_refresh_all()
        default:
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarIcons) {
        if parseConfigBool(&rsp, domain, command, &message, &wm.pointee.tab_bar_icons) { tab_bar_redraw_all() }
    } else if command.equals(Config.tabBarStyle) {
        let value = message.next()
        var style = tab_bar_style(rawValue: 0)
        if !value.isValid {
            rsp.write("\(tabBarStyleNames[Int(wm.pointee.tab_bar_style.rawValue)])\n")
        } else if value.withCString({ tab_bar_parse_style(UnsafeMutablePointer(mutating: $0), &style) }) {
            wm.pointee.tab_bar_style = style
            tab_bar_refresh_all()
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(Config.tabBarBackdrop) {
        let value = message.next()
        var backdrop = tab_bar_backdrop(rawValue: 0)
        if !value.isValid {
            rsp.write("\(tabBarBackdropNames[Int(wm.pointee.tab_bar_backdrop.rawValue)])\n")
        } else if value.withCString({ tab_bar_parse_backdrop(UnsafeMutablePointer(mutating: $0), &backdrop) }) {
            wm.pointee.tab_bar_backdrop = backdrop
            tab_bar_refresh_all()
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(Config.tabBarCardPadding) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.pointee.tab_bar_card_padding)\n")
        case .int(let padding) where padding >= 0:
            wm.pointee.tab_bar_card_padding = padding
            tab_bar_refresh_all()
        default:
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarWindowRadius) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.pointee.tab_bar_window_radius)\n")
        case .int(let radius) where radius >= 0:
            wm.pointee.tab_bar_window_radius = radius
            tab_bar_redraw_all()
        default:
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarFont) {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(Token(cString: wm.pointee.tab_bar_font_name))\n")
        } else if value.withCString({ tab_bar_set_font(UnsafeMutablePointer(mutating: $0)) }) {
            tab_bar_redraw_all()
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if let color = tabBarColor(for: command) {
        if configColor(&rsp, domain, command, &message, &wm.pointee[keyPath: color]) {
            if let custom = tabBarColorCustom(for: command) { wm.pointee[keyPath: custom] = true }
            tab_bar_redraw_all()
        }
    } else {
        return false
    }

    return true
}

/// `handle_domain_config`
func handleDomainConfig(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    var selSid: UInt64 = 0
    let selector = message.next()
    var command = selector

    if selector.equals(Config.spaceSelector) {
        let spaceSelector = parseSpaceSelector(&rsp, message.next(), acting: 0, optional: false, CSelectorContext())
        guard spaceSelector.didParse, spaceSelector.value != 0 else { return }

        selSid = spaceSelector.value
        command = message.next()
    }

    while command.isValid {
        guard handleConfigCommand(&rsp, domain, command, &message, selSid) else { return }
        command = message.next()
    }
}

/// One command of the config domain. Returns false when the remaining commands must not be run.
private func handleConfigCommand(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ selSid: UInt64) -> Bool
{
    let wm = window_manager_global()!
    let sm = space_manager_global()!
    let dm = display_manager_global()!
    let mouse = mouse_state_global()!

    if configBorder(&rsp, domain, command, &message)  { return true }
    if configTabBar(&rsp, domain, command, &message) { return true }

    if command.equals(Config.debugOutput) {
        _ = parseConfigBool(&rsp, domain, command, &message, &verbose_global()!.pointee)
    } else if command.equals(Config.mff) {
        _ = parseConfigBool(&rsp, domain, command, &message, &wm.pointee.enable_mff)
    } else if command.equals(Config.ffm) {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(ffmModeNames[Int(wm.pointee.ffm_mode.rawValue)])\n")
        } else if value.equals(Argument.off) {
            window_manager_set_focus_follows_mouse(wm, FFM_DISABLED)
        } else if value.equals(Config.ffmAutofocus) {
            window_manager_set_focus_follows_mouse(wm, FFM_AUTOFOCUS)
        } else if value.equals(Config.ffmAutoraise) {
            window_manager_set_focus_follows_mouse(wm, FFM_AUTORAISE)
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(Config.displayOrder) {
        if let choice = parseChoice(&rsp, domain, command, &message, displayArrangementOrderNames, first: DISPLAY_ARRANGEMENT_ORDER_DEFAULT.rawValue, last: DISPLAY_ARRANGEMENT_ORDER_Y.rawValue, current: dm.pointee.order.rawValue) {
            dm.pointee.order = display_arrangement_order(rawValue: choice)
        }
    } else if command.equals(Config.builtinLast) {
        if parseConfigBool(&rsp, domain, command, &message, &dm.pointee.builtin_last) { space_layout_schedule(0.0, true) }
    } else if command.equals(Config.windowOrigin) {
        if let choice = parseChoice(&rsp, domain, command, &message, windowOriginModeNames, first: WINDOW_ORIGIN_DEFAULT.rawValue, last: WINDOW_ORIGIN_CURSOR.rawValue, current: wm.pointee.window_origin_mode.rawValue) {
            wm.pointee.window_origin_mode = window_origin_mode(rawValue: choice)
        }
    } else if command.equals(Config.scratchpadExclusive) {
        _ = parseConfigBool(&rsp, domain, command, &message, &wm.pointee.scratchpad_exclusive)
    } else if command.equals(Config.scratchpadRaise) {
        _ = parseConfigBool(&rsp, domain, command, &message, &wm.pointee.scratchpad_raise)
    } else if command.equals(Config.scratchpadBelow) {
        if parseConfigBool(&rsp, domain, command, &message, &wm.pointee.scratchpad_below) { window_manager_set_scratchpad_layers(wm) }
    } else if command.equals(Config.scratchpadGrid) {
        configScratchpadGrid(&rsp, domain, command, &message)
    } else if command.equals(Config.skipSpaceAnimation) {
        _ = parseConfigBool(&rsp, domain, command, &message, &sm.pointee.skip_window_focus_animation)
    } else if command.equals(Config.spaceLayout) {
        if !configSpaceLayout(&rsp, domain, command, &message, selSid) { return false }
    } else if command.equals(Config.opacity) {
        var enabled = wm.pointee.enable_window_opacity
        if parseConfigBool(&rsp, domain, command, &message, &enabled) { window_manager_set_window_opacity_enabled(wm, enabled) }
    } else if command.equals(Config.opacityDuration) {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%f", Double(wm.pointee.window_opacity_duration)))\n")
        } else if let duration = value.floatValue {
            wm.pointee.window_opacity_duration = duration
        } else {
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.animationDuration) {
        configAnimationDuration(&rsp, domain, command, &message)
    } else if command.equals(Config.animationEasing) {
        if let choice = parseChoice(&rsp, domain, command, &message, animationEasingNames, first: 0, last: EASING_TYPE_COUNT.rawValue - 1, current: wm.pointee.window_animation_easing) {
            wm.pointee.window_animation_easing = Int32(choice)
        }
    } else if command.equals(Config.shadow) {
        if let choice = parseChoice(&rsp, domain, command, &message, purifyModeNames, first: PURIFY_DISABLED.rawValue, last: PURIFY_ALWAYS.rawValue, current: wm.pointee.purify_mode.rawValue) {
            window_manager_set_purify_mode(wm, purify_mode(rawValue: choice))
        }
    } else if command.equals(Config.menubarOpacity) {
        if let opacity = configOpacity(&rsp, domain, command, &message, current: wm.pointee.menubar_opacity, allowZero: true) { window_manager_set_menubar_opacity(wm, opacity) }
    } else if command.equals(Config.activeWindowOpacity) {
        if let opacity = configOpacity(&rsp, domain, command, &message, current: wm.pointee.active_window_opacity, allowZero: false) { window_manager_set_active_window_opacity(wm, opacity) }
    } else if command.equals(Config.normalWindowOpacity) {
        if let opacity = configOpacity(&rsp, domain, command, &message, current: wm.pointee.normal_window_opacity, allowZero: false) { window_manager_set_normal_window_opacity(wm, opacity) }
    } else if command.equals(Config.insertFeedbackColor) {
        _ = configColor(&rsp, domain, command, &message, &wm.pointee.insert_feedback_color, allowZero: false)
    } else if let flag = spacing(for: command) {
        let view = selSid != 0 ? space_manager_find_view(sm, selSid) : nil
        let spacing = view.map { view_spacing($0, flag)! } ?? space_manager_spacing(sm, flag)!
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(spacing.pointee)\n")
        case .int(let value):
            if let view {
                view.pointee.flags |= UInt64(flag.rawValue)
                spacing.pointee = value
                view_update_and_flush(view)
            } else {
                space_manager_set_spacing_for_all_spaces(sm, flag, value)
            }
        default:
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(Config.layout) {
        configLayout(&rsp, domain, command, &message, selSid)
    } else if command.equals(Config.treeOrientation) {
        if let choice = parseChoice(&rsp, domain, command, &message, treeOrientationNames, first: TREE_ORIENTATION_AUTO.rawValue, last: TREE_ORIENTATION_VERTICAL.rawValue, current: sm.pointee.tree_default_orientation.rawValue) {
            sm.pointee.tree_default_orientation = tree_orientation(rawValue: choice)
        }
    } else if command.equals(Config.treeWorkspaceLayout) {
        if let choice = parseChoice(&rsp, domain, command, &message, workspaceLayoutNames, first: 0, last: 1, current: sm.pointee.tree_workspace_tabbed ? 1 : 0) {
            sm.pointee.tree_workspace_tabbed = choice != 0
        }
    } else if command.equals(Config.treeAutotiling) {
        _ = parseConfigBool(&rsp, domain, command, &message, &sm.pointee.tree_autotiling)
    } else if command.equals(Config.focusWrapping) {
        if let choice = parseChoice(&rsp, domain, command, &message, focusWrappingNames, first: FOCUS_WRAPPING_OFF.rawValue, last: FOCUS_WRAPPING_FORCE.rawValue, current: wm.pointee.focus_wrapping.rawValue) {
            wm.pointee.focus_wrapping = focus_wrapping(rawValue: choice)
        }
    } else if command.equals(Config.autoPadding) {
        if selSid != 0 {
            var enabled = space_manager_find_view(sm, selSid)!.pointee.auto_padding
            if parseConfigBool(&rsp, domain, command, &message, &enabled) { space_manager_set_auto_padding_for_space(sm, selSid, enabled) }
        } else {
            var enabled = sm.pointee.auto_padding
            if parseConfigBool(&rsp, domain, command, &message, &enabled) { space_manager_set_auto_padding_for_all_spaces(sm, enabled) }
        }
    } else if command.equals(Config.mouseModifier) {
        if let choice = parseChoice(&rsp, domain, command, &message, mouseModNames, first: MOUSE_MOD_ALT.rawValue, last: MOUSE_MOD_FN.rawValue, current: mouse.pointee.modifier) {
            mouse.pointee.modifier = UInt8(choice)
        }
    } else if command.equals(Config.mouseAction1) {
        if let choice = parseChoice(&rsp, domain, command, &message, mouseModeNames, first: MOUSE_MODE_MOVE.rawValue, last: MOUSE_MODE_RESIZE.rawValue, current: mouse.pointee.action1.rawValue) {
            mouse.pointee.action1 = mouse_mode(rawValue: choice)
        }
    } else if command.equals(Config.mouseAction2) {
        if let choice = parseChoice(&rsp, domain, command, &message, mouseModeNames, first: MOUSE_MODE_MOVE.rawValue, last: MOUSE_MODE_RESIZE.rawValue, current: mouse.pointee.action2.rawValue) {
            mouse.pointee.action2 = mouse_mode(rawValue: choice)
        }
    } else if command.equals(Config.mouseDropAction) {
        if let choice = parseChoice(&rsp, domain, command, &message, mouseModeNames, first: MOUSE_MODE_SWAP.rawValue, last: MOUSE_MODE_STACK.rawValue, current: mouse.pointee.drop_action.rawValue) {
            mouse.pointee.drop_action = mouse_mode(rawValue: choice)
        }
    } else if command.equals(Config.externalBar) {
        configExternalBar(&rsp, domain, command, &message)
    } else {
        rsp.failUnknownCommand(domain, command)
    }

    return true
}
