import ApplicationServices
import CPrivate
import CoreGraphics
import Foundation
import Logging
import SortedCollections
import YabaiCore

//
// NOTE: The commands that focus, switch, swap, move, create and destroy spaces, mostly through the scripting addition.
//

extension SpaceManager {
  func toggleMissionControl(on sid: SpaceID) {
    try? focusSpace(sid)
    CoreDock.sendNotification("com.apple.expose.awake")
  }

  func toggleShowDesktop(on sid: SpaceID) {
    try? focusSpace(sid)
    CoreDock.sendNotification("com.apple.showdesktop.awake")
  }

  /// Swaps two spaces that are on different displays.
  private func swapSpaceAcrossDisplays(_ aSid: SpaceID, with bSid: SpaceID) {
    //
    // NOTE: Every operation may change the space or display lists (or the display that shows a space), so the cache is
    // dropped when it returns, whether or not the scripting addition succeeded.
    //
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    WindowManager.shared.withoutAnimations {
      let aWindows = aSid.windows(includingMinimized: true) ?? []
      let bWindows = bSid.windows(includingMinimized: true) ?? []

      let aView = views[aSid]!
      let bView = views[bSid]!

      views[aSid] = nil
      views[bSid] = nil

      aView.sid = bSid
      bView.sid = aSid

      let uuid = aView.uuid
      aView.uuid = bView.uuid
      bView.uuid = uuid

      views[aSid] = bView
      views[bSid] = aView

      if !aWindows.isEmpty {
        bSid.moveWindows(aWindows)
      }

      if !bWindows.isEmpty {
        aSid.moveWindows(bWindows)
      }

      labels.swap(aSid, bSid)

      aView.update()
      bView.update()

      aView.flush()
      bView.flush()
    }
  }

  func swapSpace(_ actingSid: SpaceID, with selectorSid: SpaceID) throws(SpaceOperationError) {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }

    let actingDid = actingSid.display
    let selectorDid = selectorSid.display

    if actingSid == selectorSid { throw .sameSpace }
    if actingDid != selectorDid {
      swapSpaceAcrossDisplays(actingSid, with: selectorSid)
      return
    }

    let actingPrevSid = actingSid.previous
    let selectorPrevSid = selectorSid.previous

    let actingPrevDid = actingPrevSid.flatMap { $0.display }
    let selectorPrevDid = selectorPrevSid.flatMap { $0.display }

    let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid

    let actingMCI = actingSid.missionControlIndex
    let selectorMCI = selectorSid.missionControlIndex
    var success = true

