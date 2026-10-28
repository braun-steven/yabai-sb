import ApplicationServices
import CPrivate
import SortedCollections
import YabaiCore

extension WindowManager {
  func queryWindowRules(into response: inout Response) throws(CommandError) {
    try response.write(
      json: rules.enumerated().map { index, rule in
        rule.info(index: index, matched: rules.hasMatched(at: index))
      })
  }

  func applyManageRuleEffects(_ effects: RuleEffects, to target: Window) {
    if let manage = effects.manage {
      target.isManagedByRule = manage
      makeWindowFloating(target, shouldFloat: !manage, force: true)
    }
  }

  func applyRuleEffects(_ effects: RuleEffects, to target: Window) {
    if effects.sid != nil || effects.did != nil {
      // Non-essential: the space move needs the fullscreen state of the window. While the breaker is open for its
      // application, the state cannot be read, so the move is skipped (ifResponsive returns nil).
      if let fullscreen = ifResponsive(pid: target.application.pid, { target.readFullscreen() }),
        !fullscreen && !(target.id.space.map { $0.isFullscreen } ?? false)
      {
        if let sid = effects.sid ?? effects.did.flatMap({ $0.currentSpace }) {
          sendWindow(target, to: sid, movedByRule: true)
          if effects.followSpace || effects.fullscreen == true {
            try? SpaceManager.shared.focusSpace(sid)
          }
        }
      }
    }

    if let sticky = effects.sticky {
      makeWindowSticky(target, shouldBeSticky: sticky)
    }

    if let mouseFollowsFocus = effects.mouseFollowsFocus {
      target.mouseFollowsFocusByRule = mouseFollowsFocus
    }

    if let layer = effects.layer {
      _ = setWindowLayer(target, to: layer)
    }

    if effects.fullscreen == true {
      _ = target.ref?.setAttribute(Window.fullscreenAttribute, to: true)
      target.isFullscreenByRule = true
    }

    if let scratchpad = effects.scratchpad {
      _ = setScratchpad(for: target, label: scratchpad)
    }

    let grid = effects.grid
    if grid.rows != 0 && grid.columns != 0 {
      try? applyGrid(grid, to: target)
    }
  }

  /// Evaluates a phase before any platform effects execute, without holding mutable access to the rule set.
  private func matchingRuleEffects(
    for context: RuleMatchContext, phase: RulePhase, lifecycle: RuleLifecycle, candidate: Rule?
  ) -> RuleEffects? {
    if let candidate {
      var selected: RuleSet = [candidate]
      return selected.matchingEffects(for: context, phase: phase, lifecycle: lifecycle)
    }
    return rules.matchingEffects(for: context, phase: phase, lifecycle: lifecycle)
  }

  /// Management runs first: an explicit role/subrole filter can admit a window that misreports its role,
  /// enabling ordinary effects in the second round. All application paths share this policy.
  @discardableResult
  func applyWindowRules(
    to target: Window, context: RuleMatchContext, lifecycle: RuleLifecycle, candidate: Rule? = nil
  ) -> Bool {
    if let effects = matchingRuleEffects(
      for: context, phase: .management, lifecycle: lifecycle, candidate: candidate
    ) {
      applyManageRuleEffects(effects, to: target)
    }

    guard target.isEligibleForManagement else { return false }

    target.isEligible = true
    let effects = matchingRuleEffects(
      for: context, phase: .effects(managedByRule: target.isManagedByRule),
      lifecycle: lifecycle, candidate: candidate)
    if let effects { applyRuleEffects(effects, to: target) }

    // NOTE: insert= is recorded only at creation. Adoption and reapply must preserve a pending insertion
    // and must not stack or split windows that are already tiled.
    if lifecycle == .newWindow { target.insertionByRule = effects?.insertionForNewWindow }
    return true
  }

  func reapplyAllRules() {
    reapplyRules()
  }

  func reapplyRule(at index: Int) -> Bool {
    guard rules.indices.contains(index) else { return false }
    reapplyRules(candidate: rules[index])
    return true
  }

  func reapplyRule(label: String) -> Bool {
    guard let index = rules.index(label: label) else { return false }
    return reapplyRule(at: index)
  }

  func applyRule(_ candidate: Rule) {
    reapplyRules(candidate: candidate)
  }

  private func reapplyRules(candidate: Rule? = nil) {
    if candidate?.oneShot == true { return }
    // Windows in id order: scratchpad assignment and other effects remain deterministic.
    for target in window.values where target.isRoot {
      let context = RuleMatchContext(
        app: target.application.name, title: target.ax.title ?? "",
        role: target.ax.role ?? "", subrole: target.ax.subrole ?? "")
      applyWindowRules(
        to: target, context: context, lifecycle: .existingWindow, candidate: candidate)
    }
  }

  func addRule(_ candidate: Rule) { rules.add(candidate) }
  func removeRule(at index: Int) -> Bool { rules.remove(at: index) }
  func removeRule(label: String) -> Bool { rules.remove(label: label) }

  // NOTE: Cleanup stays at discovery-batch boundaries so a one-shot can match every window created together.
  func removeOneShotRules() { rules.removeConsumedOneShotRules() }
}
