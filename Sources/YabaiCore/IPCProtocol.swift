import Foundation

/// Protocol errors never imply that an already transmitted command is safe to retry.
public enum IPCError: Error, Equatable, Sendable, CustomStringConvertible {
  case incompatibleVersion
  case invalidLength
  case invalidMessage
  case incomplete
  case timedOut
  case io

  public var description: String {
    switch self {
    case .incompatibleVersion: "incompatible IPC protocol; restart yabai after upgrading"
    case .invalidLength: "IPC frame exceeds its size limit or has an empty payload"
    case .invalidMessage: "invalid IPC message"
    case .incomplete: "incomplete IPC response"
    case .timedOut: "timed out waiting for IPC"
    case .io: "IPC socket operation failed"
    }
  }
}

/// One connection carries one command or batch request.
public enum IPCRequest: Codable, Equatable, Sendable {
  case command(arguments: [String])
  case batch(commands: [[String]])

  private enum Key: String, CodingKey { case type, arguments, commands }
  private enum Kind: String, Codable { case command, batch }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .command:
      self = .command(arguments: try container.decode([String].self, forKey: .arguments))
    case .batch: self = .batch(commands: try container.decode([[String]].self, forKey: .commands))
    }
    try validate()
  }

  public func encode(to encoder: any Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .command(let arguments):
      try container.encode(Kind.command, forKey: .type)
      try container.encode(arguments, forKey: .arguments)
    case .batch(let commands):
      try container.encode(Kind.batch, forKey: .type)
      try container.encode(commands, forKey: .commands)
    }
  }

  public func validate() throws(IPCError) {
    switch self {
    case .command(let arguments):
      guard !arguments.isEmpty else { throw .invalidMessage }
    case .batch(let commands):
      guard !commands.isEmpty, commands.allSatisfy({ !$0.isEmpty }) else {
        throw .invalidMessage
      }
    }
  }

  public var isBatch: Bool {
    if case .batch = self { true } else { false }
  }
}

/// JSON decoded by clients. Integers retain their full width instead of passing through Double.
public indirect enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case unsignedInteger(UInt64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .unsignedInteger(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .unsignedInteger(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// Response envelope decoded by the CLI and external clients.
public enum IPCReply: Codable, Equatable, Sendable {
  case output(command: Int, data: JSONValue, format: Format)
  case error(command: Int?, message: String)
  case complete(ok: Bool)
  case subscribed(events: [String])
  case event(data: [String: String])

  public enum Format: String, Codable, Sendable { case text, json }
  private enum Key: String, CodingKey { case type, command, data, format, message, ok, events }
  private enum Kind: String, Codable { case output, error, complete, subscribed, event }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    switch try c.decode(Kind.self, forKey: .type) {
    case .output:
      let command = try c.decode(Int.self, forKey: .command)
      guard command > 0 else { throw IPCError.invalidMessage }
      self = .output(
        command: command, data: try c.decode(JSONValue.self, forKey: .data),
        format: try c.decode(Format.self, forKey: .format))
    case .error:
      let command = try c.decodeIfPresent(Int.self, forKey: .command)
      guard command == nil || command! > 0 else { throw IPCError.invalidMessage }
      self = .error(command: command, message: try c.decode(String.self, forKey: .message))
    case .complete: self = .complete(ok: try c.decode(Bool.self, forKey: .ok))
    case .subscribed: self = .subscribed(events: try c.decode([String].self, forKey: .events))
    case .event: self = .event(data: try c.decode([String: String].self, forKey: .data))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    switch self {
    case .output(let command, let data, let format):
      try c.encode(Kind.output, forKey: .type)
      try c.encode(command, forKey: .command)
      try c.encode(data, forKey: .data)
      try c.encode(format, forKey: .format)
    case .error(let command, let message):
      try c.encode(Kind.error, forKey: .type)
      try c.encodeIfPresent(command, forKey: .command)
      try c.encode(message, forKey: .message)
    case .complete(let ok):
      try c.encode(Kind.complete, forKey: .type)
      try c.encode(ok, forKey: .ok)
    case .subscribed(let events):
      try c.encode(Kind.subscribed, forKey: .type)
      try c.encode(events, forKey: .events)
    case .event(let data):
      try c.encode(Kind.event, forKey: .type)
      try c.encode(data, forKey: .data)
    }
  }
}

/// Encodes typed command results directly into the envelope, without encoding and decoding query JSON twice.
public struct IPCOutput: Encodable, Sendable {
  public let command: Int
  public let entry: Response.Entry

  public init(command: Int, entry: Response.Entry) {
    self.command = command
    self.entry = entry
  }

  private enum Key: String, CodingKey { case type, command, format, data, message }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(command, forKey: .command)
    switch entry {
    case .text(let text):
      try c.encode("output", forKey: .type)
      try c.encode("text", forKey: .format)
      try c.encode(text, forKey: .data)
    case .json(let value):
      try c.encode("output", forKey: .type)
      try c.encode("json", forKey: .format)
      try c.encode(value, forKey: .data)
    case .error(let message):
      try c.encode("error", forKey: .type)
      try c.encode(message, forKey: .message)
    }
  }
}

/// Fixed framing shared by the client, daemon and raw-socket tools.
public enum IPCProtocol {
  public static let version: UInt32 = 2
  public static let headerLength = 12
  public static let requestLimit = 1 << 20
  public static let responseLimit = 64 << 20
  public static let magic: [UInt8] = Array("YBIP".utf8)

  public static func header(length: Int) -> [UInt8] {
    magic + bigEndian(version) + bigEndian(UInt32(length))
  }

  private static func bigEndian(_ value: UInt32) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ]
  }

  public static func payloadLength(_ header: [UInt8], limit: Int) throws(IPCError) -> Int {
    guard header.count == headerLength else { throw .incomplete }
    guard header.prefix(4).elementsEqual(magic),
      integer(header[4..<8]) == version
    else { throw .incompatibleVersion }
    let length = Int(integer(header[8..<12]))
    guard length > 0, length <= limit else { throw .invalidLength }
    return length
  }

  private static func integer(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  public static func encode(_ value: some Encodable, limit: Int) throws(IPCError) -> [UInt8] {
    let payload: [UInt8]
    do { payload = try JSON.encode(value) } catch { throw .invalidMessage }
    guard !payload.isEmpty, payload.count <= min(limit, Int(UInt32.max)) else {
      throw .invalidLength
    }
    return header(length: payload.count) + payload
  }

  public static func decode<T: Decodable>(_ type: T.Type, payload: [UInt8]) throws(IPCError) -> T {
    do { return try JSONDecoder().decode(type, from: Data(payload)) } catch {
      throw .invalidMessage
    }
  }
}
