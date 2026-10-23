import AppKit
import CPrivate
import CoreGraphics
import Darwin
import Synchronization
import YabaiCore

//
// NOTE: The handler of the config domain. Options print their value when none is given. Values live in Config or their
// owning manager.
//

/// The names of the config domain's options.
typealias ConfigName = ConfigCommand.Name

/// The layout of the workspace root of new trees (`config tree_workspace_layout`).
private enum WorkspaceLayout: String, CaseIterable {
  case `default`
  case tabbed
}

/// One option of the config domain. `print` writes the current value (of the space with `--space`); `parse` reads the
/// value and returns the change that applies it, or nil when no value was given. A value is checked completely before
/// anything changes, so a rejected value leaves the config as it was.
@WM private struct ConfigOption {
  typealias Change = @WM () throws(CommandError) -> Void

  let name: ConfigName
  let print: @WM (inout Response, SpaceID?) -> Void
  let parse: @WM (Token, Token, inout Message, SpaceID?) throws(CommandError) -> Change?
}

@WM private func boolOption(
  _ name: ConfigName, get: @escaping @WM () -> Bool, set: @escaping @WM (Bool) -> Void
) -> ConfigOption {
  ConfigOption(
    name: name, print: { rsp, _ in rsp.write("\(boolString(get()))\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      let value = try parseConfigBool(domain, command, token)
      return { set(value) }
    })
}

@WM private func choiceOption<Choice: RawRepresentable>(
  _ name: ConfigName, choices: [Choice], get: @escaping @WM () -> Choice,
  set: @escaping @WM (Choice) -> Void
) -> ConfigOption where Choice.RawValue == String {
  ConfigOption(
    name: name, print: { rsp, _ in rsp.write("\(get().rawValue)\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      let value = try parseConfigChoice(domain, command, token, choices)
      return { set(value) }
    })
}

@WM private func integerOption(
  _ name: ConfigName, get: @escaping @WM () -> Int, parseValue: @escaping @WM (Token) -> Int?,
  expected: String, set: @escaping @WM (Int) -> Void
) -> ConfigOption {
  ConfigOption(
    name: name, print: { rsp, _ in rsp.write("\(get())\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      guard let value = parseValue(token) else {
        throw CommandError.unknownValue(domain, command, token, expected: expected)
      }
      return { set(value) }
    })
}

@WM private func floatOption(
  _ name: ConfigName, get: @escaping @WM () -> Float, printValue: @escaping @WM (Float) -> String,
  parseValue: @escaping @WM (Token) -> Float?, expected: String, set: @escaping @WM (Float) -> Void
) -> ConfigOption {
  ConfigOption(
    name: name, print: { rsp, _ in rsp.write("\(printValue(get()))\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      guard let value = parseValue(token) else {
        throw CommandError.unknownValue(domain, command, token, expected: expected)
      }
      return { set(value) }
    })
}

@WM private func colorOption(
  _ name: ConfigName, get: @escaping @WM () -> RGBAColor, set: @escaping @WM (RGBAColor) -> Void,
  allowZero: Bool = true
) -> ConfigOption {
  let expected =
    allowZero ? "a hex color such as 0xffe1e3e4" : "a non-zero hex color such as 0xffe1e3e4"
  return ConfigOption(
    name: name, print: { rsp, _ in rsp.write("0x\(String(get().argb, radix: 16))\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      guard case .u32(let value) = token.value, allowZero || value != 0 else {
        throw CommandError.unknownValue(domain, command, token, expected: expected)
      }
      let color = RGBAColor(hex: value)
      return { set(color) }
    })
}

@WM private func focusFollowsMouseOption() -> ConfigOption {
  ConfigOption(
    name: .focusFollowsMouse,
    print: { rsp, _ in rsp.write("\(Config.current.window.focusFollowsMouse.rawValue)\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      let value: FocusFollowsMouse
      if token.equals(Argument.off) {
        value = .disabled
      } else {
        value = try parseConfigChoice(
          domain, command, token, [FocusFollowsMouse.autofocus, .autoraise],
          expected: expectedChoices([Argument.off, "autofocus", "autoraise"]))
      }
      return { WindowManager.shared.setFocusFollowsMouse(value) }
    })
}

@WM private func scratchpadGridOption() -> ConfigOption {
  ConfigOption(
    name: .scratchpadGrid,
    print: { rsp, _ in
      let grid = Config.current.scratchpad.grid
      if grid.rows == 0 || grid.columns == 0 {
        rsp.write("\(Argument.off)\n")
      } else {
        let values = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height]
        rsp.write("\(values.map { String($0) }.joined(separator: ":"))\n")
      }
    },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      if token.equals(Argument.off) { return { Config.current.scratchpad.grid = Grid() } }
      var grid = Grid()
      guard grid.parse(token), grid.rows > 0, grid.columns > 0 else {
        throw CommandError.unknownValue(
          domain, command, token,
          expected: "off or rows:columns:x:y:width:height, with rows and columns above 0")
      }
      return { Config.current.scratchpad.grid = grid }
    })
}

//
// NOTE: space_layout takes one layout per display count, e.g. '15 10:5 10:5:1b'. The layouts are the tokens that start
// with a digit, so the next command can follow them. An invalid value stops the remaining commands of the message,
// since its layouts cannot be told apart from the next command. The spec is limited to 255 bytes.
//

@WM private func spaceLayoutOption() -> ConfigOption {
  ConfigOption(
    name: .spaceLayout,
    print: { rsp, _ in
      if let spec = Config.current.space.spaceLayoutSpec {
        rsp.write("\(Token(spec))\n")
      } else {
        rsp.write("\(Argument.off)\n")
      }
    },
    parse: { (domain, command, message, selSid) throws(CommandError) in
      if selSid != nil {
        throw CommandError(
          "command '\(command)' for domain '\(domain)' does not support the '--space' selector\n",
          stopsMessage: true)
      }
      var token = message.next()
      guard token.isValid else { return nil }
      if token.equals(Argument.off) {
        return {
          Config.current.space.spaceLayoutSpec = nil
          Config.current.space.spaceLayouts = []
        }
      }

      func isLayout(_ value: Token) -> Bool {
        guard let first = value.utf8.first else { return false }
        return first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")
      }

      var layouts: [SpaceLayout] = []
      var spec: [UInt8] = []
      while isLayout(token) {
        guard layouts.count < SpaceLayout.max, let layout = SpaceLayout(parsing: token.utf8) else {
          throw CommandError(
            "invalid value '\(token)' given to command '\(command)' for domain '\(domain)'\n",
            stopsMessage: true)
        }
        if let repeated = layouts.first(where: { $0.count == layout.count }) {
          throw CommandError(
            "value '\(token)' given to command '\(command)' for domain '\(domain)' repeats a layout for \(repeated.count) display(s)\n",
            stopsMessage: true)
        }
        if !layouts.isEmpty { spec.append(UInt8(ascii: " ")) }
        spec += token.utf8
        if spec.count >= 256 {
          throw CommandError(
            "value given to command '\(command)' for domain '\(domain)' is too long\n",
            stopsMessage: true)
        }
        layouts.append(layout)
        guard isLayout(message.peek()) else { break }
        token = message.next()
      }
      guard !layouts.isEmpty else {
        throw CommandError.unknownValue(
          domain, command, token, expected: "off or one or more layouts such as 10:5 or 15 10:5:1b"
        ).stoppingMessage
      }
      let layoutSpec = String(decoding: spec, as: UTF8.self)
      return {
        Config.current.space.spaceLayouts = layouts
        Config.current.space.spaceLayoutSpec = layoutSpec
        SpaceManager.shared.scheduleSpaceLayout(after: .zero, resetPasses: true)
      }
    })
}

//
// NOTE: Animations need the scripting addition and Screen Recording permission; 0 turns them off.
//

@WM private func animationDurationOption() -> ConfigOption {
  ConfigOption(
    name: .windowAnimationDuration,
    print: { rsp, _ in rsp.write("\(cFormat("%f", Double(Config.current.animation.duration)))\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      guard let duration = token.value.floatValue else {
        throw CommandError.unknownValue(
          domain, command, token, expected: "a number of seconds (0 turns animations off)")
      }
      return { () throws(CommandError) in
        if duration == 0.0 {
          Config.current.animation.duration = duration
        } else if !ScriptingAddition.shared.isSIPFriendly {
          throw CommandError(
            "command '\(command)' for domain '\(domain)' requires System Integrity Protection to be partially disabled! ignoring request..\n"
          )
        } else if CGPreflightScreenCaptureAccess() {
          Config.current.animation.duration = duration
        } else {
          CGRequestScreenCaptureAccess()
          throw CommandError(
            "command '\(command)' for domain '\(domain)' requires Screen Recording permissions! ignoring request..\n"
          )
        }
      }
    })
}

@WM private func tabBarFontOption() -> ConfigOption {
  ConfigOption(
    name: .tabBarFont, print: { rsp, _ in rsp.write("\(Token(Config.current.tabBar.fontName))\n") },
    parse: { (domain, command, message, _) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      return { () throws(CommandError) in
        guard TabBar.setFont(token.string) else {
          throw CommandError.unknownValue(
            domain, command, token, expected: "a font as family:size, e.g. system:12")
        }
      }
    })
}

@WM private func externalBarOption() -> ConfigOption {
  ConfigOption(
    name: .externalBar,
    print: { rsp, _ in
      let externalBar = Config.current.display.externalBar
      rsp.write(
        "\(externalBar.mode.rawValue):\(externalBar.topPadding):\(externalBar.bottomPadding)\n")
    },
    parse: { (domain, command, message, _) throws(CommandError) in
      let value = message.next()
      let scan = value.scanIntegers(field: 5, count: 2)
      guard scan.assigned == 3, let modeToken = scan.field else { return nil }
      guard let choice = ExternalBarMode(token: modeToken) else {
        throw CommandError(
          "unknown mode '\(modeToken)' specified in value '\(value)' given to command '\(command)' for domain '\(domain)'\n"
        )
      }
      let topPadding = Int(scan.values[0])
      let bottomPadding = Int(scan.values[1])
      return {
        Config.current.display.externalBar.mode = choice
        Config.current.display.externalBar.topPadding = topPadding
        Config.current.display.externalBar.bottomPadding = bottomPadding
        SpaceManager.shared.markSpacesInvalid()
      }
    })
}

@WM private func spacingOption(_ name: ConfigName, spacing: ViewSpacing) -> ConfigOption {
  ConfigOption(
    name: name,
    print: { rsp, selSid in
      let manager = SpaceManager.shared
      let value =
        selSid.map { manager.view(for: $0)[keyPath: spacing.view] }
        ?? Config.current.space[keyPath: spacing.spaceDefault]
      rsp.write("\(value)\n")
    },
    parse: { (domain, command, message, selSid) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      guard case .int(let value) = token.value else {
        throw CommandError.unknownValue(domain, command, token, expected: "a non-negative integer")
      }
      return {
        let manager = SpaceManager.shared
        if let selSid {
          let view = manager.view(for: selSid)
          view.overrides.insert(spacing.override)
          view[keyPath: spacing.view] = value
          view.updateAndFlush()
        } else {
          manager.setSpacingForAllSpaces(spacing, to: value)
        }
      }
    })
}

@WM private func layoutOption() -> ConfigOption {
  ConfigOption(
    name: .layout,
    print: { rsp, selSid in
      let manager = SpaceManager.shared
      let layout = selSid.map { manager.view(for: $0).layout } ?? Config.current.space.layout
      rsp.write("\(layout.rawValue)\n")
    },
    parse: { (domain, command, message, selSid) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      let layouts: [ViewType] = [.float, .tree]
      guard let layout = layouts.first(where: { token.equals($0.rawValue) }) else {
        throw CommandError.unknownValue(
          domain, command, token, expected: expectedChoices(layouts.map(\.rawValue)))
      }
      return { () throws(CommandError) in
        let manager = SpaceManager.shared
        if selSid == nil {
          manager.setLayoutForAllSpaces(layout)
        } else if let selSid, !selSid.isUser {
          throw CommandError("cannot set layout for a macOS fullscreen space!\n")
        } else if let selSid {
          manager.view(for: selSid).overrides.insert(.layout)
          manager.setLayout(layout, for: selSid)
        }
      }
    })
}

@WM private func autoPaddingOption() -> ConfigOption {
  ConfigOption(
    name: .autoPadding,
    print: { rsp, selSid in
      let manager = SpaceManager.shared
      let enabled =
        selSid.map { manager.view(for: $0).autoPadding } ?? Config.current.space.autoPadding
      rsp.write("\(boolString(enabled))\n")
    },
    parse: { (domain, command, message, selSid) throws(CommandError) in
      let token = message.next()
      guard token.isValid else { return nil }
      let enabled = try parseConfigBool(domain, command, token)
      return {
        let manager = SpaceManager.shared
        if let selSid {
          manager.setAutoPadding(enabled, for: selSid)
        } else {
          manager.setAutoPaddingForAllSpaces(enabled)
        }
      }
    })
}

//
// NOTE: Borders, tab bars, opacity and shadows follow Config through ConfigObserver, after the message. The setters
// that do more than store the value change no renderer: they restart the event tap (focus_follows_mouse), mirror the
// modifier for the tap (mouse_modifier), move scratchpads between layers (scratchpad_below) or lay out spaces, which
// the following commands of the message rely on.
//

@WM private let configOptions: [ConfigOption] = [
  boolOption(
    .debugOutput, get: { Log.verbose.load(ordering: .relaxed) },
    set: { Log.verbose.store($0, ordering: .relaxed) }),
  boolOption(
    .mouseFollowsFocus, get: { Config.current.window.mouseFollowsFocus },
    set: { Config.current.window.mouseFollowsFocus = $0 }),
  focusFollowsMouseOption(),
  choiceOption(
    .displayArrangementOrder, choices: DisplayArrangementOrder.allCases,
    get: { Config.current.display.order },
    set: {
      Config.current.display.order = $0
      DisplayManager.shared.invalidateSpaceCaches()
    }),
  boolOption(
    .builtinDisplayLast, get: { Config.current.display.builtinDisplayLast },
    set: {
      Config.current.display.builtinDisplayLast = $0
      DisplayManager.shared.invalidateSpaceCaches()
      SpaceManager.shared.scheduleSpaceLayout(after: .zero, resetPasses: true)
    }),
  choiceOption(
    .windowOriginDisplay, choices: WindowOrigin.allCases, get: { Config.current.window.origin },
    set: { Config.current.window.origin = $0 }),
  boolOption(
    .scratchpadExclusive, get: { Config.current.scratchpad.exclusive },
    set: { Config.current.scratchpad.exclusive = $0 }),
  boolOption(
    .scratchpadRaise, get: { Config.current.scratchpad.raise },
    set: { Config.current.scratchpad.raise = $0 }),
  boolOption(
    .scratchpadBelow, get: { Config.current.scratchpad.below },
    set: {
      Config.current.scratchpad.below = $0
      WindowManager.shared.setScratchpadLayers()
    }),
  boolOption(
    .skipWindowFocusAnimation, get: { Config.current.space.skipWindowFocusAnimation },
    set: { Config.current.space.skipWindowFocusAnimation = $0 }),
  boolOption(
    .windowOpacity, get: { Config.current.opacity.enabled },
    set: { Config.current.opacity.enabled = $0 }),
  choiceOption(
    .windowAnimationEasing, choices: AnimationEasing.allCases,
    get: { Config.current.animation.easing }, set: { Config.current.animation.easing = $0 }),
  choiceOption(
    .windowShadow, choices: PurifyMode.allCases, get: { Config.current.shadow.mode },
    set: { Config.current.shadow.mode = $0 }),
  choiceOption(
    .treeDefaultOrientation, choices: TreeOrientation.allCases,
    get: { Config.current.space.treeDefaultOrientation },
    set: { Config.current.space.treeDefaultOrientation = $0 }),
  choiceOption(
    .treeWorkspaceLayout, choices: WorkspaceLayout.allCases,
    get: { Config.current.space.treeWorkspaceTabbed ? .tabbed : .default },
    set: { Config.current.space.treeWorkspaceTabbed = $0 == .tabbed }),
  boolOption(
    .treeAutotiling, get: { Config.current.space.treeAutotiling },
    set: { Config.current.space.treeAutotiling = $0 }),
  choiceOption(
    .focusWrapping, choices: FocusWrapping.allCases, get: { Config.current.window.focusWrapping },
    set: { Config.current.window.focusWrapping = $0 }),
  choiceOption(
    .mouseModifier, choices: MouseModifierKey.allCases, get: { Config.current.mouse.modifier },
    set: {
      Config.current.mouse.modifier = $0
      MouseState.shared.tap.modifier = $0
    }),
  choiceOption(
    .mouseAction1, choices: [.move, .resize], get: { Config.current.mouse.action1 },
    set: { Config.current.mouse.action1 = $0 }),
  choiceOption(
    .mouseAction2, choices: [.move, .resize], get: { Config.current.mouse.action2 },
    set: { Config.current.mouse.action2 = $0 }),
  choiceOption(
    .mouseDropAction, choices: [.swap, .stack], get: { Config.current.mouse.dropAction },
    set: { Config.current.mouse.dropAction = $0 }),
  boolOption(
    .mouseDragSplit, get: { Config.current.mouse.dragSplit },
    set: {
      Config.current.mouse.dragSplit = $0
      MouseState.shared.tap.dragSplit.store($0, ordering: .relaxed)
    }),
  boolOption(
    .windowBorder, get: { Config.current.border.enabled },
    set: { Config.current.border.enabled = $0 }),
  boolOption(
    .windowBorderHideSingle, get: { Config.current.border.hideSingle },
    set: { Config.current.border.hideSingle = $0 }),
  boolOption(
    .tabBar, get: { Config.current.tabBar.enabled }, set: { Config.current.tabBar.enabled = $0 }),
  boolOption(
    .tabBarIcons, get: { Config.current.tabBar.icons }, set: { Config.current.tabBar.icons = $0 }),
  choiceOption(
    .tabBarStyle, choices: TabBarStyle.allCases, get: { Config.current.tabBar.style },
    set: { Config.current.tabBar.style = $0 }),
  choiceOption(
    .tabBarAppearance, choices: TabBarAppearance.allCases,
    get: { Config.current.tabBar.appearance }, set: { Config.current.tabBar.appearance = $0 }),
  choiceOption(
    .tabBarBackdrop, choices: TabBarBackdrop.allCases, get: { Config.current.tabBar.backdrop },
    set: { Config.current.tabBar.backdrop = $0 }),
  floatOption(
    .windowBorderWidth, get: { Config.current.border.width },
    printValue: { cFormat("%.4f", Double($0)) },
    parseValue: { token in token.value.floatValue.flatMap { $0 > 0.0 ? $0 : nil } },
    expected: "a number above 0.0", set: { Config.current.border.width = $0 }),
  colorOption(
    .activeWindowBorderColor, get: { Config.current.border.activeColor },
    set: { Config.current.border.activeColor = $0 }),
  colorOption(
    .normalWindowBorderColor, get: { Config.current.border.normalColor },
    set: { Config.current.border.normalColor = $0 }),
  integerOption(
    .tabBarHeight, get: { Config.current.tabBar.height },
    parseValue: { token in
      if case .int(let value) = token.value, value > 0 { return value }
      return nil
    }, expected: "a positive integer", set: { Config.current.tabBar.height = $0 }),
  integerOption(
    .tabBarOffset, get: { Config.current.tabBar.offset },
    parseValue: { token in
      switch token.value {
      case .int(let value): return value
      case .float(let value) where value == Float(cInt(value)): return cInt(value)
      default: return nil
      }
    }, expected: "an integer", set: { Config.current.tabBar.offset = $0 }),
  integerOption(
    .tabBarCardPadding, get: { Config.current.tabBar.cardPadding },
    parseValue: { token in
      if case .int(let value) = token.value, value >= 0 { return value }
      return nil
    }, expected: "a non-negative integer", set: { Config.current.tabBar.cardPadding = $0 }),
  integerOption(
    .tabBarWindowRadius, get: { Config.current.tabBar.windowRadius },
    parseValue: { token in
      if case .int(let value) = token.value, value >= 0 { return value }
      return nil
    }, expected: "a non-negative integer", set: { Config.current.tabBar.windowRadius = $0 }),
  colorOption(
    .tabBarFocusedColor, get: { Config.current.tabBar.focusedColor },
    set: {
      Config.current.tabBar.focusedColor = $0
      Config.current.tabBar.focusedColorIsCustom = true
    }),
  colorOption(
    .tabBarFocusedTextColor, get: { Config.current.tabBar.focusedTextColor },
    set: {
      Config.current.tabBar.focusedTextColor = $0
      Config.current.tabBar.focusedTextColorIsCustom = true
    }),
  colorOption(
    .tabBarInactiveColor, get: { Config.current.tabBar.inactiveColor },
    set: {
      Config.current.tabBar.inactiveColor = $0
      Config.current.tabBar.inactiveColorIsCustom = true
    }),
  colorOption(
    .tabBarInactiveTextColor, get: { Config.current.tabBar.inactiveTextColor },
    set: {
      Config.current.tabBar.inactiveTextColor = $0
      Config.current.tabBar.inactiveTextColorIsCustom = true
    }),
  colorOption(
    .tabBarUnfocusedColor, get: { Config.current.tabBar.unfocusedColor },
    set: {
      Config.current.tabBar.unfocusedColor = $0
      Config.current.tabBar.unfocusedColorIsCustom = true
    }),
  colorOption(
    .tabBarUnfocusedTextColor, get: { Config.current.tabBar.unfocusedTextColor },
    set: {
      Config.current.tabBar.unfocusedTextColor = $0
      Config.current.tabBar.unfocusedTextColorIsCustom = true
    }),
  colorOption(
    .tabBarBackdropColor, get: { Config.current.tabBar.backdropColor },
    set: {
      Config.current.tabBar.backdropColor = $0
      Config.current.tabBar.backdropColorIsCustom = true
    }),
  floatOption(
    .windowOpacityDuration, get: { Config.current.window.opacityDuration },
    printValue: { cFormat("%f", Double($0)) }, parseValue: { $0.value.floatValue },
    expected: "a number of seconds", set: { Config.current.window.opacityDuration = $0 }),
  // NOTE: An opacity is printed with 4 decimals. Only the menubar accepts 0, windows need an opacity above 0.
  floatOption(
    .menubarOpacity, get: { Config.current.menuBar.opacity },
    printValue: { cFormat("%.4f", Double($0)) },
    parseValue: { token in token.value.floatValue.flatMap { $0 >= 0.0 && $0 <= 1.0 ? $0 : nil } },
    expected: "a number from 0.0 to 1.0", set: { Config.current.menuBar.opacity = $0 }),
  floatOption(
    .activeWindowOpacity, get: { Config.current.windowOpacity.active },
    printValue: { cFormat("%.4f", Double($0)) },
    parseValue: { token in token.value.floatValue.flatMap { $0 > 0.0 && $0 <= 1.0 ? $0 : nil } },
    expected: "a number above 0.0 and at most 1.0",
    set: { Config.current.windowOpacity.active = $0 }),
  floatOption(
    .normalWindowOpacity, get: { Config.current.windowOpacity.normal },
    printValue: { cFormat("%.4f", Double($0)) },
    parseValue: { token in token.value.floatValue.flatMap { $0 > 0.0 && $0 <= 1.0 ? $0 : nil } },
    expected: "a number above 0.0 and at most 1.0",
    set: { Config.current.windowOpacity.normal = $0 }),
  colorOption(
    .insertFeedbackColor, get: { Config.current.window.insertionFeedbackColor },
    set: { Config.current.window.insertionFeedbackColor = $0 }, allowZero: false),
  scratchpadGridOption(),
  spaceLayoutOption(),
  animationDurationOption(),
  tabBarFontOption(),
  externalBarOption(),
  spacingOption(.topPadding, spacing: .topPadding),
  spacingOption(.bottomPadding, spacing: .bottomPadding),
  spacingOption(.leftPadding, spacing: .leftPadding),
  spacingOption(.rightPadding, spacing: .rightPadding),
  spacingOption(.windowGap, spacing: .windowGap),
  layoutOption(),
  autoPaddingOption(),
]

@WM let configOptionNames = configOptions.map(\.name)
@WM let configOptionTableIsComplete =
  configOptionNames.count == ConfigName.allCases.count
  && ConfigName.allCases.allSatisfy { name in
    configOptionNames.filter { $0 == name }.count == 1
  }

//
// NOTE: Tab bar offsets accept integral float tokens; conversion saturates at Int32 limits and maps NaN to zero.
//

private func cInt(_ value: Float) -> Int {
  if value.isNaN { return 0 }
  if value >= Float(Int32.max) { return Int(Int32.max) }
  if value <= Float(Int32.min) { return Int(Int32.min) }
  return Int(value)
}

/// Handles a config message.
@WM func handleDomainConfig(_ rsp: inout Response, _ domain: Token, _ message: inout Message)
  throws(CommandError)
{
  var selSid: SpaceID?
  let first = message.next()
  if first.equals("--check") {
    try handleConfigCheck(&rsp, &message)
    return
  }
  if first.equals("--reload") {
    try handleConfigReload(&rsp, &message)
    return
  }

  let (spaceSelector, command) = try ConfigCommand.parseScope(first, &message)
  if let spaceSelector {
    guard let target = try spaceSelector.resolve(acting: nil, CSelectorContext()) else { return }
    selSid = target
  }

  try runCommands(&rsp, &message, from: command) {
    (rsp, source, command) throws(CommandError) -> Bool in
    try handleConfigCommand(&rsp, domain, try ConfigCommand.parseName(command), &source, selSid)
    return true
  }
}

/// The option of a command name. Every name has exactly one option (configOptionTableIsComplete).
@WM private func configOption(_ domain: Token, _ name: ConfigName) throws(CommandError)
  -> ConfigOption
{
  guard let option = configOptions.first(where: { $0.name == name }) else {
    throw CommandError.unknownCommand(domain, Token(name.rawValue))
  }
  return option
}

/// One command of the config domain.
@WM private func handleConfigCommand(
  _ rsp: inout Response, _ domain: Token, _ name: ConfigName, _ message: inout Message,
  _ selSid: SpaceID?
) throws(CommandError) {
  let command = Token(name.rawValue)
  let option = try configOption(domain, name)
  if let change = try option.parse(domain, command, &message, selSid) {
    try change()
  } else {
    option.print(&rsp, selSid)
  }
}

//
// NOTE: The check of a config message (checkMessage) parses what handleDomainConfig parses and drops every Change, so
// nothing is applied. Two differences, both from what applying needs: a --space selector is parsed but not resolved, so
// a placeholder space stands in for it (the spaceLayout option fails on any space, as it does for a real one) and the
// commands run even where the selector would find nothing; and the failures that only a Change can throw are not
// found: tab_bar_font (TabBar.setFont), window_animation_duration (SIP and Screen Recording) and the other Change
// closures. Those stay for handleMessage. `--check` is accepted with its file, as handleDomainConfig accepts it: it
// checks a file and changes nothing. `--reload` takes its file the same way; the reload itself is not run by the check
// (checkDomain notes it, since a reload inside a yabairc runs the yabairc again).
//

/// Checks a config message: the failures of its commands, parsed as handleDomainConfig parses them, with the Change of
/// each option dropped. Failures are written to `rsp`, like the commands of handleDomainConfig write them.
@WM func checkConfigMessage(_ rsp: inout Response, _ domain: Token, _ message: inout Message)
  throws(CommandError)
{
  var selSid: SpaceID?
  let first = message.next()
  if first.equals("--check") || first.equals("--reload") {
    _ = try configFileArgument(first.string, &message)
    return
  }

  let (spaceSelector, command) = try ConfigCommand.parseScope(first, &message)
  if spaceSelector != nil {
    selSid = CheckSelectorContext.placeholderSpace
  }

  try runCommands(&rsp, &message, from: command) {
    (rsp, source, command) throws(CommandError) -> Bool in
    try checkConfigCommand(domain, try ConfigCommand.parseName(command), &source, selSid)
    return true
  }
}

/// One command of the config domain, parsed as handleConfigCommand parses it, without its Change or print.
@WM private func checkConfigCommand(
  _ domain: Token, _ name: ConfigName, _ message: inout Message, _ selSid: SpaceID?
) throws(CommandError) {
  let option = try configOption(domain, name)
  _ = try option.parse(domain, Token(name.rawValue), &message, selSid)
}
