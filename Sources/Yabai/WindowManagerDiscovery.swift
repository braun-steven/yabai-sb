import ApplicationServices
import Foundation
import CPrivate
import AppKit
import YabaiCore

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
func window_manager_create_and_add_window(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application, _ windowRef: AXUIElement, _ windowID: WindowID, _ oneShotRules: Bool) -> Window?
{
    let target = Window(application: owner, reference: windowRef, id: windowID)

    let windowTitle = target.cachedTitle
    let windowRole = target.roleString
    let windowSubrole = target.subroleString
    debug("window_manager_create_and_add_window:\(target.id) \(owner.name) - \(windowTitle) (\(windowRole):\(windowSubrole):\(target.is_root ? 1 : 0))\n")

    if target.isUnknown {
        debug("window_manager_create_and_add_window: ignoring AXUnknown window \(owner.name) \(target.id)\n")
        wm.removeLostFocusedEvent(for: target.id)
        target.destroy()
        return nil
    }

    //
    // NOTE(asmvik): Attempt to track **all** windows.
    //

    if !target.observe() {
        debug("window_manager_create_and_add_window: could not observe \(owner.name) \(target.id)\n")
        wm.removeLostFocusedEvent(for: target.id)
        target.unobserve()
        target.destroy()
        return nil
    }

    if wm.hasLostFocusedEvent(for: target.id) {
        EventLoop.post(.windowFocused(windowID: target.id))
        wm.removeLostFocusedEvent(for: target.id)
    }

    wm.addWindow(target)

    //
    // NOTE(asmvik): However, only **root windows** are eligible for management.
    //

    if target.is_root {

        //
        // NOTE(asmvik): A lot of windows misreport their accessibility role, so we allow the user
        // to specify rules to make sure that we do in fact manage these windows properly.
        //
        // This part of the rule must be applied at this stage (prior to other rule properties), and if
        // no such rule matches this window, it will be ignored if it does not have a role of kAXWindowRole.
        //

        wm.applyManageRules(to: target, title: windowTitle, role: windowRole, subrole: windowSubrole, includingOneShotRules: oneShotRules)

        if target.isEligibleForManagement {
            target.is_eligible = true
            wm.applyRules(to: target, title: windowTitle, role: windowRole, subrole: windowSubrole, includingOneShotRules: oneShotRules)
            wm.purifyWindow(target)
            wm.setWindowOpacity(target, to: wm.normal_window_opacity)

            if owner.isHidden        { return target }
            if target.isMinimized     { return target }
            if target.isFullscreen    { return target }
            if target.isManagedByRule { return target }

            if target.isFullscreenByRule {
                target.isFullscreenByRule = false
                return target
            }

            if target.id.isSticky ||
               !target.canMove ||
               !target.isStandard ||
               !target.isStandardLevel ||
               (!target.canResize && target.isUndersized) {
                target.isFloating = true
            }
        } else {
            debug("window_manager_create_and_add_window ignoring incorrectly marked window \(owner.name) \(target.id)\n")
            target.isFloating = true
            windowManagerDebugWindowInfo(target)
        }
    } else {
        debug("window_manager_create_and_add_window ignoring child window \(owner.name) \(target.id)\n")
        target.isFloating = true
        windowManagerDebugWindowInfo(target)
    }

    return target
}

//
// NOTE: The space a new window is managed on, as selected by window_origin_display.
//

/// `window_manager_origin_space`
func window_manager_origin_space(_ wm: WindowManager, _ target: Window) -> SpaceID?
{
    switch wm.window_origin_mode {
    case .focused: return space_manager_global().current_space_id
    case .cursor:  return space_manager_cursor_space()
    case .default: return target.id.space
    }
}

/// `window_manager_add_application_windows`: the windows of the AX list of the application that were not known yet.
func window_manager_add_application_windows(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application) -> [Window]
{
    guard let windowList = owner.windowList else { return [] }

    var result: [Window] = []

    for windowRef in axElements(windowList) {
        guard let windowID = ax_window_id(windowRef), wm.window(for: windowID) == nil else { continue }

        if let target = window_manager_create_and_add_window(sm, wm, owner, windowRef, windowID, true) { result.append(target) }
    }

    wm.removeOneShotRules()

    return result
}

