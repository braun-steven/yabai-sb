import ApplicationServices
import Foundation
import CPrivate
import AppKit

//
// NOTE: Discovering the windows of an application: creating a window applies the rules and decides whether
// it floats. Windows on other spaces are missing from the accessibility list of an application; they are
// resolved later, or found by element id. Ported from src/window_manager_discovery.c.
//

//
// NOTE(asmvik): Print window information when debug_output is enabled.
// Useful for identifying and creating rules if this window should in fact be managed.
//

/// `window_manager_debug_window_info`
private func windowManagerDebugWindowInfo(_ target: Window)
{
    guard g_verbose else { return }

    fputs("window info: \n", stdout_global())
    fputs(windowSerialize(target, 0), stdout_global())
    fputs("\n", stdout_global())
}

/// The elements of an AX window list.
private func axElements(_ list: CFArray) -> [AXUIElement]
{
    return (0..<CFArrayGetCount(list)).map { unsafeBitCast(CFArrayGetValueAtIndex(list, $0), to: AXUIElement.self) }
}

/// `window_manager_create_and_add_window`: nil when the window is ignored (AXUnknown, or it cannot be observed).
@discardableResult
func window_manager_create_and_add_window(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application, _ windowRef: AXUIElement, _ windowID: UInt32, _ oneShotRules: Bool) -> Window?
{
    let target = window_create(owner, windowRef, windowID)

    let windowTitle = window_title_ts(target)
    let windowRole = window_role_ts(target)
    let windowSubrole = window_subrole_ts(target)
    debug("window_manager_create_and_add_window:\(target.id) \(cName(owner.name)) - \(windowTitle) (\(windowRole):\(windowSubrole):\(target.is_root ? 1 : 0))\n")

    if window_is_unknown(target) {
        debug("window_manager_create_and_add_window: ignoring AXUnknown window \(cName(owner.pointee.name)) \(target.pointee.id)\n")
        window_manager_remove_lost_focused_event(wm, target.pointee.id)
        window_destroy(target)
        return nil
    }

    //
    // NOTE(asmvik): Attempt to track **all** windows.
    //

    if !window_observe(target) {
        debug("window_manager_create_and_add_window: could not observe \(cName(owner.pointee.name)) \(target.pointee.id)\n")
        window_manager_remove_lost_focused_event(wm, target.pointee.id)
        window_unobserve(target)
        window_destroy(target)
        return nil
    }

    if window_manager_find_lost_focused_event(wm, target.pointee.id) {
        EventLoop.post(.windowFocused(windowID: target.pointee.id))
        window_manager_remove_lost_focused_event(wm, target.pointee.id)
    }

    window_manager_add_window(wm, target)

    //
    // NOTE(asmvik): However, only **root windows** are eligible for management.
    //

    if target.pointee.is_root {

        //
        // NOTE(asmvik): A lot of windows misreport their accessibility role, so we allow the user
        // to specify rules to make sure that we do in fact manage these windows properly.
        //
        // This part of the rule must be applied at this stage (prior to other rule properties), and if
        // no such rule matches this window, it will be ignored if it does not have a role of kAXWindowRole.
        //

        window_manager_apply_manage_rules_to_window(sm, wm, target, windowTitle, windowRole, windowSubrole, oneShotRules)

        if window_manager_is_window_eligible(target) {
            target.pointee.is_eligible = true
            window_manager_apply_rules_to_window(sm, wm, target, windowTitle, windowRole, windowSubrole, oneShotRules)
            window_manager_purify_window(wm, target)
            window_manager_set_window_opacity(wm, target, wm.normal_window_opacity)

            if owner.pointee.is_hidden                                { return target }
            if window_check_flag(target, WINDOW_MINIMIZE)             { return target }
            if window_check_flag(target, WINDOW_FULLSCREEN)           { return target }
            if window_check_rule_flag(target, WINDOW_RULE_MANAGED)    { return target }

            if window_check_rule_flag(target, WINDOW_RULE_FULLSCREEN) {
                window_clear_rule_flag(target, WINDOW_RULE_FULLSCREEN)
                return target
            }

            if window_is_sticky(target.pointee.id) ||
               !window_can_move(target) ||
               !window_is_standard(target) ||
               !window_level_is_standard(target) ||
               (!window_can_resize(target) && window_is_undersized(target)) {
                window_set_flag(target, WINDOW_FLOAT)
            }
        } else {
            debug("window_manager_create_and_add_window ignoring incorrectly marked window \(cName(owner.pointee.name)) \(target.pointee.id)\n")
            window_set_flag(target, WINDOW_FLOAT)
            windowManagerDebugWindowInfo(target)
        }
    } else {
        debug("window_manager_create_and_add_window ignoring child window \(cName(owner.pointee.name)) \(target.pointee.id)\n")
        window_set_flag(target, WINDOW_FLOAT)
        windowManagerDebugWindowInfo(target)
    }

    return target
}

//
// NOTE: The space a new window is managed on, as selected by window_origin_display.
//

/// `window_manager_origin_space`
func window_manager_origin_space(_ wm: WindowManager, _ target: Window) -> UInt64
{
    switch wm.window_origin_mode {
    case WINDOW_ORIGIN_FOCUSED: return space_manager_global().current_space_id
    case WINDOW_ORIGIN_CURSOR:  return space_manager_cursor_space()
    default:                    return window_space(target.pointee.id)
    }
}