    //
    // NOTE: A prev space is nil only where the sid is first, so the branches that move past it bind it.
    //
    if actingSidIsFirst && !selectorSidIsFirst && follows(selectorMCI, actingMCI) {
      success = ScriptingAddition.shared.moveSpace(
        actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
    } else if !actingSidIsFirst && selectorSidIsFirst && follows(actingMCI, selectorMCI) {
      success = ScriptingAddition.shared.moveSpace(
        selectorSid, after: actingSid, focus: selectorSid == SpaceID.active)
    } else if actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
      success = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: false)
      let second = ScriptingAddition.shared.moveSpace(
        actingSid, after: selectorPrevSid, focus: actingSid == SpaceID.active)
      success = success && second
    } else if !actingSidIsFirst && selectorSidIsFirst, let actingPrevSid {
      success = ScriptingAddition.shared.moveSpace(
        actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
      let second = ScriptingAddition.shared.moveSpace(
        selectorSid, after: actingPrevSid, focus: false)
      success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst, let actingPrevSid, let selectorPrevSid {
      if isAfter(actingMCI, selectorMCI) {
        success = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: false)
        let second = ScriptingAddition.shared.moveSpace(
          actingSid, after: selectorPrevSid, focus: actingSid == SpaceID.active)
        success = success && second
      } else {
        success = ScriptingAddition.shared.moveSpace(
          actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
        let second = ScriptingAddition.shared.moveSpace(
          selectorSid, after: actingPrevSid, focus: false)
        success = success && second
      }
    }

    if !success { throw .scriptingAdditionFailed }
  }

  func moveSpace(_ actingSid: SpaceID, to selectorSid: SpaceID) throws(SpaceOperationError) {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }

    let actingDid = actingSid.display
    let selectorDid = selectorSid.display

    if actingSid == selectorSid { throw .sameSpace }
    if actingDid != selectorDid { throw .sameDisplay }

    let actingPrevSid = actingSid.previous
    let selectorPrevSid = selectorSid.previous

    let actingPrevDid = actingPrevSid.flatMap { $0.display }
    let selectorPrevDid = selectorPrevSid.flatMap { $0.display }

    let actingSidIsFirst = actingPrevSid == nil || actingPrevDid != actingDid
    let selectorSidIsFirst = selectorPrevSid == nil || selectorPrevDid != selectorDid
    var success = true

    if actingSidIsFirst && !selectorSidIsFirst {
      success = ScriptingAddition.shared.moveSpace(
        actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
    } else if !actingSidIsFirst && selectorSidIsFirst {
      success = ScriptingAddition.shared.moveSpace(
        actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
      let second = ScriptingAddition.shared.moveSpace(selectorSid, after: actingSid, focus: false)
      success = success && second
    } else if !actingSidIsFirst && !selectorSidIsFirst, let selectorPrevSid {
      if isAfter(actingSid.missionControlIndex, selectorSid.missionControlIndex) {
        success = ScriptingAddition.shared.moveSpace(
          actingSid, after: selectorPrevSid, focus: actingSid == SpaceID.active)
      } else {
        success = ScriptingAddition.shared.moveSpace(
          actingSid, after: selectorSid, focus: actingSid == SpaceID.active)
      }
    }

    if !success { throw .scriptingAdditionFailed }
  }

  //
  // NOTE: Like sway's `move workspace to output`, a move the user asked for (`focusing`, `space --display`) focuses the
  // moved space on its new display: its focus-inactive window, or the display itself when the space is empty
  // (`DisplayID.focus(space:)`, which moves the cursor as `mouse_follows_focus` says). The window server reports the move
  // after the scripting addition has answered, so the focus waits for it (`resolvePendingSpaceMove`). The moves of the
  // space pins and of `space_layout` keep the focus where it is.
  //

  /// Moves a space to another display. With `focusing`, the space gets focus once the window server reports the move.
  func moveSpace(_ sid: SpaceID?, toDisplay did: DisplayID, focusing: Bool = false)
    throws(SpaceOperationError)
  {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }
    guard let sid else { throw .missingSource }

    let sDid = sid.display
    if sDid == did { throw .invalidDestination }

    if sid.isLastUserSpace { throw .invalidSource }

    guard let dSid = did.currentSpace else { throw .missingDestination }

    let isActive = sid == SpaceID.active

    //
    // NOTE: A visible space must be replaced on its display before the move, even when it is
    // not focused. Otherwise the WindowServer keeps it shown on the destination display next
    // to that display's current space, and its menubar stays on screen above the real one.
    //

    guard let spaceList = sDid.flatMap({ $0.spaces }) else { throw .missingSource }

    let user = spaceList.map { $0.isUser }
    let visibleSid = sDid.flatMap { $0.currentSpace }
    let replacementSid = visibleSid.flatMap {
      SpaceList.moveReplacement(spaces: spaceList, user: user, sid: sid, visible: $0)
    }

    //
    // NOTE: The scripting addition takes a plain space id, and it packs nil as 0, "no replacement space".
    //
    if ScriptingAddition.shared.moveSpace(
      sid, toDisplayOf: dSid, previous: replacementSid, focus: isActive)
    {
      markViewInvalid(for: sid)
      if focusing {
        setPendingSpaceFocus(sid, on: did, at: OSTimer.now)
        EventLoop.post(
          .spaceMoveFocusCheck, after: Self.pendingSpaceMoveInterval, key: .spaceMoveFocusCheck)
      } else if isActive {
        try? focusSpace(sid)
      }
      return
    }

    throw .scriptingAdditionFailed
  }

  /// Switches spaces with the gestures of the Dock, without its animation.
  @discardableResult
  func focusSpaceUsingGesture(_ newSid: SpaceID, on newDid: DisplayID) -> Bool {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    guard let curIndex = newDid.currentSpace.flatMap({ $0.missionControlIndex }),
      let newIndex = newSid.missionControlIndex
    else { return false }

    let count = abs(newIndex - curIndex)
    if count == 0 {
      newDid.focus(space: newSid)
      return true
    }

    let point = newDid.center
    let curDid = DisplayID.underCursor

    let focusDisplay = curDid != newDid
    if focusDisplay { CGWarpMouseCursorPosition(point) }

    //
    // NOTE(asmvik): MacOS does not have an API that allows for space activation.
    // However, we can synthesize a sequence of high velocity gestures to skip the
    // animation instead.
    //
    // :Attribution
    // https://github.com/jurplel/InstantSpaceSwitcher
    // https://github.com/thenickdude/wacom-driver-fix/blob/bdfda9a788934c88d09d31ea6a42664b9ba1471e/Readme.md
    // Technique first observed in practice, and reverse-engineered from, BetterTouchTool.
    //

    guard let eventDockControl = CGEvent(source: nil) else { return false }

    let sign: Double = (newIndex - curIndex) > 0 ? 1.0 : -1.0
    eventDockControl.setIntegerValueField(DockSwipe.typeField, value: Int64(DockSwipe.eventType))
    eventDockControl.setIntegerValueField(DockSwipe.hidTypeField, value: DockSwipe.hidType)
    eventDockControl.setIntegerValueField(DockSwipe.motionField, value: DockSwipe.motionHorizontal)
    eventDockControl.setDoubleValueField(DockSwipe.progressField, value: sign)
    eventDockControl.setDoubleValueField(DockSwipe.velocityXField, value: sign * 9999.0)

    for _ in 0..<count {
      eventDockControl.setIntegerValueField(DockSwipe.phaseField, value: DockSwipe.phaseBegan)
      eventDockControl.post(tap: .cgSessionEventTap)
      eventDockControl.setIntegerValueField(DockSwipe.phaseField, value: DockSwipe.phaseEnded)
      eventDockControl.post(tap: .cgSessionEventTap)
    }

    if focusDisplay {
      newDid.activate()
      if SpaceID.active != newSid {
        postFocusClick(at: point)
      }
    }

    return true
  }

  //
  // NOTE: On a switch within one display, macOS activates no window of the new space when yabai never focused one
  // there: the previous application (often Finder) stays frontmost. Like sway's `workspace N`, which focuses the
  // focus-inactive window of N, `space --focus` (`focusingWindow`) focuses `WindowManager.displayFocusTarget(on:from:)`
  // of the space. The switch is asynchronous, and a window focused before macOS has finished it can lose to the
  // activation of the switch, so the focus waits for the space change event (`resolvePendingSpaceFocus`). A switch to
  // another display focuses its window at once through `DisplayID.focus(space:)`, as before, and records nothing.
  //

  /// Focuses a space. With `focusingWindow`, a space on the same display also gets its focus-inactive window focused
  /// once the switch is reported.
  func focusSpace(_ sid: SpaceID, focusingWindow: Bool = false) throws(SpaceOperationError) {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }

    let curSid = SpaceID.active
    if curSid == sid { throw .sameSpace }

    let curDid = curSid.flatMap { $0.display }
    let newDid = sid.display
    let focusDisplay = curDid != newDid

    pendingSpaceFocus = nil

    if ScriptingAddition.shared.focusSpace(sid) {
      if focusDisplay, let newDid {
        newDid.focus(space: sid)
      } else if focusingWindow {
        setPendingSpaceFocus(sid, at: OSTimer.now)
      }
    } else if let newDid {
      if focusSpaceUsingGesture(sid, on: newDid), !focusDisplay, focusingWindow {
        setPendingSpaceFocus(sid, at: OSTimer.now)
      }
    }
  }

  /// How long a pending space focus waits for its space change event, in milliseconds.
  static let pendingSpaceFocusTimeoutMs: Float = 2000.0

  /// How often a pending space move focus asks the window server whether the move is done.
  static let pendingSpaceMoveInterval: Duration = .milliseconds(25)

  /// Records a space to focus: after a switch on its display, or with `display`, after a move to that display.
  func setPendingSpaceFocus(_ sid: SpaceID, on display: DisplayID? = nil, at time: UInt64) {
    pendingSpaceFocus = PendingSpaceFocus(sid: sid, time: time, display: display)
  }

  //
  // NOTE: The gesture fallback can report the spaces it passes on the way, so a change to another space keeps the
  // pending focus. It is dropped once its space is reached, or when it has expired: strictly less than
  // `pendingSpaceFocusTimeoutMs` since the request keeps it, as for `FocusState.consumePending(now:)`.
  //

  /// The space whose window gets focus after a change to `active` at `now`, or nil. Drops the pending space focus when
  /// it is returned or has expired.
  func consumePendingSpaceFocus(active: SpaceID?, now: UInt64) -> SpaceID? {
    guard let pending = pendingSpaceFocus else { return nil }

    if OSTimer.milliseconds(from: pending.time, to: now) >= Self.pendingSpaceFocusTimeoutMs {
      pendingSpaceFocus = nil
      return nil
    }

    guard pending.display == nil, active == pending.sid else { return nil }
    pendingSpaceFocus = nil
    return pending.sid
  }

  /// Focuses the focus-inactive window of the space a `space --focus` switched to, once the switch is reported. An
  /// empty space focuses nothing, and the cursor stays: the display did not change.
  func resolvePendingSpaceFocus() {
    guard let sid = consumePendingSpaceFocus(active: currentSpaceID, now: OSTimer.now) else {
      return
    }
    if MissionControl.shared.isActive { return }

    let wm = WindowManager.shared
    if let target = wm.displayFocusTarget(on: sid, from: nil) {
      wm.focusWindow(id: target.id)
    }
  }

  /// What a pending space move focus does after a check (`consumePendingSpaceMove`).
  enum PendingSpaceMoveStep: Equatable {
    /// Nothing is pending for a move, or it expired.
    case none
    /// The move is not reported yet: check again.
    case wait
    /// The space is on its new display and shown there: focus it there.
    case focus(SpaceID, on: DisplayID)
    /// The space is on its new display but hidden: switch to it.
    case show(SpaceID, on: DisplayID)
  }

  //
  // NOTE: A move of the active space asks the scripting addition to show the space on its new display; any other move
  // leaves it hidden there, after the visible space, so that one is switched to (`show`). Like the pending focus of a
  // switch, the request is dropped once it is used, or when `pendingSpaceFocusTimeoutMs` has passed.
  //

  /// The step of a pending space move focus, given the display the window server has for its space (`display`) and
  /// the space shown on its new display (`current`), at `now`. Drops the pending focus unless the step is `wait`.
  func consumePendingSpaceMove(display: DisplayID?, current: SpaceID?, now: UInt64)
    -> PendingSpaceMoveStep
  {
    guard let pending = pendingSpaceFocus, let did = pending.display else { return .none }

    if OSTimer.milliseconds(from: pending.time, to: now) >= Self.pendingSpaceFocusTimeoutMs {
      pendingSpaceFocus = nil
      return .none
    }

    guard display == did else { return .wait }
    pendingSpaceFocus = nil
    return current == pending.sid ? .focus(pending.sid, on: did) : .show(pending.sid, on: did)
  }

  /// Focuses the space a `space --display` moved, once the window server has it on its new display; until then it
  /// checks again on the event loop.
  func resolvePendingSpaceMove() {
    guard let pending = pendingSpaceFocus, let did = pending.display else { return }
    DisplayManager.shared.invalidateSpaceCaches()

    let step = consumePendingSpaceMove(
      display: pending.sid.display, current: did.currentSpace, now: OSTimer.now)
    if case .wait = step {
      EventLoop.post(
        .spaceMoveFocusCheck, after: Self.pendingSpaceMoveInterval, key: .spaceMoveFocusCheck)
      return
    }
    if MissionControl.shared.isActive { return }

    switch step {
    case .focus(let sid, let did):
      did.focus(space: sid)
    case .show(let sid, let did):
      do {
        try focusSpace(sid, focusingWindow: true)
      } catch .sameSpace {
        did.focus(space: sid)
      } catch {
        Logger.events.debug(
          "space move focus: could not focus \(Int64(bitPattern: sid.rawValue)): \(error)")
      }
    case .none, .wait:
      break
    }
  }

  func switchSpace(to sid: SpaceID) throws(SpaceOperationError) {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }

    guard let curSid = SpaceID.active else { throw .missingSource }
    if curSid == sid { throw .sameSpace }

    let curDid = curSid.display
    let did = sid.display

    if curDid != did {
      swapSpaceAcrossDisplays(curSid, with: sid)
      if let curDid { curDid.focus(space: curSid) }
      return
    }

    if !ScriptingAddition.shared.focusSpace(sid) { throw .scriptingAdditionFailed }
  }

  func destroySpace(_ sid: SpaceID?) throws(SpaceOperationError) {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }

    guard let sid else { throw .missingSource }
    if !sid.isUser { throw .invalidType }
    if sid.isLastUserSpace { throw .invalidSource }

    let did = sid.display
    let firstSid = did?.spaces?.first(where: { $0.isUser })

    if !ScriptingAddition.shared.destroySpace(sid) { throw .scriptingAdditionFailed }

    if let firstSid {
      WindowManager.shared.validateAndCheckForWindows(on: firstSid)
    }
  }

  /// Creates a space on the display of sid.
  func addSpace(onDisplayOf sid: SpaceID?) throws(SpaceOperationError) {
    defer { DisplayManager.shared.invalidateSpaceCaches() }
    if MissionControl.shared.isActive { throw .inMissionControl }
    guard let sid else { throw .missingSource }

    if !ScriptingAddition.shared.createSpace(sid) { throw .scriptingAdditionFailed }
  }
}

/// Whether `next` is the Mission Control index right after `previous`; false when either index is unknown.
private func follows(_ next: Int?, _ previous: Int?) -> Bool {
  guard let next, let previous else { return false }
  return next - previous == 1
}

/// Whether an index is after another. An unknown index sorts before every known one.
private func isAfter(_ index: Int?, _ other: Int?) -> Bool {
  switch (index, other) {
  case (let index?, let other?): return index > other
  case (_?, nil): return true
  case (nil, _): return false
  }
}
