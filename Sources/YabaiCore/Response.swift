/// A JSON result produced by a command. Each case encodes as its value, without an enum wrapper.
public enum JSONResult: Encodable, Sendable {
  case display(DisplayInfo)
  case displays([DisplayInfo])
  case space(SpaceInfo)
  case spaces([SpaceInfo])
  case window(WindowInfo)
  case windows([WindowInfo])
  case tree(TreeNode)
  case rules([RuleInfo])
  case signals([SignalInfo])

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .display(let value): try value.encode(to: encoder)
    case .displays(let value): try value.encode(to: encoder)
    case .space(let value): try value.encode(to: encoder)
    case .spaces(let value): try value.encode(to: encoder)
    case .window(let value): try value.encode(to: encoder)
    case .windows(let value): try value.encode(to: encoder)
    case .tree(let value): try value.encode(to: encoder)
    case .rules(let value): try value.encode(to: encoder)
    case .signals(let value): try value.encode(to: encoder)
    }
  }
}

/// Ordered command results, independent of sockets and CLI formatting.
public struct Response: Sendable {
  public enum Entry: Sendable {
    case text(String)
    case json(JSONResult)
    case error(String)
  }

  public enum Disposition: Sendable {
    case finished
    case subscribe([SignalType])
  }

  public private(set) var entries: [Entry] = []
  public var disposition = Disposition.finished

  public init() {}

  public var failures: [String] {
    entries.compactMap { if case .error(let text) = $0 { text } else { nil } }
  }

  /// Text output used by configuration reconciliation; JSON and errors are separate entries.
  public var text: String {
    entries.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
  }

  public mutating func write(_ text: String) { entries.append(.text(text)) }
  public mutating func write(json value: JSONResult) { entries.append(.json(value)) }
  public mutating func fail(_ error: CommandError) { entries.append(.error(error.text)) }
}
