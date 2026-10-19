import CoreGraphics
import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handler of the config domain. Options print their value when none is given. Values live in Config or their
// owning manager.
//

/// The names and optional space scope accepted by config commands.
private typealias ConfigName = ConfigCommand.Name

/// The layout of the workspace root of new trees (`config tree_workspace_layout`).
private enum WorkspaceLayout: String, CaseIterable
{
    case `default`
    case tabbed
}

@WM private func tabBarColor(for command: ConfigName) -> WritableKeyPath<TabBarConfig, RGBAColor>?
{
    if command == .tabBarFocusedColor       { return \.focusedColor }
    if command == .tabBarFocusedTextColor   { return \.focusedTextColor }
    if command == .tabBarInactiveColor      { return \.inactiveColor }
    if command == .tabBarInactiveTextColor  { return \.inactiveTextColor }
    if command == .tabBarUnfocusedColor     { return \.unfocusedColor }
    if command == .tabBarUnfocusedTextColor { return \.unfocusedTextColor }
    if command == .tabBarBackdropColor      { return \.backdropColor }
    return nil
}

@WM private func tabBarColorCustom(for command: ConfigName) -> WritableKeyPath<TabBarConfig, Bool>?
{
    if command == .tabBarFocusedColor       { return \.focusedColorIsCustom }
    if command == .tabBarInactiveColor      { return \.inactiveColorIsCustom }
    if command == .tabBarUnfocusedColor     { return \.unfocusedColorIsCustom }
    if command == .tabBarBackdropColor      { return \.backdropColorIsCustom }
    if command == .tabBarFocusedTextColor   { return \.focusedTextColorIsCustom }
    if command == .tabBarInactiveTextColor  { return \.inactiveTextColorIsCustom }
    if command == .tabBarUnfocusedTextColor { return \.unfocusedTextColorIsCustom }
    return nil
}

