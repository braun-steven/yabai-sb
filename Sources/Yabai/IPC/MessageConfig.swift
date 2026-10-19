import CoreGraphics
import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handler of the config domain. Options print their value when none is given. The options are fields of the
// managers.
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
    static let tabBarAppearance         = "tab_bar_appearance"
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
}

/// The layout of the workspace root of new trees (`config tree_workspace_layout`).
private enum WorkspaceLayout: String, CaseIterable
{
    case `default`
    case tabbed
}

@WM private func tabBarColor(for command: Token) -> ReferenceWritableKeyPath<WindowManager, RGBAColor>?
{
    if command.equals(Config.tabBarFocusedColor)       { return \.tabBarFocusedColor }
    if command.equals(Config.tabBarFocusedTextColor)   { return \.tabBarFocusedTextColor }
    if command.equals(Config.tabBarInactiveColor)      { return \.tabBarInactiveColor }
    if command.equals(Config.tabBarInactiveTextColor)  { return \.tabBarInactiveTextColor }
    if command.equals(Config.tabBarUnfocusedColor)     { return \.tabBarUnfocusedColor }
    if command.equals(Config.tabBarUnfocusedTextColor) { return \.tabBarUnfocusedTextColor }
    if command.equals(Config.tabBarBackdropColor)      { return \.tabBarBackdropColor }
    return nil
}

@WM private func tabBarColorCustom(for command: Token) -> ReferenceWritableKeyPath<WindowManager, Bool>?
{
    if command.equals(Config.tabBarFocusedColor)   { return \.tabBarFocusedColorIsCustom }
    if command.equals(Config.tabBarInactiveColor)  { return \.tabBarInactiveColorIsCustom }
    if command.equals(Config.tabBarUnfocusedColor) { return \.tabBarUnfocusedColorIsCustom }
    if command.equals(Config.tabBarBackdropColor)  { return \.tabBarBackdropColorIsCustom }
    if command.equals(Config.tabBarFocusedTextColor)   { return \.tabBarFocusedTextColorIsCustom }
    if command.equals(Config.tabBarInactiveTextColor)  { return \.tabBarInactiveTextColorIsCustom }
    if command.equals(Config.tabBarUnfocusedTextColor) { return \.tabBarUnfocusedTextColorIsCustom }
    return nil
}

@WM private func configScratchpadGrid(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let wm = WindowManager.shared
    let value = message.next()

    if !value.isValid {
        let grid = wm.scratchpadGrid
        if grid.rows == 0 || grid.columns == 0 {
            rsp.write("\(Argument.off)\n")
        } else {
            let values = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height]
            rsp.write("\(values.map { String($0) }.joined(separator: ":"))\n")
        }
    } else if value.equals(Argument.off) {
        wm.scratchpadGrid = Grid()
    } else {
        // NOTE: like the C version, "%d" writes into unsigned values, so a negative row or column count passes the check
        var grid = Grid()
        if grid.scan(value) == 6 && grid.rows > 0 && grid.columns > 0 {
            wm.scratchpadGrid = grid
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    }
}

//
// NOTE: space_layout takes one layout per display count, e.g. '15 10:5 10:5:1b'. The layouts are the
// tokens that start with a digit, so the next command can follow them. An invalid value stops the
// remaining commands of the message, since its layouts cannot be told apart from the next command.
//

