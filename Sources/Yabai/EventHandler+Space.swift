import AppKit
import CPrivate
import CoreGraphics
import Logging
import SortedCollections
import YabaiCore

//
// NOTE: The handlers of space and display events: spaces created, destroyed and changed, and displays
// added, removed, moved and resized.
//

extension EventHandler {
  func slsSpaceCreated(_ sid: SpaceID) {
    DisplayManager.shared.invalidateSpaceCaches()
    let type = SLS.spaceType(SLS.connection, sid)

    if type == 0 || type == 4 {
      Logger.events.debug("space created: \(Int64(bitPattern: sid.rawValue)), \(type)")
      SpaceManager.shared.view(for: sid)
      EventSignals.shared.push(.spaceCreated(sid))
      SpaceManager.shared.scheduleSpaceLayout(after: .seconds(1), resetPasses: false)
    }
  }

  func slsSpaceDestroyed(_ sid: SpaceID) {
    DisplayManager.shared.invalidateSpaceCaches()
    let sm = SpaceManager.shared

    if let view = sm.views[sid] {
      Logger.events.debug("space destroyed: \(Int64(bitPattern: sid.rawValue))")
      _ = sm.labels.remove(id: sid)
      sm.views[sid] = nil
      view.destroy()
      EventSignals.shared.push(.spaceDestroyed(sid))
      sm.scheduleSpaceLayout(after: .seconds(1), resetPasses: false)
    }
  }

  //
  // NOTE: Brings the windows of the applications and the layout of the current space up to
  // date after the active space or display changed.
  //

  private func refreshCurrentSpace() {
    let wm = WindowManager.shared
    let sm = SpaceManager.shared

    let view = sm.currentSpaceID.map { sm.view(for: $0) }

    if sm.refreshApplicationWindows() {
      if let focusedWindow = wm.focusedWindow, wm.focus.hasLostFocusedEvent(for: focusedWindow.id) {
        windowDidReceiveFocus(focusedWindow)
        wm.focus.removeLostFocusedEvent(for: focusedWindow.id)
      }
    }

    if !MissionControl.shared.isActive, let sid = sm.currentSpaceID, sid.isUser {
      wm.validateAndCheckForWindows(on: sid)

      if let view, view.needsUpdate {
        view.update()
      }

      if let view, view.isDirty {
        view.flush()
      }
    }
  }

  func spaceChanged() {
    DisplayManager.shared.invalidateSpaceCaches()
    let sm = SpaceManager.shared

    sm.lastSpaceID = sm.currentSpaceID
    sm.currentSpaceID = SpaceID.active

    Logger.events.debug("space changed: \(Int64(bitPattern: sm.currentSpaceID?.rawValue ?? 0))")
    refreshCurrentSpace()
    sm.refreshDisplaySpaces(includingHidden: false)
    sm.resolvePendingSpaceFocus()
    sm.spaceMoveChangeReported()

    EventSignals.shared.push(.spaceChanged)
  }

  /// Checks whether a space moved by `space --display` has arrived on its display, and focuses it then.
  func spaceMoveFocusCheck() {
    SpaceManager.shared.resolvePendingSpaceMove()
  }

  /// Checks whether the spaces moved by `SpaceManager.moveSpace(_:toDisplay:)` have arrived on their displays, and
  /// refreshes the spaces then.
  func spaceMoveRefreshCheck() {
    SpaceManager.shared.resolveSpaceMoveRefresh()
  }

  /// The refresh pass of the spaces of every display after a display change, hidden ones included.
  func displaySpacesRefresh() {
    DisplayManager.shared.invalidateSpaceCaches()
    SpaceManager.shared.refreshDisplaySpaces(includingHidden: true)
  }

  func displayChanged() {
    DisplayManager.shared.invalidateSpaceCaches()
    let dm = DisplayManager.shared
    let sm = SpaceManager.shared
    // NOTE: Also after an event that is ignored below: it can be the change of a moved active space.
    defer { sm.spaceMoveChangeReported() }

    let newDid = DisplayID.active
    if dm.currentDisplayID == newDid {
      Logger.events.debug(
        "display changed: newly activated display \(dm.currentDisplayID?.rawValue ?? 0) was already active (\(newDid?.rawValue ?? 0)), ignoring event"
      )
      return
    }

    dm.lastDisplayID = dm.currentDisplayID
    dm.currentDisplayID = newDid
    MouseState.shared.ffmDisplayFocus.reset()

    sm.lastSpaceID = sm.currentSpaceID
    sm.currentSpaceID = dm.currentDisplayID.flatMap { $0.currentSpace }

    let expectedDisplayID = sm.currentSpaceID.flatMap { $0.display }
    if dm.currentDisplayID != expectedDisplayID {
      Logger.events.debug(
        "display changed: \(dm.currentDisplayID?.rawValue ?? 0) \(Int64(bitPattern: sm.currentSpaceID?.rawValue ?? 0)) did not match \(expectedDisplayID?.rawValue ?? 0), ignoring event"
      )
      return
    }

    Logger.events.debug(
      "display changed: \(dm.currentDisplayID?.rawValue ?? 0) \(Int64(bitPattern: sm.currentSpaceID?.rawValue ?? 0))"
    )
    refreshCurrentSpace()

    EventSignals.shared.push(.displayChanged)
  }

  func displayAdded(_ did: DisplayID) {
    DisplayManager.shared.invalidateSpaceCaches()
    Logger.events.debug("display added: \(did)")
    SpaceManager.shared.handleDisplayAdd(did)
    WindowManager.shared.handleDisplayAddAndRemove(did)
    SpaceManager.shared.scheduleDisplaySpacesRefresh()
    SpaceManager.shared.scheduleSpaceLayout(after: .seconds(1), resetPasses: true)
    SpaceManager.shared.schedulePinReconcile(after: .seconds(1), resetPasses: true)
    EventSignals.shared.push(.displayAdded(did))
  }

  func displayRemoved(_ did: DisplayID) {
    DisplayManager.shared.invalidateSpaceCaches()
    Logger.events.debug("display removed: \(did)")
    _ = DisplayManager.shared.labels.remove(id: did)
    WindowManager.shared.handleDisplayAddAndRemove(DisplayID.main)
    SpaceManager.shared.scheduleDisplaySpacesRefresh()
    SpaceManager.shared.scheduleSpaceLayout(after: .seconds(1), resetPasses: true)
    SpaceManager.shared.schedulePinReconcile(after: .seconds(1), resetPasses: true)
    EventSignals.shared.push(.displayRemoved(did))
  }

  func displayMoved(_ did: DisplayID) {
    DisplayManager.shared.invalidateSpaceCaches()
    Logger.events.debug("display moved: \(did)")
    SpaceManager.shared.markSpacesInvalid()
    SpaceManager.shared.scheduleDisplaySpacesRefresh()
    SpaceManager.shared.scheduleSpaceLayout(after: .seconds(1), resetPasses: true)
    SpaceManager.shared.schedulePinReconcile(after: .seconds(1), resetPasses: true)
    EventSignals.shared.push(.displayMoved(did))
  }

  func displayResized(_ did: DisplayID) {
    DisplayManager.shared.invalidateSpaceCaches()
    Logger.events.debug("display resized: \(did)")
    SpaceManager.shared.markSpacesInvalid(on: did)
    SpaceManager.shared.scheduleDisplaySpacesRefresh()
    EventSignals.shared.push(.displayResized(did))
  }
}
