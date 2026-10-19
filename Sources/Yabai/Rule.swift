import CPrivate
import YabaiCore

extension Rule
{
    // NOTE: Without a role or subrole pattern, a rule is limited to standard windows in the manage round when it
    // makes the window managed, or in the effects round when the window is not managed by a rule.
    func skipsNonstandardWindow(role: String, subrole: String) -> Bool
    {
        if !hasRole && !role.bytesEqual("AXWindow") { return true }
        if !hasSubrole && !subrole.bytesEqual("AXStandardWindow") { return true }
        return false
    }

    /// The rule for `rule --list`, at index in the rule list.
    @WM func info(index: Int) -> RuleInfo
    {
        info(index: index, display: effects.did.map { $0.arrangement } ?? 0, space: effects.sid.map { $0.missionControlIndex } ?? 0)
    }
}
