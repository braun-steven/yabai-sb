import Foundation
import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: Batch stdin parsing preserves quoted arguments and rejects dynamic shell input before transmission.
//

/// One element of choices, picked by index, so that a failing input shrinks towards the first one.
private func pick<Element: Sendable>(_ choices: [Element]) -> Generator<
  Element, Shrink.Integer<Int>
> {
  Gen<Int>.int(in: 0...(choices.count - 1)).map { choices[$0] }
}

/// Characters of random arguments: letters, digits, separators, a space, quotes, and multi-byte characters.
private let argumentCharacters: [String] = [
  "a", "Z", "0", "9", "-", "=", " ", "\"", "'", "$", "é", "e\u{301}", "💥",
]

/// An argument of up to five characters, so that many of them are empty.
private let argumentGenerator = pick(argumentCharacters).array(of: 0...5)
  .map { (characters: [String]) -> String in characters.joined() }
  .eraseToAny()

/// The output of parseBatchInput, or the error it throws.
private func parsedInput(_ text: String) -> Result<[[String]], BatchInputError> {
  do throws(BatchInputError) {
    return .success(try parseBatchInput(text))
  } catch {
    return .failure(error)
  }
}

@Suite struct BatchInputTests {
  @Test(
    arguments: [
      ("window --focus east\n", [["window", "--focus", "east"]]),
      (
        "yabai -m space --focus 1\nyabai --message space --focus 2\n",
        [["space", "--focus", "1"], ["space", "--focus", "2"]]
      ),
      ("# a comment\n\n   \n  space --focus 1 # tail\n", [["space", "--focus", "1"]]),
      ("window --label ''\n", [["window", "--label", ""]]),
      ("window --label a\\ b 'c d' \"e\"\n", [["window", "--label", "a b", "c d", "e"]]),
      ("window --label ';'\n", [["window", "--label", ";"]]),
      ("window --label '*'\n", [["window", "--label", "*"]]),
      ("window --label '?'\n", [["window", "--label", "?"]]),
      ("window --label '['\n", [["window", "--label", "["]]),
      ("window --label \\;\n", [["window", "--label", ";"]]),
      ("window --label \\*\n", [["window", "--label", "*"]]),
      ("window --label \\?\n", [["window", "--label", "?"]]),
      ("window --label \\[\n", [["window", "--label", "["]]),
      ("window --label '$HOME'\n", [["window", "--label", "$HOME"]]),
      ("window --label \"\\$HOME\"\n", [["window", "--label", "$HOME"]]),
      ("config \\\n    layout bsp\n", [["config", "layout", "bsp"]]),
      (
        "space --focus 1\r\nspace --focus 2",
        [["space", "--focus", "1"], ["space", "--focus", "2"]]
      ),
      (
        "rule --add app='^Safari$' title=\"a \\\"b\\\"\"\n",
        [["rule", "--add", "app=^Safari$", "title=a \"b\""]]
      ),
      ("", [[String]]()),
      // NOTE: a reserved word that is quoted, or not the first word, is a plain word.
      ("window --label fi\n'if' x\n", [["window", "--label", "fi"], ["if", "x"]]),
    ] as [(String, [[String]])])
  func linesBecomeCommands(_ row: (String, [[String]])) {
    #expect(parsedInput(row.0) == .success(row.1))
  }

  @Test(
    arguments: [
      ("space --focus $ID\n", 1, "dynamic shell"),
      ("window --label \"$HOME\"\n", 1, "dynamic shell"),
      ("space --focus 1\n\nspace --focus `id`\n", 3, "dynamic shell"),
      ("space --focus 1; space --focus 2\n", 1, "dynamic shell"),
      ("window --label *\n", 1, "dynamic shell"),
      ("space --focus 1 > /dev/null\n", 1, "dynamic shell"),
      ("window --label 'x\n", 1, "unterminated quote"),
      ("window --label a\nwindow --label \"b\n", 2, "unterminated quote"),
      ("yabai -m\n", 1, "no command"),
      ("# note\n\nyabai --message\n", 3, "no command"),
      ("space --focus 1\nspace --focus $1\nspace --focus 3\n", 2, "dynamic shell"),
      ("if true\nthen\nspace --focus 2\nfi\n", 1, "dynamic shell"),
      ("space --focus 1\nfi\n", 2, "dynamic shell"),
      ("{\nspace --focus 1\n}\n", 1, "dynamic shell"),
      ("! space --focus 1\n", 1, "dynamic shell"),
    ] as [(String, Int, String)])
  func aLineTheShellWouldComputeIsAnErrorNamingIt(_ row: (String, Int, String)) {
    #expect(parsedInput(row.0) == .failure(BatchInputError(line: row.1, reason: row.2)))
  }
}

@Suite struct BatchExampleTests {
  /// The heredoc of examples/batch.sh is a batch: its lines parse as commands.
  @Test func exampleHeredocParsesAsBatchInput() throws {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "examples/batch.sh")
    let lines = try String(contentsOf: url, encoding: .utf8).split(
      separator: "\n", omittingEmptySubsequences: false)

    let start = try #require(lines.firstIndex(of: "yabai -m batch <<'EOF'"))
    let end = try #require(lines[start...].firstIndex(of: "EOF"))
    let body = lines[(start + 1)..<end].joined(separator: "\n")
    #expect(
      try parseBatchInput(body) == [
        ["config", "window_gap", "6"],
        ["config", "top_padding", "12"],
        ["config", "bottom_padding", "12"],
      ])
  }
}
