import PropertyBased
import Foundation
import Testing
@testable import YabaiCore

//
// NOTE: Tests of the yabairc extractor (`YabaircExtractor.swift`): the words of each message follow sh quoting, lines the
// shell would compute are skipped, and the shipped examples/yabairc gives its one message. The property quotes random
// words with a reference quoting function (single quotes, or double quotes with the escapes) and expects them back.
//

/// One script and the commands it must give.
struct ExtractRow: Sendable, CustomTestStringConvertible
{
    let name: String
    let script: String
    let expected: [ExtractedCommand]

    var testDescription: String { name }
}

private func extracted(_ line: Int, _ arguments: [String]) -> ExtractedCommand
{
    ExtractedCommand(line: line, arguments: arguments, skipped: nil)
}

private func skipped(_ line: Int, _ reason: String) -> ExtractedCommand
{
    ExtractedCommand(line: line, arguments: nil, skipped: reason)
}

private let extractRows: [ExtractRow] = [
    ExtractRow(name: "plain message", script: "yabai -m space --focus 1\n",
               expected: [extracted(1, ["space", "--focus", "1"])]),
    ExtractRow(name: "comments and blank lines", script: "# yabai -m space --focus 1\n\n   \n  yabai -m window --focus 2 # tail\n",
               expected: [extracted(4, ["window", "--focus", "2"])]),
    ExtractRow(name: "hash inside a word is literal", script: "yabai -m rule --add label=a#b\n",
               expected: [extracted(1, ["rule", "--add", "label=a#b"])]),
    ExtractRow(name: "long option spelling", script: "yabai --message query --spaces\n",
               expected: [extracted(1, ["query", "--spaces"])]),
    ExtractRow(name: "continuation keeps the first line", script: #"yabai -m config \"# + "\n    layout  bsp\n",
               expected: [extracted(1, ["config", "layout", "bsp"])]),
    ExtractRow(name: "single quotes are literal", script: #"yabai -m rule --add app='^Safari$' title='a "b" \c'"# + "\n",
               expected: [extracted(1, ["rule", "--add", "app=^Safari$", #"title=a "b" \c"#])]),
    ExtractRow(name: "double quotes and escapes", script: #"yabai -m rule --add title="a \"b\" \\ \$HOME""# + "\n",
               expected: [extracted(1, ["rule", "--add", #"title=a "b" \ $HOME"#])]),
    ExtractRow(name: "unquoted backslash escapes", script: #"yabai -m window --label a\ b"# + "\n",
               expected: [extracted(1, ["window", "--label", "a b"])]),
    ExtractRow(name: "empty quoted word is an argument", script: "yabai -m window '' x\n",
               expected: [extracted(1, ["window", "", "x"])]),
    ExtractRow(name: "single quote across lines", script: "yabai -m rule --add title='a\nb'\nyabai -m space --focus 1\n",
               expected: [extracted(1, ["rule", "--add", "title=a\nb"]), extracted(3, ["space", "--focus", "1"])]),
    ExtractRow(name: "sudo and a path", script: "sudo /opt/homebrew/bin/yabai -m space --focus 1\n",
               expected: [extracted(1, ["space", "--focus", "1"])]),
    ExtractRow(name: "sudo load-sa is not a message", script: "sudo yabai --load-sa\n",
               expected: [skipped(1, "not a message")]),
    ExtractRow(name: "yabai without a message", script: "yabai --restart-service\n",
               expected: [skipped(1, "not a message")]),
    ExtractRow(name: "variable", script: "yabai -m space --focus $ID\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "backticks", script: "yabai -m space --focus `echo 1`\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "command substitution", script: "id=$(yabai -m query --spaces)\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "pipe", script: "yabai -m query --spaces | head -n 1\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "and list", script: "yabai -m space --focus 1 && echo ok\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "redirection", script: "yabai -m query --windows 2>/dev/null\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "glob", script: "yabai -m window --label *\n",
               expected: [skipped(1, "dynamic shell")]),
    ExtractRow(name: "escaped dollar is literal", script: #"yabai -m window --label \$x"# + "\n",
               expected: [extracted(1, ["window", "--label", "$x"])]),
    ExtractRow(name: "if block", script: "if true\nthen\n  yabai -m space --focus 1\nfi\n",
               expected: [skipped(3, "dynamic shell")]),
    ExtractRow(name: "for block", script: "for i in 1 2\ndo\n  yabai -m space --focus 1\ndone\n",
               expected: [skipped(3, "dynamic shell")]),
    ExtractRow(name: "function and braces", script: "f() {\n  yabai -m space --focus 1\n}\nyabai -m space --focus 2\n",
               expected: [skipped(2, "dynamic shell"), extracted(4, ["space", "--focus", "2"])]),
    ExtractRow(name: "case arm", script: "case $x in\n  a) yabai -m space --focus 1 ;;\nesac\n",
               expected: [skipped(2, "dynamic shell")]),
    ExtractRow(name: "unterminated quote", script: "yabai -m rule --add title='abc\n",
               expected: [skipped(1, "unterminated quote")]),
    ExtractRow(name: "other commands are ignored", script: "echo $HOME\nls -l | wc -l\nFOO=1 yabai -m space --focus 1\n",
               expected: []),
]

@Suite("yabairc command extractor")
struct YabaircExtractorTests
{
    @Test(arguments: extractRows)
    func extractsOrSkips(_ row: ExtractRow)
    {
        #expect(extractYabaiCommands(row.script) == row.expected)
    }

    @Test("a line with several list operators skips every command of the line")
    func listOperatorsSkipEveryCommand()
    {
        #expect(extractYabaiCommands("yabai -m space --focus 1; yabai -m space --focus 2\n")
            == [skipped(1, "dynamic shell"), skipped(1, "dynamic shell")])
    }

    @Test("examples/yabairc gives its one message, with the comments left out")
    func exampleFile() throws
    {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "examples/yabairc")
        let script = try String(contentsOf: url, encoding: .utf8)

        let commands = extractYabaiCommands(script)
        #expect(commands.count == 1)
        #expect(commands.first?.line == 15)

        // NOTE: `config` and 30 key-value pairs, one per continued line.
        let arguments = try #require(commands.first?.arguments)
        #expect(arguments.count == 61)
        #expect(arguments.prefix(3) == ["config", "external_bar", "off:40:0"])
        #expect(arguments.suffix(2) == ["mouse_drop_action", "swap"])
        #expect(commands.first?.skipped == nil)
    }
}

/// The reference quoting: single quotes, with each `'` closed, escaped and reopened; or double quotes, with the
/// characters that stay special there (`"`, `\`, `$`, backtick) escaped.
private func quoteWord(_ text: String, double: Bool) -> String
{
    if double
    {
        var quoted = "\""
        for character in text
        {
            if "\"\\$`".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }

    return "'" + text.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "'\\''") + "'"
}

/// One element of choices, picked by index, so that a failing input shrinks towards the first one.
private func pick<Element: Sendable>(_ choices: [Element]) -> Generator<Element, Shrink.Integer<Int>>
{
    Gen<Int>.int(in: 0...(choices.count - 1)).map { choices[$0] }
}

/// Characters of random words: letters, separators, white space, a newline, quotes, every character that the shell
/// treats as special, and multi-byte characters.
private let wordCharacters: [String] = [
    "a", "b", "Z", "0", "-", "=", " ", "\t", "\n", "'", "\"", "\\", "$", "`", "#", ";", "&", "|", "<", ">", "(", ")",
    "*", "?", "[", "~", "!", "{", "}", "é", "e\u{301}", "💥",
]

private let wordGenerator = pick(wordCharacters).array(of: 0...6)
    .map { (characters: [String]) -> String in characters.joined() }
    .eraseToAny()

/// Words, each with the quoting style it is written in.
private let quotedWordGenerator = zip(wordGenerator, pick([false, true])).array(of: 0...4).eraseToAny()

@Suite struct YabaircQuotingPropertyTests
{
    @Test func quotedWordsRoundTrip() async
    {
        await propertyCheck(count: 3000, input: quotedWordGenerator) { words in
            let script = "yabai -m " + words.map { quoteWord($0.0, double: $0.1) }.joined(separator: " ") + "\n"
            #expect(extractYabaiCommands(script) == [extracted(1, words.map(\.0))])
        }
    }
}
