//
// NOTE: Extracts the `yabai -m` invocations of a shell script, for the tests that check the messages of the skhd recipes
// (examples/skhdrc). It finds each message and splits it into words the way sh does, without running the script. Whatever
// sh would compute makes the invocation skipped instead of guessed. The lexer is the one of the batch input (ShellWords.swift).
//

@testable import YabaiCore

/// Reserved words that open a compound command, and the ones that close it.
private let openingKeywords: Set<String> = [
  "if", "for", "while", "until", "case", "select", "function", "{",
]
private let closingKeywords: Set<String> = ["fi", "done", "esac", "}"]
/// Reserved words that only introduce the next command of their segment.
private let continuationKeywords: Set<String> = ["then", "do", "else", "elif"]

/// One `yabai -m` invocation of a script, or the reason it was not extracted.
struct ExtractedCommand: Equatable, Sendable {
  /// The 1-based line of the invocation's first word. A command continued with a backslash starts on its first line.
  let line: Int

  /// The words after `-m`, starting with the domain (`space`, `window`, ...); `-m` itself is not included. These are
  /// the words that `ClientMessage.encode` takes as bytes (`map { Array($0.utf8) }`). Nil when skipped.
  let arguments: [String]?

  /// Why the invocation was not extracted: `not a message`, `dynamic shell` or `unterminated quote`. Nil when
  /// `arguments` is set.
  let skipped: String?
}

/// The `yabai -m` invocations of a script, in order. A line that the shell would compute is reported as skipped with
/// `dynamic shell`: a `$` that starts an expansion (`$name`, `${…}`, `$1`, `$@`, `$(…)`, `$[…]`, `$'…'`, `$"…"`, and
/// `$` before a byte above ASCII, which bash expands in a UTF-8 locale), backticks, `;`, `&`, `|`, parentheses,
/// redirections, unquoted glob characters and `~`, and any command inside a compound command (`if`, `for`, `while`,
/// `until`, `case`, `select`, `function`, braces). A `$` that is not followed by one of these is literal, as in sh. Comments
/// (`#` at the start of a word) and blank lines are ignored. Lines that do not run yabai are ignored. `yabai` without
/// `-m` or `--message` (e.g. `sudo yabai --load-sa`) is skipped as `not a message`. A `yabai` path ending in `/yabai`
/// and a leading `sudo` are accepted. Only the first word of a command counts (after `sudo`), so `FOO=1 yabai -m …`
/// is not extracted.
func extractYabaiCommands(_ script: String) -> [ExtractedCommand] {
  var commands: [ExtractedCommand] = []
  var depth = 0  // compound commands open at the current segment
  var lexer = ScriptLexer(script)

  for scriptLine in lexer.lex() {
    for segment in scriptLine.segments {
      var words = segment.words[...]

      // NOTE: Reserved words lead a segment: `if x; then yabai …` and `{ yabai …; }` put the command after them.
      while let first = words.first, !first.quoted {
        if openingKeywords.contains(first.string) {
          depth += 1
        } else if closingKeywords.contains(first.string) {
          depth = max(0, depth - 1)
        } else if !continuationKeywords.contains(first.string) {
          break
        }
        words = words.dropFirst()
      }

      if words.first?.string == "sudo" { words = words.dropFirst() }
      guard let program = words.first, isYabai(program.string) else { continue }

      let rest = words.dropFirst()
      let isMessage = rest.first.map { $0.string == "-m" || $0.string == "--message" } ?? false
      if !isMessage {
        commands.append(
          ExtractedCommand(line: segment.line, arguments: nil, skipped: "not a message"))
      } else if let skipped = scriptLine.reason ?? (depth > 0 ? "dynamic shell" : nil) {
        commands.append(ExtractedCommand(line: segment.line, arguments: nil, skipped: skipped))
      } else {
        commands.append(
          ExtractedCommand(
            line: segment.line, arguments: rest.dropFirst().map(\.string), skipped: nil))
      }
    }
  }

  return commands
}
