import Foundation
import Testing
import OSAX
import YabaiCore
@testable import Yabai
import YabaiTestSupport

//
// NOTE: Rules and signals. The rule list tests run `rule` and `signal` messages through handleMessage (Golden.run).
// The effects tests apply rules to the fake windows of a Workspace view (TreeFixtures.swift), whose payload messages
// and flushes headless mode records. Left out are the effects that reach the window server or AX for a fake window:
// space=, display= and native-fullscreen= (they read the AX fullscreen attribute of the window, which traps on its nil
// ref) and grid= (AX frames). manage=on and sticky=off only run on windows that are still managed: an unmanaged window
// would be tiled on SpaceID.active, the user's space.
//

// MARK: - Window managers of their own

// The window managers of these tests are local, so they do not touch the state of the daemon.

@WM private func windowManagerCreate() -> WindowManager
{
    return WindowManager()
}

@WM private func windowManagerFree(_ wm: WindowManager)
{
    wm.rules = []
    wm.window.removeAll()
}

@WM private func windowCreate(_ id: WindowID, _ owner: Application? = nil) -> Window
{
    let result = Window(id: id)
    result.application = owner
    return result
}

@WM private func applicationCreate(_ name: String) -> Application
{
    let result = Application()
    result.name = name
    return result
}

private func oneShotTestRule(matched: Bool, _ label: String) -> Rule
{
    var result = Rule()
    result.oneShot = matched
    result.matched = matched
    result.label = label
    return result
}

@Test("window_one_shot_rules") @WM func windowOneShotRules()
{
    let wm = windowManagerCreate()
    defer { windowManagerFree(wm) }

    wm.rules = [oneShotTestRule(matched: true, "a"), oneShotTestRule(matched: false, "b"),
                oneShotTestRule(matched: true, "c"), oneShotTestRule(matched: true, "d")]

    wm.removeOneShotRules()
    #expect(wm.rules.map(\.label) == ["b"])
}

/// The rules before removeOneShotRules (labels, "*" for a matched one-shot rule) and the labels left after it.
struct OneShotCase: CustomTestStringConvertible, Sendable
{
    var rules: [String]
    var left: [String]

    var testDescription: String { rules.joined(separator: " ") }
}

// NOTE: removeOneShotRules swaps the last rule into the place of a removed one and checks that place again.
@Test(arguments: [
    OneShotCase(rules: [], left: []),
    OneShotCase(rules: ["a"], left: ["a"]),
    OneShotCase(rules: ["a*"], left: []),
    OneShotCase(rules: ["a*", "b", "c*"], left: ["b"]),
    OneShotCase(rules: ["a*", "b*", "c"], left: ["c"]),
    OneShotCase(rules: ["a", "b*", "c", "d"], left: ["a", "d", "c"]),
    OneShotCase(rules: ["a*", "b*", "c*"], left: []),
])
@WM func removeOneShotRulesSwapsTheLastRuleIn(_ row: OneShotCase)
{
    let wm = windowManagerCreate()
    defer { windowManagerFree(wm) }

    wm.rules = row.rules.map { oneShotTestRule(matched: $0.hasSuffix("*"), String($0.prefix(1))) }
    wm.removeOneShotRules()
    #expect(wm.rules.compactMap(\.label) == row.left)
}

private func windowRulesTestRule(_ app: String, _ subrole: String?, oneShot: Bool = false) -> Rule
{
    var result = Rule()
    result.oneShot = oneShot
    result.app = RulePattern(Token(app), exclude: false)
    result.subrole = subrole.map { RulePattern(Token($0), exclude: false) }
    return result
}

/// The window properties used when combining matching rule effects.
private struct WindowStrings
{
    let title = ""
    let role = "AXWindow"
    let dialog = "AXDialog"
    let standard = "AXStandardWindow"
}

