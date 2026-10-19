import CoreGraphics
import Dispatch
import Foundation
import AppKit
import CPrivate

//
// NOTE: The handlers of system events: Mission Control, the Dock, menus, the menu bar, waking from sleep,
// space_layout passes, and messages from clients. Ported from src/event_handlers_system.c.
//

/// Sets the Mission Control mode and pushes the signal of entering it.
@WM private func missionControlShow(_ mode: MissionControlMode)
{
    MissionControl.shared.mode = mode
    eventSignalPush(.missionControlEnter, UnsafeMutableRawPointer(bitPattern: mode.rawValue))
}

/// `EVENT_HANDLER(MISSION_CONTROL_SHOW_ALL_WINDOWS)`
@WM func missionControlShowAllWindows()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_ALL_WINDOWS:\n")
    missionControlShow(.showAllWindows)
}

/// `EVENT_HANDLER(MISSION_CONTROL_SHOW_FRONT_WINDOWS)`
@WM func missionControlShowFrontWindows()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_FRONT_WINDOWS:\n")
    missionControlShow(.showFrontWindows)
}

/// `EVENT_HANDLER(MISSION_CONTROL_SHOW_DESKTOP)`
@WM func missionControlShowDesktop()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_DESKTOP:\n")
    missionControlShow(.showDesktop)
}

/// `EVENT_HANDLER(MISSION_CONTROL_ENTER)`
@WM func missionControlEnter()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_ENTER:\n")
    MissionControl.shared.mode = .show

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
        EventLoop.post(.missionControlCheckForExit)
    }

    eventSignalPush(.missionControlEnter, UnsafeMutableRawPointer(bitPattern: MissionControlMode.show.rawValue))
}

/// `EVENT_HANDLER(MISSION_CONTROL_CHECK_FOR_EXIT)`
@WM func missionControlCheckForExit()
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

/// `EVENT_HANDLER(MISSION_CONTROL_EXIT)`
@WM func missionControlExit()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_EXIT:\n")

    let wm = WindowManager.shared
    let sm = space_manager_global()
    if wm.menuBarOpacity != 1.0 {
        let isFullscreen = sm.current_space_id.map { space_is_fullscreen($0) } ?? false
        let alpha: Float = isFullscreen ? 1.0 : wm.menuBarOpacity
        SLSSetMenuBarInsetAndAlpha(connection_global(), 0, 1, alpha)
    }

    if MissionControl.shared.mode == .show || MissionControl.shared.mode == .showAllWindows {
        wm.correctForMissionControlChanges()
    }

    eventSignalPush(.missionControlExit, UnsafeMutableRawPointer(bitPattern: MissionControl.shared.mode.rawValue))
    MissionControl.shared.mode = .inactive
}

/// `EVENT_HANDLER(DOCK_DID_RESTART)`
@WM func dockDidRestart()
{
    debug("EVENT_HANDLER_DOCK_DID_RESTART:\n")

    scripting_addition_payload_changed()

    MissionControl.shared.unobserve()
    MissionControl.shared.observe()

    eventSignalPush(.dockDidRestart, nil)
}

/// The focus follows mouse mode while a menu is open, and the number of open menus.
@WM private var ffmValue = FocusFollowsMouse.disabled
@WM private var isMenuOpen = 0

/// `EVENT_HANDLER(MENU_OPENED)`
@WM func menuOpened()
{
    debug("EVENT_HANDLER_MENU_OPENED\n")
    isMenuOpen += 1

    if isMenuOpen == 1 {
        let wm = WindowManager.shared
        ffmValue = wm.focusFollowsMouseMode
        wm.focusFollowsMouseMode = .disabled
    }
}

/// `EVENT_HANDLER(MENU_CLOSED)`
@WM func menuClosed()
{
    debug("EVENT_HANDLER_MENU_CLOSED\n")
    isMenuOpen -= 1

    if isMenuOpen == 0 {
        WindowManager.shared.focusFollowsMouseMode = ffmValue
    } else if isMenuOpen < 0 {
        isMenuOpen = 0
    }
}

/// `EVENT_HANDLER(MENU_BAR_HIDDEN_CHANGED)`
@WM func menuBarHiddenChanged()
{
    debug("EVENT_HANDLER_MENU_BAR_HIDDEN_CHANGED:\n")
    space_manager_mark_spaces_invalid(space_manager_global())
    eventSignalPush(.menuBarHiddenChanged, nil)
}

/// `EVENT_HANDLER(DOCK_DID_CHANGE_PREF)`
@WM func dockDidChangePref()
{
    debug("EVENT_HANDLER_DOCK_DID_CHANGE_PREF:\n")
    space_manager_mark_spaces_invalid(space_manager_global())
    eventSignalPush(.dockDidChangePref, nil)
}

/// `EVENT_HANDLER(SYSTEM_WOKE)`
@WM func systemWoke()
{
    debug("EVENT_HANDLER_SYSTEM_WOKE:\n")

    let wm = WindowManager.shared
    if let focusedWindowID = wm.focusedWindowID, let focusedWindow = wm.window(for: focusedWindowID) {
        wm.setWindowOpacity(focusedWindow, to: wm.activeWindowOpacity)
        wm.centerMouse(on: focusedWindow)
    }

    space_layout_schedule(1.0, true)
    eventSignalPush(.systemWoke, nil)
}

/// `EVENT_HANDLER(SPACE_LAYOUT_RECONCILE)`
@WM func spaceLayoutReconcile(_ generation: UInt32)
{
    let sm = space_manager_global()

    if generation != sm.space_layout_gen { return }
    if sm.space_layouts.isEmpty { return }

    if MissionControl.shared.isActive {
        space_layout_schedule(0.5, false)
        return
    }

    sm.space_layout_passes += 1
    if sm.space_layout_passes > 40 {
        debug("EVENT_HANDLER_SPACE_LAYOUT_RECONCILE: giving up, layout did not converge\n")
        return
    }

    let result = space_layout_reconcile(sm)
    switch result {
    case .performed: space_layout_schedule(0.5, false)
    case .failed:    space_layout_schedule(1.0, false)
    case .done:      sm.space_layout_passes = 0
    }
}
