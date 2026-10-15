import Darwin
import CPrivate
import YabaiCore

//
// NOTE: The rules of the window manager (the sbuffer window_manager.rules of struct rule): the json of `rule --list`,
// adding, removing and applying them again. Ported from src/rule.c.
//

/// `json_optional_bool`
private func jsonOptionalBool(_ value: Int32) -> String
{
    if value == 0 { return "null" }
    if value == 1 { return "true" }

    return "false"
}

extension ResponseText.Interpolation
{
    /// `json_string` of a C string: its bytes escaped when needed, nothing for NULL.
    mutating func appendInterpolation(json s: UnsafePointer<CChar>?)
    {
        guard let s else { return }

        let bytes = UnsafeRawBufferPointer(start: s, count: strlen(s))
        appendInterpolation(Token(JSON.escape(bytes) ?? Array(bytes)))
    }
}

/// `rule_serialize`
func rule_serialize(_ rsp: inout Response, _ candidate: UnsafeMutablePointer<rule>, _ index: Int32)
{
    let effects = candidate.pointee.effects
    let display = effects.did != 0 ? display_manager_display_id_arrangement(effects.did) : 0
    let space = effects.sid != 0 ? space_manager_mission_control_index(effects.sid) : 0
    let layer = rule_effects_check_flag(&candidate.pointee.effects, RULE_LAYER) ? windowLayer(effects.layer).rawValue : ""
    let flags = UInt32(effects.flags) << 16 | UInt32(candidate.pointee.flags)

    rsp.write("""
              {
              \t"index":\(index),
              \t"label":"\(json: candidate.pointee.label)",
              \t"app":"\(json: candidate.pointee.app)",
              \t"title":"\(json: candidate.pointee.title)",
              \t"role":"\(json: candidate.pointee.role)",
              \t"subrole":"\(json: candidate.pointee.subrole)",
              \t"display":\(display),
              \t"space":\(space),
              \t"follow_space":\(JSON.bool(rule_effects_check_flag(&candidate.pointee.effects, RULE_FOLLOW_SPACE))),
              \t"opacity":\(JSON.number(Double(effects.opacity))),
              \t"manage":\(jsonOptionalBool(effects.manage)),
              \t"sticky":\(jsonOptionalBool(effects.sticky)),
              \t"mouse_follows_focus":\(jsonOptionalBool(effects.mff)),
              \t"sub-layer":"\(layer)",
              \t"native-fullscreen":\(jsonOptionalBool(effects.fullscreen)),
              \t"grid":"\(Int32(bitPattern: effects.grid.0)):\(Int32(bitPattern: effects.grid.1)):\(Int32(bitPattern: effects.grid.2)):\(Int32(bitPattern: effects.grid.3)):\(Int32(bitPattern: effects.grid.4)):\(Int32(bitPattern: effects.grid.5))",
              \t"scratchpad":"\(json: effects.scratchpad)",
              \t"one-shot":\(JSON.bool(rule_check_flag(candidate, RULE_ONE_SHOT))),
              \t"flags":"\(cFormat("0x%08x", flags))"
              }
              """)
}

/// `rule_reapply_all`
func rule_reapply_all()
{
    let sm = space_manager_global()
    let wm = window_manager_global()

    for target in wm.window.values where target.pointee.is_root {
        let windowTitle = window_title_ts(target)
        let windowRole = window_role_ts(target)
        let windowSubrole = window_subrole_ts(target)

        window_manager_apply_manage_rules_to_window(sm, wm, target, windowTitle, windowRole, windowSubrole, false)

        if window_manager_is_window_eligible(target) {
            target.pointee.is_eligible = true
            window_manager_apply_rules_to_window(sm, wm, target, windowTitle, windowRole, windowSubrole, false)
        }
    }
}

/// `rule_reapply_by_index`
func rule_reapply_by_index(_ index: Int32) -> Bool
{
    let wm = window_manager_global()
    if index < 0 || index >= window_manager_rule_count(wm) { return false }

    if !rule_check_flag(window_manager_rule_at(wm, index), RULE_ONE_SHOT) {
        rule_apply(window_manager_rule_at(wm, index))
    }

    return true
}

/// `rule_reapply_by_label`
func rule_reapply_by_label(_ label: UnsafePointer<CChar>) -> Bool
{
    let wm = window_manager_global()

    for i in 0..<window_manager_rule_count(wm) {
        let candidate = window_manager_rule_at(wm, i)
        if string_equals(candidate.pointee.label, label) {
            if !rule_check_flag(candidate, RULE_ONE_SHOT) {
                rule_apply(candidate)
            }
            return true
        }
    }

    return false
}

/// `rule_apply`
func rule_apply(_ candidate: UnsafeMutablePointer<rule>)
{
    let sm = space_manager_global()
    let wm = window_manager_global()

    for target in wm.window.values where target.pointee.is_root {
        if window_manager_rule_matches_window(candidate, target, window_title_ts(target), window_role_ts(target), window_subrole_ts(target)) {
            window_manager_apply_manage_rule_effects_to_window(sm, wm, target, &candidate.pointee.effects)

            if window_manager_is_window_eligible(target) {
                target.pointee.is_eligible = true
                window_manager_apply_rule_effects_to_window(sm, wm, target, &candidate.pointee.effects)
            }
        }
    }
}

/// `rule_add`: the window manager takes over the strings and patterns of the rule.
func rule_add(_ candidate: UnsafeMutablePointer<rule>)
{
    if let label = candidate.pointee.label { _ = rule_remove_by_label(label) }
    window_manager_add_rule(window_manager_global(), candidate.pointee)
}

/// `rule_remove_by_index`
func rule_remove_by_index(_ index: Int32) -> Bool
{
    let wm = window_manager_global()
    if index < 0 || index >= window_manager_rule_count(wm) { return false }

    rule_destroy(window_manager_rule_at(wm, index))
    window_manager_remove_rule(wm, index)
    return true
}

/// `rule_remove_by_label`
func rule_remove_by_label(_ label: UnsafePointer<CChar>) -> Bool
{
    let wm = window_manager_global()

    for i in 0..<window_manager_rule_count(wm) {
        if string_equals(window_manager_rule_at(wm, i).pointee.label, label) {
            rule_destroy(window_manager_rule_at(wm, i))
            window_manager_remove_rule(wm, i)
            return true
        }
    }

    return false
}

/// `rule_destroy`
func rule_destroy(_ candidate: UnsafeMutablePointer<rule>)
{
    if rule_check_flag(candidate, RULE_APP_VALID)     { regfree(&candidate.pointee.app_regex) }
    if rule_check_flag(candidate, RULE_TITLE_VALID)   { regfree(&candidate.pointee.title_regex) }
    if rule_check_flag(candidate, RULE_ROLE_VALID)    { regfree(&candidate.pointee.role_regex) }
    if rule_check_flag(candidate, RULE_SUBROLE_VALID) { regfree(&candidate.pointee.subrole_regex) }

    free(candidate.pointee.label)
    free(candidate.pointee.app)
    free(candidate.pointee.title)
    free(candidate.pointee.role)
    free(candidate.pointee.subrole)

    free(candidate.pointee.effects.scratchpad)
}