/// `window_manager_existing_application_window_list`: the windows of the application (of every application for nil)
/// on the spaces of Mission Control, minimized ones included; nil when there are none or the window server fails.
func windowManagerExistingApplicationWindowList(_ owner: Application?) -> [WindowID]?
{
    guard let spaceList = space_manager_mission_control_space_list() else { return nil }

    guard let candidates = spaceWindowCandidates(spaceList, owner?.connection ?? 0, true), !candidates.isEmpty else { return nil }
    return spaceUserWindows(candidates, true)
}

/// `window_manager_unresolved_windows`: the windows of the list that the window manager does not know.
func window_manager_unresolved_windows(_ wm: WindowManager, _ windowList: [WindowID]) -> [WindowID]
{
    return windowList.filter { wm.window(for: $0) == nil }
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
private func windowManagerAddWindowsByElementID(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application, _ unresolved: inout [WindowID])
{
    var data = Data(count: 0x14)
    data.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: UInt32(bitPattern: owner.pid), toByteOffset: 0x0, as: UInt32.self)
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
            let elementWid = CFEqual(role, kAXWindowRole as CFString) ? element.windowID : nil

            if let elementWid, let i = unresolved.firstIndex(of: elementWid) {
                unresolved[i] = unresolved[unresolved.count - 1]
                unresolved.removeLast()
                window_manager_create_and_add_window(sm, wm, owner, element.ref, elementWid, false)
            }
        }
    }
}

/// `window_manager_add_existing_application_windows`: true when the windows of an application in applications_to_refresh
/// (at refreshIndex) are now all resolved; it is then removed from the list. With refreshIndex nil (a new application),
/// the application is added to the list when windows are still missing.
func window_manager_add_existing_application_windows(_ sm: SpaceManager, _ wm: WindowManager, _ owner: Application, _ refreshIndex: Int?) -> Bool
{
    guard let globalWindowList = windowManagerExistingApplicationWindowList(owner) else { return false }

    let windowList = owner.windowList.map(axElements) ?? []

    var emptyCount = 0
    for windowRef in windowList {
        //
        // @cleanup
        //
        // :Workaround
        //
        // NOTE(asmvik): The AX API appears to always include a single element for Finder that returns an empty window id.
        // This is likely the desktop window. Other similar cases should be handled the same way; simply ignore the window when
        // we attempt to do an equality check to see if we have correctly discovered the number of windows to track.
        //

        guard let windowID = ax_window_id(windowRef) else {
            emptyCount += 1
            continue
        }

        if wm.window(for: windowID) == nil {
            window_manager_create_and_add_window(sm, wm, owner, windowRef, windowID, false)
        }
    }

    var resolved = globalWindowList.count == windowList.count - emptyCount
    if !resolved {
        var unresolved = window_manager_unresolved_windows(wm, globalWindowList)
        resolved = unresolved.isEmpty

        if !resolved && refreshIndex == nil {
            debug("window_manager_add_existing_application_windows: \(owner.name) has \(unresolved.count) windows that are not yet resolved, attempting workaround\n")
            windowManagerAddWindowsByElementID(sm, wm, owner, &unresolved)

            if !unresolved.isEmpty {
                debug("window_manager_add_existing_application_windows: workaround failed to resolve all windows for \(owner.name)\n")
                wm.addApplicationToRefresh(owner)
            } else {
                debug("window_manager_add_existing_application_windows: workaround resolved all windows for \(owner.name)\n")
            }

            return false
        }
    }

    guard resolved, let refreshIndex else { return false }

    debug("window_manager_add_existing_application_windows: all windows for \(owner.name) are now resolved\n")
    wm.removeApplicationRefresh(at: refreshIndex)
    return true
}
