import PropertyBased
import Testing
import YabaiTestSupport

@testable import YabaiCore

//
// NOTE: Random messages through the parsers of YabaiCore: each one parses or throws a CommandError, and never traps.
// The tokens mix the keywords of the domains, key-value pairs, numbers that the token parsers find hard (long digit
// runs, non-finite floats, hexadecimal floats) and random bytes, also invalid UTF-8. The daemon's handlers are left
// out: a random message could run a real space or display command.
//

/// The command names of the domains.
private let commandNames: [String] =
  WindowCommand.Name.allCases.map(\.rawValue) + SpaceCommand.Name.allCases.map(\.rawValue)
  + DisplayCommand.Name.allCases.map(\.rawValue) + ConfigCommand.Name.allCases.map(\.rawValue)

/// The values of enums that the commands take.
private let enumValues: [String] =
  WindowLayout.allCases.map(\.rawValue) + WindowToggle.allCases.map(\.rawValue)
  + WindowLayer.allCases.map(\.rawValue) + SpaceToggle.allCases.map(\.rawValue)
  + SpaceCommandLayout.allCases.map(\.rawValue) + SpaceCommandAxis.allCases.map(\.rawValue)
  + SignalType.allCases.map(\.name)

/// Options, selectors and composite values.
private let otherKeywords: [String] = [
  "--displays", "--spaces", "--windows", "--tree", "--display", "--space", "--window",
  "--add", "--remove", "--apply", "--list", "--one-shot",
  "on", "off", "prev", "next", "first", "last", "recent", "north", "east", "south", "west",
  "parent", "child",
  "mouse", "stack", "largest", "smallest", "recover", "stack.", "stack.prev", "stack.1", "stack.0",
  "stack.-1",
  "stack.99999999999", "rel:", "abs:", "rel:0.1", "abs:0.5", "rel:nan", "abs:inf", "rel:-inf",
  "top:", "left:10:",
  "right:nan:0", "bottom_right:inf:-inf", "4:4:1:1:2:2", "1:1:0:0:1:1", "0:0:0:0:0:0", "id,frame",
  "id,", ",",
  "app", "title", "label", "yes", "no", "horizontal", "vertical", "x-axis", "y-axis", "90", "180",
  "270",
]

/// Keywords and values of the domains, as bytes.
private let keywords: [[UInt8]] = (commandNames + enumValues + otherKeywords).map { Array($0.utf8) }

/// Numbers and other values that the token parsers find hard.
private let values: [[UInt8]] = [
  "0", "1", "-1", "-0", "2147483647", "2147483648", "4294967296", "4294967306", "99999999999",
  "999999999999999999999",
  "0x", "0x0", "0xFFFFFFFF", "0x100000000", "0xg", "0X1F", "1e3", "1e40", "-1e40", "0x1p3", " 1",
  "1 ", "nan", "NaN",
  "-nan", "inf", "-inf", "infinity", "1.", ".5", "-.5", "+1", "0.0000001", "é", "e\u{301}", "💥",
  "\u{FEFF}", "label",
  "some.app", "^Safari$", "(", "[", "*", "\\", "regex(", ".*",
].map { Array($0.utf8) }

/// The keys of rules, and one that is none.
private let ruleKeys: [[UInt8]] = [
  "app", "title", "role", "subrole", "label", "display", "space", "grid", "manage",
  "sticky",
  "mouse_follows_focus", "native-fullscreen", "sub-layer", "scratchpad", "unknown", "",
].map { Array($0.utf8) }

/// The keys of signals, and one that is none; event and action twice, since a signal needs both.
private let signalKeys: [[UInt8]] = [
  "event", "event", "action", "action", "app", "title", "active", "label", "unknown", "",
]
.map { Array($0.utf8) }

/// The values of signals: as many event names as other values.
private let signalValues: [[UInt8]] = {
  let others = values + ["yes", "no", "echo"].map { Array($0.utf8) }
  let events = SignalType.allCases.map { Array($0.name.utf8) }
  return others + (0..<(others.count / events.count + 1)).flatMap { _ in events }
}()

/// Bytes of random tokens: separators, digits, letters, a two-byte UTF-8 sequence split in halves, and invalid UTF-8.
private let alphabet: [UInt8] =
  Array(":=!.,-+_^$x0123456789aeinfstkcAF ".utf8) + [0xC3, 0xA9, 0x80, 0xBF, 0xFE, 0xFF]

