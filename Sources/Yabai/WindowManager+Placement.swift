import ApplicationServices
import CoreGraphics
import CPrivate
import YabaiCore

extension WindowManager
{
    func sendWindow(_ target: Window, to destination: SpaceID, movedByRule: Bool)
    {
        let source = target.id.space
        if source == destination { return }

        if let source, space_is_visible(source) && (movedByRule || focused_window_id == target.id) {
            if let next = window_manager_find_window_on_space_by_rank_filtering_window(self, source, 1, target.id) {
                window_manager_focus_window_with_raise(&next.application.psn, next.id, next.ref)
            } else {
                _SLPSSetFrontProcessWithOptions(&process_manager_global().finder_psn, 0, FrontProcessMode.noWindows.rawValue)
            }
        }

        if let owner = managedView(for: target) {
            unmanageWindow(target, from: owner)
        }

        space_manager_move_window_to_space(destination, target)
        _ = space_manager_wait_for_window_on_space(target.id, destination, 200)
        SLSSpaceSetFrontPSN(connection_global(), destination.rawValue, target.application.psn)

        if target.shouldBeManaged {
            manageWindow(target, on: destination, inserting: nil)
        }

        border_refresh_space(source)
        border_refresh_window_space(target)
    }

    @discardableResult
    func applyGrid(_ grid: Grid, to target: Window) -> WindowOperationResult
    {
        let rows = grid.rows, columns = grid.columns
        if managedView(for: target) != nil { return .invalidSourceView }

        guard let displayID = target.id.displayID else { return .invalidSourceView }

        var x = grid.x, y = grid.y, width = grid.width, height = grid.height
        if x >= columns { x = columns &- 1 }
        if y >= rows { y = rows &- 1 }
        if width <= 0 { width = 1 }
        if height <= 0 { height = 1 }
        if width > columns &- x { width = columns &- x }
        if height > rows &- y { height = rows &- y }

        var bounds = display_bounds_constrained(displayID, false)

        // NOTE: A display without a space applies the grid without padding and gaps because its view has none.
        let displayView = display_space_id(displayID).map { space_manager_find_view(SpaceManager.shared, $0) }

        if let displayView, displayView.isPaddingEnabled {
            bounds.origin.x    += CGFloat(displayView.leftPadding)
            bounds.size.width  -= CGFloat(displayView.leftPadding + displayView.rightPadding)
            bounds.origin.y    += CGFloat(displayView.topPadding)
            bounds.size.height -= CGFloat(displayView.topPadding + displayView.bottomPadding)
        }

        if let displayView, displayView.isGapEnabled {
            let gap = CGFloat(displayView.windowGap)

            if x > 0 {
                bounds.origin.x   += gap
                bounds.size.width -= gap
            }

            if y > 0 {
                bounds.origin.y    += gap
                bounds.size.height -= gap
            }

            if columns > x &+ width { bounds.size.width  -= gap }
            if rows > y &+ height { bounds.size.height -= gap }
        }

        let cellWidth = Float(bounds.size.width / CGFloat(columns))
        let cellHeight = Float(bounds.size.height / CGFloat(rows))
        let frameX = Float(bounds.origin.x + bounds.size.width - CGFloat(cellWidth * Float(columns &- x)))
        let frameY = Float(bounds.origin.y + bounds.size.height - CGFloat(cellHeight * Float(rows &- y)))
        let frameWidth = cellWidth * Float(width)
        let frameHeight = cellHeight * Float(height)

        window_manager_animate_window(window_capture(window: target, x: frameX, y: frameY, w: frameWidth, h: frameHeight))
        return .success
    }

    func makeWindowFloating(_ target: Window, shouldFloat: Bool, force: Bool)
    {
        if !target.isEligibleForManagement { return }

        if !force && (!target.isStandard || !target.isStandardLevel || !target.canMove) {
            if !target.isManagedByRule { return }
        }

        if shouldFloat {
            if let owner = managedView(for: target) {
                unmanageWindow(target, from: owner)
            }
            target.isFloating = true
        } else {
            target.isFloating = false

            if !target.isSticky && target.shouldBeManaged && managedView(for: target) == nil {
                if let spaceID = space_manager_active_space() { manageWindow(target, on: spaceID, inserting: nil) }
            }
        }
    }

    func makeWindowSticky(_ target: Window, shouldBeSticky: Bool)
    {
        if !target.isEligibleForManagement { return }

        if shouldBeSticky {
            if scripting_addition_set_sticky(target.id, true) {
                if let owner = managedView(for: target) {
                    unmanageWindow(target, from: owner)
                }
                target.isSticky = true
            }
        } else if scripting_addition_set_sticky(target.id, false) {
            target.isSticky = false

            if !target.isFloating && target.shouldBeManaged && managedView(for: target) == nil {
                if let spaceID = space_manager_active_space() { manageWindow(target, on: spaceID, inserting: nil) }
            }
        }
    }
}
