import TOMLDecoder

/// The keys that the decoder accepts in each table, and the keys that take `{ not = … }`. The schema test
/// (`tests/YabaiTests/ConfigSchemaTests.swift`) checks `doc/yabai.schema.json` against these sets.
public enum ConfigTableKeys {
  /// The top-level tables.
  public static let topLevel: Set<String> = ["daemon", "config", "space", "rule", "signal"]

  // NOTE: The keys of `rule --add` (`parseRule` in Sources/YabaiCore/Rule.swift). `one_shot` is not in this list: it is
  // a boolean of the table, read separately.
  public static let rule: Set<String> = [
    "label", "scratchpad", "app", "title", "role", "subrole", "display", "space", "insert", "grid",
    "opacity", "manage",
    "sticky", "mouse_follows_focus", "native-fullscreen", "sub-layer",
  ]
  public static let ruleNegatable: Set<String> = ["app", "title", "role", "subrole"]

  // NOTE: The keys of `signal --add` (`parseSignal` in Sources/YabaiCore/Rule.swift).
  public static let signal: Set<String> = ["label", "app", "title", "active", "action", "event"]
  public static let signalNegatable: Set<String> = ["app", "title"]
}

// NOTE: The keys of a table come from `TOMLTable.keys`, which lists its plain values first, then its arrays, then its
// inline and sub-tables (`TOMLDocument.allKeys`). The file order across those kinds is not public, so a decoded list
// keeps that order, which is deterministic. The lines of `TOMLKeyLocator` could restore the file order; that is not
// done.

extension ConfigDocument {
  /// Decodes the text of a `yabai.toml` file. Every problem is collected, in the order they are found, and the document
  /// is returned only when there are none.
  public static func decode(_ source: String) throws(ConfigDocumentErrors) -> ConfigDocument {
    let root: TOMLTable
    do throws(TOMLError) {
      root = try TOMLTable(source: source)
    } catch {
      let (line, message) = splitTOMLErrorLine(error.description)
      throw ConfigDocumentErrors(errors: [
        ConfigDocumentError(keyPath: "", line: line, message: message)
      ])
    }

    var decoder = ConfigDocumentDecoder()
    let document = decoder.decode(root)
    if !decoder.errors.isEmpty {
      // NOTE: The parser reports no line for a semantic problem, so its line comes from the key path.
      let locator = TOMLKeyLocator(source: source)
      let errors = decoder.errors.map { error in
        var error = error
        if error.keyPath.isEmpty == false { error.line = locator.line(for: error.keyPath) }
        return error
      }
      throw ConfigDocumentErrors(errors: errors)
    }
    return document
  }
}

// NOTE: TOMLDecoder 0.4.5 keeps the line of a syntax error in a private `reason`. Its public `description` starts with
// "(Line N) " when there is a line, which is the only public access to it, so the prefix is parsed here. The rest of the
// text is the message.
private func splitTOMLErrorLine(_ description: String) -> (line: Int?, message: String) {
  let prefix = "(Line "
  guard description.hasPrefix(prefix) else { return (nil, description) }
  let rest = description.dropFirst(prefix.count)
  let digits = rest.prefix { $0.isASCII && $0.isNumber }
  guard let line = Int(digits), rest.dropFirst(digits.count).hasPrefix(") ") else {
    return (nil, description)
  }
  return (line, String(rest.dropFirst(digits.count + 2)))
}

/// Walks a parsed file and records the problems. Each helper reports a problem at its key path and returns nil, so the
/// walk goes on and the whole file is checked in one run.
struct ConfigDocumentDecoder {
  private(set) var errors: [ConfigDocumentError] = []

  mutating func decode(_ root: TOMLTable) -> ConfigDocument {
    var document = ConfigDocument()
    for name in root.keys where !ConfigTableKeys.topLevel.contains(name) {
      fail(name, "unknown table '\(name)'")
    }
    if let table = subtable(root, "daemon") {
      document.daemon = daemonSettings(table)
    }
    if let table = subtable(root, "config") {
      document.options = configOptions(table, prefix: "config")
    }
    for (path, table) in tableArray(root, "space") {
      if let space = spaceEntry(table, path: path) {
        document.spaces.append(space)
      }
    }
    checkUniqueSpaceIndices(document.spaces)
    for (path, table) in tableArray(root, "rule") {
      document.rules.append(ruleEntry(table, path: path))
    }
    for (path, table) in tableArray(root, "signal") {
      document.signals.append(signalEntry(table, path: path))
    }
    return document
  }

  private mutating func fail(_ keyPath: String, _ message: String) {
    errors.append(ConfigDocumentError(keyPath: keyPath, line: nil, message: message))
  }

  /// The table under `key` of `parent`; nil without a problem when the key is absent.
  private mutating func subtable(_ parent: TOMLTable, _ key: String) -> TOMLTable? {
    guard parent.contains(key: key) else { return nil }
    if let table = try? parent.table(forKey: key) { return table }
    fail(key, "expected a table")
    return nil
  }

