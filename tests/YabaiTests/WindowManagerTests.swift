import Foundation
import Testing
import YabaiC
@testable import Yabai

// NOTE: Ported from tests/src/window_frame.c and tests/src/window_rules.c. The window managers of these tests are local,
// so they do not touch the state of the daemon.

/// A window manager with the defaults of its fields, released by windowManagerFree.
private func windowManagerCreate() -> WindowManager
{
    return WindowManager()
}

private func windowManagerFree(_ wm: WindowManager)
{
    for i in 0..<window_manager_rule_count(wm) { rule_destroy(window_manager_rule_at(wm, i)) }
    window_manager_free_rules(wm)
    wm.window.removeAll()
}

/// A valid window with an id and an application, as window_create sets them.
private func windowCreate(_ id: UInt32, _ owner: Application? = nil) -> Window
{
    let result = Window()
    result.id = id
    result.application = owner
    return result
}

/// An application with a malloc'ed name, which the test frees.
private func applicationCreate(_ name: String) -> Application
{
    let result = Application()
    result.name = strdup(name)
    return result
}

@Test("window_pending_focus") func windowPendingFocus()
{
    let wm = windowManagerCreate()
    let target = windowCreate(42)
    defer { windowManagerFree(wm) }

    window_manager_add_window(wm, target)

    #expect(window_manager_pending_focus_window(wm) == nil)

    window_manager_set_pending_focus(wm, 42)
    #expect(window_manager_pending_focus_window(wm) == target)
    #expect(wm.pending_focus_window_id == 42)

    //
    // NOTE: A pending focus expires, and is dropped for windows that no longer exist.
    //

    wm.pending_focus_time = read_os_timer() - UInt64(Double(read_os_freq()) * 0.6)
    #expect(window_manager_pending_focus_window(wm) == nil)
    #expect(wm.pending_focus_window_id == 0)

    window_manager_set_pending_focus(wm, 7)
    #expect(window_manager_pending_focus_window(wm) == nil)
    #expect(wm.pending_focus_window_id == 0)
}

@Test("window_unresolved_list") func windowUnresolvedList()
{
    let wm = windowManagerCreate()
    let windows = [12, 14, 11, 13].map { windowCreate($0) }
    defer { windowManagerFree(wm) }

    window_manager_add_window(wm, windows[0])
    window_manager_add_window(wm, windows[1])
    #expect(window_manager_unresolved_windows(wm, [11, 12, 13, 14]) == [11, 13])

    window_manager_add_window(wm, windows[2])
    window_manager_add_window(wm, windows[3])
    #expect(window_manager_unresolved_windows(wm, [11, 12, 13, 14]).isEmpty)
}

@Test("window_validity") func windowValidity()
{
    let target = windowCreate(5)

    #expect(window_is_valid(target) == true)
    #expect(window_invalidate(target) == true)
    #expect(window_is_valid(target) == false)

    // NOTE: only one caller may claim the destruction of a window
    #expect(window_invalidate(target) == false)
}

private func oneShotTestRule(_ flags: rule_flag, _ label: String) -> rule
{
    var result = rule()
    result.flags = UInt16(flags.rawValue)
    result.label = strdup(label)
    return result
}

@Test("window_one_shot_rules") func windowOneShotRules()
{
    let wm = windowManagerCreate()
    defer { windowManagerFree(wm) }

    let remove = rule_flag(RULE_ONE_SHOT.rawValue | RULE_ONE_SHOT_REMOVE.rawValue)
    window_manager_add_rule(wm, oneShotTestRule(remove, "a"))
    window_manager_add_rule(wm, oneShotTestRule(rule_flag(0), "b"))
    window_manager_add_rule(wm, oneShotTestRule(remove, "c"))
    window_manager_add_rule(wm, oneShotTestRule(remove, "d"))

    window_manager_remove_one_shot_rules(wm)
    #expect(window_manager_rule_count(wm) == 1)
    #expect(String(cString: window_manager_rule_at(wm, 0).pointee.label) == "b")
}

//
// NOTE: 1 has the children 2 and 3, 3 has the child 4, and 9 belongs to another window. The direct relations
// make every window a direct child, which needs as many entries as there are relations.
//

@Test("window_child_windows_collect") func windowChildWindowsCollect()
{
    var parentList: [UInt32] = [3, 1, 9, 1]
    #expect(window_manager_collect_child_windows(1, &parentList, [4, 2, 8, 3]) == [2, 3, 4])

    var directParent: [UInt32] = [1, 1, 1]
    #expect(window_manager_collect_child_windows(1, &directParent, [2, 3, 4]).count == 3)

    // NOTE: a cycle does not repeat windows
    var cycleParent: [UInt32] = [1, 2]
    #expect(window_manager_collect_child_windows(1, &cycleParent, [2, 1]).count == 2)

    var emptyParent: [UInt32] = []
    #expect(window_manager_collect_child_windows(1, &emptyParent, []).isEmpty)
}