@WM private func configScratchpadGrid(_ rsp: inout Response, _ domain: Token, _ name: ConfigName, _ message: inout some TokenSource) throws(CommandError)
{
    let command = Token(name.rawValue)
    let value = message.next()

    if !value.isValid {
        let grid = Config.current.scratchpad.scratchpadGrid
        if grid.rows == 0 || grid.columns == 0 {
            rsp.write("\(Argument.off)\n")
        } else {
            let values = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height]
            rsp.write("\(values.map { String($0) }.joined(separator: ":"))\n")
        }
    } else if value.equals(Argument.off) {
        Config.current.scratchpad.scratchpadGrid = Grid()
    } else {
        // NOTE: like the C version, "%d" writes into unsigned values, so a negative row or column count passes the check
        var grid = Grid()
        if grid.scan(value) == 6 && grid.rows > 0 && grid.columns > 0 {
            Config.current.scratchpad.scratchpadGrid = grid
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
    if selSid != nil {
        throw CommandError("command '\(command)' for domain '\(domain)' does not support the '--space' selector\n", stopsMessage: true)
    }

    var value = message.next()

    if !value.isValid {
        if let spec = Config.current.space.spaceLayoutSpec {
            rsp.write("\(Token(spec))\n")
        } else {
            rsp.write("\(Argument.off)\n")
        }
        return
    }

    if value.equals(Argument.off) {
        Config.current.space.spaceLayoutSpec = nil
        Config.current.space.spaceLayouts = []
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

    Config.current.space.spaceLayouts = layoutList
    Config.current.space.spaceLayoutSpec = String(decoding: spec, as: UTF8.self)
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
    let token = message.next()
    let value = token.value

    if case .invalid = value {
        rsp.write("\(cFormat("%f", Double(Config.current.animation.windowAnimationDuration)))\n")
    } else if let duration = value.floatValue {
        if duration == 0.0 {
            Config.current.animation.windowAnimationDuration = duration
        } else if !ScriptingAddition.shared.isSIPFriendly {
            throw CommandError("command '\(command)' for domain '\(domain)' requires System Integrity Protection to be partially disabled! ignoring request..\n")
        } else if CGPreflightScreenCaptureAccess() {
            Config.current.animation.windowAnimationDuration = duration
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
        let layout = selSid.map { sm.view(for: $0).layout } ?? Config.current.space.layout
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
        rsp.write("\(Config.current.display.mode.rawValue):\(Config.current.display.topPadding):\(Config.current.display.bottomPadding)\n")
        return
    }

    let modeToken = mode.withUnsafeBufferPointer { Token(cString: $0.baseAddress) }
    if let choice = ExternalBarMode.allCases.first(where: { modeToken.equals($0.rawValue) }) {
        Config.current.display.mode = choice
        Config.current.display.topPadding = Int(top)
        Config.current.display.bottomPadding = Int(bottom)
        SpaceManager.shared.markSpacesInvalid()
        return
    }

    throw CommandError("unknown mode '\(modeToken)' specified in value '\(value)' given to command '\(command)' for domain '\(domain)'\n")
}

private func spacing(for command: ConfigName) -> ViewSpacing?
{
    if command == .topPadding    { return .topPadding }
    if command == .bottomPadding { return .bottomPadding }
    if command == .leftPadding   { return .leftPadding }
    if command == .rightPadding  { return .rightPadding }
    if command == .windowGap     { return .windowGap }
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

@WM private func configBorder(_ rsp: inout Response, _ domain: Token, _ name: ConfigName, _ message: inout some TokenSource) throws(CommandError) -> Bool
{
    var border = Config.current.border
    let command = Token(name.rawValue)
    var refresh = false

    if name == .windowBorder {
        refresh = try parseConfigBool(&rsp, domain, command, &message, &border.enabled)
    } else if name == .windowBorderHideSingle {
        refresh = try parseConfigBool(&rsp, domain, command, &message, &border.hideSingle)
    } else if name == .windowBorderWidth {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%.4f", Double(border.width)))\n")
        } else if let width = value.floatValue, width > 0.0 {
            border.width = width
            refresh = true
        } else {
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .activeWindowBorderColor {
        refresh = try configColor(&rsp, domain, command, &message, &border.activeColor)
    } else if name == .normalWindowBorderColor {
        refresh = try configColor(&rsp, domain, command, &message, &border.normalColor)
    } else {
        return false
    }

    Config.current.border = border
    if refresh { Border.refreshAll() }
    return true
}

//
// NOTE: The tab_bar options. Returns false when command is not one of them.
//

@WM private func configTabBar(_ rsp: inout Response, _ domain: Token, _ name: ConfigName, _ message: inout some TokenSource) throws(CommandError) -> Bool
{
    var tabBar = Config.current.tabBar
    let command = Token(name.rawValue)
    var refresh = false
    var redraw = false

    if name == .tabBar {
        refresh = try parseConfigBool(&rsp, domain, command, &message, &tabBar.enabled)
    } else if name == .tabBarHeight {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(tabBar.height)\n")
        case .int(let height) where height > 0:
            tabBar.height = height
            refresh = true
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .tabBarOffset {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(tabBar.offset)\n")
        case .int(let offset):
            tabBar.offset = offset
            refresh = true
        case .float(let offset) where offset == Float(cInt(offset)):
            tabBar.offset = cInt(offset)
            refresh = true
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .tabBarIcons {
        redraw = try parseConfigBool(&rsp, domain, command, &message, &tabBar.icons)
    } else if name == .tabBarStyle {
        if let style = try parseConfigChoice(&rsp, domain, command, &message, current: tabBar.style) {
            tabBar.style = style
            refresh = true
        }
    } else if name == .tabBarAppearance {
        if let appearance = try parseConfigChoice(&rsp, domain, command, &message, current: tabBar.appearance) {
            tabBar.appearance = appearance
            redraw = true
        }
    } else if name == .tabBarBackdrop {
        if let backdrop = try parseConfigChoice(&rsp, domain, command, &message, current: tabBar.backdrop) {
            tabBar.backdrop = backdrop
            refresh = true
        }
    } else if name == .tabBarCardPadding {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(tabBar.cardPadding)\n")
        case .int(let padding) where padding >= 0:
            tabBar.cardPadding = padding
            refresh = true
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .tabBarWindowRadius {
        let token = message.next()
        switch token.value {
        case .invalid:
            rsp.write("\(tabBar.windowRadius)\n")
        case .int(let radius) where radius >= 0:
            tabBar.windowRadius = radius
            redraw = true
        default:
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .tabBarFont {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(Token(tabBar.fontName))\n")
        } else if let name = String(validating: value.bytes, as: UTF8.self), TabBar.setFont(name) {
            tabBar.fontName = name
            redraw = true
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if let color = tabBarColor(for: name) {
        if try configColor(&rsp, domain, command, &message, &tabBar[keyPath: color]) {
            if let custom = tabBarColorCustom(for: name) { tabBar[keyPath: custom] = true }
            redraw = true
        }
    } else {
        return false
    }

    Config.current.tabBar = tabBar
    if refresh { TabBar.refreshAll() }
    else if redraw { TabBar.redrawAll() }
    return true
}

/// `handle_domain_config`
@WM func handleDomainConfig(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    var selSid: SpaceID?
    let (spaceSelector, command) = try ConfigCommand.parseScope(message.next(), &message)
    if let spaceSelector {
        guard let target = try spaceSelector.resolve(acting: nil, CSelectorContext()) else { return }
        selSid = target
    }

    try runCommands(&rsp, &message, from: command) { (rsp, source, command) throws(CommandError) -> Bool in
        try handleConfigCommand(&rsp, domain, try ConfigCommand.parseName(command), &source, selSid)
        return true
    }
}

/// One command of the config domain.
@WM private func handleConfigCommand(_ rsp: inout Response, _ domain: Token, _ name: ConfigName, _ message: inout some TokenSource, _ selSid: SpaceID?) throws(CommandError)
{
    let command = Token(name.rawValue)
    let wm = WindowManager.shared
    let sm = SpaceManager.shared

    if try configBorder(&rsp, domain, name, &message)  { return }
    if try configTabBar(&rsp, domain, name, &message) { return }

    if name == .debugOutput {
        var verbose = Log.verbose.load(ordering: .relaxed)
        if try parseConfigBool(&rsp, domain, command, &message, &verbose) {
            Log.verbose.store(verbose, ordering: .relaxed)
        }
    } else if name == .mouseFollowsFocus {
        _ = try parseConfigBool(&rsp, domain, command, &message, &Config.current.window.mouseFollowsFocusEnabled)
    } else if name == .focusFollowsMouse {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(Config.current.window.focusFollowsMouseMode.rawValue)\n")
        } else if value.equals(Argument.off) {
            wm.setFocusFollowsMouse(.disabled)
        } else if let mode = [FocusFollowsMouse.autofocus, .autoraise].first(where: { value.equals($0.rawValue) }) {
            wm.setFocusFollowsMouse(mode)
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if name == .displayArrangementOrder {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.display.order) {
            Config.current.display.order = choice
        }
    } else if name == .builtinDisplayLast {
        if try parseConfigBool(&rsp, domain, command, &message, &Config.current.display.builtinDisplayLast) { SpaceManager.shared.scheduleSpaceLayout(after: 0.0, resetPasses: true) }
    } else if name == .windowOriginDisplay {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.window.windowOriginMode) {
            Config.current.window.windowOriginMode = choice
        }
    } else if name == .scratchpadExclusive {
        _ = try parseConfigBool(&rsp, domain, command, &message, &Config.current.scratchpad.scratchpadExclusive)
    } else if name == .scratchpadRaise {
        _ = try parseConfigBool(&rsp, domain, command, &message, &Config.current.scratchpad.scratchpadRaise)
    } else if name == .scratchpadBelow {
        if try parseConfigBool(&rsp, domain, command, &message, &Config.current.scratchpad.scratchpadBelow) { wm.setScratchpadLayers() }
    } else if name == .scratchpadGrid {
        try configScratchpadGrid(&rsp, domain, name, &message)
    } else if name == .skipWindowFocusAnimation {
        _ = try parseConfigBool(&rsp, domain, command, &message, &Config.current.space.skipWindowFocusAnimation)
    } else if name == .spaceLayout {
        try configSpaceLayout(&rsp, domain, command, &message, selSid)
    } else if name == .windowOpacity {
        var enabled = Config.current.window.windowOpacityEnabled
        if try parseConfigBool(&rsp, domain, command, &message, &enabled) { wm.setWindowOpacityEnabled(enabled) }
    } else if name == .windowOpacityDuration {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%f", Double(Config.current.window.windowOpacityDuration)))\n")
        } else if let duration = value.floatValue {
            Config.current.window.windowOpacityDuration = duration
        } else {
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .windowAnimationDuration {
        try configAnimationDuration(&rsp, domain, command, &message)
    } else if name == .windowAnimationEasing {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.animation.windowAnimationEasing) {
            Config.current.animation.windowAnimationEasing = choice
        }
    } else if name == .windowShadow {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.window.purifyMode) {
            wm.setPurifyMode(choice)
        }
    } else if name == .menubarOpacity {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: Config.current.window.menuBarOpacity, allowZero: true) { wm.setMenuBarOpacity(opacity) }
    } else if name == .activeWindowOpacity {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: Config.current.window.activeWindowOpacity, allowZero: false) { wm.setActiveWindowOpacity(opacity) }
    } else if name == .normalWindowOpacity {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: Config.current.window.normalWindowOpacity, allowZero: false) { wm.setNormalWindowOpacity(opacity) }
    } else if name == .insertFeedbackColor {
        _ = try configColor(&rsp, domain, command, &message, &Config.current.window.insertionFeedbackColor, allowZero: false)
    } else if let spacing = spacing(for: name) {
        let view = selSid.map { sm.view(for: $0) }
        let current = view.map { $0[keyPath: spacing.view] } ?? Config.current.space[keyPath: spacing.spaceManager]
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
    } else if name == .layout {
        try configLayout(&rsp, domain, command, &message, selSid)
    } else if name == .treeDefaultOrientation {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.space.treeDefaultOrientation) {
            Config.current.space.treeDefaultOrientation = choice
        }
    } else if name == .treeWorkspaceLayout {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.space.treeWorkspaceTabbed ? WorkspaceLayout.tabbed : .default) {
            Config.current.space.treeWorkspaceTabbed = choice == .tabbed
        }
    } else if name == .treeAutotiling {
        _ = try parseConfigBool(&rsp, domain, command, &message, &Config.current.space.treeAutotiling)
    } else if name == .focusWrapping {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.window.focusWrapping) {
            Config.current.window.focusWrapping = choice
        }
    } else if name == .autoPadding {
        if let selSid {
            var enabled = sm.view(for: selSid).autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPadding(enabled, for: selSid) }
        } else {
            var enabled = Config.current.space.autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPaddingForAllSpaces(enabled) }
        }
    } else if name == .mouseModifier {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: Config.current.mouse.modifier) {
            Config.current.mouse.modifier = choice
            MouseState.shared.tap.modifier = choice
        }
    } else if name == .mouseAction1 {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.move, .resize], current: Config.current.mouse.action1) {
            Config.current.mouse.action1 = choice
        }
    } else if name == .mouseAction2 {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.move, .resize], current: Config.current.mouse.action2) {
            Config.current.mouse.action2 = choice
        }
    } else if name == .mouseDropAction {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.swap, .stack], current: Config.current.mouse.dropAction) {
            Config.current.mouse.dropAction = choice
        }
    } else if name == .externalBar {
        try configExternalBar(&rsp, domain, command, &message)
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}
