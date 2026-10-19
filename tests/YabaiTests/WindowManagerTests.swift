import Foundation
import Testing
import CPrivate
import YabaiCore
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
    wm.rules = []
    wm.window.removeAll()
}

/// A valid window with an id and an application.
private func windowCreate(_ id: WindowID, _ owner: Application? = nil) -> Window
{
    let result = Window(id: id)
    result.application = owner
    return result
}

/// An application with a malloc'ed name, which the test frees.
private func applicationCreate(_ name: String) -> Application
{
    let result = Application()
    result.name = name
    return result
}

@Test("window_pending_focus") func windowPendingFocus()
{
    let wm = windowManagerCreate()
    let target = windowCreate(42)
    defer { windowManagerFree(wm) }

    wm.addWindow(target)

    #expect(wm.pendingFocusWindow == nil)

    wm.setPendingFocus(42)
    #expect(wm.pendingFocusWindow == target)
    #expect(wm.pendingFocusWindowID == 42)

    //
    // NOTE: A pending focus expires, and is dropped for windows that no longer exist.
    //

    wm.pendingFocusTime = read_os_timer() - UInt64(Double(read_os_freq()) * 0.6)
    #expect(wm.pendingFocusWindow == nil)
    #expect(wm.pendingFocusWindowID == nil)

    wm.setPendingFocus(7)
    #expect(wm.pendingFocusWindow == nil)
    #expect(wm.pendingFocusWindowID == nil)
}

@Test("window_unresolved_list") func windowUnresolvedList()
{
    let wm = windowManagerCreate()
    let windows = [12, 14, 11, 13].map { windowCreate($0) }
    defer { windowManagerFree(wm) }

    wm.addWindow(windows[0])
    wm.addWindow(windows[1])
    #expect(wm.unresolvedWindows(in: [11, 12, 13, 14]) == [11, 13])

    wm.addWindow(windows[2])
    wm.addWindow(windows[3])
    #expect(wm.unresolvedWindows(in: [11, 12, 13, 14]).isEmpty)
}

@Test("window_validity") func windowValidity()
{
    let target = windowCreate(5)

    #expect(target.isValid == true)
    #expect(target.invalidate() == true)
    #expect(target.isValid == false)

    // NOTE: only one caller may claim the destruction of a window
    #expect(target.invalidate() == false)
}

private func oneShotTestRule(matched: Bool, _ label: String) -> Rule
{
    var result = Rule()
    result.oneShot = matched
    result.matched = matched
    result.label = label
    return result
}

@Test("window_one_shot_rules") func windowOneShotRules()
{
    let wm = windowManagerCreate()
    defer { windowManagerFree(wm) }

    wm.rules = [oneShotTestRule(matched: true, "a"), oneShotTestRule(matched: false, "b"),
                oneShotTestRule(matched: true, "c"), oneShotTestRule(matched: true, "d")]

    wm.removeOneShotRules()
    #expect(wm.rules.map(\.label) == ["b"])
}

//
// NOTE: 1 has the children 2 and 3, 3 has the child 4, and 9 belongs to another window. The direct relations
// make every window a direct child, which needs as many entries as there are relations.
//

@Test("window_child_windows_collect") func windowChildWindowsCollect()
{
    var parentList: [WindowID?] = [3, 1, 9, 1]
    #expect(WindowManager.collectChildWindows(1, parents: &parentList, children: [4, 2, 8, 3]) == [2, 3, 4])

    var directParent: [WindowID?] = [1, 1, 1]
    #expect(WindowManager.collectChildWindows(1, parents: &directParent, children: [2, 3, 4]).count == 3)

    // NOTE: a cycle does not repeat windows
    var cycleParent: [WindowID?] = [1, 2]
    #expect(WindowManager.collectChildWindows(1, parents: &cycleParent, children: [2, 1]).count == 2)

    var emptyParent: [WindowID?] = []
    #expect(WindowManager.collectChildWindows(1, parents: &emptyParent, children: []).isEmpty)
}

private func windowRulesTestRule(_ app: String, _ subrole: String?, oneShot: Bool = false) -> Rule
{
    var result = Rule()
    result.oneShot = oneShot
    result.app = RulePattern(Token(app), exclude: false)
    result.subrole = subrole.map { RulePattern(Token($0), exclude: false) }
    return result
}

/// The window properties used when combining matching rule effects.
private struct WindowStrings
{
    let title = ""
    let role = "AXWindow"
    let dialog = "AXDialog"
    let standard = "AXStandardWindow"

}

@Test("window_rules_combine_matching") func windowRulesCombineMatching()
{
    let owner = applicationCreate("Safari")
    let target = windowCreate(1, owner)
    let wm = windowManagerCreate()
    let strings = WindowStrings()
    defer { windowManagerFree(wm) }

    // NOTE: without a subrole pattern a rule does not match a dialog
    var any = windowRulesTestRule("^Safari$", nil)
    any.effects.sid = 4
    wm.rules.append(any)

    var dialog = windowRulesTestRule("^Safari$", "^AXDialog$")
    dialog.effects.sticky = true
    dialog.effects.scratchpad = "notes"
    wm.rules.append(dialog)

    var otherApp = windowRulesTestRule("^Mail$", "^AXDialog$")
    otherApp.effects.mouseFollowsFocus = true
    wm.rules.append(otherApp)

    var oneShot = windowRulesTestRule("^Safari$", "^AXDialog$", oneShot: true)
    oneShot.effects.layer = .above
    oneShot.effects.flags.insert(.layer)
    wm.rules.append(oneShot)

    var effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: false, manageRound: false, into: &effects) == true)
    #expect(effects.sid == nil)
    #expect(effects.sticky == true)
    #expect(effects.mouseFollowsFocus == nil)
    #expect(effects.flags.contains(.layer) == false)
    #expect(effects.scratchpad == "notes")
    #expect(wm.rules[3].matched == false)

    // NOTE: one-shot rules only apply to new windows, and are then marked for removal
    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: true, manageRound: false, into: &effects) == true)
    #expect(effects.flags.contains(.layer) == true)
    #expect(wm.rules[3].matched == true)

    wm.removeOneShotRules()
    #expect(wm.rules.count == 3)

    // NOTE: a window managed by a rule matches rules without a subrole pattern
    target.isManagedByRule = true
    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: false, manageRound: false, into: &effects) == true)
    #expect(effects.sid == 4)
}

@Test("window_rules_manage_round") func windowRulesManageRound()
{
    let owner = applicationCreate("Safari")
    let target = windowCreate(1, owner)
    let wm = windowManagerCreate()
    let strings = WindowStrings()
    defer { windowManagerFree(wm) }

    // NOTE: in the manage round only rules that make a window managed are limited to standard windows
    var manage = windowRulesTestRule("^Safari$", nil)
    manage.effects.manage = true
    wm.rules.append(manage)

    var effectsOnly = windowRulesTestRule("^Safari$", nil)
    effectsOnly.effects.sticky = true
    wm.rules.append(effectsOnly)

    var effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.dialog, includingOneShotRules: false, manageRound: true, into: &effects) == true)
    #expect(effects.manage == nil)
    #expect(effects.sticky == true)

    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.standard, includingOneShotRules: false, manageRound: true, into: &effects) == true)
    #expect(effects.manage == true)

    owner.name = "Mail"
    effects = RuleEffects()
    #expect(wm.combineMatchingRuleEffects(for: target, title: strings.title, role: strings.role, subrole: strings.standard, includingOneShotRules: false, manageRound: true, into: &effects) == false)
}