private func windowRulesTestRule(_ app: String, _ subrole: String?, _ flags: rule_flag) -> rule
{
    var result = rule()
    result.flags = UInt16(flags.rawValue | RULE_APP_VALID.rawValue)
    regcomp(&result.app_regex, app, REG_EXTENDED)

    if let subrole {
        regcomp(&result.subrole_regex, subrole, REG_EXTENDED)
        rule_set_flag(&result, RULE_SUBROLE_VALID)
    }

    return result
}

/// The strings that window_manager_combine_matching_rule_effects takes, freed by the caller.
private struct WindowStrings
{
    let title = ""
    let role = "AXWindow"
    let dialog = "AXDialog"
    let standard = "AXStandardWindow"

    func free() {}
}

@Test("window_rules_combine_matching") func windowRulesCombineMatching()
{
    let owner = applicationCreate("Safari")
    let target = windowCreate(1, owner)
    let wm = windowManagerCreate()
    let strings = WindowStrings()
    defer { windowManagerFree(wm); free(owner.name); strings.free() }

    // NOTE: without a subrole pattern a rule does not match a dialog
    var any = windowRulesTestRule("^Safari$", nil, rule_flag(0))
    any.effects.sid = 4
    window_manager_add_rule(wm, any)

    var dialog = windowRulesTestRule("^Safari$", "^AXDialog$", rule_flag(0))
    dialog.effects.sticky = RULE_PROP_ON
    dialog.effects.scratchpad = strdup("notes")
    window_manager_add_rule(wm, dialog)

    var otherApp = windowRulesTestRule("^Mail$", "^AXDialog$", rule_flag(0))
    otherApp.effects.mff = RULE_PROP_ON
    window_manager_add_rule(wm, otherApp)

    var oneShot = windowRulesTestRule("^Safari$", "^AXDialog$", RULE_ONE_SHOT)
    oneShot.effects.layer = layerValue(.above)
    rule_effects_set_flag(&oneShot.effects, RULE_LAYER)
    window_manager_add_rule(wm, oneShot)

    var effects = rule_effects()
    #expect(window_manager_combine_matching_rule_effects(wm, target, strings.title, strings.role, strings.dialog, false, false, &effects) == true)
    #expect(effects.sid == 0)
    #expect(effects.sticky == RULE_PROP_ON)
    #expect(effects.mff == RULE_PROP_UD)
    #expect(rule_effects_check_flag(&effects, RULE_LAYER) == false)
    #expect(effects.scratchpad.map { String(cString: $0) } == "notes")
    #expect(rule_check_flag(window_manager_rule_at(wm, 3), RULE_ONE_SHOT_REMOVE) == false)
    free(effects.scratchpad)

    // NOTE: one-shot rules only apply to new windows, and are then marked for removal
    effects = rule_effects()
    #expect(window_manager_combine_matching_rule_effects(wm, target, strings.title, strings.role, strings.dialog, true, false, &effects) == true)
    #expect(rule_effects_check_flag(&effects, RULE_LAYER) == true)
    #expect(rule_check_flag(window_manager_rule_at(wm, 3), RULE_ONE_SHOT_REMOVE) == true)
    free(effects.scratchpad)

    window_manager_remove_one_shot_rules(wm)
    #expect(window_manager_rule_count(wm) == 3)

    // NOTE: a window managed by a rule matches rules without a subrole pattern
    window_set_rule_flag(target, WINDOW_RULE_MANAGED)
    effects = rule_effects()
    #expect(window_manager_combine_matching_rule_effects(wm, target, strings.title, strings.role, strings.dialog, false, false, &effects) == true)
    #expect(effects.sid == 4)
    free(effects.scratchpad)
}

@Test("window_rules_manage_round") func windowRulesManageRound()
{
    let owner = applicationCreate("Safari")
    let target = windowCreate(1, owner)
    let wm = windowManagerCreate()
    let strings = WindowStrings()
    defer { windowManagerFree(wm); free(owner.name); strings.free() }

    // NOTE: in the manage round only rules that make a window managed are limited to standard windows
    var manage = windowRulesTestRule("^Safari$", nil, rule_flag(0))
    manage.effects.manage = RULE_PROP_ON
    window_manager_add_rule(wm, manage)

    var effectsOnly = windowRulesTestRule("^Safari$", nil, rule_flag(0))
    effectsOnly.effects.sticky = RULE_PROP_ON
    window_manager_add_rule(wm, effectsOnly)

    var effects = rule_effects()
    #expect(window_manager_combine_matching_rule_effects(wm, target, strings.title, strings.role, strings.dialog, false, true, &effects) == true)
    #expect(effects.manage == RULE_PROP_UD)
    #expect(effects.sticky == RULE_PROP_ON)

    effects = rule_effects()
    #expect(window_manager_combine_matching_rule_effects(wm, target, strings.title, strings.role, strings.standard, false, true, &effects) == true)
    #expect(effects.manage == RULE_PROP_ON)

    free(owner.pointee.name)
    owner.pointee.name = strdup("Mail")
    effects = rule_effects()
    #expect(window_manager_combine_matching_rule_effects(wm, target, strings.title, strings.role, strings.standard, false, true, &effects) == false)
}