  /// The tables of the array of tables `[[key]]`, with their key paths; empty when the key is absent.
  private mutating func tableArray(_ parent: TOMLTable, _ key: String) -> [(
    path: String, table: TOMLTable
  )] {
    guard parent.contains(key: key) else { return [] }
    guard let array = try? parent.array(forKey: key) else {
      fail(key, "expected an array of tables ([[\(key)]])")
      return []
    }
    var result: [(path: String, table: TOMLTable)] = []
    for index in 0..<array.count {
      let path = "\(key)[\(index)]"
      if let table = try? array.table(atIndex: index) {
        result.append((path, table))
      } else {
        fail(path, "expected a table")
      }
    }
    return result
  }

  /// A boolean, integer, float or string, typed by the first getter that accepts the value.
  private func scalar(_ table: TOMLTable, _ key: String) -> ConfigValue? {
    if let value = try? table.bool(forKey: key) { return .bool(value) }
    if let value = try? table.integer(forKey: key) { return .integer(Int(value)) }
    if let value = try? table.float(forKey: key) { return .float(value) }
    if let value = try? table.string(forKey: key) { return .string(value) }
    return nil
  }

  private mutating func daemonSettings(_ table: TOMLTable) -> DaemonSettings {
    var settings = DaemonSettings()
    for key in table.keys {
      let path = "daemon.\(key)"
      switch key {
      case "auto_reload":
        if let value = bool(table, key, path) { settings.autoReload = value }
      case "load_scripting_addition":
        if let value = bool(table, key, path) { settings.loadScriptingAddition = value }
      default:
        fail(path, "unknown key '\(key)'")
      }
    }
    return settings
  }

  private mutating func bool(_ table: TOMLTable, _ key: String, _ path: String) -> Bool? {
    if let value = try? table.bool(forKey: key) { return value }
    fail(path, "expected a boolean")
    return nil
  }

  private mutating func string(_ table: TOMLTable, _ key: String, _ path: String) -> String? {
    if let value = try? table.string(forKey: key) { return value }
    fail(path, "expected a string")
    return nil
  }

  /// The options of `[config]`; `prefix` is its key path.
  private mutating func configOptions(_ table: TOMLTable, prefix: String) -> [ConfigOptionEntry] {
    var result: [ConfigOptionEntry] = []
    for key in table.keys {
      let path = "\(prefix).\(key)"
      guard let name = ConfigCommand.Name(rawValue: key) else {
        fail(path, "unknown option '\(key)'")
        continue
      }
      if let value = optionValue(table, key, path, name: name) {
        result.append(ConfigOptionEntry(name: name, value: value, keyPath: path))
      }
    }
    return result
  }

  /// The value of an option. `space_layout` takes an array of strings, every other option a scalar. A color given as
  /// `rgb(…)` or `rgba(…)` is decoded to its integer; any other string goes to the handler as it is (e.g. `"0xff51afef"`).
  private mutating func optionValue(
    _ table: TOMLTable, _ key: String, _ path: String, name: ConfigCommand.Name
  ) -> ConfigValue? {
    guard name == .spaceLayout else {
      guard let value = scalar(table, key) else {
        fail(path, "expected a boolean, integer, float or string")
        return nil
      }
      guard name.rawValue.hasSuffix("_color"), case .string(let text) = value,
        text.lowercased().hasPrefix("rgb")
      else { return value }
      guard let color = rgbColor(text) else {
        fail(
          path,
          "expected rgb(r, g, b) or rgba(r, g, b, a), with r, g and b from 0 to 255 and a from 0 to 1"
        )
        return nil
      }
      return .integer(Int(color))
    }
    guard let array = try? table.array(forKey: key) else {
      fail(path, "expected an array of strings")
      return nil
    }
    var strings: [String] = []
    var valid = true
    for index in 0..<array.count {
      if let text = try? array.string(atIndex: index) {
        strings.append(text)
      } else {
        fail("\(path)[\(index)]", "expected a string")
        valid = false
      }
    }
    return valid ? .strings(strings) : nil
  }

  private mutating func spaceEntry(_ table: TOMLTable, path: String) -> SpaceEntry? {
    var index: Int?
    var label: String?
    var pin: String?
    var options: [ConfigOptionEntry] = []
    for key in table.keys {
      let keyPath = "\(path).\(key)"
      switch key {
      case "index":
        if let value = try? table.integer(forKey: key) {
          if value < 1 {
            fail(keyPath, "must be at least 1")
          } else {
            index = Int(value)
          }
        } else {
          fail(keyPath, "expected an integer")
        }
      case "label":
        label = string(table, key, keyPath)
      case "pin":
        pin = string(table, key, keyPath)
      default:
        guard let name = ConfigCommand.Name(rawValue: key),
          ConfigCommand.Name.spaceScoped.contains(name)
        else {
          fail(
            keyPath,
            "unknown key '\(key)' (a space takes index, label, pin and the options that accept --space)"
          )
          continue
        }
        if let value = optionValue(table, key, keyPath, name: name) {
          options.append(ConfigOptionEntry(name: name, value: value, keyPath: keyPath))
        }
      }
    }
    guard let index else {
      // NOTE: A present but invalid index was reported above; only an absent one is reported here.
      if !table.contains(key: "index") { fail("\(path).index", "missing required key 'index'") }
      return nil
    }
    return SpaceEntry(index: index, label: label, pin: pin, options: options, keyPath: path)
  }