@Test("window_rules_combine_matching") @WM func windowRulesCombineMatching()
{
    let owner = applicationCreate("Safari")
    let target = windowCreate(1, owner)
    let wm = windowManagerCreate()
    let strings = WindowStrings()
    defer { windowManagerFree(wm) }

    // NOTE: without a subrole pattern a rule does not match a dialog
    var any = windowRulesTestRule("^Safari$", nil)
    any.effects.sid = 4
    wm.rules.append(any)

    var dialog = windowRulesTestRule("^Safari$", "^AXDialog$")
    dialog.effects.sticky = true
    dialog.effects.scratchpad = "notes"
    wm.rules.append(dialog)

    var otherApp = windowRulesTestRule("^Mail$", "^AXDialog$")
    otherApp.effects.mouseFollowsFocus = true
    wm.rules.append(otherApp)

    var oneShot = windowRulesTestRule("^Safari$", "^AXDialog$", oneShot: true)
    oneShot.effects.layer = .above
    oneShot.effects.flags.insert(.layer)
    wm.rules.append(oneShot)

    var effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: false, manageRound: false, into: &effects) == true)
    #expect(effects.sid == nil)
    #expect(effects.sticky == true)
    #expect(effects.mouseFollowsFocus == nil)
    #expect(effects.flags.contains(.layer) == false)
    #expect(effects.scratchpad == "notes")
    #expect(wm.rules[3].matched == false)

    // NOTE: one-shot rules only apply to new windows, and are then marked for removal
    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: true, manageRound: false, into: &effects) == true)
    #expect(effects.flags.contains(.layer) == true)
    #expect(wm.rules[3].matched == true)

    wm.removeOneShotRules()
    #expect(wm.rules.count == 3)

    // NOTE: a window managed by a rule matches rules without a subrole pattern
    target.isManagedByRule = true
    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: false, manageRound: false, into: &effects) == true)
    #expect(effects.sid == 4)
}

@Test("window_rules_manage_round") @WM func windowRulesManageRound()
{
    let owner = applicationCreate("Safari")
    let target = windowCreate(1, owner)
    let wm = windowManagerCreate()
    let strings = WindowStrings()
    defer { windowManagerFree(wm) }

    // NOTE: in the manage round only rules that make a window managed are limited to standard windows
    var manage = windowRulesTestRule("^Safari$", nil)
    manage.effects.manage = true
    wm.rules.append(manage)

    var effectsOnly = windowRulesTestRule("^Safari$", nil)
    effectsOnly.effects.sticky = true
    wm.rules.append(effectsOnly)

    var effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: false, manageRound: true, into: &effects) == true)
    #expect(effects.manage == nil)
    #expect(effects.sticky == true)

    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.standard, includingOneShotRules: false, manageRound: true, into: &effects) == true)
    #expect(effects.manage == true)

    owner.name = "Mail"
    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.standard, includingOneShotRules: false, manageRound: true, into: &effects) == false)
}

// MARK: - Helpers of the daemon tests

/// The response to a message, as text.
@WM private func send(_ line: String) -> String
{
    String(decoding: Golden.run(line), as: UTF8.self)
}

private func failure(_ message: String) -> String
{
    String(UnicodeScalar(Response.failureByte)) + message
}