@WM private func configSpaceLayout(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ selSid: SpaceID?) throws(CommandError)
{
    let sm = SpaceManager.shared

    if selSid != nil {
        throw CommandError("command '\(command)' for domain '\(domain)' does not support the '\(Config.spaceSelector)' selector\n", stopsMessage: true)
    }

    var value = message.next()

    if !value.isValid {
        if let spec = sm.spaceLayoutSpec {
            rsp.write("\(Token(spec))\n")
        } else {
            rsp.write("\(Argument.off)\n")
        }
        return
    }

    if value.equals(Argument.off) {
        sm.spaceLayoutSpec = nil
        sm.spaceLayouts = []
        return
    }

    func isLayout(_ token: Token) -> Bool
    {
        guard let first = token.bytes.first else { return false }
        return first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")
    }

    var layoutList: [SpaceLayout] = []
    var spec: [UInt8] = []

    while isLayout(value) {
        guard layoutList.count < SpaceLayout.max, let layout = SpaceLayout(parsing: value.bytes) else {
            throw CommandError("invalid value '\(value)' given to command '\(command)' for domain '\(domain)'\n", stopsMessage: true)
        }

        if let repeated = layoutList.first(where: { $0.count == layout.count }) {
            throw CommandError("value '\(value)' given to command '\(command)' for domain '\(domain)' repeats a layout for \(repeated.count) display(s)\n", stopsMessage: true)
        }

        // NOTE: the C version built the spec in a buffer of 256 bytes, including the null terminator
        if !layoutList.isEmpty { spec.append(UInt8(ascii: " ")) }
        spec += value.bytes
        if spec.count >= 256 {
            throw CommandError("value given to command '\(command)' for domain '\(domain)' is too long\n", stopsMessage: true)
        }

        layoutList.append(layout)

        guard isLayout(message.peek()) else { break }
        value = message.next()
    }

    if layoutList.isEmpty {
        throw CommandError.unknownValue(domain, command, value).stoppingMessage
    }

    sm.spaceLayouts = layoutList
    sm.spaceLayoutSpec = String(decoding: spec, as: UTF8.self)
    SpaceManager.shared.scheduleSpaceLayout(after: 0.0, resetPasses: true)
}

//
// NOTE: Animations need the scripting addition and Screen Recording permission; 0 turns them off.
//

//
// NOTE: An opacity is printed with 4 decimals. Only the menubar accepts 0 (allowZero), windows need an
// opacity above 0.
//

private func configOpacity(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, current: Float, allowZero: Bool) throws(CommandError) -> Float?
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

    throw CommandError.unknownValue(domain, command, token)
}

@WM private func configAnimationDuration(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let wm = WindowManager.shared
    let token = message.next()
    let value = token.value

    if case .invalid = value {
        rsp.write("\(cFormat("%f", Double(wm.windowAnimationDuration)))\n")
    } else if let duration = value.floatValue {
        if duration == 0.0 {
            wm.windowAnimationDuration = duration
        } else if !ScriptingAddition.shared.isSIPFriendly {
            throw CommandError("command '\(command)' for domain '\(domain)' requires System Integrity Protection to be partially disabled! ignoring request..\n")
        } else if CGPreflightScreenCaptureAccess() {
            wm.windowAnimationDuration = duration
        } else {
            CGRequestScreenCaptureAccess()
            throw CommandError("command '\(command)' for domain '\(domain)' requires Screen Recording permissions! ignoring request..\n")
        }
    } else {
        throw CommandError.unknownValue(domain, command, token)
    }
}

@WM private func configLayout(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ selSid: SpaceID?) throws(CommandError)
{
    let sm = SpaceManager.shared
    let value = message.next()

    if !value.isValid {
        let layout = selSid.map { sm.view(for: $0).layout } ?? sm.layout
        rsp.write("\(layout.rawValue)\n")
        return
    }

    guard let layout = [ViewType.float, .tree].first(where: { value.equals($0.rawValue) }) else {
        throw CommandError.unknownValue(domain, command, value)
    }

    if selSid == nil {
        sm.setLayoutForAllSpaces(layout)
    } else if let selSid, !selSid.isUser {
        throw CommandError("cannot set layout for a macOS fullscreen space!\n")
    } else if let selSid {
        sm.view(for: selSid).overrides.insert(.layout)
        sm.setLayout(layout, for: selSid)
    }
}

