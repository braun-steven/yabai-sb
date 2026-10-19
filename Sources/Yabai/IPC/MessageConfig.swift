import CoreGraphics
import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handler of the config domain. Options print their value when none is given. The options are fields of the
// managers.
//

/// The names and optional space scope accepted by config commands.
private typealias Config = ConfigCommand.Name

/// The layout of the workspace root of new trees (`config tree_workspace_layout`).
private enum WorkspaceLayout: String, CaseIterable
{
    case `default`
    case tabbed
}

@WM private func tabBarColor(for command: Config) -> ReferenceWritableKeyPath<WindowManager, RGBAColor>?
{
    if command == .tabBarFocusedColor       { return \.tabBarFocusedColor }
    if command == .tabBarFocusedTextColor   { return \.tabBarFocusedTextColor }
    if command == .tabBarInactiveColor      { return \.tabBarInactiveColor }
    if command == .tabBarInactiveTextColor  { return \.tabBarInactiveTextColor }
    if command == .tabBarUnfocusedColor     { return \.tabBarUnfocusedColor }
    if command == .tabBarUnfocusedTextColor { return \.tabBarUnfocusedTextColor }
    if command == .tabBarBackdropColor      { return \.tabBarBackdropColor }
    return nil
}

@WM private func tabBarColorCustom(for command: Config) -> ReferenceWritableKeyPath<WindowManager, Bool>?
{
    if command == .tabBarFocusedColor   { return \.tabBarFocusedColorIsCustom }
    if command == .tabBarInactiveColor  { return \.tabBarInactiveColorIsCustom }
    if command == .tabBarUnfocusedColor { return \.tabBarUnfocusedColorIsCustom }
    if command == .tabBarBackdropColor  { return \.tabBarBackdropColorIsCustom }
    if command == .tabBarFocusedTextColor   { return \.tabBarFocusedTextColorIsCustom }
    if command == .tabBarInactiveTextColor  { return \.tabBarInactiveTextColorIsCustom }
    if command == .tabBarUnfocusedTextColor { return \.tabBarUnfocusedTextColorIsCustom }
    return nil
}

@WM private func configScratchpadGrid(_ rsp: inout Response, _ domain: Token, _ name: Config, _ message: inout some TokenSource) throws(CommandError)
{
    let command = Token(name.rawValue)
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
        throw CommandError("command '\(command)' for domain '\(domain)' does not support the '--space' selector\n", stopsMessage: true)
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

private func spacing(for command: Config) -> ViewSpacing?
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

@WM private func configBorder(_ rsp: inout Response, _ domain: Token, _ name: Config, _ message: inout some TokenSource) throws(CommandError) -> Bool
{
    let wm = WindowManager.shared
    let command = Token(name.rawValue)

    if name == .windowBorder {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.windowBorderEnabled) { Border.refreshAll() }
    } else if name == .windowBorderHideSingle {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.windowBorderHideSingle) { Border.refreshAll() }
    } else if name == .windowBorderWidth {
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
    } else if name == .activeWindowBorderColor {
        if try configColor(&rsp, domain, command, &message, &wm.activeWindowBorderColor) { Border.refreshAll() }
    } else if name == .normalWindowBorderColor {
        if try configColor(&rsp, domain, command, &message, &wm.normalWindowBorderColor) { Border.refreshAll() }
    } else {
        return false
    }

    return true
}

//
// NOTE: The tab_bar options. Returns false when command is not one of them.
//

