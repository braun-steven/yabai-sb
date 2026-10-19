import ApplicationServices
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Applying rules to windows. A window passes through two rounds: the manage round decides whether
// the window is managed, the effects round applies everything else to eligible windows.
//

/// `window_manager_query_window_rules`: the json of `rule --list`.
func window_manager_query_window_rules(_ rsp: inout Response)
{
    let rules = window_manager_global().rules

    rsp.write("[")
    for (i, candidate) in rules.enumerated() {
        rule_serialize(&rsp, candidate, i)
        if i < rules.count - 1 { rsp.write(",") }
    }
    rsp.write("]\n")
}

/// `window_manager_rule_matches_window`
func window_manager_rule_matches_window(_ candidate: Rule, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String) -> Bool
{
    candidate.matches(app: target.application.name, title: windowTitle, role: windowRole, subrole: windowSubrole)
}

/// `window_manager_apply_manage_rule_effects_to_window`
func window_manager_apply_manage_rule_effects_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ effects: RuleEffects)
{
    if let manage = effects.manage {
        target.isManagedByRule = manage
        window_manager_make_window_floating(sm, wm, target, !manage, true)
    }
}

/// `window_manager_apply_rule_effects_to_window`
func window_manager_apply_rule_effects_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ effects: RuleEffects)
{
    if effects.sid != nil || effects.did != nil {
        if !target.reportsFullscreen && !(target.id.space.map(space_is_fullscreen) ?? false) {
            if let sid = effects.sid ?? effects.did.flatMap({ display_space_id($0) }) {
                window_manager_send_window_to_space(sm, wm, target, sid, true)
                if effects.flags.contains(.followSpace) || effects.fullscreen == true {
                    _ = space_manager_focus_space(sid)
                }
            }
        }
    }

    if let sticky = effects.sticky {
        window_manager_make_window_sticky(sm, wm, target, sticky)
    }

    if let mouseFollowsFocus = effects.mouseFollowsFocus {
        target.mouseFollowsFocusByRule = mouseFollowsFocus
    }

    if effects.flags.contains(.layer) {
        _ = window_manager_set_window_layer(target, effects.layer)
    }

    if effects.flags.contains(.opacity) && effects.opacity >= 0.0 && effects.opacity <= 1.0 {
        target.opacity = effects.opacity
        window_manager_set_opacity(wm, target, effects.opacity)
    }

    if effects.fullscreen == true {
        AXUIElementSetAttributeValue(target.ref, Window.fullscreenAttribute as CFString, kCFBooleanTrue)
        target.isFullscreenByRule = true
    }

    if let scratchpad = effects.scratchpad {
        _ = window_manager_set_scratchpad_for_window(wm, target, scratchpad)
    }

    let grid = effects.grid
    if grid.rows != 0 && grid.columns != 0 {
        window_manager_apply_grid(sm, wm, target, grid)
    }
}

//
// NOTE: A rule without a role or subrole pattern only matches standard windows (AXWindow, AXStandardWindow)
// when it makes a window managed (manage round), or when the window is not managed by a rule (effects round).
//

/// `window_manager_rule_skips_nonstandard_window`
private func windowManagerRuleSkipsNonstandardWindow(_ candidate: Rule, _ windowRole: String, _ windowSubrole: String) -> Bool
{
    if !candidate.hasRole    && !string_equals(windowRole,    "AXWindow")         { return true }
    if !candidate.hasSubrole && !string_equals(windowSubrole, "AXStandardWindow") { return true }
    return false
}

//
// NOTE: Combines the effects of every matching rule into effects, in the order of WindowManager.rules, and marks
// matching one-shot rules for removal.
//

/// `window_manager_combine_matching_rule_effects`
func window_manager_combine_matching_rule_effects(_ wm: WindowManager, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String, _ oneShotRules: Bool, _ manageRound: Bool, _ effects: inout RuleEffects) -> Bool
{
    var match = false

    for i in wm.rules.indices {
        let candidate = wm.rules[i]

        if !oneShotRules && candidate.oneShot { continue }
        if !window_manager_rule_matches_window(candidate, target, windowTitle, windowRole, windowSubrole) { continue }

        let standardOnly = manageRound ? candidate.effects.manage == true : !target.isManagedByRule
        if standardOnly && windowManagerRuleSkipsNonstandardWindow(candidate, windowRole, windowSubrole) { continue }

        match = true
        effects.combine(candidate.effects)

        if candidate.oneShot { wm.rules[i].matched = true }
    }

    return match
}

/// `window_manager_apply_manage_rules_to_window`
func window_manager_apply_manage_rules_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String, _ oneShotRules: Bool)
{
    var effects = RuleEffects()

    if window_manager_combine_matching_rule_effects(wm, target, windowTitle, windowRole, windowSubrole, oneShotRules, true, &effects) {
        window_manager_apply_manage_rule_effects_to_window(sm, wm, target, effects)
    }
}

/// `window_manager_apply_rules_to_window`
func window_manager_apply_rules_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String, _ oneShotRules: Bool)
{
    var effects = RuleEffects()

    if window_manager_combine_matching_rule_effects(wm, target, windowTitle, windowRole, windowSubrole, oneShotRules, false, &effects) {
        window_manager_apply_rule_effects_to_window(sm, wm, target, effects)
    }
}

//
// NOTE: One-shot rules are marked when they were applied to a window, and removed once all windows that
// were created together have been checked.
//

/// `window_manager_remove_one_shot_rules`: removing moves the last rule into the hole, which is checked again.
func window_manager_remove_one_shot_rules(_ wm: WindowManager)
{
    var i = 0
    while i < wm.rules.count {
        if wm.rules[i].matched {
            window_manager_remove_rule(wm, i)
            continue
        }
        i += 1
    }
}
