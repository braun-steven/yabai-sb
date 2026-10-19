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
typealias ConfigName = ConfigCommand.Name

/// The layout of the workspace root of new trees (`config tree_workspace_layout`).
private enum WorkspaceLayout: String, CaseIterable
{
    case `default`
    case tabbed
}

private typealias ConfigMutation = @WM () throws(CommandError) -> Void

@WM private struct ConfigOption
{
    let name: ConfigName
    let print: @WM (inout Response, SpaceID?) -> Void
    let parse: @WM (Token, Token, inout Message, SpaceID?) throws(CommandError) -> ConfigMutation?
    let apply: @WM (ConfigMutation) throws(CommandError) -> Void
}

@WM private func configOption(_ name: ConfigName, print: @escaping @WM (inout Response, SpaceID?) -> Void, parse: @escaping @WM (Token, Token, inout Message, SpaceID?) throws(CommandError) -> ConfigMutation?) -> ConfigOption
{
    ConfigOption(name: name, print: print, parse: parse, apply: { (mutation: ConfigMutation) throws(CommandError) in try mutation() })
}

@WM private func boolOption(_ name: ConfigName, get: @escaping @WM () -> Bool, set: @escaping @WM (Bool) -> Void, applyChange: (@WM (Bool) -> Void)? = nil) -> ConfigOption
{
    configOption(name, print: { rsp, _ in rsp.write("\(boolString(get()))\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        let value: Bool
        if token.equals(Argument.on) { value = true }
        else if token.equals(Argument.off) { value = false }
        else { throw CommandError.unknownValue(domain, command, token) }
        return { set(value); applyChange?(value) }
    })
}

@WM private func choiceOption<Choice: RawRepresentable>(_ name: ConfigName, choices: [Choice], get: @escaping @WM () -> Choice, set: @escaping @WM (Choice) -> Void, applyChange: (@WM (Choice) -> Void)? = nil) -> ConfigOption where Choice.RawValue == String
{
    configOption(name, print: { rsp, _ in rsp.write("\(get().rawValue)\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        guard let value = choices.first(where: { token.equals($0.rawValue) }) else { throw CommandError.unknownValue(domain, command, token) }
        return { set(value); applyChange?(value) }
    })
}

@WM private func integerOption(_ name: ConfigName, get: @escaping @WM () -> Int, printValue: @escaping @WM (Int) -> String = { String($0) }, parseValue: @escaping @WM (Token) -> Int?, set: @escaping @WM (Int) -> Void, applyChange: (@WM () -> Void)? = nil) -> ConfigOption
{
    configOption(name, print: { rsp, _ in rsp.write("\(printValue(get()))\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        guard let value = parseValue(token) else { throw CommandError.unknownValue(domain, command, token) }
        return { set(value); applyChange?() }
    })
}

@WM private func floatOption(_ name: ConfigName, get: @escaping @WM () -> Float, printValue: @escaping @WM (Float) -> String, parseValue: @escaping @WM (Token) -> Float?, apply: @escaping @WM (Float) -> Void) -> ConfigOption
{
    configOption(name, print: { rsp, _ in rsp.write("\(printValue(get()))\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        guard let value = parseValue(token) else { throw CommandError.unknownValue(domain, command, token) }
        return { apply(value) }
    })
}

@WM private func colorOption(_ name: ConfigName, get: @escaping @WM () -> RGBAColor, set: @escaping @WM (RGBAColor) -> Void, allowZero: Bool = true, markCustom: (@WM () -> Void)? = nil, applyChange: (@WM () -> Void)? = nil) -> ConfigOption
{
    configOption(name, print: { rsp, _ in rsp.write("0x\(String(get().argb, radix: 16))\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        guard case .u32(let value) = token.value, allowZero || value != 0 else { throw CommandError.unknownValue(domain, command, token) }
        let color = RGBAColor(hex: value)
        return { set(color); markCustom?(); applyChange?() }
    })
}

@WM private func focusFollowsMouseOption() -> ConfigOption
{
    configOption(.focusFollowsMouse, print: { rsp, _ in rsp.write("\(Config.current.window.focusFollowsMouseMode.rawValue)\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        let value: FocusFollowsMouse
        if token.equals(Argument.off) { value = .disabled }
        else if let choice = [FocusFollowsMouse.autofocus, .autoraise].first(where: { token.equals($0.rawValue) }) { value = choice }
        else { throw CommandError.unknownValue(domain, command, token) }
        return { WindowManager.shared.setFocusFollowsMouse(value) }
    })
}

@WM private func scratchpadGridOption() -> ConfigOption
{
    configOption(.scratchpadGrid, print: { rsp, _ in
        let grid = Config.current.scratchpad.scratchpadGrid
        if grid.rows == 0 || grid.columns == 0 { rsp.write("\(Argument.off)\n") }
        else {
            let values = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height]
            rsp.write("\(values.map { String($0) }.joined(separator: ":"))\n")
        }
    }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        if token.equals(Argument.off) { return { Config.current.scratchpad.scratchpadGrid = Grid() } }
        var grid = Grid()
        guard grid.scan(token) == 6, grid.rows > 0, grid.columns > 0 else { throw CommandError.unknownValue(domain, command, token) }
        return { Config.current.scratchpad.scratchpadGrid = grid }
    })
}

@WM private func spaceLayoutOption() -> ConfigOption
{
    configOption(.spaceLayout, print: { rsp, _ in
        if let spec = Config.current.space.spaceLayoutSpec { rsp.write("\(Token(spec))\n") }
        else { rsp.write("\(Argument.off)\n") }
    }, parse: { (domain, command, message, selSid) throws(CommandError) in
        if selSid != nil {
            throw CommandError("command '\(command)' for domain '\(domain)' does not support the '--space' selector\n", stopsMessage: true)
        }
        var token = message.next()
        guard token.isValid else { return nil }
        if token.equals(Argument.off) {
            return {
                Config.current.space.spaceLayoutSpec = nil
                Config.current.space.spaceLayouts = []
            }
        }

        func isLayout(_ value: Token) -> Bool
        {
            guard let first = value.bytes.first else { return false }
            return first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")
        }

        var layouts: [SpaceLayout] = []
        var spec: [UInt8] = []
        while isLayout(token) {
            guard layouts.count < SpaceLayout.max, let layout = SpaceLayout(parsing: token.bytes) else {
                throw CommandError("invalid value '\(token)' given to command '\(command)' for domain '\(domain)'\n", stopsMessage: true)
            }
            if let repeated = layouts.first(where: { $0.count == layout.count }) {
                throw CommandError("value '\(token)' given to command '\(command)' for domain '\(domain)' repeats a layout for \(repeated.count) display(s)\n", stopsMessage: true)
            }
            if !layouts.isEmpty { spec.append(UInt8(ascii: " ")) }
            spec += token.bytes
            if spec.count >= 256 {
                throw CommandError("value given to command '\(command)' for domain '\(domain)' is too long\n", stopsMessage: true)
            }
            layouts.append(layout)
            guard isLayout(message.peek()) else { break }
            token = message.next()
        }
        guard !layouts.isEmpty else { throw CommandError.unknownValue(domain, command, token).stoppingMessage }
        let layoutSpec = String(decoding: spec, as: UTF8.self)
        return {
            Config.current.space.spaceLayouts = layouts
            Config.current.space.spaceLayoutSpec = layoutSpec
            SpaceManager.shared.scheduleSpaceLayout(after: 0.0, resetPasses: true)
        }
    })
}

@WM private func animationDurationOption() -> ConfigOption
{
    configOption(.windowAnimationDuration, print: { rsp, _ in rsp.write("\(cFormat("%f", Double(Config.current.animation.windowAnimationDuration)))\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        guard let duration = token.value.floatValue else { throw CommandError.unknownValue(domain, command, token) }
        return { () throws(CommandError) in
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
        }
    })
}

@WM private func tabBarFontOption() -> ConfigOption
{
    configOption(.tabBarFont, print: { rsp, _ in rsp.write("\(Token(Config.current.tabBar.fontName))\n") }, parse: { (domain, command, message, _) throws(CommandError) in
        let token = message.next()
        guard token.isValid else { return nil }
        guard let fontName = String(validating: token.bytes, as: UTF8.self) else { throw CommandError.unknownValue(domain, command, token) }
        return { () throws(CommandError) in
            guard TabBar.setFont(fontName) else { throw CommandError.unknownValue(domain, command, token) }
            TabBar.redrawAll()
        }
    })
}

@WM private func externalBarOption() -> ConfigOption
{
    configOption(.externalBar, print: { rsp, _ in
        let display = Config.current.display
        rsp.write("\(display.mode.rawValue):\(display.topPadding):\(display.bottomPadding)\n")
    }, parse: { (domain, command, message, _) throws(CommandError) in
        let value = message.next()
        var mode = [CChar](repeating: 0, count: 6)
        var top: Int32 = 0
        var bottom: Int32 = 0
        let count = mode.withUnsafeMutableBufferPointer { m in
            withUnsafeMutablePointer(to: &top) { t in
                withUnsafeMutablePointer(to: &bottom) { b in value.scan("%5[^:]:%d:%d", m.baseAddress!, t, b) }
            }
        }
        guard count == 3 else { return nil }
        let modeToken = mode.withUnsafeBufferPointer { Token(cString: $0.baseAddress) }
        guard let choice = ExternalBarMode.allCases.first(where: { modeToken.equals($0.rawValue) }) else {
            throw CommandError("unknown mode '\(modeToken)' specified in value '\(value)' given to command '\(command)' for domain '\(domain)'\n")
        }
        let topPadding = Int(top)
        let bottomPadding = Int(bottom)
        return {
            Config.current.display.mode = choice
            Config.current.display.topPadding = topPadding
            Config.current.display.bottomPadding = bottomPadding
            SpaceManager.shared.markSpacesInvalid()
        }
    })
}

@WM private let configOptions: [ConfigOption] = [
    boolOption(.debugOutput, get: { Log.verbose.load(ordering: .relaxed) }, set: { Log.verbose.store($0, ordering: .relaxed) }),
    boolOption(.mouseFollowsFocus, get: { Config.current.window.mouseFollowsFocusEnabled }, set: { Config.current.window.mouseFollowsFocusEnabled = $0 }),
    focusFollowsMouseOption(),
    choiceOption(.displayArrangementOrder, choices: DisplayArrangementOrder.allCases, get: { Config.current.display.order }, set: { Config.current.display.order = $0 }),
    boolOption(.builtinDisplayLast, get: { Config.current.display.builtinDisplayLast }, set: { Config.current.display.builtinDisplayLast = $0 }, applyChange: { _ in SpaceManager.shared.scheduleSpaceLayout(after: 0.0, resetPasses: true) }),
    choiceOption(.windowOriginDisplay, choices: WindowOrigin.allCases, get: { Config.current.window.windowOriginMode }, set: { Config.current.window.windowOriginMode = $0 }),
    boolOption(.scratchpadExclusive, get: { Config.current.scratchpad.scratchpadExclusive }, set: { Config.current.scratchpad.scratchpadExclusive = $0 }),
    boolOption(.scratchpadRaise, get: { Config.current.scratchpad.scratchpadRaise }, set: { Config.current.scratchpad.scratchpadRaise = $0 }),
    boolOption(.scratchpadBelow, get: { Config.current.scratchpad.scratchpadBelow }, set: { Config.current.scratchpad.scratchpadBelow = $0 }, applyChange: { _ in WindowManager.shared.setScratchpadLayers() }),
    boolOption(.skipWindowFocusAnimation, get: { Config.current.space.skipWindowFocusAnimation }, set: { Config.current.space.skipWindowFocusAnimation = $0 }),
    boolOption(.windowOpacity, get: { Config.current.window.windowOpacityEnabled }, set: { _ in }, applyChange: { WindowManager.shared.setWindowOpacityEnabled($0) }),
    choiceOption(.windowAnimationEasing, choices: AnimationEasing.allCases, get: { Config.current.animation.windowAnimationEasing }, set: { Config.current.animation.windowAnimationEasing = $0 }),
    choiceOption(.windowShadow, choices: PurifyMode.allCases, get: { Config.current.window.purifyMode }, set: { _ in }, applyChange: { WindowManager.shared.setPurifyMode($0) }),
    choiceOption(.treeDefaultOrientation, choices: TreeOrientation.allCases, get: { Config.current.space.treeDefaultOrientation }, set: { Config.current.space.treeDefaultOrientation = $0 }),
    choiceOption(.treeWorkspaceLayout, choices: WorkspaceLayout.allCases, get: { Config.current.space.treeWorkspaceTabbed ? .tabbed : .default }, set: { Config.current.space.treeWorkspaceTabbed = $0 == .tabbed }),
    boolOption(.treeAutotiling, get: { Config.current.space.treeAutotiling }, set: { Config.current.space.treeAutotiling = $0 }),
    choiceOption(.focusWrapping, choices: FocusWrapping.allCases, get: { Config.current.window.focusWrapping }, set: { Config.current.window.focusWrapping = $0 }),
    choiceOption(.mouseModifier, choices: MouseModifierKey.allCases, get: { Config.current.mouse.modifier }, set: { Config.current.mouse.modifier = $0 }, applyChange: { MouseState.shared.tap.modifier = $0 }),
    choiceOption(.mouseAction1, choices: [.move, .resize], get: { Config.current.mouse.action1 }, set: { Config.current.mouse.action1 = $0 }),
    choiceOption(.mouseAction2, choices: [.move, .resize], get: { Config.current.mouse.action2 }, set: { Config.current.mouse.action2 = $0 }),
    choiceOption(.mouseDropAction, choices: [.swap, .stack], get: { Config.current.mouse.dropAction }, set: { Config.current.mouse.dropAction = $0 }),
    boolOption(.windowBorder, get: { Config.current.border.enabled }, set: { Config.current.border.enabled = $0 }, applyChange: { _ in Border.refreshAll() }),
    boolOption(.windowBorderHideSingle, get: { Config.current.border.hideSingle }, set: { Config.current.border.hideSingle = $0 }, applyChange: { _ in Border.refreshAll() }),
    boolOption(.tabBar, get: { Config.current.tabBar.enabled }, set: { Config.current.tabBar.enabled = $0 }, applyChange: { _ in TabBar.refreshAll() }),
    boolOption(.tabBarIcons, get: { Config.current.tabBar.icons }, set: { Config.current.tabBar.icons = $0 }, applyChange: { _ in TabBar.redrawAll() }),
    choiceOption(.tabBarStyle, choices: TabBarStyle.allCases, get: { Config.current.tabBar.style }, set: { Config.current.tabBar.style = $0 }, applyChange: { _ in TabBar.refreshAll() }),
    choiceOption(.tabBarAppearance, choices: TabBarAppearance.allCases, get: { Config.current.tabBar.appearance }, set: { Config.current.tabBar.appearance = $0 }, applyChange: { _ in TabBar.redrawAll() }),
    choiceOption(.tabBarBackdrop, choices: TabBarBackdrop.allCases, get: { Config.current.tabBar.backdrop }, set: { Config.current.tabBar.backdrop = $0 }, applyChange: { _ in TabBar.refreshAll() }),
    floatOption(.windowBorderWidth, get: { Config.current.border.width }, printValue: { cFormat("%.4f", Double($0)) }, parseValue: { token in token.value.floatValue.flatMap { $0 > 0.0 ? $0 : nil } }, apply: { Config.current.border.width = $0; Border.refreshAll() }),
    colorOption(.activeWindowBorderColor, get: { Config.current.border.activeColor }, set: { Config.current.border.activeColor = $0 }, applyChange: { Border.refreshAll() }),
    colorOption(.normalWindowBorderColor, get: { Config.current.border.normalColor }, set: { Config.current.border.normalColor = $0 }, applyChange: { Border.refreshAll() }),
    integerOption(.tabBarHeight, get: { Config.current.tabBar.height }, parseValue: { token in if case .int(let value) = token.value, value > 0 { return value }; return nil }, set: { Config.current.tabBar.height = $0 }, applyChange: { TabBar.refreshAll() }),
    integerOption(.tabBarOffset, get: { Config.current.tabBar.offset }, parseValue: { token in
        switch token.value {
        case .int(let value): return value
        case .float(let value) where value == Float(cInt(value)): return cInt(value)
        default: return nil
        }
    }, set: { Config.current.tabBar.offset = $0 }, applyChange: { TabBar.refreshAll() }),
    integerOption(.tabBarCardPadding, get: { Config.current.tabBar.cardPadding }, parseValue: { token in if case .int(let value) = token.value, value >= 0 { return value }; return nil }, set: { Config.current.tabBar.cardPadding = $0 }, applyChange: { TabBar.refreshAll() }),
    integerOption(.tabBarWindowRadius, get: { Config.current.tabBar.windowRadius }, parseValue: { token in if case .int(let value) = token.value, value >= 0 { return value }; return nil }, set: { Config.current.tabBar.windowRadius = $0 }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarFocusedColor, get: { Config.current.tabBar.focusedColor }, set: { Config.current.tabBar.focusedColor = $0 }, markCustom: { Config.current.tabBar.focusedColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarFocusedTextColor, get: { Config.current.tabBar.focusedTextColor }, set: { Config.current.tabBar.focusedTextColor = $0 }, markCustom: { Config.current.tabBar.focusedTextColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarInactiveColor, get: { Config.current.tabBar.inactiveColor }, set: { Config.current.tabBar.inactiveColor = $0 }, markCustom: { Config.current.tabBar.inactiveColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarInactiveTextColor, get: { Config.current.tabBar.inactiveTextColor }, set: { Config.current.tabBar.inactiveTextColor = $0 }, markCustom: { Config.current.tabBar.inactiveTextColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarUnfocusedColor, get: { Config.current.tabBar.unfocusedColor }, set: { Config.current.tabBar.unfocusedColor = $0 }, markCustom: { Config.current.tabBar.unfocusedColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarUnfocusedTextColor, get: { Config.current.tabBar.unfocusedTextColor }, set: { Config.current.tabBar.unfocusedTextColor = $0 }, markCustom: { Config.current.tabBar.unfocusedTextColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    colorOption(.tabBarBackdropColor, get: { Config.current.tabBar.backdropColor }, set: { Config.current.tabBar.backdropColor = $0 }, markCustom: { Config.current.tabBar.backdropColorIsCustom = true }, applyChange: { TabBar.redrawAll() }),
    floatOption(.windowOpacityDuration, get: { Config.current.window.windowOpacityDuration }, printValue: { cFormat("%f", Double($0)) }, parseValue: { $0.value.floatValue }, apply: { Config.current.window.windowOpacityDuration = $0 }),
    floatOption(.menubarOpacity, get: { Config.current.window.menuBarOpacity }, printValue: { cFormat("%.4f", Double($0)) }, parseValue: { token in token.value.floatValue.flatMap { $0 >= 0.0 && $0 <= 1.0 ? $0 : nil } }, apply: { WindowManager.shared.setMenuBarOpacity($0) }),
    floatOption(.activeWindowOpacity, get: { Config.current.window.activeWindowOpacity }, printValue: { cFormat("%.4f", Double($0)) }, parseValue: { token in token.value.floatValue.flatMap { $0 > 0.0 && $0 <= 1.0 ? $0 : nil } }, apply: { WindowManager.shared.setActiveWindowOpacity($0) }),
    floatOption(.normalWindowOpacity, get: { Config.current.window.normalWindowOpacity }, printValue: { cFormat("%.4f", Double($0)) }, parseValue: { token in token.value.floatValue.flatMap { $0 > 0.0 && $0 <= 1.0 ? $0 : nil } }, apply: { WindowManager.shared.setNormalWindowOpacity($0) }),
    colorOption(.insertFeedbackColor, get: { Config.current.window.insertionFeedbackColor }, set: { Config.current.window.insertionFeedbackColor = $0 }, allowZero: false),
    scratchpadGridOption(),
    spaceLayoutOption(),
    animationDurationOption(),
    tabBarFontOption(),
    externalBarOption(),
]

@WM let configOptionNames = configOptions.map(\.name)

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
// NOTE: Tab bar offsets accept integral float tokens; conversion saturates at Int32 limits and maps NaN to zero.
//

private func cInt(_ value: Float) -> Int
{
    if value.isNaN { return 0 }
    if value >= Float(Int32.max) { return Int(Int32.max) }
    if value <= Float(Int32.min) { return Int(Int32.min) }
    return Int(value)
}

/// Handles a config message.
@WM func handleDomainConfig(_ rsp: inout Response, _ domain: Token, _ message: inout Message) throws(CommandError)
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
@WM private func handleConfigCommand(_ rsp: inout Response, _ domain: Token, _ name: ConfigName, _ message: inout Message, _ selSid: SpaceID?) throws(CommandError)
{
    let command = Token(name.rawValue)
    let sm = SpaceManager.shared

    if let option = configOptions.first(where: { $0.name == name }) {
        if let mutation = try option.parse(domain, command, &message, selSid) {
            try option.apply(mutation)
        } else {
            option.print(&rsp, selSid)
        }
        return
    }

    if let spacing = spacing(for: name) {
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
    } else if name == .autoPadding {
        if let selSid {
            var enabled = sm.view(for: selSid).autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPadding(enabled, for: selSid) }
        } else {
            var enabled = Config.current.space.autoPadding
            if try parseConfigBool(&rsp, domain, command, &message, &enabled) { sm.setAutoPaddingForAllSpaces(enabled) }
        }
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}
