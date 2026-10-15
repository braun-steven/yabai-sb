import ApplicationServices
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Applying rules to windows. A window passes through two rounds: the manage round decides whether
// the window is managed, the effects round applies everything else to eligible windows. Ported from
// src/window_manager_rules.c. The rules stay C (struct rule in the sbuffer window_manager.rules) while rule.c is C.
//

/// `window_manager_query_window_rules`: the json of `rule --list`.
func window_manager_query_window_rules(_ rsp: inout Response)
{
    let wm = window_manager_global()
    let count = window_manager_rule_count(wm)

    rsp.write("[")
    for i in 0..<count {
        rule_serialize(&rsp, window_manager_rule_at(wm, i), i)
        if i < count - 1 { rsp.write(",") }
    }
    rsp.write("]\n")
}

/// `window_manager_rule_matches_window`
func window_manager_rule_matches_window(_ candidate: UnsafeMutablePointer<rule>, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String) -> Bool
{
    let regexMatchApp = rule_check_flag(candidate, RULE_APP_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO
    if regex_match(rule_check_flag(candidate, RULE_APP_VALID), &candidate.pointee.app_regex, target.application.name) == regexMatchApp { return false }

    let regexMatchTitle = rule_check_flag(candidate, RULE_TITLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO
    if regex_match(rule_check_flag(candidate, RULE_TITLE_VALID), &candidate.pointee.title_regex, windowTitle) == regexMatchTitle { return false }

    let regexMatchRole = rule_check_flag(candidate, RULE_ROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO
    if regex_match(rule_check_flag(candidate, RULE_ROLE_VALID), &candidate.pointee.role_regex, windowRole) == regexMatchRole { return false }

    let regexMatchSubrole = rule_check_flag(candidate, RULE_SUBROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO
    if regex_match(rule_check_flag(candidate, RULE_SUBROLE_VALID), &candidate.pointee.subrole_regex, windowSubrole) == regexMatchSubrole { return false }

    return true
}

/// `window_manager_apply_manage_rule_effects_to_window`
func window_manager_apply_manage_rule_effects_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ effects: UnsafeMutablePointer<rule_effects>)
{
    if effects.pointee.manage == RULE_PROP_ON {
        window_set_rule_flag(target, WINDOW_RULE_MANAGED)
        window_manager_make_window_floating(sm, wm, target, false, true)
    } else if effects.pointee.manage == RULE_PROP_OFF {
        window_clear_rule_flag(target, WINDOW_RULE_MANAGED)
        window_manager_make_window_floating(sm, wm, target, true, true)
    }
}

/// `window_manager_apply_rule_effects_to_window`
func window_manager_apply_rule_effects_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ effects: UnsafeMutablePointer<rule_effects>)
{
    if effects.pointee.sid != 0 || effects.pointee.did != 0 {
        if !window_is_fullscreen(target) && !space_is_fullscreen(window_space(target.pointee.id)) {
            let sid = effects.pointee.sid != 0 ? effects.pointee.sid : display_space_id(effects.pointee.did)
            window_manager_send_window_to_space(sm, wm, target, sid, true)
            if rule_effects_check_flag(effects, RULE_FOLLOW_SPACE) || effects.pointee.fullscreen == RULE_PROP_ON {
                _ = space_manager_focus_space(sid)
            }
        }
    }

    if effects.pointee.sticky == RULE_PROP_ON {
        window_manager_make_window_sticky(sm, wm, target, true)
    } else if effects.pointee.sticky == RULE_PROP_OFF {
        window_manager_make_window_sticky(sm, wm, target, false)
    }

    if effects.pointee.mff == RULE_PROP_ON {
        window_set_rule_flag(target, WINDOW_RULE_MFF)
        window_set_rule_flag(target, WINDOW_RULE_MFF_VALUE)
    } else if effects.pointee.mff == RULE_PROP_OFF {
        window_set_rule_flag(target, WINDOW_RULE_MFF)
        window_clear_rule_flag(target, WINDOW_RULE_MFF_VALUE)
    }

    if rule_effects_check_flag(effects, RULE_LAYER) {
        _ = window_manager_set_window_layer(target, effects.pointee.layer)
    }

    if rule_effects_check_flag(effects, RULE_OPACITY) && effects.pointee.opacity >= 0.0 && effects.pointee.opacity <= 1.0 {
        target.pointee.opacity = effects.pointee.opacity
        window_manager_set_opacity(wm, target, effects.pointee.opacity)
    }

    if effects.pointee.fullscreen == RULE_PROP_ON {
        AXUIElementSetAttributeValue(target.pointee.ref, axFullscreenAttribute as CFString, kCFBooleanTrue)
        window_set_rule_flag(target, WINDOW_RULE_FULLSCREEN)
    }

    if let scratchpad = effects.pointee.scratchpad {
        let label = strdup(scratchpad)!
        if !window_manager_set_scratchpad_for_window(wm, target, label) {
            free(label)
        }
    }

    let grid = effects.pointee.grid
    if grid.0 != 0 && grid.1 != 0 {
        window_manager_apply_grid(sm, wm, target, grid.0, grid.1, grid.2, grid.3, grid.4, grid.5)
    }
}

//
// NOTE: A rule without a role or subrole pattern only matches standard windows (AXWindow, AXStandardWindow)
// when it makes a window managed (manage round), or when the window is not managed by a rule (effects round).
//

/// `window_manager_rule_skips_nonstandard_window`
private func windowManagerRuleSkipsNonstandardWindow(_ candidate: UnsafeMutablePointer<rule>, _ windowRole: String, _ windowSubrole: String) -> Bool
{
    if !rule_check_flag(candidate, RULE_ROLE_VALID)    && !string_equals(windowRole,    "AXWindow")         { return true }
    if !rule_check_flag(candidate, RULE_SUBROLE_VALID) && !string_equals(windowSubrole, "AXStandardWindow") { return true }
    return false
}

//
// NOTE: Combines the effects of every matching rule into effects, in the order the rules were added, and marks
// matching one-shot rules for removal. The caller frees effects->scratchpad.
//

/// `window_manager_combine_matching_rule_effects`
func window_manager_combine_matching_rule_effects(_ wm: WindowManager, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String, _ oneShotRules: Bool, _ manageRound: Bool, _ effects: UnsafeMutablePointer<rule_effects>) -> Bool
{
    var match = false

    for i in 0..<window_manager_rule_count(wm) {
        let candidate = window_manager_rule_at(wm, i)

        if !oneShotRules && rule_check_flag(candidate, RULE_ONE_SHOT) { continue }
        if !window_manager_rule_matches_window(candidate, target, windowTitle, windowRole, windowSubrole) { continue }

        let standardOnly = manageRound ? candidate.pointee.effects.manage == RULE_PROP_ON : !window_check_rule_flag(target, WINDOW_RULE_MANAGED)
        if standardOnly && windowManagerRuleSkipsNonstandardWindow(candidate, windowRole, windowSubrole) { continue }

        match = true
        rule_combine_effects(&candidate.pointee.effects, effects)

        if rule_check_flag(candidate, RULE_ONE_SHOT) { rule_set_flag(candidate, RULE_ONE_SHOT_REMOVE) }
    }

    return match
}

/// `window_manager_apply_manage_rules_to_window`
func window_manager_apply_manage_rules_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String, _ oneShotRules: Bool)
{
    var effects = rule_effects()

    if window_manager_combine_matching_rule_effects(wm, target, windowTitle, windowRole, windowSubrole, oneShotRules, true, &effects) {
        window_manager_apply_manage_rule_effects_to_window(sm, wm, target, &effects)
    }

    free(effects.scratchpad)
}

/// `window_manager_apply_rules_to_window`
func window_manager_apply_rules_to_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ windowTitle: String, _ windowRole: String, _ windowSubrole: String, _ oneShotRules: Bool)
{
    var effects = rule_effects()

    if window_manager_combine_matching_rule_effects(wm, target, windowTitle, windowRole, windowSubrole, oneShotRules, false, &effects) {
        window_manager_apply_rule_effects_to_window(sm, wm, target, &effects)
    }

    free(effects.scratchpad)
}

//
// NOTE: One-shot rules are marked when they were applied to a window, and removed once all windows that
// were created together have been checked.
//

/// `window_manager_remove_one_shot_rules`: buf_del moves the last rule into the hole, which is checked again.
func window_manager_remove_one_shot_rules(_ wm: WindowManager)
{
    var i: Int32 = 0
    while i < window_manager_rule_count(wm) {
        let candidate = window_manager_rule_at(wm, i)
        if rule_check_flag(candidate, RULE_ONE_SHOT_REMOVE) {
            rule_destroy(candidate)
            window_manager_remove_rule(wm, i)
            continue
        }
        i += 1
    }
}
