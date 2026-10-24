//
// NOTE: Lowering turns a decoded ConfigDocument into the messages that `yabai -m` would send for the same settings: the
// words after `-m`, as the shell words of a `yabai -m` line are. The handlers of those messages then check the values
// (C2.2), so lowering only spells each value the way its parser reads it. Nothing here is checked against the window
// server or the daemon's state.
//

/// One message of a lowered document: what it sets (`target`), the words of its value, its words after `-m`, the key path
/// of the line that gave it, and that line in the file when the lowering had the file (`lowered(locator:)`).
public struct ConfigEntry: Equatable, Sendable {
  /// What a message sets. The daemon reads this instead of the words, which are only what the handler receives.
  public enum Target: Hashable, Sendable {
    /// `config <name> <value>`.
    case option(ConfigCommand.Name)
    /// `space <index> --label <label>`.
    case spaceLabel(index: Int)
    /// `space <label or index> --pin <display>`.
    case spacePin(index: Int)
    /// `config --space <index> <name> <value>`.
    case spaceOption(index: Int, ConfigCommand.Name)
    /// `rule --add …`.
    case rule
    /// `signal --add …`.
    case signal
  }

  /// The steps of the apply order, in the order they run. The raw values give that order.
  public enum Kind: Int, CaseIterable, Sendable {
    case option
    case spaceLayout
    case space
    case rule
    case signal
  }

  public var target: Target
  /// The words of the value, joined by spaces: the option's value (`space_layout` has several words), the label or the
  /// pin. Empty for a rule or a signal, whose words are their keys.
  public var value: String
  public var arguments: [String]
  public var keyPath: String
  /// The line of `keyPath` in the file, 1-based; nil when the lowering was not given the file.
  public var line: Int?

  public init(
    target: Target, value: String, arguments: [String], keyPath: String, line: Int? = nil
  ) {
    self.target = target
    self.value = value
    self.arguments = arguments
    self.keyPath = keyPath
    self.line = line
  }

  /// A message that sets a global option to `value`.
  public static func option(_ name: ConfigCommand.Name, _ value: String, keyPath: String)
    -> ConfigEntry
  {
    ConfigEntry(
      target: .option(name), value: value, arguments: ["config", name.rawValue, value],
      keyPath: keyPath)
  }

  /// The step of the apply order that the entry belongs to.
  public var kind: Kind {
    switch target {
    case .option(let name): name == .spaceLayout ? .spaceLayout : .option
    case .spaceLabel, .spacePin, .spaceOption: .space
    case .rule: .rule
    case .signal: .signal
    }
  }
}

extension ConfigDocument {
  /// The messages of the document, in apply order (`ConfigEntry.Kind`): the `[config]` options (`space_layout` after the
  /// others), then each `[[space]]` (its label, its pin, its options), then the rules, then the signals. Every entry has
  /// at least one word.
  ///
  /// Within a table the entries keep the document's order (file order). Within a rule or signal, the key order does not
  /// change its meaning.
  ///
  /// The document does not keep the file, so the lines come only from `locator`, the locator of the same source text.
  /// Without one, every entry has no line.
  public func lowered(locator: TOMLKeyLocator? = nil) -> [ConfigEntry] {
    var entries: [ConfigEntry] = []

    for option in options where option.name != .spaceLayout {
      entries.append(optionEntry(option, space: nil))
    }
    for option in options where option.name == .spaceLayout {
      entries.append(optionEntry(option, space: nil))
    }

    for space in spaces {
      let selector = String(space.index)
      if let label = space.label {
        entries.append(
          ConfigEntry(
            target: .spaceLabel(index: space.index), value: label,
            arguments: ["space", selector, "--label", label], keyPath: "\(space.keyPath).label"))
      }
      if let pin = space.pin {
        // NOTE: The label names the space once the first entry above has set it; the index is used without one.
        entries.append(
          ConfigEntry(
            target: .spacePin(index: space.index), value: pin,
            arguments: ["space", space.label ?? selector, "--pin", pin],
            keyPath: "\(space.keyPath).pin"))
      }
      for option in space.options {
        entries.append(optionEntry(option, space: space.index))
      }
    }

    for rule in rules {
      var arguments = ["rule", "--add"]
      if rule.oneShot { arguments.append("--one-shot") }
      arguments += rule.keys.map { keyWord($0, yesNo: false) }
      entries.append(
        ConfigEntry(target: .rule, value: "", arguments: arguments, keyPath: rule.keyPath))
    }

    for signal in signals {
      let arguments =
        ["signal", "--add"]
        + signal.keys.map { key in
          // NOTE: `signal --add active=` takes yes or no, while the boolean keys of rules take on or off.
          keyWord(key, yesNo: key.name == "active")
        }
      entries.append(
        ConfigEntry(target: .signal, value: "", arguments: arguments, keyPath: signal.keyPath))
    }

    guard let locator else { return entries }
    return entries.map { entry in
      var entry = entry
      entry.line = locator.line(for: entry.keyPath)
      return entry
    }
  }
}

/// The message of an option: global (`config <name> <value>`), or of the space at `space` (`config --space <index> …`).
private func optionEntry(_ option: ConfigOptionEntry, space: Int?) -> ConfigEntry {
  let words = optionWords(option)
  let name = option.name
  guard let space else {
    return ConfigEntry(
      target: .option(name), value: words.joined(separator: " "),
      arguments: ["config", name.rawValue] + words, keyPath: option.keyPath)
  }
  return ConfigEntry(
    target: .spaceOption(index: space, name), value: words.joined(separator: " "),
    arguments: ["config", "--space", String(space), name.rawValue] + words,
    keyPath: option.keyPath)
}

/// The words of an option's value. Colors print as eight hex digits, as `yabai -m config` takes them.
private func optionWords(_ option: ConfigOptionEntry) -> [String] {
  switch option.value {
  case .strings(let layouts):
    // NOTE: `config space_layout` without a value prints the layouts instead of changing them, so an empty list is
    // `off`, which removes them.
    return layouts.isEmpty ? [Argument.off] : layouts
  case .integer(let value)
  where option.name.rawValue.hasSuffix("_color") && (0...Int(UInt32.max)).contains(value):
    return [colorWord(UInt32(value))]
  default:
    return [scalarText(option.value, yesNo: false)]
  }
}

/// `key=value`, or `key!=value` for an exclusion.
private func keyWord(_ key: ConfigKey, yesNo: Bool) -> String {
  "\(key.name)\(key.negated ? "!=" : "=")\(scalarText(key.value, yesNo: yesNo))"
}

/// The text of a value as the IPC parsers read it: `on` or `off` (or `yes` or `no` when `yesNo`), decimal integers,
/// floats in their shortest form, strings as they are, and a list as its words joined by spaces (lists are only
/// options, see `optionWords`, so this is for completeness).
private func scalarText(_ value: ConfigValue, yesNo: Bool) -> String {
  switch value {
  case .bool(let enabled):
    if yesNo { return enabled ? "yes" : "no" }
    return boolString(enabled)
  case .integer(let number):
    return String(number)
  case .float(let number):
    return String(number)
  case .string(let text):
    return text
  case .strings(let texts):
    return texts.joined(separator: " ")
  }
}

/// `0x` and eight lowercase hex digits, e.g. `0xff51afef`.
private func colorWord(_ value: UInt32) -> String {
  let digits = String(value, radix: 16)
  return "0x" + String(repeating: "0", count: 8 - digits.count) + digits
}