  /// Every index of `[[space]]` names one space, so a repeated index is reported at its later table.
  private mutating func checkUniqueSpaceIndices(_ spaces: [SpaceEntry]) {
    var firstPath: [Int: String] = [:]
    for space in spaces {
      if let first = firstPath[space.index] {
        fail("\(space.keyPath).index", "duplicate space index \(space.index) (first at \(first))")
      } else {
        firstPath[space.index] = space.keyPath
      }
    }
  }

  private mutating func ruleEntry(_ table: TOMLTable, path: String) -> RuleEntry {
    var oneShot = false
    if table.contains(key: "one_shot") {
      oneShot = bool(table, "one_shot", "\(path).one_shot") ?? false
    }
    let keys = keyList(
      table, path: path, allowed: ConfigTableKeys.rule, negatable: ConfigTableKeys.ruleNegatable,
      skipping: ["one_shot"])
    return RuleEntry(keys: keys, oneShot: oneShot, keyPath: path)
  }

  private mutating func signalEntry(_ table: TOMLTable, path: String) -> SignalEntry {
    let keys = keyList(
      table, path: path, allowed: ConfigTableKeys.signal,
      negatable: ConfigTableKeys.signalNegatable, skipping: [])
    // NOTE: Presence in the table, not in `keys`: a required key with a bad value was reported already.
    for required in ["event", "action"] where !table.contains(key: required) {
      fail("\(path).\(required)", "missing required key '\(required)'")
    }
    return SignalEntry(keys: keys, keyPath: path)
  }

  private mutating func keyList(
    _ table: TOMLTable, path: String, allowed: Set<String>, negatable: Set<String>,
    skipping: Set<String>
  ) -> [ConfigKey] {
    var result: [ConfigKey] = []
    for name in table.keys where !skipping.contains(name) {
      let keyPath = "\(path).\(name)"
      guard allowed.contains(name) else {
        fail(keyPath, "unknown key '\(name)'")
        continue
      }
      if let entry = keyEntry(table, name, keyPath, negatable: negatable.contains(name)) {
        result.append(entry)
      }
    }
    return result
  }

  /// A key of a rule or signal: a scalar, or `{ not = "value" }` for an exclusion of a key that has one.
  private mutating func keyEntry(
    _ table: TOMLTable, _ name: String, _ keyPath: String, negatable: Bool
  ) -> ConfigKey? {
    if let inline = try? table.table(forKey: name) {
      guard inline.keys == ["not"] else {
        fail(keyPath, "expected a value or { not = \"...\" }")
        return nil
      }
      guard negatable else {
        fail("\(keyPath).not", "'\(name)' cannot be negated")
        return nil
      }
      guard let value = string(inline, "not", "\(keyPath).not") else { return nil }
      return ConfigKey(name: name, negated: true, value: .string(value), keyPath: keyPath)
    }
    guard let value = scalar(table, name) else {
      fail(keyPath, "expected a boolean, integer, float, string or { not = \"...\" }")
      return nil
    }
    return ConfigKey(name: name, negated: false, value: value, keyPath: keyPath)
  }
}

/// The color of `rgb(r, g, b)` or `rgba(r, g, b, a)` as 0xAARRGGBB, as CSS writes them: r, g and b are integers from 0
/// to 255 and a is a number from 0 to 1 (`rgb` is opaque). The function name is case-insensitive and spaces may surround
/// the components. Nil for any other text.
func rgbColor(_ text: String) -> UInt32? {
  let lowered = text.lowercased()
  let hasAlpha: Bool
  if lowered.hasPrefix("rgba(") {
    hasAlpha = true
  } else if lowered.hasPrefix("rgb(") {
    hasAlpha = false
  } else {
    return nil
  }
  guard lowered.hasSuffix(")") else { return nil }
  let inner = lowered.dropFirst(hasAlpha ? 5 : 4).dropLast()
  let components = inner.split(separator: ",", omittingEmptySubsequences: false).map {
    String($0.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
  }
  guard components.count == (hasAlpha ? 4 : 3) else { return nil }
  var color: UInt32 = 0
  for component in components.prefix(3) {
    guard let channel = UInt8(component) else { return nil }
    color = color << 8 | UInt32(channel)
  }
  var alpha: UInt32 = 0xff
  if hasAlpha {
    guard let value = Double(components[3]), value.isFinite, (0...1).contains(value) else {
      return nil
    }
    alpha = UInt32((value * 255).rounded())
  }
  return alpha << 24 | color
}
