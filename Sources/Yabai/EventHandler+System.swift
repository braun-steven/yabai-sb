import CoreGraphics
import Foundation
import AppKit
import CPrivate
import Logging
import YabaiCore

//
// NOTE: The handlers of system events: Mission Control, the Dock, menus, the menu bar, waking from sleep,
// space_layout passes, and messages from clients.
//

extension EventHandler
{
    /// Sets the Mission Control mode and pushes the signal of entering it.
    private func missionControlShow(_ mode: MissionControlMode)
    {
        MissionControl.shared.mode = mode
        EventSignals.shared.push(.missionControlEnter, .missionControl(mode))
    }

    func missionControlShowAllWindows()
    {
        Logger.events.debug("mission control show all windows")
        missionControlShow(.showAllWindows)
    }

    func missionControlShowFrontWindows()
    {
        Logger.events.debug("mission control show front windows")
        missionControlShow(.showFrontWindows)
    }

    func missionControlShowDesktop()
    {
        Logger.events.debug("mission control show desktop")
        missionControlShow(.showDesktop)
    }

    //
    // NOTE: The fallback check for the exit. The AX notification AXExposeExit is the primary exit signal; the check
    // only covers an exit that AX does not report. Nothing posts missionControlEnter now (the window server's enter
    // notification is no longer registered), so no check is armed; the AX exit ends the session. The check runs every
    // 500 ms, is keyed (one pending at a time), and missionControlExit cancels it.
    //

    func missionControlEnter()
    {
        Logger.events.debug("mission control enter")
        MissionControl.shared.mode = .show

        EventLoop.post(.missionControlCheckForExit, after: .milliseconds(500), key: .missionControlCheck)

        EventSignals.shared.push(.missionControlEnter, .missionControl(.show))
    }

    func missionControlCheckForExit()
    {
        if !MissionControl.shared.isActive { return }

        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var found = false

        for dictionary in windowList {
            if dictionary[kCGWindowName as String] != nil { continue }

            guard let owner = dictionary[kCGWindowOwnerName as String] as? String else { continue }
            guard let layer = dictionary[kCGWindowLayer as String] as? Int else { continue }
            if layer != 18 { continue }

            if owner == "Dock" {
                found = true
                break
            }
        }

        if found {
            EventLoop.post(.missionControlCheckForExit, after: .milliseconds(500), key: .missionControlCheck)
        } else {
            EventLoop.post(.missionControlExit)
        }
    }

    //
    // NOTE: The exit cancels the fallback check, pending or in flight, so the check cannot end a session after the AX
    // exit. An exit without an active session still restores the menu bar alpha and pushes the mission_control_exit
    // signal with mode inactive, as before.
    //

    func missionControlExit()
    {
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

        EventSignals.shared.push(.missionControlExit, .missionControl(MissionControl.shared.mode))
        MissionControl.shared.mode = .inactive
    }

    func dockDidRestart()
    {
        Logger.events.debug("dock did restart")

        ScriptingAddition.shared.payloadChanged()

        MissionControl.shared.unobserve()
        MissionControl.shared.observe()

        EventSignals.shared.push(.dockDidRestart)
    }

    func menuOpened()
    {
        Logger.events.debug("menu opened")
        openMenuCount += 1
    }

    func menuClosed()
    {
        Logger.events.debug("menu closed")
        openMenuCount -= 1

        if openMenuCount < 0 {
            openMenuCount = 0
        }
    }

    func menuBarHiddenChanged()
    {
        Logger.events.debug("menu bar hidden changed")
        SpaceManager.shared.markSpacesInvalid()
        EventSignals.shared.push(.menuBarHiddenChanged)
    }

    func dockDidChangePref()
    {
        Logger.events.debug("dock preferences changed")
        SpaceManager.shared.markSpacesInvalid()
        EventSignals.shared.push(.dockDidChangePref)
    }

    func systemWoke()
    {
        Logger.events.debug("system woke")

        let wm = WindowManager.shared
        if let focusedWindowID = wm.focus.focused, let focusedWindow = wm.window(for: focusedWindowID) {
            wm.setWindowOpacity(focusedWindow, to: Config.current.windowOpacity.active)
            wm.centerMouse(on: focusedWindow)
        }

        SpaceManager.shared.scheduleSpaceLayout(after: .seconds(1), resetPasses: true)
        EventSignals.shared.push(.systemWoke)
    }

    func configChanged(_ group: ConfigGroup)
    {
        Logger.events.debug("config changed")
        ConfigObserver.shared.apply(group)
    }

    func spaceLayoutReconcile()
    {
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
        case .failed:    sm.scheduleSpaceLayout(after: .seconds(1), resetPasses: false)
        case .done:      sm.spaceLayoutPasses = 0
        }
    }
}
