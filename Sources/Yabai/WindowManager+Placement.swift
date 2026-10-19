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

        if let source, source.isVisible && (movedByRule || focusedWindowID == target.id) {
            if let next = window(on: source, byRank: 1, excluding: target.id) {
                focusWithRaise(next)
            } else {
                SLS.setFrontProcess(ProcessManager.shared.finderPSN, window: nil, mode: .noWindows)
            }
        }

        if let owner = managedView(for: target) {
            unmanageWindow(target, from: owner)
        }

        destination.moveWindow(target)
        _ = destination.waitForWindow(target.id, timeoutMS: 200)
        SLS.setFrontProcess(SLS.connection, target.application.psn, forSpace: destination)

        if target.shouldBeManaged {
            manageWindow(target, on: destination, inserting: nil)
        }

        Border.refresh(space: source)
        Border.refreshSpace(of: target)
    }

    func applyGrid(_ grid: Grid, to target: Window) throws(WindowOperationError)
    {
        let rows = grid.rows, columns = grid.columns
        if managedView(for: target) != nil { throw .invalidSourceView }

        guard let displayID = target.id.displayID else { throw .invalidSourceView }

        var x = grid.x, y = grid.y, width = grid.width, height = grid.height
        if x >= columns { x = columns &- 1 }
        if y >= rows { y = rows &- 1 }
        if width <= 0 { width = 1 }
        if height <= 0 { height = 1 }
        if width > columns &- x { width = columns &- x }
        if height > rows &- y { height = rows &- y }

        var bounds = displayID.constrainedBounds(ignoringExternalBar: false)

        // NOTE: A display without a space applies the grid without padding and gaps because its view has none.
        let displayView = displayID.currentSpace.map { SpaceManager.shared.view(for: $0) }

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

        animateWindow(WindowPlacement(window: target, x: frameX, y: frameY, w: frameWidth, h: frameHeight))
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
                if let spaceID = SpaceID.active { manageWindow(target, on: spaceID, inserting: nil) }
            }
        }
    }

    func makeWindowSticky(_ target: Window, shouldBeSticky: Bool)
    {
        if !target.isEligibleForManagement { return }

        if shouldBeSticky {
            if ScriptingAddition.shared.setSticky(true, of: target.id) {
                if let owner = managedView(for: target) {
                    unmanageWindow(target, from: owner)
                }
                target.isSticky = true
            }
        } else if ScriptingAddition.shared.setSticky(false, of: target.id) {
            target.isSticky = false

            if !target.isFloating && target.shouldBeManaged && managedView(for: target) == nil {
                if let spaceID = SpaceID.active { manageWindow(target, on: spaceID, inserting: nil) }
            }
        }
    }
}
