import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: Tests of `TOMLKeyLocator` (`TOMLKeyLocator.swift`): the line of each key path of a yabai.toml source. The rows
// give one construct each; the property test writes random documents line by line and checks the line of every key.
//

// One construct per row: the source, the key path, and the line it is on.
@Test(
  arguments: [
    // a top-level key, a table header, a key under it, and a key that is not in the file
    ("a = 1\n", "a", 1),
    ("\n\n[config]\nwindow_gap = 1\n", "config", 3),
    ("[config]\nwindow_gap = 1\n", "config.window_gap", 2),
    // quoted and literal keys, a dotted key at the top level, CRLF line ends
    ("[config]\n\"window_gap\" = 1\n", "config.window_gap", 2),
    ("[config]\n'window_gap' = 1\n", "config.window_gap", 2),
    ("[config]\n\"a\\\"b\" = 1\n", "config.a\"b", 2),
    ("config.window_gap = 1\n", "config.window_gap", 1),
    ("[config]\r\nwindow_gap = 1\r\n", "config.window_gap", 2),
    // comments, including key-like text in them, and a `#` inside a string
    ("# window_gap = 9\n[config]\nwindow_gap = 1 # note\n", "config.window_gap", 3),
    ("[[rule]]\nlabel = \"a # b = c\"\napp = \"^x$\"\n", "rule[0].app", 3),
    // a multi-line array: its elements resolve to the line of the key, a key after it to its own line
    (
      "[config]\nspace_layout = [\n  \"15\",\n  \"10:5\", # note\n]\nwindow_gap = 1\n",
      "config.window_gap", 6
    ),
    ("[config]\nspace_layout = [\n  \"15\",\n  \"10:5\",\n]\n", "config.space_layout", 2),
    ("[config]\nspace_layout = [\n  \"15\",\n  \"10:5\",\n]\n", "config.space_layout[1]", 2),
    // a multi-line string with table headers and key-like lines in it, and one with a line continuation
    (
      "[[signal]]\naction = \"\"\"\nwindow_gap = 5\n[rule]\n\"\"\"\nevent = \"window_focused\"\n",
      "signal[0].event", 6
    ),
    ("[[signal]]\naction = '''\nx = 1\n'''\nevent = 'window_focused'\n", "signal[0].event", 5),
    ("[[signal]]\naction = \"\"\"\\\n  x\"\"\"\nevent = \"y\"\n", "signal[0].event", 4),
    // an inline table on one line, and one that spans lines (TOML 1.1)
    ("[[rule]]\napp = \"x\"\ntitle = { not = \"^Copy$\" }\n", "rule[0].title.not", 3),
    ("[[rule]]\ntitle = {\n  not = \"x\",\n}\n", "rule[0].title.not", 3),
    ("[[rule]]\ntitle = {\n  not = \"x\",\n}\n", "rule[0].title", 2),
    // the elements of an array of tables, each with its running index
    ("[[rule]]\napp = \"a\"\n\n[[rule]]\napp = \"b\"\n", "rule[0]", 1),
    ("[[rule]]\napp = \"a\"\n\n[[rule]]\napp = \"b\"\n", "rule[1]", 4),
    ("[[rule]]\napp = \"a\"\n\n[[rule]]\napp = \"b\"\n", "rule[1].app", 5),
    // a dotted table name defines its prefixes too
    ("[a.b]\nc = 1\n", "a", 1),
    ("[a.b]\nc = 1\n", "a.b.c", 2),
    // a key that is missing from the file gives the line of its table header, or of the header of its element
    ("[[space]]\nlabel = \"chat\"\n", "space[0].index", 1),
    ("[config]\n\n", "config.window_gap", 1),
    ("[config]\nwindow_gap = 1\n[[rule]]\n", "rule[0].title", 3),
    // an unknown table
    ("[bogus]\nwindow_gap = 1\n", "bogus", 1),
  ] as [(String, String, Int)])
func locatesTheLineOfAKeyPath(_ source: String, _ keyPath: String, _ line: Int) {
  #expect(TOMLKeyLocator(source: source).line(for: keyPath) == line)
}

