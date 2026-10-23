import Foundation
import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: `BatchMessage.decode` takes the tokens that `encode` returns after the domain token. The round trip covers
// empty arguments and multi-byte characters, and every token of a command is read back as the same Token.
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

/// The commands of a batch: one to four commands of one to four arguments.
private let commandsGenerator = argumentGenerator.array(of: 1...4).array(of: 1...4).eraseToAny()

/// The tokens of a batch message after the domain token, as bytes.
private func afterDomain(_ commands: [[String]]) -> [[UInt8]] {
  Array(BatchMessage.encode(commands).dropFirst())
}

/// The bytes of the strings, for the decoder's input.
private func bytes(_ strings: [String]) -> [[UInt8]] {
  strings.map { Array($0.utf8) }
}

@Suite struct BatchMessageTests {
  @Test func encodeWritesTheDomainAndCountPrefixedCommands() {
    let tokens = BatchMessage.encode([["window", "--focus", "", "west"], ["space"]])
    #expect(tokens == bytes(["batch", "4", "window", "--focus", "", "west", "1", "space"]))
  }

  @Test func decodeReadsCommandsWithEmptyArguments() throws {
    let decoded = try BatchMessage.decode(
      bytes(["4", "window", "--focus", "", "west", "1", "space"]))
    #expect(
      decoded == [
        [Token("window"), Token("--focus"), Token(""), Token("west")],
        [Token("space")],
      ])
  }

  @Test func decodeAcceptsALeadingZeroCount() throws {
    #expect(try BatchMessage.decode(bytes(["01", "a"])) == [[Token("a")]])
  }

  @Test func decodeAcceptsCountLikeArguments() throws {
    // The count of a command is read only where a command starts, so a digit argument is an argument.
    #expect(try BatchMessage.decode(bytes(["2", "1", "1"])) == [[Token("1"), Token("1")]])
  }

  @Test(
    arguments: [
      ([String](), BatchError.emptyBatch),
      (["x"], .malformedCount(command: 1, Token("x"))),
      ([""], .malformedCount(command: 1, Token(""))),
      (["-1", "a"], .malformedCount(command: 1, Token("-1"))),
      (["+1", "a"], .malformedCount(command: 1, Token("+1"))),
      ([" 1", "a"], .malformedCount(command: 1, Token(" 1"))),
      (["1.0", "a"], .malformedCount(command: 1, Token("1.0"))),
      (["0x1", "a"], .malformedCount(command: 1, Token("0x1"))),
      (
        ["99999999999999999999999", "a"],
        .malformedCount(command: 1, Token("99999999999999999999999"))
      ),
      (["1", "a", "x", "b"], .malformedCount(command: 2, Token("x"))),
      (["0"], .emptyCommand(command: 1)),
      (["1", "a", "0"], .emptyCommand(command: 2)),
      (["1"], .countExceedsTokens(command: 1, count: 1, remaining: 0)),
      (["2", "a"], .countExceedsTokens(command: 1, count: 2, remaining: 1)),
      (["1", "a", "3", "b", "c"], .countExceedsTokens(command: 2, count: 3, remaining: 2)),
    ] as [([String], BatchError)])
  func malformedBatchesAreRefused(_ row: ([String], BatchError)) {
    do throws(BatchError) {
      _ = try BatchMessage.decode(bytes(row.0))
      Issue.record("\(row.0) decoded, expected \(row.1)")
    } catch {
      #expect(error == row.1)
      #expect(error.message.hasPrefix("batch: "))
      #expect(!error.message.hasSuffix("\n"))
    }
  }

  @Test func singleEmptyArgumentIsAccepted() throws {
    // A count of 0 is refused (above); a command with one empty token is accepted, and the command parser refuses it.
    #expect(try BatchMessage.decode(bytes(["1", ""])) == [[Token("")]])
  }

  @Test func roundTripReadsEveryCommandBack() async {
    await propertyCheck(count: 3000, input: commandsGenerator) { commands in
      let tokens = BatchMessage.encode(commands)
      #expect(tokens.first == Array("batch".utf8))

      let decoded = try? BatchMessage.decode(Array(tokens.dropFirst()))
      #expect(decoded == commands.map { $0.map { Token($0) } })
    }
  }
}

//
// NOTE: The daemon reads a batch from the pieces after its domain token (Message.rawPieces, empty pieces kept): the
// tokens end at the empty piece where a count is due (BatchMessage.terminated), and each command is read from its own
// tokens (Message(commandTokens:)). The client parses stdin with parseBatchInput, so a script's line reaches the
// daemon as the same tokens. The message is built as the daemon reads it: the payload with the two padding nulls.
//

