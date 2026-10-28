import Testing
import YabaiCore
import YabaiTestSupport

private func parsedRule(_ text: String) throws(CommandError) -> Rule {
  var message = Message("--add\0" + text.split(separator: " ").joined(separator: "\0") + "\0")
  guard case .add(let rule) = try RuleCommand.parse(&message, FixtureContext()) else {
    throw CommandError("expected an add command")
  }
  return rule
}

/// A short text of the effects a rule set: those of the effects round that stay off the window server.
private func describe(_ effects: RuleEffects) -> String {
  var parts: [String] = []
  if let manage = effects.manage { parts.append("manage=\(boolString(manage))") }
  if let sticky = effects.sticky { parts.append("sticky=\(boolString(sticky))") }
  if let follows = effects.mouseFollowsFocus {
    parts.append("mouse_follows_focus=\(boolString(follows))")
  }
  if let layer = effects.layer { parts.append("sub-layer=\(layer.rawValue)") }
  if let scratchpad = effects.scratchpad { parts.append("scratchpad=\(scratchpad)") }
  return parts.joined(separator: " ")
}

struct InsertionCase: CustomTestStringConvertible, Sendable {
  var name: String
  var manage: Bool?
  var insert: InsertDirection?
  var expected: InsertDirection?

  var testDescription: String { name }
}

// NOTE: a rule with manage=off does not tile the window, so its insert= does not apply to it.
@Test(arguments: [
  InsertionCase(name: "no insert", manage: nil, insert: nil, expected: nil),
  InsertionCase(name: "insert", manage: nil, insert: .stack, expected: .stack),
  InsertionCase(name: "insert with manage=on", manage: true, insert: .east, expected: .east),
  InsertionCase(name: "manage=off drops insert", manage: false, insert: .north, expected: nil),
])
func insertionForNewWindowFollowsManage(_ row: InsertionCase) {
  var effects = RuleEffects()
  effects.manage = row.manage
  effects.insert = row.insert
  #expect(effects.insertionForNewWindow == row.expected)
}

@Test func laterRuleInsertWinsAndAbsentInsertKeepsIt() {
  var effects = RuleEffects()
  effects.insert = .north

  var later = RuleEffects()
  later.insert = .stack
  effects.combine(later)
  #expect(effects.insert == .stack)

  effects.combine(RuleEffects())
  #expect(effects.insert == .stack)
}

@Suite struct RuleSetTests {
  /// A row of the matching table: the rules added in order, the window, and the combined effects (nil when no
  /// rule matches).
  struct MatchCase: CustomTestStringConvertible, Sendable {
    var name: String
    var rules: [String]
    var app = "Safari"
    var title = "Document"
    var role = "AXWindow"
    var subrole = "AXStandardWindow"
    var managedByRule = false
    var manageRound = false
    var oneShot = false
    var effects: String?

    var testDescription: String { name }
  }

