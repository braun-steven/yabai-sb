import ApplicationServices
import CPrivate
import YabaiC

//
// NOTE: A window that yabai tracks, a thin wrapper of its AX element and the window server queries about its id.
// struct window stays C until rule.c and the remaining model bridges are removed in P14. Ported from src/window.c.
//

// the notifications of window_observe, in the order of the bits of window->notification (AX_WINDOW_*_INDEX)
private let axWindowNotifications: [(name: String, text: String)] =
[
    (kAXWindowMiniaturizedNotification,   "kAXWindowMiniaturizedNotification"),
    (kAXWindowDeminiaturizedNotification, "kAXWindowDeminiaturizedNotification"),
    (kAXUIElementDestroyedNotification,   "kAXUIElementDestroyedNotification"),
]

// AX_WINDOW_ALL
private let axWindowAll: UInt8 = 0b111

// kAXFullscreenAttribute (window.h)
let axFullscreenAttribute = "AXFullScreen"

//
// NOTE: The notifications use the observer of the application, and their context is the window: the callback is
// applicationNotificationHandler (Application.swift), whose NOTE says who owns the window.
//

/// `window_observe`: true if every notification of AX_WINDOW_ALL is registered.
func window_observe(_ target: Window) -> Bool
{
    let observerRef = target.pointee.application.pointee.observer_ref.takeUnretainedValue()

    for (i, notification) in axWindowNotifications.enumerated() {
        let result = AXObserverAddNotification(observerRef, target.pointee.ref.takeUnretainedValue(), notification.name as CFString, UnsafeMutableRawPointer(target))
        if result == .success || result == .notificationAlreadyRegistered {
            target.pointee.notification |= UInt8(1 << i)
        } else {
            debug("window_observe: \(notification.text) failed with error \(axErrorName(result))\n")
        }
    }

    return (target.pointee.notification & axWindowAll) == axWindowAll
}

/// `window_unobserve`
func window_unobserve(_ target: Window)
{
    let observerRef = target.pointee.application.pointee.observer_ref.takeUnretainedValue()

    for (i, notification) in axWindowNotifications.enumerated() {
        if target.pointee.notification & UInt8(1 << i) == 0 { continue }

        AXObserverRemoveNotification(observerRef, target.pointee.ref.takeUnretainedValue(), notification.name as CFString)
        target.pointee.notification &= ~UInt8(1 << i)
    }
}

/// `window_display_uuid`
private func windowDisplayUUID(_ wid: UInt32) -> String?
{
    if let uuid = SLS.managedDisplay(connection_global(), forWindow: wid) { return uuid }

    let frame = SLS.windowBounds(connection_global(), wid) ?? .zero
    return SLS.bestManagedDisplay(connection_global(), forRect: frame)
}

/// `window_display_id`
func window_display_id(_ wid: UInt32) -> UInt32
{
    guard let uuid = windowDisplayUUID(wid) else { return 0 }
    return displayID(uuid)
}

/// `window_display_space`
private func windowDisplaySpace(_ wid: UInt32) -> UInt64
{
    guard let uuid = windowDisplayUUID(wid) else { return 0 }
    return SLS.currentSpace(connection_global(), forDisplay: uuid)
}

/// `window_space`: the first space of the window, or the current space of its display.
@_cdecl("window_space")
func window_space(_ wid: UInt32) -> UInt64
{
    let sid = SLS.spaces(connection_global(), forWindows: [wid]).first ?? 0
    return sid != 0 ? sid : windowDisplaySpace(wid)
}

/// `window_space_list`: the spaces of the window (more than one for a sticky window).
func window_space_list(_ wid: UInt32) -> [UInt64]
{
    return SLS.spaces(connection_global(), forWindows: [wid])
}

/// `window_title_ts`: the cached title in temporary storage, "" without one.
@_cdecl("window_title_ts")
func window_title_ts(_ target: Window) -> UnsafeMutablePointer<CChar>?
{
    return tsString(target.pointee.title.map { $0.takeUnretainedValue() as String } ?? "")
}

/// `window_title`: the title as the application reports it now.
func window_title(_ target: Window) -> CFString?
{
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXTitleAttribute as CFString, &value)
    return value.map { unsafeDowncast($0, to: CFString.self) }
}

/// `window_ax_origin`
func window_ax_origin(_ target: Window) -> CGPoint
{
    var origin = CGPoint.zero
    var positionRef: CFTypeRef?

    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXPositionAttribute as CFString, &positionRef)

    if let positionRef {
        AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &origin)
    }

    return origin
}

/// `window_ax_frame`
func window_ax_frame(_ target: Window) -> CGRect
{
    var frame = CGRect.zero
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?

    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXPositionAttribute as CFString, &positionRef)
    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXSizeAttribute as CFString, &sizeRef)

    if let positionRef {
        AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &frame.origin)
    }

    if let sizeRef {
        AXValueGetValue(unsafeDowncast(sizeRef, to: AXValue.self), .cgSize, &frame.size)
    }

    return frame
}

