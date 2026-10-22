import ApplicationServices
import CPrivate
import CoreGraphics
import YabaiCore

extension WindowManager {
  func sendWindow(_ target: Window, to destination: SpaceID, movedByRule: Bool) {
    let source = target.id.space
    if source == destination { return }

    if let source, source.isVisible && (movedByRule || focus.focused == target.id) {
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

  func applyGrid(_ grid: Grid, to target: Window) throws(WindowOperationError) {
    if managedView(for: target) != nil { throw .invalidSourceView }

    guard let displayID = target.id.displayID else { throw .invalidSourceView }

    // NOTE: A display without a space applies the grid without padding and gaps because its view has none.
    let displayView = displayID.currentSpace.map { SpaceManager.shared.view(for: $0) }
    let padding = displayView.flatMap {
      $0.isPaddingEnabled
        ? (
          top: $0.topPadding, bottom: $0.bottomPadding, left: $0.leftPadding, right: $0.rightPadding
        ) : nil
    }
    let gap = displayView.flatMap { $0.isGapEnabled ? $0.windowGap : nil }

    let frame = grid.frame(
      in: displayID.constrainedBounds(ignoringExternalBar: false), padding: padding, gap: gap)
    animateWindow(WindowPlacement(window: target, x: frame.x, y: frame.y, w: frame.w, h: frame.h))
  }

  func makeWindowFloating(_ target: Window, shouldFloat: Bool, force: Bool) {
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

  func makeWindowSticky(_ target: Window, shouldBeSticky: Bool) {
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
