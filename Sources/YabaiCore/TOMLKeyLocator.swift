//
// NOTE: `TOMLKeyLocator` finds the line of a key path of a `yabai.toml` file. It is a locator, not a parser:
// TOMLDecoder has already accepted the text when the locator runs, so the scan only has to read well-formed input
// correctly. It never fails; on malformed input it may miss a key, and `line(for:)` then falls back to an enclosing
// key or header.
//

/// The line of each key path of a TOML source, 1-based. Key paths have the form of `ConfigDocumentError.keyPath`:
/// `config.window_gap`, `space[0].index`, `rule[3].app.not`, or a bare top-level key.
public struct TOMLKeyLocator: Equatable, Sendable {
  private let lines: [String: Int]

  public init(source: String) {
    var scanner = TOMLLineScanner(bytes: Array(source.utf8))
    scanner.scan()
    lines = scanner.lines
  }

  /// The line of `keyPath`. A path that is not in the file, such as a required key that is missing or an element of an
  /// array, gives the line of its nearest enclosing key or table header. Nil when no enclosing one is in the file.
  public func line(for keyPath: String) -> Int? {
    var path = keyPath
    while true {
      if let line = lines[path] { return line }
      guard let parent = parentPath(of: path) else { return nil }
      path = parent
    }
  }
}

/// `rule[3].app` gives `rule[3]`, `config.space_layout[2]` gives `config.space_layout`, and `config` gives nil.
private func parentPath(of path: String) -> String? {
  if path.hasSuffix("]"), let open = path.lastIndex(of: "[") {
    return String(path[..<open])
  }
  if let dot = path.lastIndex(of: ".") {
    return String(path[..<dot])
  }
  return nil
}

/// Joins a key path and the parts of a dotted key.
private func joined(_ prefix: String, _ parts: [String]) -> String {
  ([prefix] + parts).filter { !$0.isEmpty }.joined(separator: ".")
}

/// Walks the bytes of a TOML source once, tracking the line and the current table header, and records the line of
/// every key and table. A key path keeps the first line it is seen on. A dotted key, a dotted table name or a key of an
/// inline table also records each of its prefixes, unless the prefix is already known.
private struct TOMLLineScanner {
  private let bytes: [UInt8]
  private var position = 0
  private var line = 1
  private var arrayCounts: [String: Int] = [:]
  private(set) var lines: [String: Int] = [:]

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// Scans the whole source. Every iteration consumes at least one byte, so malformed input cannot loop.
  mutating func scan() {
    var table = ""
    while true {
      skipBlankLines()
      guard let byte = current else { return }
      if byte == UInt8(ascii: "[") {
        table = header()
      } else {
        keyValue(table: table)
      }
    }
  }

  // MARK: - Cursor

  private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

  private func isAt(_ character: Unicode.Scalar) -> Bool {
    current == UInt8(ascii: character)
  }

  /// Moves past one byte, counting the lines.
  private mutating func advance() {
    if isAt("\n") { line += 1 }
    position += 1
  }

  private mutating func skipSpaces() {
    while isAt(" ") || isAt("\t") { position += 1 }
  }

  /// Skips to the newline that ends the current line; the newline itself is left for `advance`.
  private mutating func skipToLineEnd() {
    while let byte = current, byte != UInt8(ascii: "\n") { position += 1 }
  }

  /// Skips spaces, tabs, newlines and comments.
  private mutating func skipBlankLines() {
    while let byte = current {
      switch byte {
      case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"):
        advance()
      case UInt8(ascii: "#"):
        skipToLineEnd()
      default:
        return
      }
    }
  }

  private func hasPrefix(_ text: String) -> Bool {
    let needle = Array(text.utf8)
    guard position + needle.count <= bytes.count else { return false }
    return needle.indices.allSatisfy { bytes[position + $0] == needle[$0] }
  }

  // MARK: - Recording

  private mutating func record(_ path: String, _ line: Int) {
    if lines[path] == nil { lines[path] = line }
  }

  /// Records `prefix.parts[0]`, `prefix.parts[0].parts[1]`, and so on, at `line`. A nil prefix records nothing.
  private mutating func record(prefix: String?, parts: [String], line: Int) {
    guard let prefix else { return }
    var path = prefix
    for part in parts {
      path = joined(path, [part])
      record(path, line)
    }
  }

  // MARK: - Lines

  /// A table header `[name]` or `[[name]]`. Returns the key path that the keys below it are prefixed with.
  private mutating func header() -> String {
    let headerLine = line
    advance()
    let isArray = isAt("[")
    if isArray { advance() }
    skipSpaces()
    let parts = parseKey() ?? []
    skipToLineEnd()
    guard !parts.isEmpty else { return "" }
    let name = parts.joined(separator: ".")
    guard isArray else {
      record(prefix: "", parts: parts, line: headerLine)
      return name
    }
    // NOTE: Each `[[name]]` is the next element of the array, so its key path has the running index of the array.
    let index = arrayCounts[name, default: 0]
    arrayCounts[name] = index + 1
    let path = "\(name)[\(index)]"
    record(path, headerLine)
    return path
  }

