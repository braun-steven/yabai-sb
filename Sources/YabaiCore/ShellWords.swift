//
// NOTE: The sh word lexer. It splits a script into logical lines of words the way sh does, without running it. Whatever sh
// would compute (variables, command substitution, lists, pipes, redirections, globs, compound commands) is reported as a
// reason on its line instead of being guessed, so a word that is kept is exactly the word the shell would pass. The stdin
// of `yabai -m batch` is read with it (parseBatchInput). The tests extract the `yabai -m` invocations of a script with
// the same lexer (tests/YabaiTests/Support/ShellCommandExtractor.swift).
//

/// `yabai`, or a path ending in `/yabai`.
func isYabai(_ program: String) -> Bool {
  program == "yabai" || program.hasSuffix("/yabai")
}

/// A word of a script: its bytes, and whether any part of it was quoted (a quoted word is never a reserved word).
struct ScriptWord {
  var bytes: [UInt8] = []
  var quoted = false

  /// The word as text. The bytes come from valid UTF-8 and are split only at ASCII bytes, so this is exact.
  var string: String { String(decoding: bytes, as: UTF8.self) }
}

/// The words of one simple command: the text between list operators, which are `;`, `&`, `|`, parentheses and
/// redirections, or a newline. `line` is the line of its first word.
struct ScriptSegment {
  let line: Int
  let words: [ScriptWord]
}

/// A logical line: the text up to an unquoted newline, with backslash continuations joined. `line` is the line where it
/// starts. `reason` names the first construct that the shell would compute on this line, and it applies to every
/// segment of the line.
struct ScriptLine {
  let line: Int
  let segments: [ScriptSegment]
  let reason: String?
}

/// Splits a script into logical lines of words, following sh quoting. Single quotes are literal. Double quotes keep
/// backticks and a `$` that starts an expansion (both make the line dynamic), and treat a backslash before `"`, `\`,
/// `$`, a backtick or a newline as an escape. Any other `$` is a literal byte (see `startsExpansion`). An unquoted
/// backslash escapes the next byte. A `\r` directly before a `\n` belongs to the line ending: it is dropped, and so is
/// the `\r` of a backslash continuation (`\` then `\r\n`). Only ASCII bytes are special, so multi-byte characters pass
/// through unchanged.
struct ScriptLexer {
  private enum Quote {
    case none, single, double
  }

  private let bytes: [UInt8]
  private var index = 0
  private var line = 1
  private var quote = Quote.none
  private var lines: [ScriptLine] = []
  private var segments: [ScriptSegment] = []
  private var words: [ScriptWord] = []
  private var segmentLine = 1
  private var lineStart = 1
  private var word: ScriptWord?
  private var reason: String?

  init(_ script: String) {
    bytes = Array(script.utf8)
  }

  mutating func lex() -> [ScriptLine] {
    while index < bytes.count {
      switch quote
      {
      case .none: lexUnquoted()
      case .single: lexSingleQuoted()
      case .double: lexDoubleQuoted()
      }
    }

    if quote != .none { mark("unterminated quote") }
    endLine()
    return lines
  }

  private mutating func mark(_ construct: String) {
    reason = reason ?? construct
  }

  /// Starts a word when none is in progress. The first word of a segment gives the segment its line.
  private mutating func startWord() {
    guard word == nil else { return }
    if words.isEmpty { segmentLine = line }
    word = ScriptWord()
  }

  private mutating func add(_ byte: UInt8, quoted: Bool) {
    startWord()
    word?.bytes.append(byte)
    if quoted { word?.quoted = true }
  }

  /// Starts a word even when it stays empty (`''` is an argument).
  private mutating func markQuoted() {
    startWord()
    word?.quoted = true
  }

  private mutating func endWord() {
    if let finished = word {
      words.append(finished)
      word = nil
    }
  }

  private mutating func endSegment() {
    endWord()
    if !words.isEmpty {
      segments.append(ScriptSegment(line: segmentLine, words: words))
      words = []
    }
  }

  private mutating func endLine() {
    endSegment()
    lines.append(ScriptLine(line: lineStart, segments: segments, reason: reason))
    lineStart = line
    segments = []
    reason = nil
  }

  /// Whether the `$` before `position` starts an expansion, so that the line is dynamic. The next byte decides: a
  /// name start, a digit, `{`, `(`, `[` (arithmetic), a special parameter, or a byte above ASCII (a name start in a
  /// UTF-8 locale). Unquoted, `'` and `"` also start `$'…'` and `$"…"`. Inside double quotes they are literal.
  /// Anything else (end of input, white space, `/`, `:`, `=`, `^`, `.`, a closing `"`) leaves `$` literal.
  private func startsExpansion(at position: Int, doubleQuoted: Bool) -> Bool {
    guard position < bytes.count else { return false }

    switch bytes[position]
    {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"),
      UInt8(ascii: "_"), UInt8(ascii: "{"), UInt8(ascii: "("), UInt8(ascii: "["), 0x80...0xFF:
      return true
    case UInt8(ascii: "@"), UInt8(ascii: "*"), UInt8(ascii: "#"), UInt8(ascii: "?"),
      UInt8(ascii: "$"),
      UInt8(ascii: "!"), UInt8(ascii: "-"):
      return true
    case UInt8(ascii: "'"), UInt8(ascii: "\""):
      return !doubleQuoted
    default:
      return false
    }
  }

