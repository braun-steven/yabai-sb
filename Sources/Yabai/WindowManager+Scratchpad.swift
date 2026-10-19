import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Scratchpads are labeled windows that are floated and toggled between hidden (ordered out)
// and shown on the active space, using the scratchpad_* options. WindowManager owns their list.
//

extension WindowManager
{
    private func scratchpadWindow(withLabel label: String) -> Window?
    {
        scratchpad_window.first { string_equals($0.label, label) }?.window
    }

    func toggleScratchpad(withLabel label: String) -> Bool
    {
        guard let target = scratchpadWindow(withLabel: label) else { return false }
        return toggleScratchpad(target)
    }

    func setScratchpadLayers()
    {
        for entry in scratchpad_window {
            entry.window.adjustLayer(to: scratchpad_below ? .below : .normal)
        }
    }

    private func hideOtherScratchpadWindows(except target: Window)
    {
        for entry in scratchpad_window {
            let other = entry.window
            if other == target { continue }

            if SLS.windowIsOrderedIn(connection_global(), other.id) { scripting_addition_order_window(other.id, 0, nil) }
        }
    }

    private func applyScratchpadGrid(to target: Window)
    {
        let grid = scratchpad_grid
        if grid.rows == 0 || grid.columns == 0 { return }

        //
        // NOTE: The window is still ordered out, so an animation
        // would capture a stale image; set the frame directly instead.
        //

        let animationDuration = window_animation_duration
        window_animation_duration = 0.0
        applyGrid(grid, to: target)
        window_animation_duration = animationDuration
    }

    private func hideScratchpad(_ target: Window, on spaceID: SpaceID)
    {
        if let next = window(on: spaceID, byRank: 1, excluding: target.id) {
            focusWithRaise(next)
        } else {
            _SLPSSetFrontProcessWithOptions(&process_manager_global().finder_psn, 0, FrontProcessMode.noWindows.rawValue)
        }

        scripting_addition_order_window(target.id, 0, nil)
    }

    private func showScratchpad(
        _ target: Window,
        on spaceID: SpaceID,
        movingToSpace: Bool,
        applyingGrid: Bool
    )
    {
        if movingToSpace {
            space_manager_move_window_to_space(spaceID, target)
            _ = space_manager_wait_for_window_on_space(target.id, spaceID, 200)
        }

        if applyingGrid { applyScratchpadGrid(to: target) }
        scripting_addition_order_window(target.id, 1, nil)
        focusWithRaise(target)
    }

    func toggleScratchpad(_ target: Window) -> Bool
    {
        guard let spaceID = space_manager_active_space() else { return false }

        // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
        let visibleSpace = target.id.space == spaceID || target.id.isSticky

        let orderedIn = SLS.windowIsOrderedIn(connection_global(), target.id)

        var shown = true

        if visibleSpace && orderedIn {
            if scratchpad_raise && focused_window_id != target.id && !target.isMinimized && !target.application.isHidden {
                focusWithRaise(target)
            } else {
                hideScratchpad(target, on: spaceID)
                shown = false
            }
        } else {
            showScratchpad(target, on: spaceID, movingToSpace: !visibleSpace, applyingGrid: !orderedIn)
        }

        if shown && scratchpad_exclusive {
            hideOtherScratchpadWindows(except: target)
        }

        border_refresh_window_space(target)

        return true
    }

    func setScratchpad(for target: Window, label: String) -> Bool
    {
        if scratchpadWindow(withLabel: label) != nil { return false }

        _ = removeScratchpad(from: target, unfloat: false)
        addScratchpad(label: label, window: target)
        target.scratchpad = label
        makeWindowFloating(target, shouldFloat: true, force: false)

        //
        // NOTE: Floating puts the window on the normal sub-layer, above
        // tiled windows; scratchpad_below moves it to their sub-layer.
        //

        if scratchpad_below { target.adjustLayer(to: .below) }

        return true
    }

    //
    // NOTE: A window that stops being a scratchpad is brought to the active space and shown,
    // without the scratchpad_* options, which only apply to toggling by label.
    //

    private func releaseScratchpad(_ target: Window)
    {
        if let spaceID = space_manager_active_space() {
            showScratchpad(target, on: spaceID, movingToSpace: true, applyingGrid: false)
            border_refresh_window_space(target)
        }

        if scratchpad_below { target.adjustLayer(to: .normal) }
        makeWindowFloating(target, shouldFloat: false, force: false)
    }

    @discardableResult
    func removeScratchpad(from target: Window, unfloat: Bool) -> Bool
    {
        for index in 0..<scratchpadCount where scratchpad_window[index].window == target {
            target.scratchpad = nil

            removeScratchpad(at: index)

            if unfloat { releaseScratchpad(target) }

            return true
        }

        return false
    }

    func recoverScratchpadWindows()
    {
        guard let windowList = existingApplicationWindowList(for: nil) else { return }

        if scripting_addition_order_window_in(windowList) {
            _ = space_manager_refresh_application_windows(space_manager_global())
        }
    }
}
