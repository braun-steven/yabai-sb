import ApplicationServices
import CPrivate
import CoreGraphics
import YabaiCore

extension WindowManager {
  //
  // NOTE: sway cmd_move_container (`move container to output|workspace`). The window leaves its view first, so that the
  // focus left behind on a visible source is the window its tree focuses now, the most recently focused one there
  // (displayFocusTarget(on:from:excluding:), as sway takes the focus-inactive container of the old parent and then of
  // the old workspace), not the frontmost window of the space, which can be a dialog yabai does not manage. A source
  // without such a window activates Finder. A caller that focuses the moved window right afterwards passes
  // `refocusingSource: false`, so the source does not take the focus in between. With `besideFocus` the window becomes
  // the sibling after the window the destination's tree focuses, without tree_autotiling (View.add); with `arrivingFrom`
  // it arrives on the side it comes from, as moved in that direction; a window moved by a rule opens like a new window
  // instead. A window that a command focused just before (`window --focus B --display west`, one message) counts as
  // focused although its application has not reported the focus yet (`FocusState.hasFocus(_:now:)`), as sway's focus
  // command sets the focus at once.
  //

  // NOTE: A window that a rule moves away has not taken the focus yet, so its source takes it back only when the source
  // is the focused space. An application can open a window on a visible space of another display (ChatGPT opens an
  // untitled helper window on the main display while the user types on the other one); refocusing that space would
  // pull the focus to the other display.
  static func refocusesSource(
    isVisible: Bool, isFocusedSpace: Bool, movedByRule: Bool, wasFocused: Bool
  ) -> Bool {
    return isVisible && (wasFocused || (movedByRule && isFocusedSpace))
  }

  func sendWindow(
    _ target: Window, to destination: SpaceID, movedByRule: Bool, besideFocus: Bool = false,
    arrivingFrom direction: Direction? = nil, refocusingSource: Bool = true
  ) {
    let source = target.id.space
    if source == destination { return }

    let wasFocused = focus.hasFocus(target.id, now: OSTimer.now)
    if let owner = managedView(for: target) {
      unmanageWindow(target, from: owner)
    }

    if refocusingSource, let source,
      Self.refocusesSource(
        isVisible: source.isVisible, isFocusedSpace: source == SpaceManager.shared.currentSpaceID,
        movedByRule: movedByRule, wasFocused: wasFocused)
    {
      if let next = displayFocusTarget(on: source, from: nil, excluding: target.id) {
        focusWithRaise(next)
        setPendingFocus(next.id, warpsMouse: false)
      } else {
        SLS.setFrontProcess(ProcessManager.shared.finderPSN, window: nil, mode: .noWindows)
      }
    }

    destination.moveWindow(target)
    _ = destination.waitForWindow(target.id, timeoutMS: 200)
    SLS.setFrontProcess(SLS.connection, target.application.psn, forSpace: destination)

    if target.shouldBeManaged {
      manageWindow(
        target, on: destination, inserting: nil, besideFocus: besideFocus, arrivingFrom: direction)
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
    placeWindow(WindowPlacement(window: target, x: frame.x, y: frame.y, w: frame.w, h: frame.h))
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
      let wasFloating = target.isFloating
      target.isFloating = true
      if !wasFloating { restoreFloatingFrame(of: target) }
    } else {
      target.rememberFloatingFrame()
      target.isFloating = false

      // NOTE: In headless mode the test process must not ask the window server for the active space.
      if !target.isSticky && target.shouldBeManaged && managedView(for: target) == nil {
        if let spaceID = Headless.isEnabled ? Headless.activeSpace : SpaceID.active {
          manageWindow(target, on: spaceID, inserting: nil)
        }
      }
    }
  }

  /// Moves a window that starts floating to the frame it remembers (`Window.lastFloatingFrame`), through the placement
  /// path. Nothing moves when no frame is remembered, or when the frame decision keeps the current frame.
  private func restoreFloatingFrame(of target: Window) {
    guard let remembered = target.lastFloatingFrame else { return }
    guard
      let frame = FloatingFrame.restoredFrame(
        remembered: remembered, current: target.frame, displays: visibleDisplayFrames())
    else { return }
    placeWindow(
      WindowPlacement(
        window: target, x: Float(frame.origin.x), y: Float(frame.origin.y),
        w: Float(frame.size.width), h: Float(frame.size.height)))
  }

  /// The visible frame of each display, the area that windows can use. In headless mode, the one headless display.
  func visibleDisplayFrames() -> [CGRect] {
    if Headless.isEnabled { return [Headless.displayFrame] }
    return DisplayID.all.map { $0.constrainedBounds(ignoringExternalBar: false) }
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