@WM private func configTabBar(_ rsp: inout Response, _ domain: Token, _ name: Config, _ message: inout some TokenSource) throws(CommandError) -> Bool
{
    let wm = WindowManager.shared
    let command = Token(name.rawValue)

    if name == .tabBar {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.tabBarEnabled) { TabBar.refreshAll() }
    } else if name == .tabBarHeight {
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
    } else if name == .tabBarOffset {
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
    } else if name == .tabBarIcons {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.tabBarIcons) { TabBar.redrawAll() }
    } else if name == .tabBarStyle {
        if let style = try parseConfigChoice(&rsp, domain, command, &message, current: wm.tabBarStyle) {
            wm.tabBarStyle = style
            TabBar.refreshAll()
        }
    } else if name == .tabBarAppearance {
        if let appearance = try parseConfigChoice(&rsp, domain, command, &message, current: wm.tabBarAppearance) {
            wm.tabBarAppearance = appearance
            TabBar.redrawAll()
        }
    } else if name == .tabBarBackdrop {
        if let backdrop = try parseConfigChoice(&rsp, domain, command, &message, current: wm.tabBarBackdrop) {
            wm.tabBarBackdrop = backdrop
            TabBar.refreshAll()
        }
    } else if name == .tabBarCardPadding {
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
    } else if name == .tabBarWindowRadius {
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
    } else if name == .tabBarFont {
        let value = message.next()
        if !value.isValid {
            rsp.write("\(Token(wm.tabBarFontName))\n")
        } else if let name = String(validating: value.bytes, as: UTF8.self), TabBar.setFont(name) {
            TabBar.redrawAll()
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if let color = tabBarColor(for: name) {
        if try configColor(&rsp, domain, command, &message, &wm[keyPath: color]) {
            if let custom = tabBarColorCustom(for: name) { wm[keyPath: custom] = true }
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
@WM private func handleConfigCommand(_ rsp: inout Response, _ domain: Token, _ name: Config, _ message: inout some TokenSource, _ selSid: SpaceID?) throws(CommandError)
{
    let command = Token(name.rawValue)
    let wm = WindowManager.shared
    let sm = SpaceManager.shared
    let dm = DisplayManager.shared
    let mouse = MouseState.shared

    if try configBorder(&rsp, domain, name, &message)  { return }
    if try configTabBar(&rsp, domain, name, &message) { return }

    if name == .debugOutput {
        var verbose = Log.verbose.load(ordering: .relaxed)
        if try parseConfigBool(&rsp, domain, command, &message, &verbose) {
            Log.verbose.store(verbose, ordering: .relaxed)
        }
    } else if name == .mouseFollowsFocus {
        _ = try parseConfigBool(&rsp, domain, command, &message, &wm.mouseFollowsFocusEnabled)
    } else if name == .focusFollowsMouse {
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
    } else if name == .displayArrangementOrder {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: dm.order) {
            dm.order = choice
        }
    } else if name == .builtinDisplayLast {
        if try parseConfigBool(&rsp, domain, command, &message, &dm.builtinDisplayLast) { SpaceManager.shared.scheduleSpaceLayout(after: 0.0, resetPasses: true) }
    } else if name == .windowOriginDisplay {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.windowOriginMode) {
            wm.windowOriginMode = choice
        }
    } else if name == .scratchpadExclusive {
        _ = try parseConfigBool(&rsp, domain, command, &message, &wm.scratchpadExclusive)
    } else if name == .scratchpadRaise {
        _ = try parseConfigBool(&rsp, domain, command, &message, &wm.scratchpadRaise)
    } else if name == .scratchpadBelow {
        if try parseConfigBool(&rsp, domain, command, &message, &wm.scratchpadBelow) { wm.setScratchpadLayers() }
    } else if name == .scratchpadGrid {
        try configScratchpadGrid(&rsp, domain, name, &message)
    } else if name == .skipWindowFocusAnimation {
        _ = try parseConfigBool(&rsp, domain, command, &message, &sm.skipWindowFocusAnimation)
    } else if name == .spaceLayout {
        try configSpaceLayout(&rsp, domain, command, &message, selSid)
    } else if name == .windowOpacity {
        var enabled = wm.windowOpacityEnabled
        if try parseConfigBool(&rsp, domain, command, &message, &enabled) { wm.setWindowOpacityEnabled(enabled) }
    } else if name == .windowOpacityDuration {
        let token = message.next()
        let value = token.value
        if case .invalid = value {
            rsp.write("\(cFormat("%f", Double(wm.windowOpacityDuration)))\n")
        } else if let duration = value.floatValue {
            wm.windowOpacityDuration = duration
        } else {
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if name == .windowAnimationDuration {
        try configAnimationDuration(&rsp, domain, command, &message)
    } else if name == .windowAnimationEasing {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.windowAnimationEasing) {
            wm.windowAnimationEasing = choice
        }
    } else if name == .windowShadow {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.purifyMode) {
            wm.setPurifyMode(choice)
        }
    } else if name == .menubarOpacity {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: wm.menuBarOpacity, allowZero: true) { wm.setMenuBarOpacity(opacity) }
    } else if name == .activeWindowOpacity {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: wm.activeWindowOpacity, allowZero: false) { wm.setActiveWindowOpacity(opacity) }
    } else if name == .normalWindowOpacity {
        if let opacity = try configOpacity(&rsp, domain, command, &message, current: wm.normalWindowOpacity, allowZero: false) { wm.setNormalWindowOpacity(opacity) }
    } else if name == .insertFeedbackColor {
        _ = try configColor(&rsp, domain, command, &message, &wm.insertionFeedbackColor, allowZero: false)
    } else if let spacing = spacing(for: name) {
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
    } else if name == .layout {
        try configLayout(&rsp, domain, command, &message, selSid)
    } else if name == .treeDefaultOrientation {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: sm.treeDefaultOrientation) {
            sm.treeDefaultOrientation = choice
        }
    } else if name == .treeWorkspaceLayout {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: sm.treeWorkspaceTabbed ? WorkspaceLayout.tabbed : .default) {
            sm.treeWorkspaceTabbed = choice == .tabbed
        }
    } else if name == .treeAutotiling {
        _ = try parseConfigBool(&rsp, domain, command, &message, &sm.treeAutotiling)
    } else if name == .focusWrapping {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: wm.focusWrapping) {
            wm.focusWrapping = choice
        }
    } else if name == .autoPadding {
        if let selSid {
            var enabled = sm.view(for: selSid).autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPadding(enabled, for: selSid) }
        } else {
            var enabled = sm.autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPaddingForAllSpaces(enabled) }
        }
    } else if name == .mouseModifier {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, current: mouse.modifier) {
            mouse.modifier = choice
        }
    } else if name == .mouseAction1 {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.move, .resize], current: mouse.action1) {
            mouse.action1 = choice
        }
    } else if name == .mouseAction2 {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.move, .resize], current: mouse.action2) {
            mouse.action2 = choice
        }
    } else if name == .mouseDropAction {
        if let choice = try parseConfigChoice(&rsp, domain, command, &message, [.swap, .stack], current: mouse.dropAction) {
            mouse.dropAction = choice
        }
    } else if name == .externalBar {
        try configExternalBar(&rsp, domain, command, &message)
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}
