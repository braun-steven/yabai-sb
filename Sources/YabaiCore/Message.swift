/// One argument of a message. Invalid when empty.
public struct Token: Equatable, Sendable, CustomStringConvertible {
  public var string: String

  public init(_ string: String) {
    self.string = string
  }

  public init(_ string: Substring) {
    self.string = String(string)
  }

  public init(_ bytes: some Collection<UInt8>) {
    self.string = String(decoding: bytes, as: UTF8.self)
  }

  public var description: String { string }

  public init(_ domain: Domain) { string = domain.rawValue }

  public func equals(_ domain: Domain) -> Bool { string == domain.rawValue }

  public var isValid: Bool { !string.isEmpty }

  /// The UTF-8 bytes, for the parsers that split at ASCII separators.
  public var utf8: String.UTF8View { string.utf8 }

  public func equals(_ match: String) -> Bool {
    string == match
  }

  public func hasPrefix(_ match: String) -> Bool {
    string.hasPrefix(match)
  }

  /// The token without its first count characters.
  public func dropFirst(_ count: Int) -> Token {
    Token(string.dropFirst(count))
  }

  //
  // NOTE: A decimal value beyond Int32.max, or a hexadecimal one beyond UInt32.max, is not an integer: `value` then
  // reads the token as a float, which the integer and color options reject as an unknown value, instead of taking
  // a wrapped value.
  //

  /// `token_is_positive_integer`: true for an empty token.
  public var positiveInteger: Int? {
    decimal(as: Int32.self).map(Int.init)
  }

  /// The digits of a window id, which is a uint32_t; nil for an empty token.
  public var unsignedInteger: UInt32? {
    isValid ? decimal(as: UInt32.self) : nil
  }

  private func decimal<T: FixedWidthInteger>(as type: T.Type) -> T? {
    var value: T = 0
    for byte in utf8 {
      guard byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") else { return nil }
      let shifted = value.multipliedReportingOverflow(by: 10)
      let sum = shifted.partialValue.addingReportingOverflow(T(byte - UInt8(ascii: "0")))
      guard !shifted.overflow && !sum.overflow else { return nil }
      value = sum.partialValue
    }
    return value
  }

  /// `token_is_hexadecimal`: 0x or 0X followed by at least one hexadecimal digit.
  public var hexadecimal: UInt32? {
    let bytes = Array(utf8)
    guard bytes.count > 2 else { return nil }
    guard
      bytes[0] == UInt8(ascii: "0")
        && (bytes[1] == UInt8(ascii: "x") || bytes[1] == UInt8(ascii: "X"))
    else { return nil }

    var value: UInt32 = 0
    for byte in bytes.dropFirst(2) {
      let digit: UInt8
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
      default: return nil
      }
      let shifted = value.multipliedReportingOverflow(by: 16)
      let sum = shifted.partialValue.addingReportingOverflow(UInt32(digit))
      guard !shifted.overflow && !sum.overflow else { return nil }
      value = sum.partialValue
    }
    return value
  }

  /// `token_to_value`
  public var value: TokenValue {
    guard isValid else { return .invalid }
    if let value = positiveInteger { return .int(value) }
    if let value = hexadecimal { return .u32(value) }
    if let value = float { return .float(value) }
    return .string(self)
  }
}

extension CaseIterable where Self: RawRepresentable, RawValue == String {
  /// The case whose raw value the token equals (case-sensitive, `Token.equals`), in `allCases` order; nil when none.
  public init?(token: Token) {
    guard let match = Self.allCases.first(where: { token.equals($0.rawValue) }) else { return nil }
    self = match
  }
}

/// `struct token_value`. C also had TOKEN_TYPE_UNKNOWN, which token_to_value could not return for a valid token.
public enum TokenValue: Sendable {
  case invalid
  case int(Int)
  case u32(UInt32)
  case float(Float)
  case string(Token)

  //
  // NOTE: Float options also accept integers, which token_to_value reports as TOKEN_TYPE_INT. They reject nan and
  // inf, which the float conversion of the token accepts.
  //

  /// `token_value_float`
  public var floatValue: Float? {
    switch self {
    case .float(let value): return value.isFinite ? value : nil
    case .int(let value): return Float(value)
    default: return nil
    }
  }
}

/// The arguments of one command, consumed incrementally as commands execute.
/// Empty arguments are values; only `take()` returning nil means exhaustion.
public struct Message: Sendable {
  private let tokens: [Token]
  private var position = 0

  public init(arguments: [String]) { tokens = arguments.map { Token($0) } }
  public init(commandTokens: [Token]) { tokens = commandTokens }

  public var isAtEnd: Bool { position == tokens.count }

  public mutating func take() -> Token? {
    guard !isAtEnd else { return nil }
    defer { position += 1 }
    return tokens[position]
  }

  /// Reads an argument, treating a missing value like an empty value for legacy option grammars.
  public mutating func next() -> Token { take() ?? Token("") }

  /// Peeks at an optional value using the same missing-value convention as `next()`.
  public func peek() -> Token { isAtEnd ? Token("") : tokens[position] }
}

/// Domains recognized by command execution and configuration checking.
public enum Domain: String, CaseIterable, Sendable {
  case config, display, space, window, query, rule, signal, subscribe, batch
}

/// Why a command failed: the message presented to the client. Command code throws it, and the
/// message handler writes it with `Response.fail(_:)`.
public struct CommandError: Error, Sendable, CustomStringConvertible {
  public var text: String
  /// Whether the failure also skips the remaining commands of the message, e.g. after an invalid value whose
  /// arguments cannot be told apart from the next command. Otherwise the next command still runs.
  public var stopsMessage: Bool

  public init(_ text: String, stopsMessage: Bool = false) {
    self.text = text
    self.stopsMessage = stopsMessage
  }

  /// One failure that lists several problems, e.g. every invalid key of a rule, in order.
  public init(combining errors: [CommandError]) {
    var text: String = ""
    for error in errors { text += error.text }
    self.init(text, stopsMessage: errors.contains { $0.stopsMessage })
  }

  /// The same failure, which also skips the remaining commands of the message.
  public var stoppingMessage: CommandError {
    var copy = self
    copy.stopsMessage = true
    return copy
  }

  public var description: String { text }

  /// The failure of a command the domain does not know.
  public static func unknownCommand(_ domain: Token, _ command: Token) -> CommandError {
    CommandError("unknown command '\(command)' for domain '\(domain)'\n")
  }

  /// The failure of a command given an option it does not have.
  public static func unknownOption(_ domain: Token, _ command: Token, _ option: Token)
    -> CommandError
  {
    CommandError(
      "unknown option '\(option)' given to command '\(command)' for domain '\(domain)'\n")
  }

  /// The failure of a command given a value it does not accept. `expected` names the values it takes, e.g.
  /// `one of: a, b`, and is appended as `; expected …`.
  public static func unknownValue(
    _ domain: Token, _ command: Token, _ value: Token, expected: String? = nil
  ) -> CommandError {
    let hint = expected.map { "; expected \($0)" } ?? ""
    return CommandError(
      "unknown value '\(value)' given to command '\(command)' for domain '\(domain)'\(hint)\n")
  }
}
