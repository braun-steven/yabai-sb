import Foundation
import CPrivate

//
// NOTE: Scratchpads: windows with a label that are floated and toggled between hidden (ordered out)
// and shown on the active space, configured by the scratchpad_* options. Ported from
// src/window_manager_scratchpad.c. The list is window_manager.scratchpad_window.
//

/// `window_manager_find_scratchpad_window`
private func windowManagerFindScratchpadWindow(_ wm: WindowManager, _ label: UnsafeMutablePointer<CChar>) -> Window?
{
    return wm.scratchpad_window.first { string_equals($0.label, label) }?.window
}

/// `window_manager_toggle_scratchpad_window_by_label`
func window_manager_toggle_scratchpad_window_by_label(_ wm: WindowManager, _ label: UnsafeMutablePointer<CChar>) -> Bool
{
    guard let target = windowManagerFindScratchpadWindow(wm, label) else { return false }
    return window_manager_toggle_scratchpad_window(wm, target)
}

/// `window_manager_set_scratchpad_layers`
func window_manager_set_scratchpad_layers(_ wm: WindowManager)
{
    for entry in wm.scratchpad_window {
        window_manager_adjust_layer(entry.window, wm.scratchpad_below ? layerValue(.below) : layerValue(.normal))
    }
}

/// `window_manager_hide_other_scratchpad_windows`
private func windowManagerHideOtherScratchpadWindows(_ wm: WindowManager, _ target: Window)
{
    for entry in wm.scratchpad_window {
        let other = entry.window
        if other == target { continue }

        if SLS.windowIsOrderedIn(connection_global(), other.id) { scripting_addition_order_window(other.id, 0, 0) }
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
    window_manager_apply_grid(space_manager_global(), wm, target, grid)
    wm.window_animation_duration = animationDuration
}

/// `window_manager_hide_scratchpad_window`
private func windowManagerHideScratchpadWindow(_ wm: WindowManager, _ target: Window, _ sid: UInt64)
{
    if let next = window_manager_find_window_on_space_by_rank_filtering_window(wm, sid, 1, target.id) {
        window_manager_focus_window_with_raise(&next.application.psn, next.id, next.ref)
    } else {
        _SLPSSetFrontProcessWithOptions(&process_manager_global().finder_psn, 0, UInt32(kCPSNoWindows))
    }

    scripting_addition_order_window(target.id, 0, 0)
}

/// `window_manager_show_scratchpad_window`
private func windowManagerShowScratchpadWindow(_ wm: WindowManager, _ target: Window, _ sid: UInt64, _ moveToSpace: Bool, _ applyGrid: Bool)
{
    if moveToSpace {
        space_manager_move_window_to_space(sid, target)
        _ = space_manager_wait_for_window_on_space(target.id, sid, 200)
    }

    if applyGrid { windowManagerApplyScratchpadGrid(wm, target) }
    scripting_addition_order_window(target.id, 1, 0)
    window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
}

/// `window_manager_toggle_scratchpad_window`
func window_manager_toggle_scratchpad_window(_ wm: WindowManager, _ target: Window) -> Bool
{
    let sid = space_manager_active_space()
    if sid == 0 { return false }

    // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
    let visibleSpace = window_space(target.id) == sid || window_is_sticky(target.id)

    let orderedIn = SLS.windowIsOrderedIn(connection_global(), target.id)

    var shown = true

    if visibleSpace && orderedIn {
        if wm.scratchpad_raise && wm.focused_window_id != target.id && !window_check_flag(target, WINDOW_MINIMIZE) && !target.application.is_hidden {
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

/// `window_manager_set_scratchpad_for_window`: the window manager takes over the malloc'ed label on success.
func window_manager_set_scratchpad_for_window(_ wm: WindowManager, _ target: Window, _ label: UnsafeMutablePointer<CChar>) -> Bool
{
    if windowManagerFindScratchpadWindow(wm, label) != nil { return false }

    _ = window_manager_remove_scratchpad_for_window(wm, target, false)
    window_manager_add_scratchpad(wm, label, target)
    target.scratchpad = label
    window_manager_make_window_floating(space_manager_global(), wm, target, true, false)

    //
    // NOTE: Floating puts the window on the normal sub-layer, above
    // tiled windows; scratchpad_below moves it to their sub-layer.
    //

    if wm.scratchpad_below { window_manager_adjust_layer(target, layerValue(.below)) }

    return true
}

//
// NOTE: A window that stops being a scratchpad is brought to the active space and shown,
// without the scratchpad_* options, which only apply to toggling by label.
//

/// `window_manager_release_scratchpad_window`
private func windowManagerReleaseScratchpadWindow(_ wm: WindowManager, _ target: Window)
{
    let sid = space_manager_active_space()
    if sid != 0 {
        windowManagerShowScratchpadWindow(wm, target, sid, true, false)
        border_refresh_window_space(target)
    }

    if wm.scratchpad_below { window_manager_adjust_layer(target, layerValue(.normal)) }
    window_manager_make_window_floating(space_manager_global(), wm, target, false, false)
}

/// `window_manager_remove_scratchpad_for_window`
@discardableResult
func window_manager_remove_scratchpad_for_window(_ wm: WindowManager, _ target: Window, _ unfloat: Bool) -> Bool
{
    for i in 0..<window_manager_scratchpad_count(wm) where wm.scratchpad_window[Int(i)].window == target {
        target.scratchpad = nil

        free(wm.scratchpad_window[Int(i)].label)
        window_manager_remove_scratchpad(wm, i)

        if unfloat { windowManagerReleaseScratchpadWindow(wm, target) }

        return true
    }

    return false
}

/// `window_manager_scratchpad_recover_windows`
func window_manager_scratchpad_recover_windows()
{
    guard var windowList = windowManagerExistingApplicationWindowList(nil) else { return }

    if windowList.withUnsafeMutableBufferPointer({ scripting_addition_order_window_in($0.baseAddress, Int32($0.count)) }) {
        _ = space_manager_refresh_application_windows(space_manager_global())
    }
}