@Test(arguments: ["", "nope", "config.nope.deeper", "rule[0]"])
func aPathNotInTheFileWithoutAnEnclosingKeyHasNoLine(_ keyPath: String) {
  #expect(TOMLKeyLocator(source: "a = 1\n").line(for: keyPath) == nil)
}

// The key paths of targetFormat (ConfigDocumentTests.swift), with their lines.
private let targetFormatLines: [(String, Int)] = [
  ("daemon", 3),
  ("daemon.auto_reload", 4),
  ("daemon.load_scripting_addition", 5),
  ("config", 7),
  ("config.mouse_follows_focus", 8),
  ("config.window_shadow", 9),
  ("config.window_gap", 10),
  ("config.active_window_border_color", 11),
  ("config.tab_bar_font", 12),
  ("config.space_layout", 13),
  ("config.space_layout[2]", 13),
  ("config.scratchpad_grid", 14),
  ("config.external_bar", 15),
  ("space[0]", 17),
  ("space[0].index", 18),
  ("space[0].label", 19),
  ("space[0].pin", 20),
  ("space[0].window_gap", 21),
  ("rule[0]", 23),
  ("rule[0].app", 24),
  ("rule[0].space", 25),
  ("rule[0].insert", 26),
  ("rule[1]", 28),
  ("rule[1].label", 29),
  ("rule[1].app", 30),
  ("rule[1].title", 31),
  ("rule[1].title.not", 31),
  ("rule[1].manage", 32),
  ("signal[0]", 34),
  ("signal[0].event", 35),
  ("signal[0].action", 36),
]

@Test(arguments: targetFormatLines)
func everyKeyPathOfTheTargetFormatIsOnItsLine(_ keyPath: String, _ line: Int) {
  #expect(TOMLKeyLocator(source: targetFormat).line(for: keyPath) == line)
}

@Test func everyKeyPathOfTheDecodedTargetFormatHasALine() throws {
  let document = try ConfigDocument.decode(targetFormat)
  let locator = TOMLKeyLocator(source: targetFormat)
  var keyPaths = document.options.map(\.keyPath)
  for space in document.spaces {
    keyPaths += [space.keyPath] + space.options.map(\.keyPath)
    keyPaths += ["\(space.keyPath).index"]
  }
  for rule in document.rules {
    keyPaths += [rule.keyPath] + rule.keys.map(\.keyPath)
  }
  for signal in document.signals {
    keyPaths += [signal.keyPath] + signal.keys.map(\.keyPath)
  }
  #expect(keyPaths.count > 20)
  for keyPath in keyPaths {
    #expect(locator.line(for: keyPath) != nil, "\(keyPath) has no line")
  }
}

// MARK: - Properties

/// Writes a source line by line and records the line of each key path it writes.
private struct SourceWriter {
  var lines: [String] = []
  var expected: [(keyPath: String, line: Int)] = []

  /// Appends one line. A key path given here is expected on that line.
  mutating func line(_ text: String, keyPath: String? = nil) {
    if let keyPath { expected.append((keyPath, lines.count + 1)) }
    lines.append(text)
  }

  var source: String { lines.joined(separator: "\n") + "\n" }
}

private let locatorOptionNames = [
  "window_gap", "mouse_follows_focus", "tab_bar_font", "active_window_border_color",
  "window_shadow",
]
private let locatorStrings = ["x", "a # b", "a = b", "[not.a.header]", "x.y"]

/// A random scalar value of a key.
private func tomlScalar(_ picks: inout Picks) -> String {
  switch picks.next(4) {
  case 0: return picks.bool() ? "true" : "false"
  case 1: return String(picks.next(1000))
  case 2: return "0xff51afef"
  default: return "\"\(locatorStrings[picks.next(locatorStrings.count)])\""
  }
}