  static let matchCases: [MatchCase] = [
    MatchCase(
      name: "a later rule overrides",
      rules: [
        "app=^Safari$ sub-layer=above sticky=on",
        "app=Safari sub-layer=below sticky=off",
      ],
      effects: "sticky=off sub-layer=below"),
    MatchCase(
      name: "a later rule only sets its own effects",
      rules: [
        "app=^Safari$ sub-layer=above scratchpad=a", "app=^Safari$ mouse_follows_focus=on",
      ],
      effects: "manage=off mouse_follows_focus=on sub-layer=above scratchpad=a"),
    MatchCase(
      name: "a rule of another app",
      rules: ["app=^Safari$ sub-layer=above", "app=^Mail$ sub-layer=below"],
      effects: "sub-layer=above"),
    MatchCase(name: "an exclusion skips the app", rules: ["app!=^Safari$ sticky=on"]),
    MatchCase(
      name: "an exclusion admits other apps", rules: ["app!=^Safari$ sticky=on"], app: "Mail",
      effects: "sticky=on"),
    MatchCase(
      name: "patterns are not anchored", rules: ["app=far sticky=on"], effects: "sticky=on"),
    MatchCase(name: "patterns are case sensitive", rules: ["app=^safari$ sticky=on"]),
    MatchCase(
      name: "patterns are extended regexes", rules: ["app=^(Mail|Safari)$ sticky=on"],
      effects: "sticky=on"),
    MatchCase(
      name: "the title and the app must match", rules: ["app=^Safari$ title=^Doc sticky=on"],
      effects: "sticky=on"),
    MatchCase(name: "a title mismatch", rules: ["app=^Safari$ title=^Notes sticky=on"]),
    MatchCase(name: "a title exclusion", rules: ["title!=^Doc sticky=on"]),
    MatchCase(
      name: "without a role pattern a sheet is skipped", rules: ["app=^Safari$ sticky=on"],
      role: "AXSheet", subrole: ""),
    MatchCase(
      name: "a role pattern admits its role, the subrole stays standard",
      rules: ["role=^AXSheet$ sticky=on"], role: "AXSheet", subrole: ""),
    MatchCase(
      name: "role and subrole patterns admit a sheet",
      rules: ["role=^AXSheet$ subrole=^$ sticky=on"], role: "AXSheet", subrole: "",
      effects: "sticky=on"),
    MatchCase(
      name: "without a subrole pattern a dialog is skipped", rules: ["app=^Safari$ sticky=on"],
      subrole: "AXDialog"),
    MatchCase(
      name: "a subrole pattern admits a dialog",
      rules: ["app=^Safari$ subrole=^AXDialog$ sticky=on"], subrole: "AXDialog",
      effects: "sticky=on"),
    MatchCase(name: "a role exclusion", rules: ["role!=^AXWindow$ sticky=on"]),
    MatchCase(
      name: "a window managed by a rule gets every effect", rules: ["app=^Safari$ sticky=on"],
      subrole: "AXDialog", managedByRule: true, effects: "sticky=on"),
    MatchCase(
      name: "manage round: manage=on only for standard windows",
      rules: ["app=^Safari$ manage=on"], subrole: "AXDialog", managedByRule: true,
      manageRound: true),
    MatchCase(
      name: "manage round: manage=on of a standard window", rules: ["app=^Safari$ manage=on"],
      manageRound: true, effects: "manage=on"),
    MatchCase(
      name: "manage round: manage=off of a dialog", rules: ["app=^Safari$ manage=off"],
      subrole: "AXDialog", manageRound: true, effects: "manage=off"),
    MatchCase(
      name: "a one-shot rule skipped for an existing window",
      rules: ["--one-shot app=^Safari$ sticky=on"]),
    MatchCase(
      name: "a one-shot rule for a new window",
      rules: ["--one-shot app=^Safari$ sticky=on", "app=^Safari$ sub-layer=above"],
      oneShot: true, effects: "sticky=on sub-layer=above"),
  ]