/// A message as the daemon reads it from a client, for the batch commands.
private func daemonMessage(_ commands: [[String]]) -> Message {
  let payload = Array(
    ClientMessage.encode(BatchMessage.encode(commands)).dropFirst(MemoryLayout<Int32>.size))
  return Message(payload + [0, 0])
}

/// The pieces of a batch as the daemon reads them, with the domain token already read.
private func batchTokens(_ message: inout Message) -> [[UInt8]] {
  #expect(message.next().equals(BatchMessage.domain))
  return BatchMessage.terminated(message.rawPieces())
}

/// The output of parseBatchInput, or the error it throws.
private func parsedInput(_ text: String) -> Result<[[String]], BatchInputError> {
  do throws(BatchInputError) {
    return .success(try parseBatchInput(text))
  } catch {
    return .failure(error)
  }
}

@Suite struct BatchReadingTests {
  @Test(
    arguments: [
      ([String](), []),
      (["", ""], []),
      (["1", "a", "", ""], ["1", "a"]),
      (["2", "a", "", "", ""], ["2", "a", ""]),
      (["1", "a", "1", ""], ["1", "a", "1", ""]),
      (["1", "a", "2", "b"], ["1", "a", "2", "b"]),
      (["3", "a", "b", "", ""], ["3", "a", "b", ""]),
      (["x", "a"], ["x"]),
      (["1", "a", "", "x"], ["1", "a"]),
    ] as [([String], [String])])
  func terminatedEndsAtTheEmptyCount(_ row: ([String], [String])) {
    #expect(BatchMessage.terminated(bytes(row.0)) == bytes(row.1))
  }

  @Test func commandsOfAClientMessageAreReadWithTheirEmptyArguments() throws {
    var message = daemonMessage([["window", "--focus", "", "west"], ["space"]])
    let decoded = try BatchMessage.decode(batchTokens(&message))
    #expect(
      decoded == [
        [Token("window"), Token("--focus"), Token(""), Token("west")],
        [Token("space")],
      ])
  }

  @Test func aBatchWithNoCommandsHasNoTokens() {
    var message = daemonMessage([])
    #expect(batchTokens(&message).isEmpty)
  }

  @Test func aCommandMessageReadsEveryTokenIncludingEmptyOnes() {
    var command = Message(commandTokens: [
      Token("window"), Token("--focus"), Token(""), Token("west"),
    ])
    #expect(command.next() == Token("window"))
    #expect(command.next() == Token("--focus"))
    #expect(command.next() == Token(""))
    #expect(command.next() == Token("west"))
    #expect(command.next() == Token(""))
    #expect(command.next() == Token(""))
    #expect(command.peek() == Token(""))
  }

  @Test func aCommandMessageEndsAfterItsLastToken() {
    var command = Message(commandTokens: [Token("space")])
    #expect(command.peek() == Token("space"))
    #expect(command.next() == Token("space"))
    #expect(!command.next().isValid)
  }

  @Test func rawPiecesKeepEmptyPiecesFromTheCursor() {
    var message = Message(
      bytes(["batch", "2", "a", "", ""]).reduce(into: [UInt8]()) { $0 += $1 + [0] })
    #expect(message.next() == Token("batch"))
    #expect(message.rawPieces() == bytes(["2", "a", "", "", ""]))
  }

  @Test func stdinReachesTheDaemonAsTheSameCommands() throws {
    let commands = try parseBatchInput("window --focus '' west\nspace --focus 1\n")
    var message = daemonMessage(commands)
    let decoded = try BatchMessage.decode(batchTokens(&message))
    #expect(
      decoded == [
        [Token("window"), Token("--focus"), Token(""), Token("west")],
        [Token("space"), Token("--focus"), Token("1")],
      ])
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
    ] as [(String, [[String]])])
  func linesBecomeCommands(_ row: (String, [[String]])) {
    #expect(parsedInput(row.0) == .success(row.1))
  }

  @Test(
    arguments: [
      ("space --focus $ID\n", 1, "dynamic shell"),
      ("space --focus 1\n\nspace --focus `id`\n", 3, "dynamic shell"),
      ("space --focus 1; space --focus 2\n", 1, "dynamic shell"),
      ("window --label *\n", 1, "dynamic shell"),
      ("space --focus 1 > /dev/null\n", 1, "dynamic shell"),
      ("window --label 'x\n", 1, "unterminated quote"),
      ("window --label a\nwindow --label \"b\n", 2, "unterminated quote"),
      ("yabai -m\n", 1, "no command"),
      ("# note\n\nyabai --message\n", 3, "no command"),
      ("space --focus 1\nspace --focus $1\nspace --focus 3\n", 2, "dynamic shell"),
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