/// `window_manager_add_application_windows`: the windows of the AX list of the application that were not known yet.
func window_manager_add_application_windows(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application) -> [Window]
{
    guard let windowList = application_window_list(owner) else { return [] }

    var result: [Window] = []

    for windowRef in axElements(windowList) {
        let windowID = ax_window_id(windowRef)
        if windowID == 0 || window_manager_find_window(wm, windowID) != nil { continue }

        if let target = window_manager_create_and_add_window(sm, wm, owner, windowRef, windowID, true) { result.append(target) }
    }

    window_manager_remove_one_shot_rules(wm)

    return result
}

/// `window_manager_existing_application_window_list`: the windows of the application (of every application for nil)
/// on the spaces of Mission Control, minimized ones included; nil when there are none or the window server fails.
func windowManagerExistingApplicationWindowList(_ owner: Application?) -> [UInt32]?
{
    guard let spaceList = space_manager_mission_control_space_list() else { return nil }

    var windowCount: Int32 = 0
    return space_window_list_for_connection(spaceList, owner?.connection ?? 0, &windowCount, true)
}

/// `window_manager_unresolved_windows`: the windows of the list that the window manager does not know.
func window_manager_unresolved_windows(_ wm: WindowManager, _ windowList: [UInt32]) -> [UInt32]
{
    return windowList.filter { window_manager_find_window(wm, $0) == nil }
}

//
// NOTE(asmvik): MacOS API does not return AXUIElementRef of windows on inactive spaces.
// However, we can just brute-force the element_id and create the AXUIElementRef ourselves.
// Every window that is found is removed from the unresolved list.
//
// :Attribution
// https://github.com/decodism
// https://github.com/lwouis/alt-tab-macos/issues/1324#issuecomment-2631035482
//

/// `window_manager_add_windows_by_element_id`
private func windowManagerAddWindowsByElementID(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application, _ unresolved: inout [UInt32])
{
    var data = Data(count: 0x14)
    data.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: UInt32(bitPattern: owner.pointee.pid), toByteOffset: 0x0, as: UInt32.self)
        bytes.storeBytes(of: UInt32(0x636f636f), toByteOffset: 0x8, as: UInt32.self)
    }

    for elementID in UInt64(0)..<0x7fff {
        if unresolved.isEmpty { break }

        data.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 0xc, as: UInt64.self) }
        guard let element = AXElement(remoteToken: data) else { continue }

        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.ref, kAXRoleAttribute as CFString, &role)

        //
        // NOTE: An application that does not respond makes every attempt wait for the
        // messaging timeout, so give up on it instead of trying all element ids.
        //

        if error == .cannotComplete { break }

        if let role {
            let elementWid = CFEqual(role, kAXWindowRole as CFString) ? element.windowID : 0

            if elementWid != 0, let i = unresolved.firstIndex(of: elementWid) {
                unresolved[i] = unresolved[unresolved.count - 1]
                unresolved.removeLast()
                window_manager_create_and_add_window(sm, wm, owner, element.ref, elementWid, false)
            }
        }
    }
}

/// `window_manager_add_existing_application_windows`: true when the windows of an application in applications_to_refresh
/// (at refreshIndex) are now all resolved; it is then removed from the list. With refreshIndex -1 (a new application),
/// the application is added to the list when windows are still missing.
func window_manager_add_existing_application_windows(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application, _ refreshIndex: Int32) -> Bool
{
    guard let globalWindowList = windowManagerExistingApplicationWindowList(owner) else { return false }

    let windowList = application_window_list(owner).map(axElements) ?? []

    var emptyCount = 0
    for windowRef in windowList {
        let windowID = ax_window_id(windowRef)

        //
        // @cleanup
        //
        // :Workaround
        //
        // NOTE(asmvik): The AX API appears to always include a single element for Finder that returns an empty window id.
        // This is likely the desktop window. Other similar cases should be handled the same way; simply ignore the window when
        // we attempt to do an equality check to see if we have correctly discovered the number of windows to track.
        //

        if windowID == 0 {
            emptyCount += 1
            continue
        }

        if window_manager_find_window(wm, windowID) == nil {
            window_manager_create_and_add_window(sm, wm, owner, windowRef, windowID, false)
        }
    }

    var resolved = globalWindowList.count == windowList.count - emptyCount
    if !resolved {
        var unresolved = window_manager_unresolved_windows(wm, globalWindowList)
        resolved = unresolved.isEmpty

        if !resolved && refreshIndex == -1 {
            debug("window_manager_add_existing_application_windows: \(cName(owner.pointee.name)) has \(unresolved.count) windows that are not yet resolved, attempting workaround\n")
            windowManagerAddWindowsByElementID(sm, wm, owner, &unresolved)

            if !unresolved.isEmpty {
                debug("window_manager_add_existing_application_windows: workaround failed to resolve all windows for \(cName(owner.pointee.name))\n")
                window_manager_add_application_refresh(wm, owner)
            } else {
                debug("window_manager_add_existing_application_windows: workaround resolved all windows for \(cName(owner.pointee.name))\n")
            }

            return false
        }
    }

    if !resolved || refreshIndex == -1 { return false }

    debug("window_manager_add_existing_application_windows: all windows for \(cName(owner.pointee.name)) are now resolved\n")
    window_manager_remove_application_refresh(wm, refreshIndex)
    return true
}
