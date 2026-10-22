import PropertyBased
import Testing
@testable import YabaiCore

//
// NOTE: `BatchMessage.decode` takes the tokens that `encode` returns after the domain token. The round trip covers
// empty arguments and multi-byte characters, and every token of a command is read back as the same Token.
//

/// One element of choices, picked by index, so that a failing input shrinks towards the first one.
private func pick<Element: Sendable>(_ choices: [Element]) -> Generator<Element, Shrink.Integer<Int>>
{
    Gen<Int>.int(in: 0...(choices.count - 1)).map { choices[$0] }
}

/// Characters of random arguments: letters, digits, separators, a space, quotes, and multi-byte characters.
private let argumentCharacters: [String] = ["a", "Z", "0", "9", "-", "=", " ", "\"", "'", "$", "é", "e\u{301}", "💥"]

/// An argument of up to five characters, so that many of them are empty.
private let argumentGenerator = pick(argumentCharacters).array(of: 0...5)
    .map { (characters: [String]) -> String in characters.joined() }
    .eraseToAny()

/// The commands of a batch: one to four commands of one to four arguments.
private let commandsGenerator = argumentGenerator.array(of: 1...4).array(of: 1...4).eraseToAny()

/// The tokens of a batch message after the domain token, as bytes.
private func afterDomain(_ commands: [[String]]) -> [[UInt8]]
{
    Array(BatchMessage.encode(commands).dropFirst())
}

/// The bytes of the strings, for the decoder's input.
private func bytes(_ strings: [String]) -> [[UInt8]]
{
    strings.map { Array($0.utf8) }
}

@Suite struct BatchMessageTests
{
    @Test func encodeWritesTheDomainAndCountPrefixedCommands()
    {
        let tokens = BatchMessage.encode([["window", "--focus", "", "west"], ["space"]])
        #expect(tokens == bytes(["batch", "4", "window", "--focus", "", "west", "1", "space"]))
    }

    @Test func decodeReadsCommandsWithEmptyArguments() throws
    {
        let decoded = try BatchMessage.decode(bytes(["4", "window", "--focus", "", "west", "1", "space"]))
        #expect(decoded == [
            [Token("window"), Token("--focus"), Token(""), Token("west")],
            [Token("space")],
        ])
    }

    @Test func decodeAcceptsALeadingZeroCount() throws
    {
        #expect(try BatchMessage.decode(bytes(["01", "a"])) == [[Token("a")]])
    }

    @Test func decodeAcceptsCountLikeArguments() throws
    {
        // The count of a command is read only where a command starts, so a digit argument is an argument.
        #expect(try BatchMessage.decode(bytes(["2", "1", "1"])) == [[Token("1"), Token("1")]])
    }

    @Test(arguments: [
        ([String](), BatchError.emptyBatch),
        (["x"], .malformedCount(command: 1, Token("x"))),
        ([""], .malformedCount(command: 1, Token(""))),
        (["-1", "a"], .malformedCount(command: 1, Token("-1"))),
        (["+1", "a"], .malformedCount(command: 1, Token("+1"))),
        ([" 1", "a"], .malformedCount(command: 1, Token(" 1"))),
        (["1.0", "a"], .malformedCount(command: 1, Token("1.0"))),
        (["0x1", "a"], .malformedCount(command: 1, Token("0x1"))),
        (["99999999999999999999999", "a"], .malformedCount(command: 1, Token("99999999999999999999999"))),
        (["1", "a", "x", "b"], .malformedCount(command: 2, Token("x"))),
        (["0"], .emptyCommand(command: 1)),
        (["1", "a", "0"], .emptyCommand(command: 2)),
        (["1"], .countExceedsTokens(command: 1, count: 1, remaining: 0)),
        (["2", "a"], .countExceedsTokens(command: 1, count: 2, remaining: 1)),
        (["1", "a", "3", "b", "c"], .countExceedsTokens(command: 2, count: 3, remaining: 2)),
    ] as [([String], BatchError)])
    func malformedBatchesAreRefused(_ row: ([String], BatchError))
    {
        do throws(BatchError) {
            _ = try BatchMessage.decode(bytes(row.0))
            Issue.record("\(row.0) decoded, expected \(row.1)")
        } catch {
            #expect(error == row.1)
            #expect(error.message.hasPrefix("batch: "))
            #expect(!error.message.hasSuffix("\n"))
        }
    }

    @Test func singleEmptyArgumentIsAccepted() throws
    {
        // A count of 0 is refused (above); a command with one empty token is accepted, and the command parser refuses it.
        #expect(try BatchMessage.decode(bytes(["1", ""])) == [[Token("")]])
    }

    @Test func roundTripReadsEveryCommandBack() async
    {
        await propertyCheck(count: 3000, input: commandsGenerator) { commands in
            let tokens = BatchMessage.encode(commands)
            #expect(tokens.first == Array("batch".utf8))

            let decoded = try? BatchMessage.decode(Array(tokens.dropFirst()))
            #expect(decoded == commands.map { $0.map { Token($0) } })
        }
    }
}