@WM private func configExternalBar(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let dm = DisplayManager.shared
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
        rsp.write("\(dm.mode.rawValue):\(dm.topPadding):\(dm.bottomPadding)\n")
        return
    }

    let modeToken = mode.withUnsafeBufferPointer { Token(cString: $0.baseAddress) }
    if let choice = ExternalBarMode.allCases.first(where: { modeToken.equals($0.rawValue) }) {
        dm.mode = choice
        dm.topPadding = Int(top)
        dm.bottomPadding = Int(bottom)
        SpaceManager.shared.markSpacesInvalid()
        return
    }

    throw CommandError("unknown mode '\(modeToken)' specified in value '\(value)' given to command '\(command)' for domain '\(domain)'\n")
}

private func spacing(for command: Token) -> ViewSpacing?
{
    if command.equals(Config.topPadding)    { return .topPadding }
    if command.equals(Config.bottomPadding) { return .bottomPadding }
    if command.equals(Config.leftPadding)   { return .leftPadding }
    if command.equals(Config.rightPadding)  { return .rightPadding }
    if command.equals(Config.windowGap)     { return .windowGap }
    return nil
}

//
// NOTE: The C version converted with (int), which on arm64 saturates at the limits of int and turns NaN into 0.
//

private func cInt(_ value: Float) -> Int
{
    if value.isNaN { return 0 }
    if value >= Float(Int32.max) { return Int(Int32.max) }
    if value <= Float(Int32.min) { return Int(Int32.min) }
    return Int(value)
}

/// A color option: prints it as "0x%x", or sets it from a hexadecimal value. Returns true when it was set, and throws an
/// invalid value.
private func configColor(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ color: inout RGBAColor, allowZero: Bool = true) throws(CommandError) -> Bool
{
    let token = message.next()
    switch token.value {
    case .invalid:
        rsp.write("0x\(String(color.argb, radix: 16))\n")
    case .u32(let hex) where allowZero || hex != 0:
        color = RGBAColor(hex: hex)
        return true
    default:
        throw CommandError.unknownValue(domain, command, token)
    }
    return false
}

//
// NOTE: The window_border options. Returns false when command is not one of them.
//

@WM private func configBorder(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) throws(CommandError) -> Bool
{
    let wm = WindowManager.shared

    if command.equals(Config.border) {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.windowBorderEnabled) { Border.refreshAll() }
    } else if command.equals(Config.borderHideSingle) {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.windowBorderHideSingle) { Border.refreshAll() }
    } else if command.equals(Config.borderWidth) {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%.4f", Double(wm.windowBorderWidth)))\n")
        } else if let width = value.floatValue, width > 0.0 {
            wm.windowBorderWidth = width
            Border.refreshAll()
        } else {
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.activeBorderColor) {
        if try configColor(&rsp, domain, command, &message, &wm.activeWindowBorderColor) { Border.refreshAll() }
    } else if command.equals(Config.normalBorderColor) {
        if try configColor(&rsp, domain, command, &message, &wm.normalWindowBorderColor) { Border.refreshAll() }
    } else {
        return false
    }

    return true
}

//
// NOTE: The tab_bar options. Returns false when command is not one of them.
//

