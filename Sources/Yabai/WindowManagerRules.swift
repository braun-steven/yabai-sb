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
    candidate.matches(app: String(cString: target.application.name), title: windowTitle, role: windowRole, subrole: windowSubrole)
}

/// `window_manager_apply_manage_rule_effects_to_window`
func window_manager_apply_manage_rule_effects_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ effects: RuleEffects)
{
    if effects.manage == .on {
        window_set_rule_flag(target, WINDOW_RULE_MANAGED)
        window_manager_make_window_floating(sm, wm, target, false, true)
    } else if effects.manage == .off {
        window_clear_rule_flag(target, WINDOW_RULE_MANAGED)
        window_manager_make_window_floating(sm, wm, target, true, true)
    }
}

/// `window_manager_apply_rule_effects_to_window`
func window_manager_apply_rule_effects_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ effects: RuleEffects)
{
    if effects.sid != 0 || effects.did != 0 {
        if !window_is_fullscreen(target) && !space_is_fullscreen(window_space(target.id)) {
            let sid = effects.sid != 0 ? effects.sid : display_space_id(effects.did)
            window_manager_send_window_to_space(sm, wm, target, sid, true)
            if effects.flags.contains(.followSpace) || effects.fullscreen == .on {
                _ = space_manager_focus_space(sid)
            }
        }
    }

    if effects.sticky == .on {
        window_manager_make_window_sticky(sm, wm, target, true)
    } else if effects.sticky == .off {
        window_manager_make_window_sticky(sm, wm, target, false)
    }

    if effects.mff == .on {
        window_set_rule_flag(target, WINDOW_RULE_MFF)
        window_set_rule_flag(target, WINDOW_RULE_MFF_VALUE)
    } else if effects.mff == .off {
        window_set_rule_flag(target, WINDOW_RULE_MFF)
        window_clear_rule_flag(target, WINDOW_RULE_MFF_VALUE)
    }

    if effects.flags.contains(.layer) {
        _ = window_manager_set_window_layer(target, layerValue(effects.layer))
    }

    if effects.flags.contains(.opacity) && effects.opacity >= 0.0 && effects.opacity <= 1.0 {
        target.opacity = effects.opacity
        window_manager_set_opacity(wm, target, effects.opacity)
    }

    if effects.fullscreen == .on {
        AXUIElementSetAttributeValue(target.ref, axFullscreenAttribute as CFString, kCFBooleanTrue)
        window_set_rule_flag(target, WINDOW_RULE_FULLSCREEN)
    }

    if let scratchpad = effects.scratchpad {
        let label = strdup(scratchpad)!
        if !window_manager_set_scratchpad_for_window(wm, target, label) {
            free(label)
        }
    }

    let grid = effects.grid
    if grid.rows != 0 && grid.columns != 0 {
        window_manager_apply_grid(sm, wm, target, grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height)
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

        let standardOnly = manageRound ? candidate.effects.manage == .on : !window_check_rule_flag(target, WINDOW_RULE_MANAGED)
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