/// One element of choices, picked by index, so that a failing input shrinks towards the first one.
private func pick<Element: Sendable>(_ choices: [Element]) -> Generator<
  Element, Shrink.Integer<Int>
> {
  Gen<Int>.int(in: 0...(choices.count - 1)).map { choices[$0] }
}

/// A key-value pair with one of keys and of choices, mostly with `=`, sometimes with an exclusion or no separator.
private func pairGenerator(_ keys: [[UInt8]], _ choices: [[UInt8]] = keywords + values)
  -> Generator<[UInt8], AnySequence<Any>>
{
  let separators = ["=", "=", "=", "!=", "!", ""].map { Array($0.utf8) }
  return zip(pick(keys), pick(separators), pick(choices))
    .map { (key: [UInt8], separator: [UInt8], value: [UInt8]) -> [UInt8] in key + separator + value
    }
    .eraseToAny()
}

/// A keyword followed by a value without a separator, e.g. `stack.` and `2147483648`.
private let joinedGenerator = zip(pick(keywords + values), pick(values))
  .map { (first: [UInt8], second: [UInt8]) -> [UInt8] in first + second }

/// One token of a random message, as bytes.
private let tokenGenerator = Gen<[UInt8]>.oneOf(
  pick(keywords).eraseToAny(),
  pick(values).eraseToAny(),
  pairGenerator(ruleKeys + signalKeys),
  joinedGenerator.eraseToAny(),
  pick(alphabet).array(of: 0...8).eraseToAny()
)

/// A command name of a domain and up to two values.
private let commandGenerator = zip(
  pick(commandNames.map { Array($0.utf8) }), tokenGenerator.array(of: 0...2)
)
.map { (name: [UInt8], values: [[UInt8]]) -> [[UInt8]] in [name] + values }

/// The tokens of a random message: mostly commands with their values, and single tokens. An empty token ends the
/// message early, as in the daemon.
private let tokensGenerator = Gen<[[UInt8]]>.frequency(
  (3, commandGenerator.eraseToAny()),
  (1, tokenGenerator.map { [$0] }.eraseToAny())
).array(of: 0...6).map { (segments: [[[UInt8]]]) -> [[UInt8]] in segments.flatMap { $0 } }

/// The tokens of a rule or signal: key-value pairs of keys and choices, or random tokens.
private func pairsGenerator(_ keys: [[UInt8]], _ choices: [[UInt8]] = keywords + values)
  -> Generator<[[UInt8]], AnySequence<Any>>
{
  Gen<[[UInt8]]>.frequency(
    (3, pairGenerator(keys, choices).array(of: 1...6).eraseToAny()),
    (1, tokensGenerator.eraseToAny())
  ).eraseToAny()
}

/// The message of the tokens, after the tokens of prefix.
private func makeMessage(_ tokens: [[UInt8]], after prefix: [String] = []) -> Message {
  Message(commandTokens: (prefix.map { Array($0.utf8) } + tokens).map { Token($0) })
}

/// The tokens for a failure message.
private func describe(_ tokens: [[UInt8]]) -> String {
  tokens.map { String(decoding: $0, as: UTF8.self) }.debugDescription
}

private let context = FixtureContext(
  activeDisplay: 1, activeSpace: 1, acting: 10, displays: [1, 2], spaces: [1, 2, 3], recentSpace: 2,
  displayLabels: ["main": 1], spaceLabels: ["code": 3], windows: [10, 11, 12], stack: [10, 11]
)

/// A failure the parsers throw: a response line.
private func expectResponse(
  _ error: CommandError, _ tokens: [[UInt8]], sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    !error.description.isEmpty && error.description.hasSuffix("\n"),
    "\(error.description.debugDescription) for \(describe(tokens))", sourceLocation: sourceLocation)
}

/// Runs parse on the commands of the message like `runCommands`: a name that is no command is skipped, and a failure
/// that stops the message ends it. Every call reads at least the name, so the loop ends.
private func parseCommands(
  _ tokens: [[UInt8]], _ parse: (Token, inout Message) throws(CommandError) -> Void
) {
  var message = makeMessage(tokens)
  while message.peek().isValid {
    let name = message.next()
    do {
      try parse(name, &message)
    } catch {
      expectResponse(error, tokens)
      if error.stopsMessage { return }
    }
  }
}

