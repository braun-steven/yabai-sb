import CPrivate
import YabaiCore

/// true, false, or null for a property the rule leaves alone.
private func jsonOptionalBool(_ value: Bool?) -> String
{
    value.map(JSON.bool) ?? "null"
}

extension ResponseText.Interpolation
{
    /// Escapes the bytes of a string when needed; emits nothing for nil.
    mutating func appendInterpolation(json string: String?)
    {
        guard let string else { return }

        let bytes = Array(string.utf8)
        appendInterpolation(Token(JSON.escape(bytes) ?? bytes))
    }
}

extension Rule
{
    // NOTE: Without a role or subrole pattern, a rule is limited to standard windows in the manage round when it
    // makes the window managed, or in the effects round when the window is not managed by a rule.
    func skipsNonstandardWindow(role: String, subrole: String) -> Bool
    {
        if !hasRole && !string_equals(role, "AXWindow") { return true }
        if !hasSubrole && !string_equals(subrole, "AXStandardWindow") { return true }
        return false
    }

    func serialize(into response: inout Response, index: Int)
    {
        let display = effects.did.map { display_manager_display_id_arrangement($0) } ?? 0
        let space = effects.sid.map { space_manager_mission_control_index($0) } ?? 0
        let layer = effects.flags.contains(.layer) ? effects.layer.rawValue : ""
        let grid = effects.grid

        response.write("""
                  {
                  \t"index":\(index),
                  \t"label":"\(json: label)",
                  \t"app":"\(json: app?.text)",
                  \t"title":"\(json: title?.text)",
                  \t"role":"\(json: role?.text)",
                  \t"subrole":"\(json: subrole?.text)",
                  \t"display":\(display),
                  \t"space":\(space),
                  \t"follow_space":\(JSON.bool(effects.flags.contains(.followSpace))),
                  \t"opacity":\(JSON.number(Double(effects.opacity))),
                  \t"manage":\(jsonOptionalBool(effects.manage)),
                  \t"sticky":\(jsonOptionalBool(effects.sticky)),
                  \t"mouse_follows_focus":\(jsonOptionalBool(effects.mouseFollowsFocus)),
                  \t"sub-layer":"\(layer)",
                  \t"native-fullscreen":\(jsonOptionalBool(effects.fullscreen)),
                  \t"grid":"\(Int32(bitPattern: grid.rows)):\(Int32(bitPattern: grid.columns)):\(Int32(bitPattern: grid.x)):\(Int32(bitPattern: grid.y)):\(Int32(bitPattern: grid.width)):\(Int32(bitPattern: grid.height))",
                  \t"scratchpad":"\(json: effects.scratchpad)",
                  \t"one-shot":\(JSON.bool(oneShot)),
                  \t"flags":"\(cFormat("0x%08x", listFlags))"
                  }
                  """)
    }
}