/// Blank lines and comment lines, some with key-like and header-like text, between the entries.
private func noise(_ writer: inout SourceWriter, _ picks: inout Picks) {
  for _ in 0..<picks.next(3) {
    switch picks.next(3) {
    case 0: writer.line("")
    case 1: writer.line("# window_gap = 9")
    default: writer.line("# [rule] and label = \"x\"")
    }
  }
}

/// A random document: `[daemon]`, `[config]` with a subset of the options, a multi-line `space_layout`, rules with
/// inline and multi-line `title` tables, spaces, and signals with single- and multi-line actions. Every key path is
/// written on the line that the expectation records.
private func randomSource(_ picks: inout Picks) -> SourceWriter {
  var writer = SourceWriter()
  noise(&writer, &picks)

  if picks.bool() {
    writer.line("[daemon]")
    writer.line("auto_reload = \(picks.bool())", keyPath: "daemon.auto_reload")
    noise(&writer, &picks)
  }

  writer.line("[config]")
  for name in locatorOptionNames where picks.bool() {
    writer.line("\(name) = \(tomlScalar(&picks)) # note", keyPath: "config.\(name)")
    noise(&writer, &picks)
  }
  if picks.bool() {
    let keyLine = writer.lines.count + 1
    writer.line("space_layout = [", keyPath: "config.space_layout")
    for position in 0..<(1 + picks.next(3)) {
      writer.expected.append(("config.space_layout[\(position)]", keyLine))
      writer.line("  \"\(locatorStrings[picks.next(locatorStrings.count)])\",")
    }
    writer.line("]")
    noise(&writer, &picks)
  }

  for position in 0..<picks.next(4) {
    writer.line("[[space]]", keyPath: "space[\(position)]")
    writer.line("index = \(position + 1)", keyPath: "space[\(position)].index")
    if picks.bool() {
      writer.line("label = \"chat\"", keyPath: "space[\(position)].label")
    }
    noise(&writer, &picks)
  }

  for position in 0..<picks.next(4) {
    writer.line("[[rule]]", keyPath: "rule[\(position)]")
    for name in ["label", "app", "manage", "space"] where picks.bool() {
      writer.line("\(name) = \(tomlScalar(&picks))", keyPath: "rule[\(position)].\(name)")
    }
    if picks.bool() {
      if picks.bool() {
        writer.line("title = { not = \"x\" }", keyPath: "rule[\(position)].title")
        writer.expected.append(("rule[\(position)].title.not", writer.lines.count))
      } else {
        writer.line("title = {", keyPath: "rule[\(position)].title")
        writer.line("  not = \"y\",", keyPath: "rule[\(position)].title.not")
        writer.line("}")
      }
    }
    noise(&writer, &picks)
  }

  for position in 0..<picks.next(3) {
    writer.line("[[signal]]", keyPath: "signal[\(position)]")
    writer.line("event = \"window_focused\"", keyPath: "signal[\(position)].event")
    if picks.bool() {
      writer.line("action = \"\"\"", keyPath: "signal[\(position)].action")
      writer.line("window_gap = 5")
      writer.line("[rule]")
      writer.line("\"\"\"")
    } else {
      writer.line("action = \"echo\"", keyPath: "signal[\(position)].action")
    }
    noise(&writer, &picks)
  }
  return writer
}

// NOTE: The generated documents are valid TOML that the decoder accepts, so the rows above are not the only inputs the
// locator sees. Every key path written on a line is found on that line, which covers blank and comment noise,
// multi-line arrays and strings, and inline tables that span lines.
@Test func everyKeyPathIsFoundOnTheLineItWasWrittenOn() async {
  await propertyCheck(count: 300, input: Gen<Int>.int(in: 0...1_000_000).array(of: 0...160)) {
    values in
    var picks = Picks(values)
    let writer = randomSource(&picks)
    let locator = TOMLKeyLocator(source: writer.source)
    #expect((try? ConfigDocument.decode(writer.source)) != nil, "\(writer.source)")
    for (keyPath, line) in writer.expected {
      #expect(
        locator.line(for: keyPath) == line,
        "\(keyPath) should be on line \(line) of:\n\(writer.source)")
    }
  }
}