@Suite struct ParserPropertyTests {
  @Test func windowCommandsParseOrFail() async {
    await propertyCheck(count: 3000, input: tokensGenerator) { tokens in
      parseCommands(tokens) { (token, source) throws(CommandError) in
        guard let name = WindowCommand.Name(token: token) else { return }
        _ = try WindowCommand.parse(name, &source)
      }
    }
  }

  @Test func spaceAndDisplayCommandsParseOrFail() async {
    await propertyCheck(count: 3000, input: tokensGenerator) { tokens in
      parseCommands(tokens) { (token, source) throws(CommandError) in
        guard let name = SpaceCommand.Name(token: token) else { return }
        _ = try SpaceCommand.parse(name, &source)
      }

      parseCommands(tokens) { (token, source) throws(CommandError) in
        guard let name = DisplayCommand.Name(token: token) else { return }
        _ = try DisplayCommand.parse(name, &source)
      }
    }
  }

  @Test func configNamesAndScopesParseOrFail() async {
    await propertyCheck(count: 3000, input: tokensGenerator) { tokens in
      parseCommands(tokens) { (token, source) throws(CommandError) in
        let (scope, name) = try ConfigCommand.parseScope(token, &source)
        _ = try scope?.resolve(acting: context.activeSpace, context)
        _ = try ConfigCommand.parseName(name)
      }
    }
  }

  @Test func queriesParseOrFail() async {
    await propertyCheck(count: 3000, input: tokensGenerator) { tokens in
      var source = makeMessage(tokens)
      do throws(CommandError) {
        _ = try QueryCommand.parse(&source)
      } catch {
        expectResponse(error, tokens)
      }
    }
  }

  @Test func rulesParseOrFail() async {
    // Most messages start with a rule command, so that they reach the key-value pairs.
    let commands = pick([
      "--add", "--add --one-shot", "--add app=.", "--apply", "--remove", "--list", "",
    ])
    await propertyCheck(count: 3000, input: commands, pairsGenerator(ruleKeys)) { command, tokens in
      var source = makeMessage(tokens, after: command.split(separator: " ").map(String.init))
      do throws(CommandError) {
        _ = try RuleCommand.parse(&source, context)
      } catch {
        expectResponse(error, tokens)
      }

      var pairs = makeMessage(tokens)
      var rule = Rule()
      do throws(CommandError) {
        _ = try parseRule(&pairs, &rule, pairs.take(), context)
      } catch {
        expectResponse(error, tokens)
      }
    }
  }

  @Test func signalsParseOrFail() async {
    // Half of the signals start with a valid event and action, so that the other pairs decide.
    let commands = pick([
      "--add", "--add event=window_created action=echo", "--remove", "--list", "",
    ])
    await propertyCheck(count: 3000, input: commands, pairsGenerator(signalKeys, signalValues)) {
      command, tokens in
      var source = makeMessage(tokens, after: command.split(separator: " ").map(String.init))
      do throws(CommandError) {
        _ = try SignalCommand.parse(&source)
      } catch {
        expectResponse(error, tokens)
      }
    }
  }

  @Test func selectorsParseAndResolveOrFail() async {
    await propertyCheck(count: 3000, input: tokenGenerator) { bytes in
      let token = Token(bytes)
      do throws(CommandError) {
        if let selector = WindowSelector(token) {
          _ = try selector.resolve(acting: context.actingWindow(), context)
        }
        _ = try WindowSelector.optional(token)
      } catch {
        expectResponse(error, [bytes])
      }
      do throws(CommandError) {
        if let selector = SpaceSelector(token) {
          _ = try selector.resolve(acting: context.activeSpace, context)
        }
        _ = try SpaceSelector.required(token)
      } catch {
        expectResponse(error, [bytes])
      }
      do throws(CommandError) {
        if let selector = DisplaySelector(token) {
          _ = try selector.resolve(acting: context.activeDisplay, context)
        }
        _ = try DisplaySelector.required(token)
      } catch {
        expectResponse(error, [bytes])
      }
      do throws(CommandError) {
        _ = try parseInsertSelector(token)
      } catch {
        expectResponse(error, [bytes])
      }
      _ = TreeFocus(token)
      _ = parseKeyValuePair(token)
      _ = token.value
    }
  }
}