  @Test(arguments: matchCases)
  func matchingEffects(_ row: MatchCase) throws(CommandError) {
    var rules = RuleSet()
    for text in row.rules { rules.add(try parsedRule(text)) }
    let definitions = rules.definitions
    let effects = rules.matchingEffects(
      for: RuleMatchContext(app: row.app, title: row.title, role: row.role, subrole: row.subrole),
      phase: row.manageRound ? .management : .effects(managedByRule: row.managedByRule),
      lifecycle: row.oneShot ? .newWindow : .existingWindow)
    #expect((effects != nil) == (row.effects != nil))
    #expect(describe(effects ?? RuleEffects()) == (row.effects ?? ""))
    #expect(rules.definitions == definitions)
    for index in rules.indices {
      #expect(
        rules.hasMatched(at: index) == (rules[index].oneShot && row.oneShot && effects != nil))
    }
  }

  @Test func replacementKeepsPrecedenceAndResetsConsumption() throws(CommandError) {
    var rules = RuleSet()
    for text in ["--one-shot label=a app=A", "label=b app=B", "label=a app=C"] {
      rules.add(try parsedRule(text))
    }
    #expect(rules.map(\.label) == ["a", "b"])
    #expect(rules.map { $0.app?.text } == ["C", "B"])
    #expect(!rules[0].oneShot)
    #expect(!rules.hasMatched(at: 0))
    #expect(rules.remove(at: -1) == false)
    #expect(rules.remove(at: 2) == false)
    #expect(rules.remove(label: "missing") == false)
    #expect(rules.remove(at: 0) == true)
    #expect(rules.map(\.label) == ["b"])
  }

  @Test func labelsUseCanonicalStringEquality() throws(CommandError) {
    var rules = RuleSet()
    rules.add(try parsedRule("label=caf\u{E9} app=A"))
    rules.add(try parsedRule("label=cafe\u{301} app=B"))
    #expect(rules.count == 1)
    #expect(rules[0].app?.text == "B")
    #expect(rules.remove(label: "caf\u{E9}") == true)
    #expect(rules.isEmpty)
  }

  @Test func oneShotSurvivesUntilBatchEndAndReplacementResetsIt() throws(CommandError) {
    var rules = RuleSet()
    for text in [
      "--one-shot label=a app=A", "label=b app=B", "--one-shot label=c app=A", "label=d app=D",
    ] {
      rules.add(try parsedRule(text))
    }
    let context = RuleMatchContext(
      app: "A", title: "", role: "AXWindow", subrole: "AXStandardWindow")
    #expect(
      rules.matchingEffects(for: context, phase: .management, lifecycle: .existingWindow) == nil)
    #expect(rules.unmatchedOneShotRules.count == 2)
    #expect(rules.matchingEffects(for: context, phase: .management, lifecycle: .newWindow) != nil)
    #expect(rules.unmatchedOneShotRules.isEmpty)
    #expect(rules.matchingEffects(for: context, phase: .management, lifecycle: .newWindow) != nil)
    rules.add(try parsedRule("--one-shot label=a app=A"))
    #expect(!rules.hasMatched(at: 0))
    rules.removeConsumedOneShotRules()
    #expect(rules.map(\.label) == ["a", "b", "d"])
    #expect(rules.unmatchedOneShotRules.count == 1)
  }

  @Test func absentLayerAndExplicitAutoDiffer() {
    var effects = RuleEffects()
    effects.layer = .above
    effects.combine(RuleEffects())
    #expect(effects.layer == .above)
    var reset = RuleEffects()
    reset.layer = .auto
    effects.combine(reset)
    #expect(effects.layer == .auto)
    var rule = Rule()
    #expect(rule.info(index: 0, display: 0, space: 0).subLayer == "")
    rule.effects = reset
    #expect(rule.info(index: 0, display: 0, space: 0).subLayer == "auto")
    #expect(rule.listFlags() == 0x0004_0000)
  }

  struct ConsumptionCase: Sendable {
    var labels: [String]
    var remaining: [String]
  }

  @Test(arguments: [
    ConsumptionCase(labels: [], remaining: []),
    ConsumptionCase(labels: ["a"], remaining: ["a"]),
    ConsumptionCase(labels: ["a*"], remaining: []),
    ConsumptionCase(labels: ["a*", "b", "c*"], remaining: ["b"]),
    ConsumptionCase(labels: ["a*", "b*", "c"], remaining: ["c"]),
    ConsumptionCase(labels: ["a", "b*", "c", "d"], remaining: ["a", "c", "d"]),
    ConsumptionCase(labels: ["a*", "b*", "c*"], remaining: []),
  ])
  func consumptionKeepsSurvivorOrder(_ row: ConsumptionCase) throws(CommandError) {
    var rules = RuleSet()
    for label in row.labels {
      rules.add(
        try parsedRule(
          (label.hasSuffix("*") ? "--one-shot " : "") + "label=" + label + " app=^Consumed$"))
    }
    _ = rules.matchingEffects(
      for: RuleMatchContext(
        app: "Consumed", title: "", role: "AXWindow", subrole: "AXStandardWindow"),
      phase: .management, lifecycle: .newWindow)
    for index in rules.indices where rules[index].oneShot {
      #expect(rules.hasMatched(at: index))
      #expect(rules[index].listFlags(matched: rules.hasMatched(at: index)) & 0x200 != 0)
    }
    rules.removeConsumedOneShotRules()
    #expect(rules.compactMap(\.label) == row.remaining)
    rules.removeConsumedOneShotRules()
    #expect(rules.compactMap(\.label) == row.remaining)
  }

  @Test func destinationFieldsMergeIndependentlyAndControlFollow() {
    var effects = RuleEffects()
    effects.sid = SpaceID(10)
    effects.followSpace = true
    var later = RuleEffects()
    later.did = DisplayID(20)
    effects.combine(later)
    #expect(effects.sid == SpaceID(10))
    #expect(effects.did == DisplayID(20))
    #expect(!effects.followSpace)
    later = RuleEffects()
    later.sticky = true
    later.followSpace = true
    effects.combine(later)
    #expect(!effects.followSpace)
    later.sid = SpaceID(30)
    effects.combine(later)
    #expect(effects.sid == SpaceID(30))
    #expect(effects.followSpace)
  }
}
