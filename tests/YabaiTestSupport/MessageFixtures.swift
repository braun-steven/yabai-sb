import YabaiCore

extension Message {
  /// Compact parser fixtures spell argument separators as NUL, independently of the IPC protocol.
  public init(_ text: String) { self.init(Array(text.utf8)) }

  public init(_ bytes: [UInt8]) {
    if bytes.isEmpty {
      self.init(arguments: [])
      return
    }
    var pieces = bytes.split(separator: 0, omittingEmptySubsequences: false).map { Token($0) }
    if bytes.last == 0 { pieces.removeLast() }
    self.init(commandTokens: pieces)
  }
}
