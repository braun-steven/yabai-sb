import CoreGraphics
import Dispatch
import Foundation
import YabaiC

//
// NOTE: The handlers of system events: Mission Control, the Dock, menus, the menu bar, waking from sleep,
// space_layout passes, and messages from clients. Ported from src/event_handlers_system.c.
//

/// Sets the Mission Control mode and pushes the signal of entering it.
@WM private func missionControlShow(_ mode: mission_control_mode)
{
    mission_control_mode_global()!.pointee = mode
    eventSignalPush(.missionControlEnter, UnsafeMutableRawPointer(bitPattern: UInt(mode.rawValue)))
}

/// `EVENT_HANDLER(MISSION_CONTROL_SHOW_ALL_WINDOWS)`
@WM func missionControlShowAllWindows()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_ALL_WINDOWS:\n")
    missionControlShow(MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS)
}

/// `EVENT_HANDLER(MISSION_CONTROL_SHOW_FRONT_WINDOWS)`
@WM func missionControlShowFrontWindows()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_FRONT_WINDOWS:\n")
    missionControlShow(MISSION_CONTROL_MODE_SHOW_FRONT_WINDOWS)
}

/// `EVENT_HANDLER(MISSION_CONTROL_SHOW_DESKTOP)`
@WM func missionControlShowDesktop()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_SHOW_DESKTOP:\n")
    missionControlShow(MISSION_CONTROL_MODE_SHOW_DESKTOP)
}

/// `EVENT_HANDLER(MISSION_CONTROL_ENTER)`
@WM func missionControlEnter()
{
    debug("EVENT_HANDLER_MISSION_CONTROL_ENTER:\n")
    mission_control_mode_global()!.pointee = MISSION_CONTROL_MODE_SHOW

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
        EventLoop.post(.missionControlCheckForExit)
    }

    eventSignalPush(.missionControlEnter, UnsafeMutableRawPointer(bitPattern: UInt(MISSION_CONTROL_MODE_SHOW.rawValue)))
}

/// `EVENT_HANDLER(MISSION_CONTROL_CHECK_FOR_EXIT)`
@WM func missionControlCheckForExit()
{
    if !mission_control_is_active() { return }

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

    let wm = window_manager_global()
    let sm = space_manager_global()
    let mode = mission_control_mode_global()!

    if wm.menubar_opacity != 1.0 {
        let alpha: Float = space_is_fullscreen(sm.current_space_id) ? 1.0 : wm.menubar_opacity
        SLSSetMenuBarInsetAndAlpha(connection_global(), 0, 1, alpha)
    }

    if mode.pointee == MISSION_CONTROL_MODE_SHOW || mode.pointee == MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS {
        window_manager_correct_for_mission_control_changes(sm, wm)
    }

    eventSignalPush(.missionControlExit, UnsafeMutableRawPointer(bitPattern: UInt(mode.pointee.rawValue)))
    mode.pointee = MISSION_CONTROL_MODE_INACTIVE
}

/// `EVENT_HANDLER(DOCK_DID_RESTART)`
@WM func dockDidRestart()
{
    debug("EVENT_HANDLER_DOCK_DID_RESTART:\n")

    scripting_addition_payload_changed()

    missionControlUnobserve()
    mission_control_observe()

    eventSignalPush(.dockDidRestart, nil)
}

/// The focus follows mouse mode while a menu is open, and the number of open menus.
@WM private var ffmValue = FFM_DISABLED
@WM private var isMenuOpen = 0

/// `EVENT_HANDLER(MENU_OPENED)`
@WM func menuOpened()
{
    debug("EVENT_HANDLER_MENU_OPENED\n")
    isMenuOpen += 1

    if isMenuOpen == 1 {
        let wm = window_manager_global()
        ffmValue = wm.ffm_mode
        wm.ffm_mode = FFM_DISABLED
    }
}

/// `EVENT_HANDLER(MENU_CLOSED)`
@WM func menuClosed()
{
    debug("EVENT_HANDLER_MENU_CLOSED\n")
    isMenuOpen -= 1

    if isMenuOpen == 0 {
        window_manager_global().ffm_mode = ffmValue
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

    let wm = window_manager_global()
    if let focusedWindow = window_manager_find_window(wm, wm.focused_window_id) {
        window_manager_set_window_opacity(wm, focusedWindow, wm.active_window_opacity)
        window_manager_center_mouse(wm, focusedWindow)
    }

    space_layout_schedule(1.0, true)
    eventSignalPush(.systemWoke, nil)
}

/// `EVENT_HANDLER(SPACE_LAYOUT_RECONCILE)`
@WM func spaceLayoutReconcile(_ generation: Int32)
{
    let sm = space_manager_global()

    if UInt32(bitPattern: generation) != sm.space_layout_gen { return }
    if sm.space_layout_count == 0 { return }

    if mission_control_is_active() {
        space_layout_schedule(0.5, false)
        return
    }

    sm.space_layout_passes += 1
    if sm.space_layout_passes > 40 {
        debug("EVENT_HANDLER_SPACE_LAYOUT_RECONCILE: giving up, layout did not converge\n")
        return
    }

    let result = space_layout_reconcile(sm)
    if result == SPACE_LAYOUT_RESULT_PERFORMED {
        space_layout_schedule(0.5, false)
    } else if result == SPACE_LAYOUT_RESULT_FAILED {
        space_layout_schedule(1.0, false)
    } else {
        sm.space_layout_passes = 0
    }
}
