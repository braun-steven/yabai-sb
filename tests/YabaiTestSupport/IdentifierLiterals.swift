import YabaiCore

//
// NOTE: Tests write ids as integer literals. The daemon cannot: no id is nil, never 0.
//

extension WindowID: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: UInt32) { self.init(rawValue: value) }
}

extension SpaceID: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: UInt64) { self.init(rawValue: value) }
}

extension DisplayID: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: UInt32) { self.init(rawValue: value) }
}
