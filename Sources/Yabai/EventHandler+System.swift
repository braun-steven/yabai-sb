import CoreGraphics
import Dispatch
import Foundation
import AppKit
import CPrivate

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
        debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_ALL_WINDOWS:\n")
        missionControlShow(.showAllWindows)
    }

    func missionControlShowFrontWindows()
    {
        debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_FRONT_WINDOWS:\n")
        missionControlShow(.showFrontWindows)
    }

    func missionControlShowDesktop()
    {
        debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_DESKTOP:\n")
        missionControlShow(.showDesktop)
    }

    func missionControlEnter()
    {
        debug("EVENT_HANDLER_MISSION_CONTROL_ENTER:\n")
        MissionControl.shared.mode = .show

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            EventLoop.post(.missionControlCheckForExit)
        }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                EventLoop.post(.missionControlCheckForExit)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                EventLoop.post(.missionControlExit)
            }
        }
    }

    func missionControlExit()
    {
        debug("EVENT_HANDLER_MISSION_CONTROL_EXIT:\n")

        let wm = WindowManager.shared
        let sm = SpaceManager.shared
        if wm.menuBarOpacity != 1.0 {
            let isFullscreen = sm.currentSpaceID.map { $0.isFullscreen } ?? false
            let alpha: Float = isFullscreen ? 1.0 : wm.menuBarOpacity
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
        debug("EVENT_HANDLER_DOCK_DID_RESTART:\n")

        ScriptingAddition.shared.payloadChanged()

        MissionControl.shared.unobserve()
        MissionControl.shared.observe()

        EventSignals.shared.push(.dockDidRestart)
    }

    func menuOpened()
    {
        debug("EVENT_HANDLER_MENU_OPENED\n")
        openMenuCount += 1

        if openMenuCount == 1 {
            let wm = WindowManager.shared
            focusFollowsMouseBeforeMenu = wm.focusFollowsMouseMode
            wm.focusFollowsMouseMode = .disabled
        }
    }

    func menuClosed()
    {
        debug("EVENT_HANDLER_MENU_CLOSED\n")
        openMenuCount -= 1

        if openMenuCount == 0 {
            WindowManager.shared.focusFollowsMouseMode = focusFollowsMouseBeforeMenu
        } else if openMenuCount < 0 {
            openMenuCount = 0
        }
    }

    func menuBarHiddenChanged()
    {
        debug("EVENT_HANDLER_MENU_BAR_HIDDEN_CHANGED:\n")
        SpaceManager.shared.markSpacesInvalid()
        EventSignals.shared.push(.menuBarHiddenChanged)
    }

    func dockDidChangePref()
    {
        debug("EVENT_HANDLER_DOCK_DID_CHANGE_PREF:\n")
        SpaceManager.shared.markSpacesInvalid()
        EventSignals.shared.push(.dockDidChangePref)
    }

    func systemWoke()
    {
        debug("EVENT_HANDLER_SYSTEM_WOKE:\n")

        let wm = WindowManager.shared
        if let focusedWindowID = wm.focusedWindowID, let focusedWindow = wm.window(for: focusedWindowID) {
            wm.setWindowOpacity(focusedWindow, to: wm.activeWindowOpacity)
            wm.centerMouse(on: focusedWindow)
        }

        SpaceManager.shared.scheduleSpaceLayout(after: 1.0, resetPasses: true)
        EventSignals.shared.push(.systemWoke)
    }

    func spaceLayoutReconcile(_ generation: UInt32)
    {
        let sm = SpaceManager.shared

        if generation != sm.spaceLayoutGeneration { return }
        if sm.spaceLayouts.isEmpty { return }

        if MissionControl.shared.isActive {
            sm.scheduleSpaceLayout(after: 0.5, resetPasses: false)
            return
        }

        sm.spaceLayoutPasses += 1
        if sm.spaceLayoutPasses > 40 {
            debug("EVENT_HANDLER_SPACE_LAYOUT_RECONCILE: giving up, layout did not converge\n")
            return
        }

        let result = sm.reconcileSpaceLayout()
        switch result {
        case .performed: sm.scheduleSpaceLayout(after: 0.5, resetPasses: false)
        case .failed:    sm.scheduleSpaceLayout(after: 1.0, resetPasses: false)
        case .done:      sm.spaceLayoutPasses = 0
        }
    }
}