/// Whether the AX attribute of the window is settable; false if the call fails.
private func windowAttributeIsSettable(_ target: Window, _ attribute: String) -> Bool
{
    var result: DarwinBoolean = false
    if AXUIElementIsAttributeSettable(target.pointee.ref.takeUnretainedValue(), attribute as CFString, &result) != .success {
        result = false
    }
    return result.boolValue
}

/// `window_ax_can_move`
func window_ax_can_move(_ target: Window) -> Bool
{
    return windowAttributeIsSettable(target, kAXPositionAttribute)
}

/// `window_can_move`
func window_can_move(_ target: Window) -> Bool
{
    return window_check_flag(target, WINDOW_MOVABLE)
}

/// `window_ax_can_resize`
func window_ax_can_resize(_ target: Window) -> Bool
{
    return windowAttributeIsSettable(target, kAXSizeAttribute)
}

/// `window_can_resize`
func window_can_resize(_ target: Window) -> Bool
{
    return window_check_flag(target, WINDOW_RESIZABLE)
}

/// `window_can_minimize`
func window_can_minimize(_ target: Window) -> Bool
{
    return windowAttributeIsSettable(target, kAXMinimizedAttribute)
}

/// `window_is_undersized`
func window_is_undersized(_ target: Window) -> Bool
{
    if target.pointee.frame.size.width  <= 500.0 { return true }
    if target.pointee.frame.size.height <= 500.0 { return true }
    return false
}

/// The value of a boolean AX attribute of the window; false if the call fails.
private func windowBooleanAttribute(_ target: Window, _ attribute: CFString) -> Bool
{
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), attribute, &value) == .success, let value else { return false }
    return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
}

/// `window_is_minimized`
private func windowIsMinimized(_ target: Window) -> Bool
{
    return windowBooleanAttribute(target, kAXMinimizedAttribute as CFString)
}

/// `window_is_fullscreen`
func window_is_fullscreen(_ target: Window) -> Bool
{
    return windowBooleanAttribute(target, axFullscreenAttribute as CFString)
}

/// `window_is_sticky`: true if the window is on more than one space.
@_cdecl("window_is_sticky")
func window_is_sticky(_ wid: UInt32) -> Bool
{
    return SLS.spaces(connection_global(), forWindows: [wid]).count > 1
}

/// `window_shadow`
func window_shadow(_ wid: UInt32) -> Bool
{
    let tags = window_tags(wid)
    return (tags & 0x8) == 0
}

/// `window_opacity`
func window_opacity(_ wid: UInt32) -> Float
{
    return SLS.windowAlpha(connection_global(), wid)
}

/// The window as the window server reports it, when it knows exactly this window.
private func windowQuery(_ wid: UInt32) -> SLS.QueriedWindow?
{
    let windows = SLS.queryWindows(connection_global(), [wid])
    return windows.count == 1 ? windows[0] : nil
}

/// `window_parent`
func window_parent(_ wid: UInt32) -> UInt32
{
    return windowQuery(wid)?.parent ?? 0
}

/// `window_level`
@_cdecl("window_level")
func window_level(_ wid: UInt32) -> Int32
{
    return windowQuery(wid)?.level ?? 0
}

/// `window_sub_level`: through the bounded message of SLSGetWindowSubLevelBounded (CPrivate.h) when it works.
@_cdecl("window_sub_level")
func window_sub_level(_ wid: UInt32) -> Int32
{
    var subLevel: Int32 = 0
    if SLSGetWindowSubLevelBounded(connection_global(), wid, &subLevel) {
        return subLevel
    }

    return SLS.windowSubLevel(connection_global(), wid)
}

/// `window_tags`
func window_tags(_ wid: UInt32) -> UInt64
{
    return windowQuery(wid)?.tags ?? 0
}

/// `window_ax_role`: +1, stored in window->role.
private func windowAXRole(_ target: Window) -> Unmanaged<CFString>?
{
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXRoleAttribute as CFString, &role)
    return role.map { Unmanaged.passRetained(unsafeDowncast($0, to: CFString.self)) }
}

/// `window_role`: the cached role.
func window_role(_ target: Window) -> CFString?
{
    return target.pointee.role?.takeUnretainedValue()
}

/// `window_role_ts`: the cached role in temporary storage, "" without one.
@_cdecl("window_role_ts")
func window_role_ts(_ target: Window) -> UnsafeMutablePointer<CChar>?
{
    return tsString(window_role(target).map { $0 as String } ?? "")
}

/// `window_ax_subrole`: +1, stored in window->subrole.
private func windowAXSubrole(_ target: Window) -> Unmanaged<CFString>?
{
    var subrole: CFTypeRef?
    AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXSubroleAttribute as CFString, &subrole)
    return subrole.map { Unmanaged.passRetained(unsafeDowncast($0, to: CFString.self)) }
}

