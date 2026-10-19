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
        scratchpads.first { $0.label.bytesEqual(label) }?.window
    }

    func toggleScratchpad(withLabel label: String) -> Bool
    {
        guard let target = scratchpadWindow(withLabel: label) else { return false }
        return toggleScratchpad(target)
    }

    func setScratchpadLayers()
    {
        for entry in scratchpads {
            entry.window.adjustLayer(to: scratchpadBelow ? .below : .normal)
        }
    }

    private func hideOtherScratchpadWindows(except target: Window)
    {
        for entry in scratchpads {
            let other = entry.window
            if other == target { continue }

            if SLS.windowIsOrderedIn(SLS.connection, other.id) { ScriptingAddition.shared.orderWindow(other.id, 0, relativeTo: nil) }
        }
    }

    private func applyScratchpadGrid(to target: Window)
    {
        let grid = scratchpadGrid
        if grid.rows == 0 || grid.columns == 0 { return }

        //
        // NOTE: The window is still ordered out, so an animation
        // would capture a stale image; set the frame directly instead.
        //

        let animationDuration = windowAnimationDuration
        windowAnimationDuration = 0.0
        applyGrid(grid, to: target)
        windowAnimationDuration = animationDuration
    }

    private func hideScratchpad(_ target: Window, on spaceID: SpaceID)
    {
        if let next = window(on: spaceID, byRank: 1, excluding: target.id) {
            focusWithRaise(next)
        } else {
            SLS.setFrontProcess(ProcessManager.shared.finderPSN, window: nil, mode: .noWindows)
        }

        ScriptingAddition.shared.orderWindow(target.id, 0, relativeTo: nil)
    }

    private func showScratchpad(
        _ target: Window,
        on spaceID: SpaceID,
        movingToSpace: Bool,
        applyingGrid: Bool
    )
    {
        if movingToSpace {
            spaceID.moveWindow(target)
            _ = spaceID.waitForWindow(target.id, timeoutMS: 200)
        }

        if applyingGrid { applyScratchpadGrid(to: target) }
        ScriptingAddition.shared.orderWindow(target.id, 1, relativeTo: nil)
        focusWithRaise(target)
    }

    func toggleScratchpad(_ target: Window) -> Bool
    {
        guard let spaceID = SpaceID.active else { return false }

        // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
        let visibleSpace = target.id.space == spaceID || target.id.isSticky

        let orderedIn = SLS.windowIsOrderedIn(SLS.connection, target.id)

        var shown = true

        if visibleSpace && orderedIn {
            if scratchpadRaise && focusedWindowID != target.id && !target.isMinimized && !target.application.isHidden {
                focusWithRaise(target)
            } else {
                hideScratchpad(target, on: spaceID)
                shown = false
            }
        } else {
            showScratchpad(target, on: spaceID, movingToSpace: !visibleSpace, applyingGrid: !orderedIn)
        }

        if shown && scratchpadExclusive {
            hideOtherScratchpadWindows(except: target)
        }

        Border.refreshSpace(of: target)

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
        // tiled windows; scratchpadBelow moves it to their sub-layer.
        //

        if scratchpadBelow { target.adjustLayer(to: .below) }

        return true
    }

    //
    // NOTE: A window that stops being a scratchpad is brought to the active space and shown,
    // without the scratchpad_* options, which only apply to toggling by label.
    //

    private func releaseScratchpad(_ target: Window)
    {
        if let spaceID = SpaceID.active {
            showScratchpad(target, on: spaceID, movingToSpace: true, applyingGrid: false)
            Border.refreshSpace(of: target)
        }

        if scratchpadBelow { target.adjustLayer(to: .normal) }
        makeWindowFloating(target, shouldFloat: false, force: false)
    }

    @discardableResult
    func removeScratchpad(from target: Window, unfloat: Bool) -> Bool
    {
        for index in 0..<scratchpadCount where scratchpads[index].window == target {
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

        if ScriptingAddition.shared.orderIn(windowList) {
            _ = SpaceManager.shared.refreshApplicationWindows()
        }
    }
}
