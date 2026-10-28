import Foundation
import OSAX
import OrderedCollections
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: Rules and signals. The rule list tests run `rule` and `signal` messages through handleMessage (Golden.run).
// The effects tests apply rules to the fake windows of a Workspace view (TreeFixtures.swift), whose payload messages
// and flushes headless mode records. Left out are the effects that reach the window server or AX for a fake window:
// space=, display= and native-fullscreen= (they read the AX fullscreen attribute of the window, which traps on its nil
// ref) and grid= (AX frames). manage=on and sticky=off only run on windows that are still managed: an unmanaged window
// would be tiled on SpaceID.active, the user's space.
//

// MARK: - Helpers of the daemon tests

/// The response to a message, as text.
@WM private func send(_ line: String) -> String {
  String(decoding: Golden.run(line), as: UTF8.self)
}

private func failure(_ message: String) -> String {
  String(UnicodeScalar(Response.failureByte)) + message
}

/// The entries of a `--list` response as "<index> <label>:<key>", where key is the app (or the title) of a rule, or
/// the action of a signal.
@WM private func listed(_ domain: String, key: String) throws -> [String] {
  let response = Golden.run("\(domain) --list")
  let entries = try #require(
    try JSONSerialization.jsonObject(with: Data(response)) as? [[String: Any]])
  return entries.map { entry in
    let index = entry["index"] as? Int ?? -1
    let label = entry["label"] as? String ?? ""
    let value =
      (entry[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entry["title"] as? String ?? ""
    return "\(index) \(label):\(value)"
  }
}

/// The payload messages recorded since the last drain, as "<operation> w<n>".
private func drainPayloadCalls() -> [String] {
  let names: [UInt8: String] = [
    UInt8(SA_OPCODE_WINDOW_LAYER.rawValue): "layer",
    UInt8(SA_OPCODE_WINDOW_STICKY.rawValue): "sticky",
    UInt8(SA_OPCODE_WINDOW_SHADOW.rawValue): "shadow",
  ]
  return Headless.drain().messages.map { message in
    let id = message[3..<7].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    return "\(names[message[2]] ?? "opcode \(message[2])") w\(id &- treeTestWindowBase)"
  }
}

extension Workspace {
  /// Opens windows 1 to count as standard root windows of Safari, except the last, which belongs to Mail; window 1
  /// has focus.
  @discardableResult
  func openForRules(_ count: UInt32) -> [Window] {
    application.name = "Safari"
    let mail = Application()
    mail.name = "Mail"

    let windows = (1...count).map { n in
      let target = open(n, focus: n == 1)
      target.ax.role = "AXWindow"
      target.ax.subrole = "AXStandardWindow"
      target.ax.title = "Window \(n)"
      target.isRoot = true
      target.ax.isMovable = true
      return target
    }
    windows.last?.application = mail
    view.updateAndFlush()
    _ = Headless.drain()
    return windows
  }
}

extension DaemonState {
  @Suite
  @WM struct RuleTests {
    // MARK: - The rule list

    @Test func addReplacesTheRuleWithTheSameLabel() throws {
      #expect(send("rule --add label=a app=A") == "")
      #expect(send("rule --add label=b app=B") == "")
      #expect(send("rule --add app=C") == "")
      #expect(try listed("rule", key: "app") == ["0 a:A", "1 b:B", "2 :C"])

      // NOTE: the new rule takes the old one's index
      #expect(send("rule --add label=a app=D") == "")
      #expect(try listed("rule", key: "app") == ["0 a:D", "1 b:B", "2 :C"])
    }

    @Test func removeByIndexKeepsTheOrderOfTheOthers() throws {
      for app in ["A", "B", "C", "D"] { _ = send("rule --add app=\(app)") }

      #expect(send("rule --remove 1") == "")
      #expect(try listed("rule", key: "app") == ["0 :A", "1 :C", "2 :D"])
      #expect(send("rule --remove 0") == "")
      #expect(try listed("rule", key: "app") == ["0 :C", "1 :D"])
      #expect(send("rule --remove 1") == "")
      #expect(try listed("rule", key: "app") == ["0 :C"])

      #expect(send("rule --remove 1") == failure("rule with index '1' not found.\n"))
      #expect(
        send("rule --remove -1") == failure("value '-1' is not a valid option for RULE_SEL\n"))
      #expect(send("rule --remove 0") == "")
      #expect(send("rule --list") == "[]\n")
    }

    @Test func removeByLabelKeepsTheOrderOfTheOthers() throws {
      for label in ["a", "b", "c"] {
        _ = send("rule --add label=\(label) app=\(label.uppercased())")
      }

      #expect(send("rule --remove a") == "")
      #expect(try listed("rule", key: "app") == ["0 b:B", "1 c:C"])
      #expect(send("rule --remove a") == failure("rule with label 'a' not found.\n"))
      #expect(send("rule --remove b") == "")
      #expect(try listed("rule", key: "app") == ["0 c:C"])
    }

    @Test func labelsCompareAsStrings() throws {
      // NOTE: precomposed é and e + U+0301 are the same label
      #expect(send("rule --add label=caf\u{E9} app=A") == "")
      #expect(send("rule --add label=cafe\u{301} app=B") == "")
      #expect(try listed("rule", key: "app") == ["0 caf\u{E9}:B"])
      #expect(send("rule --remove cafe\u{301}") == "")
      #expect(send("rule --list") == "[]\n")
    }

    @Test func listShowsTheFiltersAndEffects() throws {
      #expect(
        send(
          "rule --add --one-shot label=x app!=^Finder$ title=Doc role=AXWindow subrole=^AXStandardWindow$ sub-layer=above sticky=off mouse_follows_focus=on scratchpad=pad insert=east manage=on"
        ) == "")

      let response = Golden.run("rule --list")
      let entries = try #require(
        try JSONSerialization.jsonObject(with: Data(response)) as? [[String: Any]])
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
      #expect(rule["insert"] as? String == "east")
      #expect(rule["opacity"] == nil)
      // NOTE: the effects flags (layer) in the high half; the four patterns, the app exclusion and one-shot in the low
      // half
      #expect(rule["flags"] as? String == "0x4011f")
    }

    struct FailureCase: CustomTestStringConvertible, Sendable {
      var command: String
      var failure: String

      var testDescription: String { command }
    }

    @Test(arguments: [
      FailureCase(command: "rule", failure: "unknown command '' for domain 'rule'\n"),
      FailureCase(
        command: "rule --one-shot", failure: "unknown command '--one-shot' for domain 'rule'\n"),
      FailureCase(
        command: "rule --remove", failure: "value '' is not a valid option for RULE_SEL\n"),
      FailureCase(command: "rule --remove 0", failure: "rule with index '0' not found.\n"),
      FailureCase(command: "rule --apply 0", failure: "rule with index '0' not found.\n"),
      FailureCase(
        command: "rule --apply 1.5", failure: "value '1.5' is not a valid option for RULE_SEL\n"),
      FailureCase(command: "rule --apply app=A bogus=1", failure: "unknown key 'bogus'\n"),
      FailureCase(
        command: "rule --add app=A manage=maybe",
        failure: "invalid value 'maybe' for key 'manage'\n"),
      FailureCase(
        command: "rule --add app=[ manage=off", failure: "invalid regex pattern '[' for key 'app'\n"
      ),
      FailureCase(
        command: "rule --add app=A opacity=0.5", failure: "unknown key 'opacity'\n"),
      FailureCase(
        command: "rule --add app=A insert=bogus",
        failure: "invalid value 'bogus' for key 'insert'\n"),
      FailureCase(
        command: "rule --apply nolabel",
        failure:
          "invalid key-value pair 'nolabel'\nmissing required key-value pair 'app[!]=..' or 'title[!]=..'\n"
      ),
    ])
    func ruleFailures(_ row: FailureCase) {
      #expect(send(row.command) == failure(row.failure))
      #expect(WindowManager.shared.rules.isEmpty)
    }

    // MARK: - Applying rules

    enum ApplicationPath: CaseIterable, Sendable {
      case discovery, all, index, label, inline
    }

    private func apply(_ fields: String, through path: ApplicationPath, to target: Window) {
      if path == .inline {
        #expect(send("rule --apply " + fields) == "")
        return
      }
      #expect(send("rule --add label=test " + fields) == "")
      switch path {
      case .discovery:
        WindowManager.shared.applyWindowRules(
          to: target,
          context: RuleMatchContext(
            app: target.application.name, title: target.ax.title ?? "",
            role: target.ax.role ?? "", subrole: target.ax.subrole ?? ""),
          lifecycle: .newWindow)
      case .all: #expect(send("rule --apply") == "")
      case .index: #expect(send("rule --apply 0") == "")
      case .label: #expect(send("rule --apply test") == "")
      case .inline: break
      }
    }

    @Test(arguments: ApplicationPath.allCases, [false, true])
    func everyApplicationPathRequiresAFilterForDialogEffects(
      _ path: ApplicationPath, explicitSubrole: Bool
    ) {
      let workspace = Workspace()
      let windows = workspace.openForRules(2)
      windows[1].ax.subrole = "AXDialog"
      apply(
        "app=^Mail$ sticky=on" + (explicitSubrole ? " subrole=^AXDialog$" : ""),
        through: path, to: windows[1])
      #expect(windows[1].isSticky == explicitSubrole)
      #expect(!windows[0].isSticky)
    }

    @Test(arguments: ApplicationPath.allCases, [false, true])
    func everyApplicationPathRequiresAFilterForManagementOptIn(
      _ path: ApplicationPath, explicitRole: Bool
    ) {
      let workspace = Workspace()
      let windows = workspace.openForRules(2)
      windows[1].ax.role = "AXSheet"
      apply(
        "app=^Mail$ manage=on sticky=on" + (explicitRole ? " role=^AXSheet$" : ""),
        through: path, to: windows[1])
      #expect(windows[1].isManagedByRule == explicitRole)
      #expect(windows[1].isSticky == explicitRole)
      #expect(!windows[0].isSticky)
    }

    @Test func selectedApplicationDoesNotApplyOtherRegisteredRules() {
      let workspace = Workspace()
      let windows = workspace.openForRules(2)
      #expect(send("rule --add app=^Mail$ sticky=on") == "")
      #expect(send("rule --add label=selected app=^Mail$ mouse_follows_focus=on") == "")
      #expect(send("rule --apply selected") == "")
      #expect(!windows[1].isSticky)
      #expect(windows[1].mouseFollowsFocusByRule == true)
    }

    @Test func applyByLabelFloatsTheMatchingWindows() throws {
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

    @Test func applyAllAppliesEveryRuleExceptOneShotRules() throws {
      let space = Workspace()
      let windows = space.openForRules(3)

      #expect(send("rule --add app=^Mail$ sticky=on") == "")
      #expect(
        send("rule --add app=^Safari$ title=^Window.2$ mouse_follows_focus=on sub-layer=above")
          == "")
      #expect(send("rule --add --one-shot label=once app=. manage=off") == "")
      #expect(send("rule --apply") == "")

      #expect(space.order == "w1 w2")
      #expect(windows.map(\.isSticky) == [false, false, true])
      #expect(windows.map(\.isFloating) == [false, false, false])
      #expect(windows.map(\.mouseFollowsFocusByRule) == [nil, true, nil])
      #expect(windows.map(\.layer) == [.auto, .above, .auto])
      #expect(drainPayloadCalls() == ["layer w2", "sticky w3", "layer w3", "shadow w3"])
      // NOTE: one-shot rules are never applied again, by label either
      #expect(send("rule --apply 2") == "")
      #expect(send("rule --apply once") == "")
      #expect(windows.map(\.isFloating) == [false, false, false])
      #expect(!WindowManager.shared.rules.hasMatched(at: 2))
    }

    @Test func applyByIndexSetsTheSubLayer() throws {
      let space = Workspace()
      let windows = space.openForRules(2)

      #expect(send("rule --add app=^Safari$ sub-layer=above") == "")
      #expect(send("rule --add app=^Mail$ sub-layer=below") == "")
      #expect(send("rule --apply 1") == "")
      #expect(windows.map(\.layer) == [.auto, .below])
      #expect(drainPayloadCalls() == ["layer w2"])
      #expect(send("rule --apply 0") == "")
      #expect(windows.map(\.layer) == [.above, .below])
      #expect(drainPayloadCalls() == ["layer w1"])
    }

    @Test func applyAnInlineRuleWithoutAddingIt() throws {
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

    @Test func applyWithoutAMatchChangesNothing() throws {
      let space = Workspace()
      let windows = space.openForRules(2)

      #expect(send("rule --apply app=^Notes$ manage=off") == "")
      windows[0].isRoot = false
      #expect(send("rule --apply app=^Safari$ manage=off") == "")

      #expect(space.order == "w1 w2")
      #expect(windows.map(\.isFloating) == [false, false])
      #expect(drainPayloadCalls() == [])
    }

    // NOTE: applyWindowRules is the rule step of createAndAddWindow (one-shot rules included for a new window) and of
    // reapplyAllRules (never one-shot). createAndAddWindow needs AX windows, so it is called here directly.
    @Test func windowRulesRecordInsertOnlyForNewWindows() throws {
      let space = Workspace()
      let windows = space.openForRules(2)

      #expect(send("rule --add app=^Safari$ insert=stack") == "")
      #expect(send("rule --add --one-shot app=^Mail$ insert=east") == "")

      let wm = WindowManager.shared
      func insertion(of target: Window, oneShotRules: Bool) -> InsertDirection? {
        target.insertionByRule = nil
        #expect(
          wm.applyWindowRules(
            to: target,
            context: RuleMatchContext(
              app: target.application.name, title: "", role: "AXWindow", subrole: "AXStandardWindow"
            ),
            lifecycle: oneShotRules ? .newWindow : .existingWindow))
        return target.insertionByRule
      }

      #expect(insertion(of: windows[0], oneShotRules: false) == nil)
      #expect(insertion(of: windows[1], oneShotRules: false) == nil)
      #expect(insertion(of: windows[1], oneShotRules: true) == .east)
      #expect(insertion(of: windows[0], oneShotRules: true) == .stack)

      // A reapply keeps the insert a new window has not used yet.
      wm.reapplyAllRules()
      #expect(windows[0].insertionByRule == .stack)
    }

    @Test func windowRulesApplyManageBeforeOtherEffects() throws {
      let space = Workspace()
      let windows = space.openForRules(2)
      windows[1].ax.role = "AXSheet"

      // NOTE: sticky= skips a nonstandard window unless the manage round has already marked it managed.
      #expect(send("rule --add app=^Mail$ role=^AXSheet$ manage=on") == "")
      #expect(send("rule --add app=^Mail$ sticky=on") == "")
      _ = drainPayloadCalls()

      #expect(
        WindowManager.shared.applyWindowRules(
          to: windows[1],
          context: RuleMatchContext(
            app: "Mail", title: "Window 2", role: "AXSheet", subrole: "AXStandardWindow"),
          lifecycle: .newWindow))
      #expect(windows[1].isManagedByRule)
      #expect(windows[1].isEligible)
      #expect(windows[1].isSticky)
      #expect(drainPayloadCalls().contains("sticky w2"))
    }

    @Test func oneShotManageRuleOnlyAppliesToNewWindows() throws {
      let space = Workspace()
      let windows = space.openForRules(2)
      windows[1].ax.role = "AXSheet"

      #expect(send("rule --add --one-shot app=^Mail$ role=^AXSheet$ manage=on") == "")

      let wm = WindowManager.shared
      #expect(
        !wm.applyWindowRules(
          to: windows[1],
          context: RuleMatchContext(
            app: "Mail", title: "Window 2", role: "AXSheet", subrole: "AXStandardWindow"),
          lifecycle: .existingWindow))
      #expect(!windows[1].isManagedByRule)
      #expect(wm.rules.hasMatched(at: 0) == false)

      #expect(
        wm.applyWindowRules(
          to: windows[1],
          context: RuleMatchContext(
            app: "Mail", title: "Window 2", role: "AXSheet", subrole: "AXStandardWindow"),
          lifecycle: .newWindow))
      #expect(windows[1].isManagedByRule)
      #expect(wm.rules.hasMatched(at: 0) == true)
    }

    @Test func manageOnOfAManagedWindowKeepsItTiled() throws {
      let space = Workspace()
      let windows = space.openForRules(2)
      windows[1].ax.role = "AXSheet"

      // NOTE: a window that is not real is only eligible once a rule manages it
      #expect(send("rule --apply app=^Mail$ role=^AXSheet$ manage=on sticky=on") == "")
      #expect(windows[1].isManagedByRule)
      #expect(windows[1].isSticky)
      #expect(space.order == "w1")
      #expect(drainPayloadCalls() == ["sticky w2", "layer w2", "shadow w2"])

      #expect(send("rule --apply app=^Safari$ manage=on") == "")
      #expect(windows[0].isManagedByRule)
      #expect(!windows[0].isFloating)
      #expect(space.order == "w1")
    }

    @Test func scratchpadRuleFloatsTheWindow() throws {
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

    @Test func signalsListInEventOrderAndReplaceTheirLabel() throws {
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
      #expect(
        send("signal --remove -1") == failure("value '-1' is not a valid option for SIGNAL_SEL\n"))
      #expect(send("signal --remove") == failure("value '' is not a valid option for SIGNAL_SEL\n"))
      #expect(send("signal") == failure("unknown command '' for domain 'signal'\n"))
    }
  }
}
