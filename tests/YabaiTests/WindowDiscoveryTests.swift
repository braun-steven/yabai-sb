import Testing
import YabaiCore

@testable import Yabai

extension DaemonState {
  @Suite
  @WM struct WindowDiscoveryTests {
    private func discoveryWindow(
      _ id: UInt32, role: String, subrole: String
    ) -> Window {
      let owner = Application()
      owner.name = "Safari"

      let target = Window(id: wid(id))
      target.application = owner
      target.isRoot = true
      target.ax.title = "Document"
      target.ax.role = role
      target.ax.subrole = subrole
      return target
    }

    @Test func discoveryAppliesManageRulesBeforeOtherEffects() {
      #expect(
        Golden.run(
          "rule --add app=^Safari$ role=^AXSheet$ subrole=^AXDialog$ manage=on") == [])
      #expect(Golden.run("rule --add app=^Safari$ sticky=on") == [])

      let target = discoveryWindow(1, role: "AXSheet", subrole: "AXDialog")
      let wm = WindowManager.shared
      let plan = wm.discoveryRulePlan(
        for: target, title: "Document", role: "AXSheet", subrole: "AXDialog",
        includingOneShotRules: true)

      #expect(plan.isEligible)
      #expect(plan.manageEffects?.manage == true)
      #expect(plan.effects?.sticky == true)
      #expect(!target.isManagedByRule)
      #expect(!target.isSticky)
      #expect(!target.isEligible)
    }

    @Test func oneShotManageRulesOnlyMakeNewlyObservedWindowsEligible() {
      #expect(
        Golden.run(
          "rule --add --one-shot app=^Safari$ role=^AXSheet$ subrole=^AXDialog$ manage=on") == [])

      let wm = WindowManager.shared
      let newlyObserved = discoveryWindow(1, role: "AXSheet", subrole: "AXDialog")
      let newPlan = wm.discoveryRulePlan(
        for: newlyObserved, title: "Document", role: "AXSheet", subrole: "AXDialog",
        includingOneShotRules: true)
      #expect(newPlan.isEligible)
      #expect(newPlan.manageEffects?.manage == true)
      #expect(newPlan.rulesAfterApplication.first?.matched == true)
      #expect(wm.rules.first?.matched == false)

      let foundLater = discoveryWindow(2, role: "AXSheet", subrole: "AXDialog")
      let laterPlan = wm.discoveryRulePlan(
        for: foundLater, title: "Document", role: "AXSheet", subrole: "AXDialog",
        includingOneShotRules: false)
      #expect(!laterPlan.isEligible)
      #expect(laterPlan.manageEffects == nil)
      #expect(laterPlan.rulesAfterApplication.first?.matched == false)
      #expect(!foundLater.isManagedByRule)
      #expect(!foundLater.isEligible)
    }

    @Test func insertRuleIsRecordedOnlyForNewlyObservedWindows() {
      #expect(Golden.run("rule --add app=^Safari$ insert=east") == [])

      let wm = WindowManager.shared
      let newlyObserved = discoveryWindow(
        1, role: "AXWindow", subrole: "AXStandardWindow")
      #expect(
        wm.applyDiscoveryRules(
          to: newlyObserved, title: "Document", role: "AXWindow", subrole: "AXStandardWindow",
          includingOneShotRules: true))
      #expect(newlyObserved.insertionByRule == .east)

      let foundLater = discoveryWindow(2, role: "AXWindow", subrole: "AXStandardWindow")
      #expect(
        wm.applyDiscoveryRules(
          to: foundLater, title: "Document", role: "AXWindow", subrole: "AXStandardWindow",
          includingOneShotRules: false))
      #expect(foundLater.insertionByRule == nil)
    }
  }
}