  /// A `key = value` line, recorded under `table` (empty at the top level).
  private mutating func keyValue(table: String) {
    let keyLine = line
    guard let parts = parseKey() else {
      skipToLineEnd()
      return
    }
    skipSpaces()
    guard isAt("=") else {
      skipToLineEnd()
      return
    }
    advance()
    skipSpaces()
    record(prefix: table, parts: parts, line: keyLine)
    value(path: joined(table, parts))
    skipToLineEnd()
  }

  /// The value after `=`. An inline table records its keys under `path`; arrays and strings are skipped. `path` is nil
  /// inside an array, where no key path is recorded.
  private mutating func value(path: String?) {
    guard let byte = current else { return }
    switch byte {
    case UInt8(ascii: "{"):
      inlineTable(path: path)
    case UInt8(ascii: "["):
      array()
    case UInt8(ascii: "\""):
      basicString()
    case UInt8(ascii: "'"):
      literalString()
    default:
      // NOTE: A number, a boolean or a date ends at a space, a comment or a separator.
      while let next = current, !Self.scalarEnds.contains(next) { position += 1 }
    }
  }

  private static let scalarEnds: Set<UInt8> = [
    UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"),
    UInt8(ascii: "#"),
    UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"),
  ]

  /// `{ key = value, … }`, which may span lines in TOML 1.1. Each key is recorded under `path`.
  private mutating func inlineTable(path: String?) {
    advance()
    while true {
      skipBlankLines()
      guard let byte = current else { return }
      if byte == UInt8(ascii: "}") {
        advance()
        return
      }
      let keyLine = line
      guard let parts = parseKey() else { return }
      skipSpaces()
      guard isAt("=") else { return }
      advance()
      skipSpaces()
      record(prefix: path, parts: parts, line: keyLine)
      value(path: path.map { joined($0, parts) })
      skipSpaces()
      if isAt(",") { advance() }
    }
  }

  /// `[ value, … ]`, which may span lines and hold inline tables. Its elements are not recorded.
  private mutating func array() {
    advance()
    while true {
      skipBlankLines()
      guard let byte = current else { return }
      if byte == UInt8(ascii: "]") {
        advance()
        return
      }
      let start = position
      value(path: nil)
      skipBlankLines()
      if isAt(",") { advance() }
      if position == start { advance() }
    }
  }

  /// `"…"` or `"""…"""`, with backslash escapes. A single-line string stops at its line end when it is not closed.
  private mutating func basicString() {
    if hasPrefix("\"\"\"") {
      position += 3
      while let byte = current {
        if byte == UInt8(ascii: "\\") {
          advance()
          if current != nil { advance() }
        } else if hasPrefix("\"\"\"") {
          position += 3
          // NOTE: Up to two more quotes right after the closing delimiter belong to the string.
          for _ in 0..<2 where isAt("\"") { position += 1 }
          return
        } else {
          advance()
        }
      }
      return
    }
    position += 1
    while let byte = current, byte != UInt8(ascii: "\n") {
      position += 1
      if byte == UInt8(ascii: "\\") {
        if isAt("\n") { advance() } else if current != nil { position += 1 }
      } else if byte == UInt8(ascii: "\"") {
        return
      }
    }
  }

  /// `'…'` or `'''…'''`, without escapes.
  private mutating func literalString() {
    if hasPrefix("'''") {
      position += 3
      while current != nil {
        if hasPrefix("'''") {
          position += 3
          for _ in 0..<2 where isAt("'") { position += 1 }
          return
        }
        advance()
      }
      return
    }
    position += 1
    while let byte = current, byte != UInt8(ascii: "\n") {
      position += 1
      if byte == UInt8(ascii: "'") { return }
    }
  }

  /// A dotted key: bare keys (`A-Za-z0-9_-`), basic keys `"…"` and literal keys `'…'`, separated by dots.
  private mutating func parseKey() -> [String]? {
    var parts: [String] = []
    while true {
      skipSpaces()
      guard let part = simpleKey() else { return parts.isEmpty ? nil : parts }
      parts.append(part)
      skipSpaces()
      guard isAt(".") else { return parts }
      advance()
    }
  }

  private mutating func simpleKey() -> String? {
    if isAt("\"") {
      let start = position + 1
      basicString()
      // NOTE: Only `\"` and `\\` are decoded; a key that needs another escape is not matched to its decoded name.
      let end = max(start, position - 1)
      return String(decoding: unescaped(bytes[start..<end]), as: UTF8.self)
    }
    if isAt("'") {
      let start = position + 1
      literalString()
      let end = max(start, position - 1)
      return String(decoding: bytes[start..<end], as: UTF8.self)
    }
    let start = position
    while let byte = current, Self.isBareKeyByte(byte) { position += 1 }
    guard position > start else { return nil }
    return String(decoding: bytes[start..<position], as: UTF8.self)
  }

  private static func isBareKeyByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
      return true
    default:
      return false
    }
  }

  private func unescaped(_ slice: ArraySlice<UInt8>) -> [UInt8] {
    var result: [UInt8] = []
    var index = slice.startIndex
    while index < slice.endIndex {
      let next = index + 1
      if slice[index] == UInt8(ascii: "\\"), next < slice.endIndex,
        slice[next] == UInt8(ascii: "\"") || slice[next] == UInt8(ascii: "\\")
      {
        result.append(slice[next])
        index += 2
      } else {
        result.append(slice[index])
        index += 1
      }
    }
    return result
  }
}
