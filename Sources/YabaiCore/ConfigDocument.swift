/// The contents of a `yabai.toml` file as plain values. `ConfigDocumentDecoding.swift` reads a file into it and checks
/// the keys and the types; the values themselves are checked by the handlers that the lowered messages reach (C2.2).
public struct ConfigDocument: Equatable, Sendable {
  public var daemon = DaemonSettings()
  /// The `[config]` options, in the key order of `ConfigDocumentDecoding.swift`.
  public var options: [ConfigOptionEntry] = []
  /// The `[[space]]` tables, in file order.
  public var spaces: [SpaceEntry] = []
  /// The `[[rule]]` tables, in file order.
  public var rules: [RuleEntry] = []
  /// The `[[signal]]` tables, in file order.
  public var signals: [SignalEntry] = []

  public init() {}
}

/// The `[daemon]` table. The defaults are the ones of an empty file.
public struct DaemonSettings: Equatable, Sendable {
  public var autoReload = true
  public var loadScriptingAddition = false

  public init() {}
}

/// A value of the file. Options take a boolean, an integer, a float or a string; `space_layout` takes an array of
/// strings. The integers of a color (`0xff51afef`) are integers.
public enum ConfigValue: Equatable, Sendable {
  case bool(Bool)
  case integer(Int)
  case float(Double)
  case string(String)
  case strings([String])
}

/// One `name = value` line of `[config]`, or of a `[[space]]` table.
public struct ConfigOptionEntry: Equatable, Sendable {
  public var name: ConfigCommand.Name
  public var value: ConfigValue
  /// The key path of the line, e.g. `config.window_gap` or `space[1].window_gap`.
  public var keyPath: String
}

/// One `[[space]]` table: a space index with its label, its pin and its options that accept `--space`.
public struct SpaceEntry: Equatable, Sendable {
  public var index: Int
  public var label: String?
  public var pin: String?
  /// The options of the table, in the key order of `ConfigDocumentDecoding.swift`.
  public var options: [ConfigOptionEntry]
  /// The key path of the table, e.g. `space[1]`.
  public var keyPath: String
}

/// One key of a `[[rule]]` or `[[signal]]` table. `key = { not = "value" }` is the exclusion of `key!=value`, and it
/// is only accepted for the keys that have one (`ConfigDocumentDecoding.swift`).
public struct ConfigKey: Equatable, Sendable {
  public var name: String
  public var negated: Bool
  public var value: ConfigValue
  /// The key path of the key, e.g. `rule[3].app`. An exclusion's value is at `rule[3].app.not`.
  public var keyPath: String
}

/// One `[[rule]]` table: its keys in the key order of `ConfigDocumentDecoding.swift`, and `one_shot`.
public struct RuleEntry: Equatable, Sendable {
  public var keys: [ConfigKey]
  public var oneShot: Bool
  /// The key path of the table, e.g. `rule[3]`.
  public var keyPath: String
}

/// One `[[signal]]` table: its keys in the key order of `ConfigDocumentDecoding.swift`. `event` and `action` are among
/// them.
public struct SignalEntry: Equatable, Sendable {
  public var keys: [ConfigKey]
  /// The key path of the table, e.g. `signal[0]`.
  public var keyPath: String
}

/// A problem of a `yabai.toml` file. An empty key path is a problem of the whole file (a syntax error).
public struct ConfigDocumentError: Equatable, Sendable {
  public var keyPath: String
  /// The line of the problem when the parser reports one. Other problems get their line from C1.4.
  public var line: Int?
  public var message: String

  public init(keyPath: String, line: Int? = nil, message: String) {
    self.keyPath = keyPath
    self.line = line
    self.message = message
  }
}

/// Every problem of a file, in the order they were found. Decoding throws this only when there is at least one.
public struct ConfigDocumentErrors: Error, Equatable, Sendable {
  public var errors: [ConfigDocumentError]

  public init(errors: [ConfigDocumentError]) {
    self.errors = errors
  }
}

extension ConfigCommand.Name {
  // NOTE: The options whose parser reads the `--space` selector (`selSid` in Sources/Yabai/IPC/MessageConfig.swift):
  // the four paddings and `window_gap` (`spacingOption`), `layout` (`layoutOption`) and `auto_padding`
  // (`autoPaddingOption`). `space_layout` rejects the selector; every other option ignores it. Keep this set in step
  // with those parsers.
  public static let spaceScoped: Set<ConfigCommand.Name> = [
    .topPadding, .bottomPadding, .leftPadding, .rightPadding, .windowGap, .layout, .autoPadding,
  ]
}
