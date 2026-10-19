import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Scratchpads: windows with a label that are floated and toggled between hidden (ordered out)
// and shown on the active space, configured by the scratchpad_* options. Ported from
// src/window_manager_scratchpad.c. The list is WindowManager.scratchpad_window.
//

/// `window_manager_find_scratchpad_window`
private func windowManagerFindScratchpadWindow(_ wm: WindowManager, _ label: String) -> Window?
{
    return wm.scratchpad_window.first { string_equals($0.label, label) }?.window
}

/// `window_manager_toggle_scratchpad_window_by_label`
func window_manager_toggle_scratchpad_window_by_label(_ wm: WindowManager, _ label: String) -> Bool
{
    guard let target = windowManagerFindScratchpadWindow(wm, label) else { return false }
    return window_manager_toggle_scratchpad_window(wm, target)
}

/// `window_manager_set_scratchpad_layers`
func window_manager_set_scratchpad_layers(_ wm: WindowManager)
{
    for entry in wm.scratchpad_window {
        entry.window.adjustLayer(to: wm.scratchpad_below ? .below : .normal)
    }
}

/// `window_manager_hide_other_scratchpad_windows`
private func windowManagerHideOtherScratchpadWindows(_ wm: WindowManager, _ target: Window)
{
    for entry in wm.scratchpad_window {
        let other = entry.window
        if other == target { continue }

        if SLS.windowIsOrderedIn(connection_global(), other.id) { scripting_addition_order_window(other.id, 0, nil) }
    }
}

/// `window_manager_apply_scratchpad_grid`
private func windowManagerApplyScratchpadGrid(_ wm: WindowManager, _ target: Window)
{
    let grid = wm.scratchpad_grid
    if grid.rows == 0 || grid.columns == 0 { return }

    //
    // NOTE: The window is still ordered out, so an animation
    // would capture a stale image; set the frame directly instead.
    //

    let animationDuration = wm.window_animation_duration
    wm.window_animation_duration = 0.0
    wm.applyGrid(grid, to: target)
    wm.window_animation_duration = animationDuration
}

/// `window_manager_hide_scratchpad_window`
private func windowManagerHideScratchpadWindow(_ wm: WindowManager, _ target: Window, _ sid: SpaceID)
{
    if let next = window_manager_find_window_on_space_by_rank_filtering_window(wm, sid, 1, target.id) {
        window_manager_focus_window_with_raise(&next.application.psn, next.id, next.ref)
    } else {
        _SLPSSetFrontProcessWithOptions(&process_manager_global().finder_psn, 0, FrontProcessMode.noWindows.rawValue)
    }

    scripting_addition_order_window(target.id, 0, nil)
}

/// `window_manager_show_scratchpad_window`
private func windowManagerShowScratchpadWindow(_ wm: WindowManager, _ target: Window, _ sid: SpaceID, _ moveToSpace: Bool, _ applyGrid: Bool)
{
    if moveToSpace {
        space_manager_move_window_to_space(sid, target)
        _ = space_manager_wait_for_window_on_space(target.id, sid, 200)
    }

    if applyGrid { windowManagerApplyScratchpadGrid(wm, target) }
    scripting_addition_order_window(target.id, 1, nil)
    window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
}

/// `window_manager_toggle_scratchpad_window`
func window_manager_toggle_scratchpad_window(_ wm: WindowManager, _ target: Window) -> Bool
{
    guard let sid = space_manager_active_space() else { return false }

    // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
    let visibleSpace = target.id.space == sid || target.id.isSticky

    let orderedIn = SLS.windowIsOrderedIn(connection_global(), target.id)

    var shown = true

    if visibleSpace && orderedIn {
        if wm.scratchpad_raise && wm.focused_window_id != target.id && !target.isMinimized && !target.application.isHidden {
            window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
        } else {
            windowManagerHideScratchpadWindow(wm, target, sid)
            shown = false
        }
    } else {
        windowManagerShowScratchpadWindow(wm, target, sid, !visibleSpace, !orderedIn)
    }

    if shown && wm.scratchpad_exclusive {
        windowManagerHideOtherScratchpadWindows(wm, target)
    }

    border_refresh_window_space(target)

    return true
}

/// `window_manager_set_scratchpad_for_window`: fails when another window has the label.
func window_manager_set_scratchpad_for_window(_ wm: WindowManager, _ target: Window, _ label: String) -> Bool
{
    if windowManagerFindScratchpadWindow(wm, label) != nil { return false }

    _ = window_manager_remove_scratchpad_for_window(wm, target, false)
    wm.addScratchpad(label: label, window: target)
    target.scratchpad = label
    wm.makeWindowFloating(target, shouldFloat: true, force: false)

    //
    // NOTE: Floating puts the window on the normal sub-layer, above
    // tiled windows; scratchpad_below moves it to their sub-layer.
    //

    if wm.scratchpad_below { target.adjustLayer(to: .below) }

    return true
}

//
// NOTE: A window that stops being a scratchpad is brought to the active space and shown,
// without the scratchpad_* options, which only apply to toggling by label.
//

/// `window_manager_release_scratchpad_window`
private func windowManagerReleaseScratchpadWindow(_ wm: WindowManager, _ target: Window)
{
    if let sid = space_manager_active_space() {
        windowManagerShowScratchpadWindow(wm, target, sid, true, false)
        border_refresh_window_space(target)
    }

    if wm.scratchpad_below { target.adjustLayer(to: .normal) }
    wm.makeWindowFloating(target, shouldFloat: false, force: false)
}

/// `window_manager_remove_scratchpad_for_window`
@discardableResult
func window_manager_remove_scratchpad_for_window(_ wm: WindowManager, _ target: Window, _ unfloat: Bool) -> Bool
{
    for i in 0..<wm.scratchpadCount where wm.scratchpad_window[i].window == target {
        target.scratchpad = nil

        wm.removeScratchpad(at: i)

        if unfloat { windowManagerReleaseScratchpadWindow(wm, target) }

        return true
    }

    return false
}

/// `window_manager_scratchpad_recover_windows`
func window_manager_scratchpad_recover_windows()
{
    guard let windowList = windowManagerExistingApplicationWindowList(nil) else { return }

    if scripting_addition_order_window_in(windowList) {
        _ = space_manager_refresh_application_windows(space_manager_global())
    }
}