@WM private func configTabBar(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource) throws(CommandError) -> Bool
{
    let wm = WindowManager.shared

    if command.equals(Config.tabBar) {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.tabBarEnabled) { TabBar.refreshAll() }
    } else if command.equals(Config.tabBarHeight) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.tabBarHeight)\n")
        case .int(let height) where height > 0:
            wm.tabBarHeight = height
            TabBar.refreshAll()
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarOffset) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.tabBarOffset)\n")
        case .int(let offset):
            wm.tabBarOffset = offset
            TabBar.refreshAll()
        case .float(let offset) where offset == Float(cInt(offset)):
            wm.tabBarOffset = cInt(offset)
            TabBar.refreshAll()
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarIcons) {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.tabBarIcons) { TabBar.redrawAll() }
    } else if command.equals(Config.tabBarStyle) {
        if let style = try parseConfigChoice(&rsp, domain, command, &message, current: wm.tabBarStyle) {
            wm.tabBarStyle = style
            TabBar.refreshAll()
        }
    } else if command.equals(Config.tabBarAppearance) {
        if let appearance = try parseConfigChoice(&rsp, domain, command, &message, current: wm.tabBarAppearance) {
            wm.tabBarAppearance = appearance
            TabBar.redrawAll()
        }
    } else if command.equals(Config.tabBarBackdrop) {
        if let backdrop = try parseConfigChoice(&rsp, domain, command, &message, current: wm.tabBarBackdrop) {
            wm.tabBarBackdrop = backdrop
            TabBar.refreshAll()
        }
    } else if command.equals(Config.tabBarCardPadding) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.tabBarCardPadding)\n")
        case .int(let padding) where padding >= 0:
            wm.tabBarCardPadding = padding
            TabBar.refreshAll()
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarWindowRadius) {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(wm.tabBarWindowRadius)\n")
        case .int(let radius) where radius >= 0:
            wm.tabBarWindowRadius = radius
            TabBar.redrawAll()
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.tabBarFont) {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(Token(wm.tabBarFontName))\n")
        } else if let name = String(validating: value.bytes, as: UTF8.self), TabBar.setFont(name) {
            TabBar.redrawAll()
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if let color = tabBarColor(for: command) {
        if try configColor(&rsp, domain, command, &message, &wm[keyPath: color]) {
            if let custom = tabBarColorCustom(for: command) { wm[keyPath: custom] = true }
            TabBar.redrawAll()
        }
    } else {
        return false
    }

    return true
}

/// `handle_domain_config`
@WM func handleDomainConfig(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    var selSid: SpaceID?
    let selector = message.next()
    var command = selector

    if selector.equals(Config.spaceSelector) {
        let spaceSelector = try SpaceSelector.required(message.next())
        guard let target = try spaceSelector.resolve(acting: nil, CSelectorContext()) else { return }

        selSid = target
        command = message.next()
    }

    try runCommands(&rsp, &message, from: command) { (rsp, source, command) throws(CommandError) -> Bool in
        try handleConfigCommand(&rsp, domain, command, &source, selSid)
        return true
    }
}

