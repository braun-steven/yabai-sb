import AppKit
import CPrivate
import CoreGraphics
import Foundation
import Logging
import YabaiCore

//
// NOTE: The handlers of system events: Mission Control, the Dock, menus, the menu bar, waking from sleep,
// space_layout passes, and messages from clients.
//

extension EventHandler {
  /// Sets the Mission Control mode and pushes the signal of entering it.
  private func missionControlShow(_ mode: MissionControlMode) {
    MissionControl.shared.mode = mode
    Border.setHiddenForMissionControl(true)
    EventSignals.shared.push(.missionControlEnter, .missionControl(mode))
  }

  func missionControlShowAllWindows() {
    Logger.events.debug("mission control show all windows")
    missionControlShow(.showAllWindows)
  }

  func missionControlShowFrontWindows() {
    Logger.events.debug("mission control show front windows")
    missionControlShow(.showFrontWindows)
  }

  func missionControlShowDesktop() {
    Logger.events.debug("mission control show desktop")
    missionControlShow(.showDesktop)
  }

  //
  // NOTE: The front change notification of the window server posts missionControlEnter when the Mission Control
  // overlay is on screen (MissionControl.overlayIsShown). It also comes for app switches inside Mission Control, so
  // an enter during a session only arms the check again. Nothing reports the exit on macOS 27 (the AX exit no longer
  // comes), so the check polls the overlay every 100 ms until it is gone. It is keyed (one pending at a time), and
  // missionControlExit cancels it.
  //

  func missionControlEnter() {
    let entered = !MissionControl.shared.isActive
    if entered {
      Logger.events.debug("mission control enter")
      MissionControl.shared.mode = .show
    }
    Border.setHiddenForMissionControl(true)

    EventLoop.post(
      .missionControlCheckForExit, after: .milliseconds(100), key: .missionControlCheck)

    if entered { EventSignals.shared.push(.missionControlEnter, .missionControl(.show)) }
  }

  func missionControlCheckForExit() {
    if !MissionControl.shared.isActive { return }

    if MissionControl.overlayIsShown() {
      EventLoop.post(
        .missionControlCheckForExit, after: .milliseconds(100), key: .missionControlCheck)
    } else {
      EventLoop.post(.missionControlExit)
    }
  }

  //
  // NOTE: The exit cancels the fallback check, pending or in flight, so the check cannot end a session after the AX
  // exit. An exit without an active session still restores the menu bar alpha and pushes the mission_control_exit
  // signal with mode inactive, as before.
  //

  func missionControlExit() {
    EventLoop.cancel(key: .missionControlCheck)
    DisplayManager.shared.invalidateSpaceCaches()

    Logger.events.debug("mission control exit")

    let wm = WindowManager.shared
    let sm = SpaceManager.shared
    if Config.current.menuBar.opacity != 1.0 {
      let isFullscreen = sm.currentSpaceID.map { $0.isFullscreen } ?? false
      let alpha: Float = isFullscreen ? 1.0 : Config.current.menuBar.opacity
      SLS.setMenuBarAlpha(SLS.connection, alpha)
    }

    if MissionControl.shared.mode == .show || MissionControl.shared.mode == .showAllWindows {
      wm.correctForMissionControlChanges()
    }
    Border.setHiddenForMissionControl(false)

    EventSignals.shared.push(.missionControlExit, .missionControl(MissionControl.shared.mode))
    MissionControl.shared.mode = .inactive
  }

  func dockDidRestart() {
    Logger.events.debug("dock did restart")

    ScriptingAddition.shared.payloadChanged()

    MissionControl.shared.unobserve()
    MissionControl.shared.observe()

    EventSignals.shared.push(.dockDidRestart)
  }

  func menuOpened() {
    Logger.events.debug("menu opened")
    openMenuCount += 1
  }

  func menuClosed() {
    Logger.events.debug("menu closed")
    openMenuCount -= 1

    if openMenuCount < 0 {
      openMenuCount = 0
    }
  }

  func menuBarHiddenChanged() {
    Logger.events.debug("menu bar hidden changed")
    SpaceManager.shared.markSpacesInvalid()
    EventSignals.shared.push(.menuBarHiddenChanged)
  }

  func dockDidChangePref() {
    Logger.events.debug("dock preferences changed")
    SpaceManager.shared.markSpacesInvalid()
    EventSignals.shared.push(.dockDidChangePref)
  }

  func systemWoke() {
    Logger.events.debug("system woke")

    let wm = WindowManager.shared
    if let focusedWindowID = wm.focus.focused, let focusedWindow = wm.window(for: focusedWindowID) {
      wm.setWindowOpacity(focusedWindow, to: Config.current.windowOpacity.active)
      wm.centerMouse(on: focusedWindow)
    }

    SpaceManager.shared.scheduleSpaceLayout(after: .seconds(1), resetPasses: true)
    EventSignals.shared.push(.systemWoke)
  }

  func configChanged(_ group: ConfigGroup) {
    Logger.events.debug("config changed")
    ConfigObserver.shared.apply(group)
  }

  func spaceLayoutReconcile() {
    let sm = SpaceManager.shared

    if Config.current.space.spaceLayouts.isEmpty { return }

    if MissionControl.shared.isActive {
      sm.scheduleSpaceLayout(after: .milliseconds(500), resetPasses: false)
      return
    }

    sm.spaceLayoutPasses += 1
    if sm.spaceLayoutPasses > 40 {
      Logger.spaces.notice("giving up on the space layout: it did not converge")
      return
    }

    let result = sm.reconcileSpaceLayout()
    switch result {
    case .performed: sm.scheduleSpaceLayout(after: .milliseconds(500), resetPasses: false)
    case .failed: sm.scheduleSpaceLayout(after: .seconds(1), resetPasses: false)
    case .done: sm.spaceLayoutPasses = 0
    }
  }

  //
  // NOTE: One pinned space moves per pass. A move re-posts the space layout pass, so the counts of the displays are
  // fixed with the spaces that the layout may move (SpacePinning.pinnedSpaces keeps the pinned ones).
  //

  func spacePinReconcile() {
    let sm = SpaceManager.shared

    if sm.pins.isEmpty {
      sm.spacePinPasses = 0
      return
    }

    if MissionControl.shared.isActive {
      sm.schedulePinReconcile(after: .milliseconds(500), resetPasses: false)
      return
    }

    sm.spacePinPasses += 1
    if sm.spacePinPasses > 40 {
      Logger.spaces.notice("giving up on the space pins: they did not converge")
      return
    }

    switch sm.reconcileSpacePins() {
    case .performed:
      sm.schedulePinReconcile(after: .milliseconds(500), resetPasses: false)
      sm.scheduleSpaceLayout(after: .milliseconds(500), resetPasses: false)
    case .failed: sm.schedulePinReconcile(after: .seconds(1), resetPasses: false)
    case .done: sm.spacePinPasses = 0
    }
  }
}