  private mutating func lexUnquoted() {
    let byte = bytes[index]
    index += 1

    switch byte
    {
    case UInt8(ascii: " "), UInt8(ascii: "\t"):
      endWord()

    case UInt8(ascii: "\r") where index < bytes.count && bytes[index] == UInt8(ascii: "\n"):
      // NOTE: The `\r` of a CRLF line ending is not part of the last word; the `\n` after it ends the line.
      break

    case UInt8(ascii: "\n"):
      line += 1
      endLine()

    case UInt8(ascii: "#") where word == nil:
      // NOTE: `#` starts a comment only at the start of a word; `a#b` is one word, as in sh.
      while index < bytes.count && bytes[index] != UInt8(ascii: "\n") { index += 1 }

    case UInt8(ascii: "\\"):
      guard index < bytes.count else {
        add(byte, quoted: true)
        return
      }
      let next = bytes[index]
      index += 1
      if next == UInt8(ascii: "\n") {
        line += 1
      } else if next == UInt8(ascii: "\r") && index < bytes.count
        && bytes[index] == UInt8(ascii: "\n")
      {
        // NOTE: `\` then CRLF is a continuation too; the `\r` belongs to the line ending.
        index += 1
        line += 1
      } else {
        add(next, quoted: true)
      }

    case UInt8(ascii: "'"):
      quote = .single
      markQuoted()

    case UInt8(ascii: "\""):
      quote = .double
      markQuoted()

    case UInt8(ascii: "$"):
      if startsExpansion(at: index, doubleQuoted: false) { mark("dynamic shell") }
      add(byte, quoted: false)

    case UInt8(ascii: "`"):
      mark("dynamic shell")
      add(byte, quoted: false)

    case UInt8(ascii: ";"), UInt8(ascii: "&"), UInt8(ascii: "|"), UInt8(ascii: "("),
      UInt8(ascii: ")"),
      UInt8(ascii: "<"), UInt8(ascii: ">"):
      mark("dynamic shell")
      endSegment()

    case UInt8(ascii: "*"), UInt8(ascii: "?"), UInt8(ascii: "["):
      mark("dynamic shell")
      add(byte, quoted: false)

    case UInt8(ascii: "~") where word == nil:
      mark("dynamic shell")
      add(byte, quoted: false)

    default:
      add(byte, quoted: false)
    }
  }

  private mutating func lexSingleQuoted() {
    let byte = bytes[index]
    index += 1

    if byte == UInt8(ascii: "'") {
      quote = .none
      return
    }
    if byte == UInt8(ascii: "\n") { line += 1 }
    add(byte, quoted: true)
  }

  private mutating func lexDoubleQuoted() {
    let byte = bytes[index]

    switch byte
    {
    case UInt8(ascii: "\""):
      index += 1
      quote = .none

    case UInt8(ascii: "\\") where index + 1 < bytes.count:
      let next = bytes[index + 1]
      switch next
      {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "$"), UInt8(ascii: "`"):
        add(next, quoted: true)
        index += 2
      case UInt8(ascii: "\n"):
        line += 1
        index += 2
      default:
        add(byte, quoted: true)
        index += 1
      }

    case UInt8(ascii: "$"):
      index += 1
      if startsExpansion(at: index, doubleQuoted: true) { mark("dynamic shell") }
      add(byte, quoted: true)

    case UInt8(ascii: "`"):
      index += 1
      mark("dynamic shell")
      add(byte, quoted: true)

    default:
      index += 1
      if byte == UInt8(ascii: "\n") { line += 1 }
      add(byte, quoted: true)
    }
  }
}

/// The reserved words of sh and bash that can start a command. Unquoted, they make the command a compound command (or a
/// negated pipeline), which only a shell runs.
private let reservedWords: Set<String> = [
  "if", "then", "else", "elif", "fi", "do", "done", "case", "esac", "while", "until", "for",
  "select",
  "function", "{", "}", "!", "[[", "]]",
]

/// Why the stdin of `yabai -m batch` could not be read: the 1-based line where the command starts, and the reason, which
/// is one of the reasons the lexer gives (`dynamic shell`, `unterminated quote`) or `no command`.
public struct BatchInputError: Error, Equatable, Sendable {
  public let line: Int
  public let reason: String

  public init(line: Int, reason: String) {
    self.line = line
    self.reason = reason
  }
}

/// The commands on the stdin of `yabai -m batch`, in order, each as its words after `-m`. One command per line, read
/// with the sh quoting of the lexer (ScriptLexer). Blank lines and comments (`#` at the start of a word) are skipped, and
/// a leading `yabai -m` (or `--message`) is stripped. Nothing is run by a shell, so a line that the shell would compute
/// (variables, substitutions, lists, pipes, redirections, globs, an unquoted reserved word such as `if` or `fi` that
/// starts a command) is an error naming its line, and so is a line with no command after `-m`.
public func parseBatchInput(_ input: String) throws(BatchInputError) -> [[String]] {
  var commands: [[String]] = []
  var lexer = ScriptLexer(input)

  for scriptLine in lexer.lex() {
    if let reason = scriptLine.reason {
      throw BatchInputError(line: scriptLine.line, reason: reason)
    }

    guard let segment = scriptLine.segments.first else { continue }
    if let first = segment.words.first, !first.quoted, reservedWords.contains(first.string) {
      throw BatchInputError(line: scriptLine.line, reason: "dynamic shell")
    }

    var words = segment.words.map(\.string)
    if words.count >= 2, isYabai(words[0]), words[1] == "-m" || words[1] == "--message" {
      words.removeFirst(2)
    }

    guard !words.isEmpty else { throw BatchInputError(line: scriptLine.line, reason: "no command") }
    commands.append(words)
  }

  return commands
}
