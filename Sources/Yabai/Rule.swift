import Darwin
import CPrivate
import YabaiCore

//
// NOTE: The rules of the window manager (WindowManager.rules): the json of `rule --list`, adding, removing and
// applying them again.
//

/// `json_optional_bool`
private func jsonOptionalBool(_ value: RuleProp) -> String
{
    switch value {
    case .undefined: "null"
    case .on:        "true"
    case .off:       "false"
    }
}

extension ResponseText.Interpolation
{
    /// `json_string`: the bytes of s escaped when needed, nothing for nil.
    mutating func appendInterpolation(json s: String?)
    {
        guard let s else { return }

        let bytes = Array(s.utf8)
        appendInterpolation(Token(JSON.escape(bytes) ?? bytes))
    }
}

/// `rule_serialize`
func rule_serialize(_ rsp: inout Response, _ candidate: Rule, _ index: Int)
{
    let effects = candidate.effects
    let display = effects.did != 0 ? display_manager_display_id_arrangement(effects.did) : 0
    let space = effects.sid != 0 ? space_manager_mission_control_index(effects.sid) : 0
    let layer = effects.flags.contains(.layer) ? effects.layer.rawValue : ""
    let grid = effects.grid

    rsp.write("""
              {
              \t"index":\(index),
              \t"label":"\(json: candidate.label)",
              \t"app":"\(json: candidate.app?.text)",
              \t"title":"\(json: candidate.title?.text)",
              \t"role":"\(json: candidate.role?.text)",
              \t"subrole":"\(json: candidate.subrole?.text)",
              \t"display":\(display),
              \t"space":\(space),
              \t"follow_space":\(JSON.bool(effects.flags.contains(.followSpace))),
              \t"opacity":\(JSON.number(Double(effects.opacity))),
              \t"manage":\(jsonOptionalBool(effects.manage)),
              \t"sticky":\(jsonOptionalBool(effects.sticky)),
              \t"mouse_follows_focus":\(jsonOptionalBool(effects.mff)),
              \t"sub-layer":"\(layer)",
              \t"native-fullscreen":\(jsonOptionalBool(effects.fullscreen)),
              \t"grid":"\(Int32(bitPattern: grid.rows)):\(Int32(bitPattern: grid.columns)):\(Int32(bitPattern: grid.x)):\(Int32(bitPattern: grid.y)):\(Int32(bitPattern: grid.width)):\(Int32(bitPattern: grid.height))",
              \t"scratchpad":"\(json: effects.scratchpad)",
              \t"one-shot":\(JSON.bool(candidate.oneShot)),
              \t"flags":"\(cFormat("0x%08x", candidate.listFlags))"
              }
              """)
}

/// `rule_reapply_all`
func rule_reapply_all()
{
    let sm = space_manager_global()
    let wm = window_manager_global()

    for target in wm.window.values where target.is_root {
        let windowTitle = window_title_ts(target)
        let windowRole = window_role_ts(target)
        let windowSubrole = window_subrole_ts(target)

        window_manager_apply_manage_rules_to_window(sm, wm, target, windowTitle, windowRole, windowSubrole, false)

        if window_manager_is_window_eligible(target) {
            target.is_eligible = true
            window_manager_apply_rules_to_window(sm, wm, target, windowTitle, windowRole, windowSubrole, false)
        }
    }
}

/// `rule_reapply_by_index`
func rule_reapply_by_index(_ index: Int) -> Bool
{
    let wm = window_manager_global()
    guard wm.rules.indices.contains(index) else { return false }

    if !wm.rules[index].oneShot {
        rule_apply(wm.rules[index])
    }

    return true
}

/// The index of the rule with this label, compared byte by byte.
private func ruleIndex(label: some Collection<UInt8>) -> Int?
{
    window_manager_global().rules.firstIndex { $0.label?.utf8.elementsEqual(label) ?? false }
}

/// `rule_reapply_by_label`
func rule_reapply_by_label(_ label: some Collection<UInt8>) -> Bool
{
    let wm = window_manager_global()
    guard let index = ruleIndex(label: label) else { return false }

    if !wm.rules[index].oneShot {
        rule_apply(wm.rules[index])
    }

    return true
}

/// `rule_apply`
func rule_apply(_ candidate: Rule)
{
    let sm = space_manager_global()
    let wm = window_manager_global()

    for target in wm.window.values where target.is_root {
        if window_manager_rule_matches_window(candidate, target, window_title_ts(target), window_role_ts(target), window_subrole_ts(target)) {
            window_manager_apply_manage_rule_effects_to_window(sm, wm, target, candidate.effects)

            if window_manager_is_window_eligible(target) {
                target.is_eligible = true
                window_manager_apply_rule_effects_to_window(sm, wm, target, candidate.effects)
            }
        }
    }
}

/// `rule_add`: replaces the rule with the same label.
func rule_add(_ candidate: Rule)
{
    if let label = candidate.label { _ = rule_remove_by_label(label.utf8) }
    window_manager_global().rules.append(candidate)
}

/// `rule_remove_by_index`
func rule_remove_by_index(_ index: Int) -> Bool
{
    let wm = window_manager_global()
    guard wm.rules.indices.contains(index) else { return false }

    window_manager_remove_rule(wm, index)
    return true
}

/// `rule_remove_by_label`
func rule_remove_by_label(_ label: some Collection<UInt8>) -> Bool
{
    guard let index = ruleIndex(label: label) else { return false }

    window_manager_remove_rule(window_manager_global(), index)
    return true
}