/// The entries of a `--list` response as "<index> <label>:<key>", where key is the app (or the title) of a rule, or
/// the action of a signal.
@WM private func listed(_ domain: String, key: String) throws -> [String]
{
    let response = Golden.run("\(domain) --list")
    let entries = try #require(try JSONSerialization.jsonObject(with: Data(response)) as? [[String: Any]])
    return entries.map { entry in
        let index = entry["index"] as? Int ?? -1
        let label = entry["label"] as? String ?? ""
        let value = (entry[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entry["title"] as? String ?? ""
        return "\(index) \(label):\(value)"
    }
}

/// A short text of the effects a rule set: those of the effects round that stay off the window server.
private func describe(_ effects: RuleEffects) -> String
{
    var parts: [String] = []
    if let manage = effects.manage { parts.append("manage=\(boolString(manage))") }
    if let sticky = effects.sticky { parts.append("sticky=\(boolString(sticky))") }
    if let follows = effects.mouseFollowsFocus { parts.append("mouse_follows_focus=\(boolString(follows))") }
    if effects.flags.contains(.opacity) { parts.append("opacity=\(effects.opacity)") }
    if effects.flags.contains(.layer) { parts.append("sub-layer=\(effects.layer.rawValue)") }
    if let scratchpad = effects.scratchpad { parts.append("scratchpad=\(scratchpad)") }
    return parts.joined(separator: " ")
}

/// The payload messages recorded since the last drain, as "<operation> w<n>".
private func drainPayloadCalls() -> [String]
{
    let names: [UInt8: String] = [
        UInt8(SA_OPCODE_WINDOW_LAYER.rawValue): "layer",
        UInt8(SA_OPCODE_WINDOW_STICKY.rawValue): "sticky",
        UInt8(SA_OPCODE_WINDOW_SHADOW.rawValue): "shadow",
        UInt8(SA_OPCODE_WINDOW_OPACITY.rawValue): "opacity",
        UInt8(SA_OPCODE_WINDOW_OPACITY_FADE.rawValue): "opacity-fade",
    ]
    return Headless.drain().messages.map { message in
        let id = message[3..<7].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return "\(names[message[2]] ?? "opcode \(message[2])") w\(id &- treeTestWindowBase)"
    }
}

extension Workspace
{
    /// Opens windows 1 to count as standard root windows of Safari, except the last, which belongs to Mail; window 1
    /// has focus.
    @discardableResult
    func openForRules(_ count: UInt32) -> [Window]
    {
        application.name = "Safari"
        let mail = Application()
        mail.name = "Mail"

        let windows = (1...count).map { n in
            let target = open(n, focus: n == 1)
            target.role = "AXWindow" as CFString
            target.subrole = "AXStandardWindow" as CFString
            target.title = "Window \(n)" as CFString
            target.isRoot = true
            target.isMovable = true
            return target
        }
        windows.last?.application = mail
        view.updateAndFlush()
        _ = Headless.drain()
        return windows
    }
}

extension DaemonState
{
    @Suite
    @WM struct RuleTests
    {
        // MARK: - The rule list

        @Test func addReplacesTheRuleWithTheSameLabel() throws
        {
            #expect(send("rule --add label=a app=A") == "")
            #expect(send("rule --add label=b app=B") == "")
            #expect(send("rule --add app=C") == "")
            #expect(try listed("rule", key: "app") == ["0 a:A", "1 b:B", "2 :C"])

            // NOTE: the old rule is swap-removed, and the new one appended
            #expect(send("rule --add label=a app=D") == "")
            #expect(try listed("rule", key: "app") == ["0 :C", "1 b:B", "2 a:D"])
        }

        @Test func removeByIndexMovesTheLastRuleIntoItsPlace() throws
        {
            for app in ["A", "B", "C", "D"] { _ = send("rule --add app=\(app)") }

            #expect(send("rule --remove 1") == "")
            #expect(try listed("rule", key: "app") == ["0 :A", "1 :D", "2 :C"])
            #expect(send("rule --remove 0") == "")
            #expect(try listed("rule", key: "app") == ["0 :C", "1 :D"])
            #expect(send("rule --remove 1") == "")
            #expect(try listed("rule", key: "app") == ["0 :C"])

            #expect(send("rule --remove 1") == failure("rule with index '1' not found.\n"))
            #expect(send("rule --remove -1") == failure("value '-1' is not a valid option for RULE_SEL\n"))
            #expect(send("rule --remove 0") == "")
            #expect(send("rule --list") == "[]\n")
        }

        @Test func removeByLabelMovesTheLastRuleIntoItsPlace() throws
        {
            for label in ["a", "b", "c"] { _ = send("rule --add label=\(label) app=\(label.uppercased())") }

            #expect(send("rule --remove a") == "")
            #expect(try listed("rule", key: "app") == ["0 c:C", "1 b:B"])
            #expect(send("rule --remove a") == failure("rule with label 'a' not found.\n"))
            #expect(send("rule --remove c") == "")
            #expect(try listed("rule", key: "app") == ["0 b:B"])
        }

        @Test func labelsCompareAsStrings() throws
        {
            // NOTE: precomposed é and e + U+0301 are the same label
            #expect(send("rule --add label=caf\u{E9} app=A") == "")
            #expect(send("rule --add label=cafe\u{301} app=B") == "")
            #expect(try listed("rule", key: "app") == ["0 caf\u{E9}:B"])
            #expect(send("rule --remove cafe\u{301}") == "")
            #expect(send("rule --list") == "[]\n")
        }

        @Test func listShowsTheFiltersAndEffects() throws
        {
            #expect(send("rule --add --one-shot label=x app!=^Finder$ title=Doc role=AXWindow subrole=^AXStandardWindow$ opacity=0.5 sub-layer=above sticky=off mouse_follows_focus=on scratchpad=pad manage=on") == "")

            let response = Golden.run("rule --list")
            let entries = try #require(try JSONSerialization.jsonObject(with: Data(response)) as? [[String: Any]])
            let rule = try #require(entries.first)
            #expect(entries.count == 1)
            #expect(rule["label"] as? String == "x")
            #expect(rule["app"] as? String == "^Finder$")
            #expect(rule["title"] as? String == "Doc")
            #expect(rule["role"] as? String == "AXWindow")
            #expect(rule["subrole"] as? String == "^AXStandardWindow$")
            #expect(rule["one-shot"] as? Bool == true)
            #expect(rule["manage"] as? Bool == true)
            #expect(rule["sticky"] as? Bool == false)
            #expect(rule["mouse_follows_focus"] as? Bool == true)
            #expect(rule["sub-layer"] as? String == "above")
            #expect(rule["scratchpad"] as? String == "pad")
            #expect((rule["opacity"] as? Double).map { abs($0 - 0.5) < 1e-6 } == true)
            // NOTE: the effects flags (opacity, layer) in the high half; the four patterns, the app exclusion and
            // one-shot in the low half
            #expect(rule["flags"] as? String == "0x0006011f")
        }

        struct FailureCase: CustomTestStringConvertible, Sendable
        {
            var command: String
            var failure: String

            var testDescription: String { command }
        }

        @Test(arguments: [
            FailureCase(command: "rule", failure: "unknown command '' for domain 'rule'\n"),
            FailureCase(command: "rule --one-shot", failure: "unknown command '--one-shot' for domain 'rule'\n"),
            FailureCase(command: "rule --remove", failure: "value '' is not a valid option for RULE_SEL\n"),
            FailureCase(command: "rule --remove 0", failure: "rule with index '0' not found.\n"),
            FailureCase(command: "rule --apply 0", failure: "rule with index '0' not found.\n"),
            FailureCase(command: "rule --apply 1.5", failure: "value '1.5' is not a valid option for RULE_SEL\n"),
            FailureCase(command: "rule --apply app=A bogus=1", failure: "unknown key 'bogus'\n"),
            FailureCase(command: "rule --add app=A manage=maybe", failure: "invalid value 'maybe' for key 'manage'\n"),
            FailureCase(command: "rule --add app=[ manage=off", failure: "invalid regex pattern '[' for key 'app'\n"),
            FailureCase(command: "rule --add app=A opacity=1.5", failure: "invalid value '1.5' for key 'opacity'\n"),
            FailureCase(command: "rule --apply nolabel", failure: "invalid key-value pair 'nolabel'\nmissing required key-value pair 'app[!]=..' or 'title[!]=..'\n"),
        ])
        func ruleFailures(_ row: FailureCase)
        {
            #expect(send(row.command) == failure(row.failure))
            #expect(WindowManager.shared.rules.isEmpty)
        }

        // MARK: - Matching

        /// A row of the matching table: the rules added in order, the window, and the combined effects (nil when no
        /// rule matches).
        struct MatchCase: CustomTestStringConvertible, Sendable
        {
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

        nonisolated static let matchCases: [MatchCase] = [
            MatchCase(name: "a later rule overrides", rules: ["app=^Safari$ opacity=0.5 sub-layer=above sticky=on", "app=Safari opacity=0.75 sub-layer=below sticky=off"],
                      effects: "sticky=off opacity=0.75 sub-layer=below"),
            MatchCase(name: "a later rule only sets its own effects", rules: ["app=^Safari$ opacity=0.5 scratchpad=a", "app=^Safari$ mouse_follows_focus=on"],
                      effects: "manage=off mouse_follows_focus=on opacity=0.5 scratchpad=a"),
            MatchCase(name: "a rule of another app", rules: ["app=^Safari$ opacity=0.5", "app=^Mail$ opacity=0.75"], effects: "opacity=0.5"),
            MatchCase(name: "an exclusion skips the app", rules: ["app!=^Safari$ sticky=on"]),
            MatchCase(name: "an exclusion admits other apps", rules: ["app!=^Safari$ sticky=on"], app: "Mail", effects: "sticky=on"),
            MatchCase(name: "patterns are not anchored", rules: ["app=far sticky=on"], effects: "sticky=on"),
            MatchCase(name: "patterns are case sensitive", rules: ["app=^safari$ sticky=on"]),
            MatchCase(name: "patterns are extended regexes", rules: ["app=^(Mail|Safari)$ sticky=on"], effects: "sticky=on"),
            MatchCase(name: "the title and the app must match", rules: ["app=^Safari$ title=^Doc sticky=on"], effects: "sticky=on"),
            MatchCase(name: "a title mismatch", rules: ["app=^Safari$ title=^Notes sticky=on"]),
            MatchCase(name: "a title exclusion", rules: ["title!=^Doc sticky=on"]),
            MatchCase(name: "without a role pattern a sheet is skipped", rules: ["app=^Safari$ sticky=on"], role: "AXSheet", subrole: ""),
            MatchCase(name: "a role pattern admits its role, the subrole stays standard", rules: ["role=^AXSheet$ sticky=on"], role: "AXSheet", subrole: ""),
            MatchCase(name: "role and subrole patterns admit a sheet", rules: ["role=^AXSheet$ subrole=^$ sticky=on"], role: "AXSheet", subrole: "", effects: "sticky=on"),
            MatchCase(name: "without a subrole pattern a dialog is skipped", rules: ["app=^Safari$ sticky=on"], subrole: "AXDialog"),
            MatchCase(name: "a subrole pattern admits a dialog", rules: ["app=^Safari$ subrole=^AXDialog$ sticky=on"], subrole: "AXDialog", effects: "sticky=on"),
            MatchCase(name: "a role exclusion", rules: ["role!=^AXWindow$ sticky=on"]),
            MatchCase(name: "a window managed by a rule gets every effect", rules: ["app=^Safari$ sticky=on"], subrole: "AXDialog", managedByRule: true, effects: "sticky=on"),
            MatchCase(name: "manage round: manage=on only for standard windows", rules: ["app=^Safari$ manage=on"], subrole: "AXDialog", managedByRule: true, manageRound: true),
            MatchCase(name: "manage round: manage=on of a standard window", rules: ["app=^Safari$ manage=on"], manageRound: true, effects: "manage=on"),
            MatchCase(name: "manage round: manage=off of a dialog", rules: ["app=^Safari$ manage=off"], subrole: "AXDialog", manageRound: true, effects: "manage=off"),
            MatchCase(name: "a one-shot rule skipped for an existing window", rules: ["--one-shot app=^Safari$ sticky=on"]),
            MatchCase(name: "a one-shot rule for a new window", rules: ["--one-shot app=^Safari$ sticky=on", "app=^Safari$ opacity=0.5"], oneShot: true, effects: "sticky=on opacity=0.5"),
        ]

        @Test(arguments: matchCases)
        func combineMatchingRuleEffects(_ row: MatchCase)
        {
            for rule in row.rules { #expect(send("rule --add \(rule)") == "") }
            let owner = Application()
            owner.name = row.app
            let target = Window(id: wid(1))
            target.application = owner
            target.isManagedByRule = row.managedByRule

            var effects = RuleEffects()
            let matched = WindowManager.shared.combineMatchingRuleEffects(
                for: target, title: row.title, role: row.role, subrole: row.subrole,
                includingOneShotRules: row.oneShot, manageRound: row.manageRound, into: &effects
            )

            #expect(matched == (row.effects != nil))
            #expect(describe(effects) == (row.effects ?? ""))
            // NOTE: a matching one-shot rule is marked for removal
            #expect(WindowManager.shared.rules.map(\.matched) == WindowManager.shared.rules.map { $0.oneShot && row.oneShot && matched })
        }

        // MARK: - Applying rules

        @Test func applyByLabelFloatsTheMatchingWindows() throws
        {
            let space = Workspace()
            let windows = space.openForRules(3)

            #expect(send("rule --add label=float app=^Safari$ manage=off") == "")
            #expect(space.order == "w1 w3 w2")
            #expect(send("rule --apply float") == "")

            #expect(space.order == "w3")
            #expect(windows.map(\.isFloating) == [true, true, false])
            #expect(windows.map(\.isManagedByRule) == [false, false, false])
            #expect(WindowManager.shared.managedWindows[wid(1)] == nil)
            #expect(drainPayloadCalls() == ["layer w1", "shadow w1", "layer w2", "shadow w2"])
            #expect(drainPlacements().map(\.description) == [])
        }

        @Test func applyAllAppliesEveryRuleExceptOneShotRules() throws
        {
            let space = Workspace()
            let windows = space.openForRules(3)

            #expect(send("rule --add app=^Mail$ sticky=on") == "")
            #expect(send("rule --add app=^Safari$ title=^Window.2$ mouse_follows_focus=on sub-layer=above") == "")
            #expect(send("rule --add --one-shot app=. manage=off") == "")
            #expect(send("rule --apply") == "")

            #expect(space.order == "w1 w2")
            #expect(windows.map(\.isSticky) == [false, false, true])
            #expect(windows.map(\.isFloating) == [false, false, false])
            #expect(windows.map(\.mouseFollowsFocusByRule) == [nil, true, nil])
            #expect(windows.map(\.layer) == [.auto, .above, .auto])
            #expect(drainPayloadCalls() == ["layer w2", "sticky w3", "layer w3", "shadow w3"])
            // NOTE: one-shot rules are never applied again, by label either
            #expect(send("rule --apply 2") == "")
            #expect(windows.map(\.isFloating) == [false, false, false])
        }

        @Test func applyByIndexSetsTheOpacity() throws
        {
            let space = Workspace()
            let windows = space.openForRules(2)

            #expect(send("rule --add app=^Safari$ opacity=0.5") == "")
            #expect(send("rule --add app=^Mail$ opacity=0.25") == "")
            #expect(send("rule --apply 1") == "")
            #expect(windows.map(\.opacity) == [0, 0.25])
            #expect(drainPayloadCalls() == ["opacity w2"])
            #expect(send("rule --apply 0") == "")
            #expect(windows.map(\.opacity) == [0.5, 0.25])
            #expect(drainPayloadCalls() == ["opacity w1"])

            Config.current.window.opacityDuration = 0.25
            #expect(send("rule --apply 0") == "")
            #expect(drainPayloadCalls() == ["opacity-fade w1"])
        }

        @Test func applyAnInlineRuleWithoutAddingIt() throws
        {
            let space = Workspace()
            let windows = space.openForRules(2)

            #expect(send("rule --apply app=^Mail$ manage=off") == "")
            #expect(space.order == "w1")
            #expect(windows.map(\.isFloating) == [false, true])
            #expect(WindowManager.shared.rules.isEmpty)

            // NOTE: an existing label takes precedence over the tokens of an inline rule
            #expect(send("rule --add label=app=^Safari$ app=^Mail$ sticky=on") == "")
            #expect(send("rule --apply app=^Safari$") == "")
            #expect(windows.map(\.isSticky) == [false, true])
        }

        @Test func applyWithoutAMatchChangesNothing() throws
        {
            let space = Workspace()
            let windows = space.openForRules(2)

            #expect(send("rule --apply app=^Notes$ manage=off") == "")
            windows[0].isRoot = false
            #expect(send("rule --apply app=^Safari$ manage=off") == "")

            #expect(space.order == "w1 w2")
            #expect(windows.map(\.isFloating) == [false, false])
            #expect(drainPayloadCalls() == [])
        }

        @Test func manageOnOfAManagedWindowKeepsItTiled() throws
        {
            let space = Workspace()
            let windows = space.openForRules(2)
            windows[1].role = "AXSheet" as CFString

            // NOTE: a window that is not real is only eligible once a rule manages it
            #expect(send("rule --apply app=^Mail$ manage=on sticky=on") == "")
            #expect(windows[1].isManagedByRule)
            #expect(windows[1].isSticky)
            #expect(space.order == "w1")
            #expect(drainPayloadCalls() == ["sticky w2", "layer w2", "shadow w2"])

            #expect(send("rule --apply app=^Safari$ manage=on") == "")
            #expect(windows[0].isManagedByRule)
            #expect(!windows[0].isFloating)
            #expect(space.order == "w1")
        }

        @Test func scratchpadRuleFloatsTheWindow() throws
        {
            let space = Workspace()
            let windows = space.openForRules(2)

            #expect(send("rule --apply app=^Mail$ scratchpad=notes") == "")
            #expect(WindowManager.shared.scratchpads["notes"] == windows[1])
            #expect(windows[1].scratchpad == "notes")
            #expect(windows[1].isFloating)
            #expect(space.order == "w1")

            // NOTE: a label taken by another window is not moved, but scratchpad= also sets manage=off
            #expect(send("rule --apply app=^Safari$ scratchpad=notes") == "")
            #expect(WindowManager.shared.scratchpads["notes"] == windows[1])
            #expect(windows[0].scratchpad == nil)
            #expect(windows[0].isFloating)
            #expect(space.order == "")

            Config.current.scratchpad.below = true
            _ = Headless.drain()
            #expect(send("rule --apply app=^Safari$ scratchpad=web") == "")
            #expect(WindowManager.shared.scratchpads["web"] == windows[0])
            #expect(drainPayloadCalls() == ["layer w1"])
        }

        // MARK: - Signals

        @Test func signalsListInEventOrderAndReplaceTheirLabel() throws
        {
            #expect(send("signal --add event=window_focused action=a label=x") == "")
            #expect(send("signal --add event=application_launched action=b") == "")
            #expect(send("signal --add event=window_focused action=c") == "")
            #expect(try listed("signal", key: "action") == ["0 :b", "1 x:a", "2 :c"])

            #expect(send("signal --add event=space_changed action=d label=x") == "")
            #expect(try listed("signal", key: "action") == ["0 :b", "1 :c", "2 x:d"])

            #expect(send("signal --remove 1") == "")
            #expect(try listed("signal", key: "action") == ["0 :b", "1 x:d"])
            #expect(send("signal --remove x") == "")
            #expect(try listed("signal", key: "action") == ["0 :b"])

            #expect(send("signal --remove x") == failure("signal with label 'x' not found.\n"))
            #expect(send("signal --remove 1") == failure("signal with index '1' not found.\n"))
            #expect(send("signal --remove -1") == failure("value '-1' is not a valid option for SIGNAL_SEL\n"))
            #expect(send("signal --remove") == failure("value '' is not a valid option for SIGNAL_SEL\n"))
            #expect(send("signal") == failure("unknown command '' for domain 'signal'\n"))
        }
    }
}
