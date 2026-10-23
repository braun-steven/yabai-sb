//
// NOTE: Lowering turns a decoded ConfigDocument into the messages that `yabai -m` would send for the same settings: the
// words after `-m`, as the shell words of a `yabai -m` line are. The handlers of those messages then check the values
// (C2.2), so lowering only spells each value the way its parser reads it. Nothing here is checked against the window
// server or the daemon's state.
//

/// One message of a lowered document: its words after `-m`, the key path of the line that gave it, its step in the
/// apply order (`ConfigEntry.Kind`), and that line in the file when the lowering had the file (`lowered(locator:)`).
public struct ConfigEntry: Equatable, Sendable {
  /// The steps of the apply order, in the order they run. The raw values give that order.
  public enum Kind: Int, CaseIterable, Sendable {
    case option
    case spaceLayout
    case space
    case rule
    case signal
  }

  public var arguments: [String]
  public var keyPath: String
  public var kind: Kind
  /// The line of `keyPath` in the file, 1-based; nil when the lowering was not given the file.
  public var line: Int?

  public init(arguments: [String], keyPath: String, kind: Kind, line: Int? = nil) {
    self.arguments = arguments
    self.keyPath = keyPath
    self.kind = kind
    self.line = line
  }
}

extension ConfigDocument {
  /// The messages of the document, in apply order: the `[config]` options (`space_layout` after the others), then each
  /// `[[space]]` (its label, its pin, its options), then the rules, then the signals. Every entry has at least one word.
  ///
  /// Within a table the entries keep the key order of `ConfigDocumentDecoding.swift`. Within a rule or signal, the key
  /// order does not change its meaning.
  ///
  /// The document does not keep the file, so the lines come only from `locator`, the locator of the same source text.
  /// Without one, every entry has no line.
  public func lowered(locator: TOMLKeyLocator? = nil) -> [ConfigEntry] {
    var entries: [ConfigEntry] = []

    for option in options where option.name != .spaceLayout {
      entries.append(
        optionEntry(option, arguments: ["config", option.name.rawValue], kind: .option))
    }
    for option in options where option.name == .spaceLayout {
      entries.append(
        optionEntry(option, arguments: ["config", option.name.rawValue], kind: .spaceLayout))
    }

    for space in spaces {
      let selector = String(space.index)
      if let label = space.label {
        entries.append(
          ConfigEntry(
            arguments: ["space", selector, "--label", label], keyPath: "\(space.keyPath).label",
            kind: .space))
      }
      if let pin = space.pin {
        // NOTE: The label names the space once the first entry above has set it; the index is used without one.
        entries.append(
          ConfigEntry(
            arguments: ["space", space.label ?? selector, "--pin", pin],
            keyPath: "\(space.keyPath).pin", kind: .space))
      }
      for option in space.options {
        entries.append(
          optionEntry(
            option, arguments: ["config", "--space", selector, option.name.rawValue], kind: .space))
      }
    }

    for rule in rules {
      var arguments = ["rule", "--add"]
      if rule.oneShot { arguments.append("--one-shot") }
      arguments += rule.keys.map { keyWord($0, yesNo: false) }
      entries.append(ConfigEntry(arguments: arguments, keyPath: rule.keyPath, kind: .rule))
    }

    for signal in signals {
      let arguments =
        ["signal", "--add"]
        + signal.keys.map { key in
          // NOTE: `signal --add active=` takes yes or no, while the boolean keys of rules take on or off.
          keyWord(key, yesNo: key.name == "active")
        }
      entries.append(ConfigEntry(arguments: arguments, keyPath: signal.keyPath, kind: .signal))
    }

    guard let locator else { return entries }
    return entries.map { entry in
      var entry = entry
      entry.line = locator.line(for: entry.keyPath)
      return entry
    }
  }
}

private func optionEntry(_ option: ConfigOptionEntry, arguments: [String], kind: ConfigEntry.Kind)
  -> ConfigEntry
{
  ConfigEntry(
    arguments: arguments + optionWords(option), keyPath: option.keyPath, kind: kind)
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