/// One command of the config domain.
@WM private func handleConfigCommand(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ selSid: SpaceID?) throws(CommandError)
{
    let wm = WindowManager.shared
    let sm = SpaceManager.shared
    let dm = DisplayManager.shared
    let mouse = MouseState.shared

    if try configBorder(&rsp, domain, command, &message)  { return }
    if try configTabBar(&rsp, domain, command, &message) { return }

    if command.equals(Config.debugOutput) {
        var verbose = Log.verbose.load(ordering: .relaxed)
        if try parseConfigBool(&rsp, domain, command, &message, &verbose) {
            Log.verbose.store(verbose, ordering: .relaxed)
        }
    } else if command.equals(Config.mff) {
        _ = try parseConfigBool(&rsp, domain, command, &message, &wm.mouseFollowsFocusEnabled)
    } else if command.equals(Config.ffm) {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(wm.focusFollowsMouseMode.rawValue)\n")
        } else if value.equals(Argument.off) {
            wm.setFocusFollowsMouse(.disabled)
        } else if let mode = [FocusFollowsMouse.autofocus, .autoraise].first(where: { value.equals($0.rawValue) }) {
            wm.setFocusFollowsMouse(mode)
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(Config.displayOrder) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: dm.order) {
            dm.order = choice
        }
    } else if command.equals(Config.builtinLast) {
        if try parseConfigBool(&rsp, domain, command, &message, &dm.builtinDisplayLast) { SpaceManager.shared.scheduleSpaceLayout(after: 0.0, resetPasses: true) }
    } else if command.equals(Config.windowOrigin) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.windowOriginMode) {
            wm.windowOriginMode = choice
        }
    } else if command.equals(Config.scratchpadExclusive) {
        _ = try parseConfigBool(&rsp, domain, command, &message, &wm.scratchpadExclusive)
    } else if command.equals(Config.scratchpadRaise) {
        _ = try parseConfigBool(&rsp, domain, command, &message, &wm.scratchpadRaise)
    } else if command.equals(Config.scratchpadBelow) {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.scratchpadBelow) { wm.setScratchpadLayers() }
    } else if command.equals(Config.scratchpadGrid) {
        try configScratchpadGrid(&rsp, domain, command, &message)
    } else if command.equals(Config.skipSpaceAnimation) {
        _ = try parseConfigBool(&rsp, domain, command, &message, &sm.skipWindowFocusAnimation)
    } else if command.equals(Config.spaceLayout) {
        try configSpaceLayout(&rsp, domain, command, &message, selSid)
    } else if command.equals(Config.opacity) {
        var enabled = wm.windowOpacityEnabled
        if try parseConfigBool(&rsp, domain, command, &message, &enabled) { wm.setWindowOpacityEnabled(enabled) }
    } else if command.equals(Config.opacityDuration) {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%f", Double(wm.windowOpacityDuration)))\n")
        } else if let duration = value.floatValue {
            wm.windowOpacityDuration = duration
        } else {
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.animationDuration) {
        try configAnimationDuration(&rsp, domain, command, &message)
    } else if command.equals(Config.animationEasing) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.windowAnimationEasing) {
            wm.windowAnimationEasing = choice
        }
    } else if command.equals(Config.shadow) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.purifyMode) {
            wm.setPurifyMode(choice)
        }
    } else if command.equals(Config.menubarOpacity) {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: wm.menuBarOpacity, allowZero: true) { wm.setMenuBarOpacity(opacity) }
    } else if command.equals(Config.activeWindowOpacity) {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: wm.activeWindowOpacity, allowZero: false) { wm.setActiveWindowOpacity(opacity) }
    } else if command.equals(Config.normalWindowOpacity) {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: wm.normalWindowOpacity, allowZero: false) { wm.setNormalWindowOpacity(opacity) }
    } else if command.equals(Config.insertFeedbackColor) {
        _ = try configColor(&rsp, domain, command, &message, &wm.insertionFeedbackColor, allowZero: false)
    } else if let spacing = spacing(for: command) {
        let view = selSid.map { sm.view(for: $0) }
        let current = view.map { $0[keyPath: spacing.view] } ?? sm[keyPath: spacing.spaceManager]
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(current)\n")
        case .int(let value):
            if let view {
                view.overrides.insert(spacing.override)
                view[keyPath: spacing.view] = value
                view.updateAndFlush()
            } else {
                sm.setSpacingForAllSpaces(spacing, to: value)
            }
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(Config.layout) {
        try configLayout(&rsp, domain, command, &message, selSid)
    } else if command.equals(Config.treeOrientation) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: sm.treeDefaultOrientation) {
            sm.treeDefaultOrientation = choice
        }
    } else if command.equals(Config.treeWorkspaceLayout) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: sm.treeWorkspaceTabbed ? WorkspaceLayout.tabbed : .default) {
            sm.treeWorkspaceTabbed = choice == .tabbed
        }
    } else if command.equals(Config.treeAutotiling) {
        _ = try parseConfigBool(&rsp, domain, command, &message, &sm.treeAutotiling)
    } else if command.equals(Config.focusWrapping) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.focusWrapping) {
            wm.focusWrapping = choice
        }
    } else if command.equals(Config.autoPadding) {
        if let selSid {
            var enabled = sm.view(for: selSid).autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPadding(enabled, for: selSid) }
        } else {
            var enabled = sm.autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPaddingForAllSpaces(enabled) }
        }
    } else if command.equals(Config.mouseModifier) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: mouse.modifier) {
            mouse.modifier = choice
        }
    } else if command.equals(Config.mouseAction1) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.move, .resize], current: mouse.action1) {
            mouse.action1 = choice
        }
    } else if command.equals(Config.mouseAction2) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.move, .resize], current: mouse.action2) {
            mouse.action2 = choice
        }
    } else if command.equals(Config.mouseDropAction) {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.swap, .stack], current: mouse.dropAction) {
            mouse.dropAction = choice
        }
    } else if command.equals(Config.externalBar) {
        try configExternalBar(&rsp, domain, command, &message)
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}
