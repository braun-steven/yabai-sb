import Darwin

//
// NOTE: The tokens of a client message and the response the daemon writes. A message is a list of null-separated tokens
// that ends with an empty token. Each token is decoded once into a String, so tokens compare like Swift strings; bytes
// that are not UTF-8 become U+FFFD, also where a failure response echoes the token.
//

/// One argument of a message. Invalid when empty.
public struct Token: Equatable, Sendable {
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

/// Where the parsers take the next token from: a `Message`.
public protocol TokenSource {
  mutating func next() -> Token

  /// The next token, without moving the cursor.
  func peek() -> Token
}

/// A client message, read token by token like `get_token` does.
public struct Message: TokenSource, Sendable {
  private let bytes: [UInt8]
  /// The tokens of one batch command, read as they are (`init(commandTokens:)`). Nil for a client message.
  private let tokens: [Token]?
  private var position = 0

  public init(_ bytes: [UInt8]) {
    self.bytes = bytes
    self.tokens = nil
  }

  /// A message from text with the null separators written out, e.g. "--focus\0east\0".
  public init(_ text: String) {
    self.bytes = Array(text.utf8)
    self.tokens = nil
  }

  //
  // NOTE: A batch command is read from its own tokens, so an empty token is an argument of it. A client message cannot
  // carry one (`next` ends at it), so the tokens of a batch are split by BatchMessage.terminated and read here instead.
  //

  /// The tokens of one command of a batch, each read as it is: an empty token is an argument, and the tokens end the
  /// message after the last one.
  public init(commandTokens tokens: [Token]) {
    self.bytes = []
    self.tokens = tokens
  }

  //
  // NOTE: The token ends at the next null byte. The cursor moves past that null byte only when another token follows,
  // so an empty token (two null bytes) ends the message, and every call after the end returns an empty token.
  //

  /// `get_token`
  public mutating func next() -> Token {
    if let tokens {
      guard position < tokens.count else { return Token("") }
      position += 1
      return tokens[position - 1]
    }

    let start = position
    var end = start
    while end < bytes.count && bytes[end] != 0 { end += 1 }

    position = end
    if end + 1 < bytes.count && bytes[end + 1] != 0 { position = end + 1 }

    return Token(bytes[start..<end])
  }

  /// The next token, without moving the cursor.
  public func peek() -> Token {
    var message = self
    return message.next()
  }

  /// The bytes from the cursor to the end, split at each null byte with the empty pieces kept. A batch reads its tokens
  /// from these (`BatchMessage.terminated`), since `next` ends at an empty token.
  public func rawPieces() -> [[UInt8]] {
    if let tokens {
      return tokens.dropFirst(position).map { Array($0.utf8) }
    }
    return bytes[position...].split(separator: 0, omittingEmptySubsequences: false).map {
      Array($0)
    }
  }
}

/// The domains of a message (`DOMAIN_*`, src/message_parse.c).
public enum Domain {
  public static let config = "config"
  public static let display = "display"
  public static let space = "space"
  public static let window = "window"
  public static let query = "query"
  public static let rule = "rule"
  public static let signal = "signal"
  public static let subscribe = "subscribe"
}

/// printf: the arguments formatted as the C version's fprintf did, e.g. `cFormat("%.4f", Double(value))`.
public func cFormat(_ format: String, _ arguments: any CVarArg...) -> String {
  // NOTE: vsnprintf takes a C va_list and writes into a C buffer. The buffer is sized again when the output is truncated.
  var buffer = [CChar](repeating: 0, count: 64)
  let length = unsafe Int(
    withVaList(arguments) { unsafe vsnprintf(&buffer, buffer.count, format, $0) })

  if length >= buffer.count {
    buffer = [CChar](repeating: 0, count: length + 1)
    _ = unsafe withVaList(arguments) { unsafe vsnprintf(&buffer, buffer.count, format, $0) }
  }

  return String(decoding: buffer[0..<max(length, 0)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The text of a response, built with string interpolation. A number is written as "%d" would.
public struct ResponseText: ExpressibleByStringInterpolation, Sendable {
  public var bytes: [UInt8] = []

  public init(stringLiteral value: String) {
    bytes = Array(value.utf8)
  }

  public init(stringInterpolation: Interpolation) {
    bytes = stringInterpolation.bytes
  }

  public struct Interpolation: StringInterpolationProtocol, Sendable {
    var bytes: [UInt8] = []

    public init(literalCapacity: Int, interpolationCount: Int) {
      bytes.reserveCapacity(literalCapacity + 16 * interpolationCount)
    }

    public mutating func appendLiteral(_ literal: String) { bytes += literal.utf8 }
    public mutating func appendInterpolation(_ token: Token) { bytes += token.utf8 }
    public mutating func appendInterpolation(_ text: String) { bytes += text.utf8 }
    public mutating func appendInterpolation(_ value: Int32) { bytes += String(value).utf8 }
    public mutating func appendInterpolation(_ value: Int) { bytes += String(value).utf8 }
  }
}

/// Why a command failed: the text of its failure response, without the failure byte. Command code throws it, and the
/// message handler writes it with `Response.fail(_:)`.
public struct CommandError: Error, Sendable, CustomStringConvertible {
  public var text: ResponseText
  /// Whether the failure also skips the remaining commands of the message, e.g. after an invalid value whose
  /// arguments cannot be told apart from the next command. Otherwise the next command still runs.
  public var stopsMessage: Bool

  public init(_ text: ResponseText, stopsMessage: Bool = false) {
    self.text = text
    self.stopsMessage = stopsMessage
  }

  /// One failure that lists several problems, e.g. every invalid key of a rule, in order.
  public init(combining errors: [CommandError]) {
    var text: ResponseText = ""
    for error in errors { text.bytes += error.text.bytes }
    self.init(text, stopsMessage: errors.contains { $0.stopsMessage })
  }

  /// The same failure, which also skips the remaining commands of the message.
  public var stoppingMessage: CommandError {
    var copy = self
    copy.stopsMessage = true
    return copy
  }

  public var description: String { String(decoding: text.bytes, as: UTF8.self) }

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

/// The response to a message (`FILE *rsp`).
public struct Response: Sendable {
  /// `FAILURE_MESSAGE` (src/misc/macros.h): the first byte of a failure, which makes the client exit with an error.
  public static let failureByte: UInt8 = 0x07

  public var bytes: [UInt8] = []

  //
  // NOTE: `subscribe` does not end its message: the socket stays open and receives the events of these types, after
  // `bytes`, which hold its first line. The message loop hands the socket to the event subscribers instead of writing
  // the response and closing it. Only a successful subscribe sets this; a failure is an ordinary response.
  //
  /// The event types of a subscription, or nil when the message is not one.
  public var subscribedTypes: [SignalType]?

  public init() {}

  /// The response as a string, for tests.
  public var text: String { String(decoding: bytes, as: UTF8.self) }

  public mutating func write(_ text: ResponseText) {
    bytes += text.bytes
  }

  /// Writes the json of a query response and a newline.
  public mutating func write(json value: some Encodable) throws(CommandError) {
    bytes += try JSON.encode(value)
    bytes.append(UInt8(ascii: "\n"))
  }

  /// Writes a failure: the failure byte, then its text.
  public mutating func fail(_ error: CommandError) {
    bytes.append(Response.failureByte)
    bytes += error.text.bytes
  }
}
