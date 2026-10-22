import ApplicationServices
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Applying rules to windows. A window passes through two rounds: the manage round decides whether
// the window is managed, the effects round applies everything else to eligible windows.
//

extension WindowManager
{
    func queryWindowRules(into response: inout Response) throws(CommandError)
    {
        try response.write(json: rules.enumerated().map { $1.info(index: $0) })
    }

    // NOTE: Matching rule effects combine in WindowManager.rules order; matching one-shot rules are marked for removal.
    func combineMatchingRuleEffects(
        for target: Window,
        title: String,
        role: String,
        subrole: String,
        includingOneShotRules: Bool,
        manageRound: Bool,
        into effects: inout RuleEffects
    ) -> Bool
    {
        var match = false

        for index in rules.indices {
            let candidate = rules[index]

            if !includingOneShotRules && candidate.oneShot { continue }
            if !candidate.matches(app: target.application.name, title: title, role: role, subrole: subrole) { continue }

            let standardOnly = manageRound ? candidate.effects.manage == true : !target.isManagedByRule
            if standardOnly && candidate.skipsNonstandardWindow(role: role, subrole: subrole) { continue }

            match = true
            effects.combine(candidate.effects)

            if candidate.oneShot { rules[index].matched = true }
        }

        return match
    }

    func applyManageRuleEffects(_ effects: RuleEffects, to target: Window)
    {
        if let manage = effects.manage {
            target.isManagedByRule = manage
            makeWindowFloating(target, shouldFloat: !manage, force: true)
        }
    }

    func applyRuleEffects(_ effects: RuleEffects, to target: Window)
    {
        if effects.sid != nil || effects.did != nil {
            // Non-essential: the space move needs the fullscreen state of the window. While the breaker is open for its
            // application, the state cannot be read, so the move is skipped (ifResponsive returns nil).
            if let fullscreen = ifResponsive(pid: target.application.pid, { target.readFullscreen() }),
               !fullscreen && !(target.id.space.map { $0.isFullscreen } ?? false) {
                if let sid = effects.sid ?? effects.did.flatMap({ $0.currentSpace }) {
                    sendWindow(target, to: sid, movedByRule: true)
                    if effects.flags.contains(.followSpace) || effects.fullscreen == true {
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

        if effects.flags.contains(.layer) {
            _ = setWindowLayer(target, to: effects.layer)
        }

        if effects.flags.contains(.opacity) && effects.opacity >= 0.0 && effects.opacity <= 1.0 {
            target.opacity = effects.opacity
            setOpacity(for: target, to: effects.opacity)
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

    func applyManageRules(
        to target: Window,
        title: String,
        role: String,
        subrole: String,
        includingOneShotRules: Bool
    )
    {
        var effects = RuleEffects()

        if combineMatchingRuleEffects(
            for: target,
            title: title,
            role: role,
            subrole: subrole,
            includingOneShotRules: includingOneShotRules,
            manageRound: true,
            into: &effects
        ) {
            applyManageRuleEffects(effects, to: target)
        }
    }

    func applyRules(
        to target: Window,
        title: String,
        role: String,
        subrole: String,
        includingOneShotRules: Bool
    )
    {
        var effects = RuleEffects()

        if combineMatchingRuleEffects(
            for: target,
            title: title,
            role: role,
            subrole: subrole,
            includingOneShotRules: includingOneShotRules,
            manageRound: false,
            into: &effects
        ) {
            applyRuleEffects(effects, to: target)
        }
    }

    func reapplyAllRules()
    {
        // Windows in id order, so rules apply in the same order every time.
        for target in window.values where target.isRoot {
            let title = target.ax.title ?? ""
            let role = target.ax.role ?? ""
            let subrole = target.ax.subrole ?? ""

            applyManageRules(to: target, title: title, role: role, subrole: subrole, includingOneShotRules: false)

            if target.isEligibleForManagement {
                target.isEligible = true
                applyRules(to: target, title: title, role: role, subrole: subrole, includingOneShotRules: false)
            }
        }
    }

    func reapplyRule(at index: Int) -> Bool
    {
        guard rules.indices.contains(index) else { return false }

        if !rules[index].oneShot {
            applyRule(rules[index])
        }

        return true
    }

    func reapplyRule(label: String) -> Bool
    {
        guard let index = ruleIndex(label: label) else { return false }

        if !rules[index].oneShot {
            applyRule(rules[index])
        }

        return true
    }

    private func ruleIndex(label: String) -> Int?
    {
        rules.firstIndex { $0.label == label }
    }

    func applyRule(_ candidate: Rule)
    {
        // Windows in id order, so rules apply in the same order every time.
        for target in window.values where target.isRoot {
            if candidate.matches(app: target.application.name, title: target.ax.title ?? "", role: target.ax.role ?? "", subrole: target.ax.subrole ?? "") {
                applyManageRuleEffects(candidate.effects, to: target)

                if target.isEligibleForManagement {
                    target.isEligible = true
                    applyRuleEffects(candidate.effects, to: target)
                }
            }
        }
    }

    /// Replaces any rule with the same label, then appends the new rule.
    func addRule(_ candidate: Rule)
    {
        if let label = candidate.label { _ = removeRule(label: label) }
        rules.append(candidate)
    }

    func removeRule(at index: Int) -> Bool
    {
        guard rules.indices.contains(index) else { return false }

        removeRule(index)
        return true
    }

    func removeRule(label: String) -> Bool
    {
        guard let index = ruleIndex(label: label) else { return false }

        removeRule(index)
        return true
    }

    /// Removes by moving the last rule into its place, preserving the existing list behavior.
    private func removeRule(_ index: Int)
    {
        rules.swapAt(index, rules.count - 1)
        rules.removeLast()
    }

    // NOTE: One-shot rules are marked when applied to a window, then removed once all windows created together
    // have been checked. After swap-removal, the replacement at that index is checked again.
    func removeOneShotRules()
    {
        var index = 0
        while index < rules.count {
            if rules[index].matched {
                removeRule(index)
                continue
            }
            index += 1
        }
    }
}