/// `window_subrole`: the cached subrole.
func window_subrole(_ target: Window) -> CFString?
{
    return target.pointee.subrole?.takeUnretainedValue()
}

/// `window_subrole_ts`: the cached subrole in temporary storage, "" without one.
@_cdecl("window_subrole_ts")
func window_subrole_ts(_ target: Window) -> UnsafeMutablePointer<CChar>?
{
    return tsString(window_subrole(target).map { $0 as String } ?? "")
}

/// `window_is_root`: true if the AX parent of the window is its application (or it has none).
private func windowIsRoot(_ target: Window) -> Bool
{
    var result = false
    var value: CFTypeRef?

    if AXUIElementCopyAttributeValue(target.pointee.ref.takeUnretainedValue(), kAXParentAttribute as CFString, &value) == .success {
        result = !(value != nil && !CFEqual(value, target.pointee.application.pointee.ref.takeUnretainedValue()))
    }

    return result
}

/// `window_is_real`: an AXWindow that is a standard, floating or dialog window.
func window_is_real(_ target: Window) -> Bool
{
    guard let role = window_role(target), let subrole = window_subrole(target) else { return false }

    return CFEqual(role, kAXWindowRole as CFString) &&
           (CFEqual(subrole, kAXStandardWindowSubrole as CFString) ||
            CFEqual(subrole, kAXFloatingWindowSubrole as CFString) ||
            CFEqual(subrole, kAXDialogSubrole as CFString))
}

/// `window_is_standard`
@_cdecl("window_is_standard")
func window_is_standard(_ target: Window) -> Bool
{
    guard let role = window_role(target), let subrole = window_subrole(target) else { return false }

    return CFEqual(role, kAXWindowRole as CFString) && CFEqual(subrole, kAXStandardWindowSubrole as CFString)
}

/// `window_level_is_standard`: the level of the window is that of LAYER_NORMAL (g_layer_normal_window_level).
@_cdecl("window_level_is_standard")
func window_level_is_standard(_ target: Window) -> Bool
{
    let level = window_level(target.pointee.id)
    return level == CGWindowLevelForKey(.normalWindow)
}

/// `window_is_unknown`
func window_is_unknown(_ target: Window) -> Bool
{
    guard let subrole = window_subrole(target) else { return false }
    return CFEqual(subrole, kAXUnknownSubrole as CFString)
}

//
// NOTE: Windows report other roles and capabilities while they are minimized or in native fullscreen,
// so these cached properties are read again whenever that state changes.
//

/// `window_refresh_ax_properties`
func window_refresh_ax_properties(_ target: Window)
{
    if window_ax_can_move(target) {
        window_set_flag(target, WINDOW_MOVABLE)
    } else {
        window_clear_flag(target, WINDOW_MOVABLE)
    }

    if window_ax_can_resize(target) {
        window_set_flag(target, WINDOW_RESIZABLE)
    } else {
        window_clear_flag(target, WINDOW_RESIZABLE)
    }

    target.pointee.role?.release()
    target.pointee.role = windowAXRole(target)

    target.pointee.subrole?.release()
    target.pointee.subrole = windowAXSubrole(target)
}

//
// NOTE: The struct holds ref, role, subrole and title at +1 until window_destroy. id_ptr points at id until the window
// is invalidated (window_is_valid in window.h).
//

/// `window_create`: takes over the +1 reference of the element (CF_CONSUMED in C).
func window_create(_ owner: Application, _ windowRef: AXUIElement, _ windowID: UInt32) -> Window
{
    let result = calloc(1, MemoryLayout<window>.size)!.bindMemory(to: window.self, capacity: 1)

    result.pointee.application = owner
    result.pointee.ref = Unmanaged.passRetained(windowRef)
    result.pointee.id = windowID
    result.pointee.id_ptr = (UnsafeMutableRawPointer(result) + MemoryLayout<window>.offset(of: \window.id)!).assumingMemoryBound(to: UInt32.self)
    result.pointee.frame = window_ax_frame(result)
    result.pointee.title = window_title(result).map { Unmanaged.passRetained($0) }
    result.pointee.is_root = window_parent(result.pointee.id) == 0 || windowIsRoot(result)

    if window_shadow(result.pointee.id) {
        window_set_flag(result, WINDOW_SHADOW)
    }

    if windowIsMinimized(result) {
        window_set_flag(result, WINDOW_MINIMIZE)
    }

    window_refresh_ax_properties(result)

    if window_is_fullscreen(result) || space_is_fullscreen(window_space(result.pointee.id)) {
        window_set_flag(result, WINDOW_FULLSCREEN)
    }

    if window_is_sticky(result.pointee.id) {
        window_set_flag(result, WINDOW_STICKY)
    }

    return result
}

/// `window_destroy`
func window_destroy(_ target: Window)
{
    target.pointee.id = 0
    target.pointee.role?.release()
    target.pointee.subrole?.release()
    target.pointee.title?.release()
    target.pointee.ref.release()
    free(target)
}
