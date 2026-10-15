import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import AppKit

//
// NOTE: The windows of yabai: the tables of applications, windows and managed windows, the commands on windows (move,
// resize, layout, opacity, layer, shadow, fullscreen, minimize, close, send to a space) and the checks of the windows on
// a space after Mission Control and display changes. Ported from src/window_manager.c.
//

/// `struct scratchpad`: the window manager owns the malloc'ed label.
struct Scratchpad
{
    var label: UnsafeMutablePointer<CChar>
    var window: Window
}

/// `struct window_manager`
final class WindowManager
{
    var system_element: AXUIElement?
    var application = Table<pid_t, Application>(capacity: 150)
    var window = Table<UInt32, Window>(capacity: 150)
    var managed_window = Table<UInt32, View>(capacity: 150)
    var window_lost_focused_event = Table<UInt32, Bool>(capacity: 150)
    var application_lost_front_switched_event = Table<pid_t, Bool>(capacity: 150)
    var rules: [UnsafeMutablePointer<rule>] = []
    var applications_to_refresh: [Application] = []
    var focused_window_id: UInt32 = 0
    var focused_window_psn = ProcessSerialNumber()
    var pending_focus_window_id: UInt32 = 0
    var pending_focus_time: UInt64 = 0
    var last_window_id: UInt32 = 0
    var enable_mff = false
    var ffm_mode = FFM_DISABLED
    var purify_mode = PURIFY_DISABLED
    var window_origin_mode = WINDOW_ORIGIN_DEFAULT
    var enable_window_opacity = false
    var menubar_opacity: Float = 0
    var active_window_opacity: Float = 0
    var normal_window_opacity: Float = 0
    var window_opacity_duration: Float = 0
    var window_animation_duration: Float = 0
    var window_animation_easing: Int32 = 0
    var insert_feedback_color = rgba_color()
    var enable_window_border = false
    var window_border_hide_single = false
    var window_border_width: Float = 0
    var active_window_border_color = rgba_color()
    var normal_window_border_color = rgba_color()
    var focus_wrapping = FOCUS_WRAPPING_OFF
    var enable_tab_bar = false
    var tab_bar_height: Int32 = 0
    var tab_bar_offset: Int32 = 0
    var tab_bar_icons = false
    var tab_bar_style = TAB_BAR_STYLE_GLASS
    var tab_bar_backdrop = TAB_BAR_BACKDROP_OFF
    var tab_bar_card_padding: Int32 = 0
    var tab_bar_window_radius: Int32 = 0
    var tab_bar_font_name: UnsafeMutablePointer<CChar>!
    var tab_bar_font: CTFont?
    var tab_bar_focused_color = rgba_color()
    var tab_bar_focused_text_color = rgba_color()
    var tab_bar_inactive_color = rgba_color()
    var tab_bar_inactive_text_color = rgba_color()
    var tab_bar_unfocused_color = rgba_color()
    var tab_bar_backdrop_color = rgba_color()
    var tab_bar_unfocused_text_color = rgba_color()
    var tab_bar_focused_color_custom = false
    var tab_bar_inactive_color_custom = false
    var tab_bar_unfocused_color_custom = false
    var tab_bar_backdrop_color_custom = false
    var scratchpad_window: [Scratchpad] = []
    var scratchpad_exclusive = false
    var scratchpad_raise = false
    var scratchpad_below = false
    var scratchpad_grid: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0)
}

/// `g_window_manager` (see the NOTE of g_display_manager)
nonisolated(unsafe) let g_window_manager = WindowManager()

func window_manager_global() -> WindowManager
{
    g_window_manager
}

//
// NOTE: The lists of the window manager that were sbuffers (applications_to_refresh, rules, scratchpad_window). Their
// removal moves the last element into the hole, as buf_del did.
//

func window_manager_application_refresh_index(_ wm: WindowManager, _ owner: Application) -> Int32
{
    return wm.applications_to_refresh.firstIndex(of: owner).map { Int32($0) } ?? -1
}

func window_manager_remove_application_refresh(_ wm: WindowManager, _ index: Int32)
{
    wm.applications_to_refresh.swapAt(Int(index), wm.applications_to_refresh.count - 1)
    wm.applications_to_refresh.removeLast()
}

func window_manager_application_refresh_count(_ wm: WindowManager) -> Int32
{
    return Int32(wm.applications_to_refresh.count)
}

func window_manager_application_refresh_at(_ wm: WindowManager, _ index: Int32) -> Application
{
    return wm.applications_to_refresh[Int(index)]
}

func window_manager_add_application_refresh(_ wm: WindowManager, _ owner: Application)
{
    wm.applications_to_refresh.append(owner)
}

func window_manager_rule_count(_ wm: WindowManager) -> Int32
{
    return Int32(wm.rules.count)
}

func window_manager_rule_at(_ wm: WindowManager, _ index: Int32) -> UnsafeMutablePointer<rule>
{
    return wm.rules[Int(index)]
}

/// Takes over the strings and patterns of the rule.
func window_manager_add_rule(_ wm: WindowManager, _ value: rule)
{
    let stored = UnsafeMutablePointer<rule>.allocate(capacity: 1)
    stored.initialize(to: value)
    wm.rules.append(stored)
}

/// The caller destroys the rule first (rule_destroy).
func window_manager_remove_rule(_ wm: WindowManager, _ index: Int32)
{
    let removed = wm.rules[Int(index)]
    wm.rules.swapAt(Int(index), wm.rules.count - 1)
    wm.rules.removeLast()
    removed.deinitialize(count: 1)
    removed.deallocate()
}

func window_manager_free_rules(_ wm: WindowManager)
{
    for stored in wm.rules {
        stored.deinitialize(count: 1)
        stored.deallocate()
    }
    wm.rules = []
}

func window_manager_scratchpad_count(_ wm: WindowManager) -> Int32
{
    return Int32(wm.scratchpad_window.count)
}

func window_manager_add_scratchpad(_ wm: WindowManager, _ label: UnsafeMutablePointer<CChar>, _ target: Window)
{
    wm.scratchpad_window.append(Scratchpad(label: label, window: target))
}

func window_manager_remove_scratchpad(_ wm: WindowManager, _ index: Int32)
{
    wm.scratchpad_window.swapAt(Int(index), wm.scratchpad_window.count - 1)
    wm.scratchpad_window.removeLast()
}

// MOUSE_EVENT_MASK (mouse_handler.h, which Swift does not import: the macro is built from other macros)
let mouseEventMask: UInt32 =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << UInt32(kCGSEventDockControl))

// MOUSE_EVENT_MASK_FFM
private let mouseEventMaskFFM: UInt32 = mouseEventMask | (1 << CGEventType.mouseMoved.rawValue)

// kAXEnhancedUserInterface (helpers.h; a static global there, which Swift cannot reach)
private let axEnhancedUserInterface = "AXEnhancedUserInterface"

/// `ax_enhanced_userinterface`
private func axEnhancedUserInterfaceEnabled(_ ref: AXUIElement) -> Bool
{
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ref, axEnhancedUserInterface as CFString, &value) == .success, let value else { return false }
    return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
}

/// `AX_ENHANCED_UI_WORKAROUND`: turns AXEnhancedUserInterface off around the body, which some applications need to
/// apply a frame at once.
func axEnhancedUIWorkaround(_ ref: AXUIElement, _ body: () -> Void)
{
    let eui = axEnhancedUserInterfaceEnabled(ref)
    if eui { AXUIElementSetAttributeValue(ref, axEnhancedUserInterface as CFString, kCFBooleanFalse) }
    body()
    if eui { AXUIElementSetAttributeValue(ref, axEnhancedUserInterface as CFString, kCFBooleanTrue) }
}

/// `window_manager_is_window_eligible`
func window_manager_is_window_eligible(_ target: Window) -> Bool
{
    return target.is_root && (window_is_real(target) || window_check_rule_flag(target, WINDOW_RULE_MANAGED))
}

/// `window_manager_set_focus_follows_mouse`
func window_manager_set_focus_follows_mouse(_ wm: WindowManager, _ mode: ffm_mode)
{
    mouse_handler_end(mouse_state_global())

    if mode == FFM_DISABLED {
        mouse_handler_begin(mouse_state_global(), mouseEventMask)
    } else {
        mouse_handler_begin(mouse_state_global(), mouseEventMaskFFM)
    }

    wm.ffm_mode = mode
}

/// `window_manager_set_window_opacity_enabled`
func window_manager_set_window_opacity_enabled(_ wm: WindowManager, _ enabled: Bool)
{
    wm.enable_window_opacity = enabled
    for target in wm.window.values where window_manager_is_window_eligible(target) {
        window_manager_set_opacity(wm, target, enabled ? target.opacity : 1.0)
    }
}

/// `window_manager_center_mouse`
func window_manager_center_mouse(_ wm: WindowManager, _ target: Window)
{
    if window_check_rule_flag(target, WINDOW_RULE_MFF) {
        if !window_check_rule_flag(target, WINDOW_RULE_MFF_VALUE) {
            return
        }
    } else {
        if !wm.enable_mff {
            return
        }
    }

    let cursor = SLS.cursorLocation(connection_global())
    if target.frame.contains(cursor) { return }

    let did = window_display_id(target.id)
    if did == 0 { return }

    let center = CGPoint(x: target.frame.origin.x + target.frame.size.width / 2,
                         y: target.frame.origin.y + target.frame.size.height / 2)

    let bounds = CGDisplayBounds(did)
    if !bounds.contains(center) { return }

    CGWarpMouseCursorPosition(center)
}

/// `window_manager_should_manage_window`
func window_manager_should_manage_window(_ target: Window) -> Bool
{
    if !target.is_root                          { return false }
    if window_check_flag(target, WINDOW_FLOAT)          { return false }
    if window_is_sticky(target.id)              { return false }
    if window_check_flag(target, WINDOW_MINIMIZE)       { return false }
    if target.application.is_hidden     { return false }

    return (window_is_standard(target) && window_level_is_standard(target) && window_can_move(target)) || window_check_rule_flag(target, WINDOW_RULE_MANAGED)
}

/// `window_manager_find_managed_window`: the view that manages the window, or nil.
func window_manager_find_managed_window(_ wm: WindowManager, _ target: Window) -> View?
{
    return wm.managed_window.find(target.id)
}

/// `window_manager_remove_managed_window`
func window_manager_remove_managed_window(_ wm: WindowManager, _ wid: UInt32)
{
    wm.managed_window.remove(wid)
}

/// `window_manager_add_managed_window`
func window_manager_add_managed_window(_ wm: WindowManager, _ target: Window, _ owner: View)
{
    if owner.layout == VIEW_FLOAT { return }

    wm.managed_window.add(target.id, owner)
    window_manager_purify_window(wm, target)
}

//
// NOTE: Operations on spaces with the 'tree' layout. They act on the container selected with
// 'window --focus parent' when there is one, and on the window otherwise.
//

//
// NOTE: Takes a window out of the tree of its view and gives it the shadow and layer of an unmanaged window.
//

/// `window_manager_unmanage_window`
func window_manager_unmanage_window(_ wm: WindowManager, _ owner: View, _ target: Window)
{
    space_manager_untile_window(owner, target)
    window_manager_remove_managed_window(wm, target.id)
    window_manager_purify_window(wm, target)
}

/// `window_manager_manage_window`
func window_manager_manage_window(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ sid: UInt64, _ insertionPoint: UInt32)
{
    let owner = space_manager_tile_window_on_space_with_insertion_point(sm, target, sid, insertionPoint)
    window_manager_add_managed_window(wm, target, owner)
}

/// `window_manager_find_tree_view`: the view of the window when it is managed on a space with a tree.
func window_manager_find_tree_view(_ wm: WindowManager, _ target: Window?) -> View?
{
    guard let target, let owner = window_manager_find_managed_window(wm, target) else { return nil }
    return owner.tree != nil ? owner : nil
}

/// `window_manager_tree_acting_con`
func windowManagerTreeActingCon(_ owner: View, _ target: Window) -> Con?
{
    if let selected = tree_find_selected(owner.tree), target.id == window_manager_global().focused_window_id { return selected }
    return tree_find_window(owner.tree, target.id)
}

/// `window_manager_tree_apply`
func windowManagerTreeApply(_ owner: View)
{
    //
    // NOTE: Operations on other windows must not hide the focused window in a tab that is not active.
    //

    if let focused = tree_find_window(owner.tree, window_manager_global().focused_window_id) { tree_focus(focused) }

    if !view_update_auto_padding(owner) { tree_view_update(owner) }
    view_flush(owner)
}

/// `window_manager_focus_window_id`
func windowManagerFocusWindowID(_ wm: WindowManager, _ windowID: UInt32)
{
    if let target = window_manager_find_window(wm, windowID) {
        window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
        window_manager_set_pending_focus(wm, target.id)
    }
}

//
// NOTE: The windows of the container that are on another space are moved with one operation, which
// is asynchronous. The returned list of moved windows is passed to window_manager_tree_wait_for_view
// before the layout of the view is applied, so that the frames are not set before the windows arrive.
//

/// `window_manager_tree_set_view`
func windowManagerTreeSetView(_ wm: WindowManager, _ node: Con, _ owner: View) -> [UInt32]
{
    var windowList: [UInt32] = []
    tree_collect_window_ids(node, &windowList)

    var moveList: [UInt32] = []
    for windowID in windowList {
        guard let target = window_manager_find_window(wm, windowID) else { continue }

        if window_space(target.id) != owner.sid { moveList.append(target.id) }
        window_manager_remove_managed_window(wm, target.id)
        window_manager_add_managed_window(wm, target, owner)
    }

    if !moveList.isEmpty {
        moveList.withUnsafeMutableBufferPointer { space_manager_move_window_list_to_space(owner.sid, $0.baseAddress!, Int32($0.count)) }
    }
    return moveList
}

/// `window_manager_tree_wait_for_view`
func windowManagerTreeWaitForView(_ moveList: [UInt32], _ owner: View)
{
    if moveList.isEmpty { return }

    var moveList = moveList
    _ = moveList.withUnsafeMutableBufferPointer { space_manager_wait_for_windows_on_space($0.baseAddress!, Int32($0.count), owner.sid, 200) }
}

//
// NOTE: The ratio of a window on a tree space is its share of its container. The space is taken from
// or given to the next container, or the previous one for the last container.
//

/// `window_manager_adjust_window_ratio`
func window_manager_adjust_window_ratio(_ wm: WindowManager, _ target: Window, _ type: Int32, _ ratio: Float) -> window_op_error
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    //
    // NOTE: Tabs share the area of their container, so the ratio of a tab is the one of its tabbed
    // container, like i3 skips tabbed containers when it looks for the containers to resize.
    //

    var node = windowManagerTreeActingCon(owner, target)
    while let current = node, let parent = current.parent, parent.layout == CON_TABBED { node = parent }
    guard let node, let parent = node.parent else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    let horizontal = parent.layout == CON_SPLITH
    let size = horizontal ? parent.area.w : parent.area.h
    let percent = type == TYPE_REL ? node.percent + ratio : ratio
    let delta = (clampf_range(percent, 0.05, 0.95) - node.percent) * size

    if !tree_resize(node, horizontal ? DIR_EAST : DIR_SOUTH, delta) &&
       !tree_resize(node, horizontal ? DIR_WEST : DIR_NORTH, -delta) {
        return WINDOW_OP_ERROR_INVALID_SRC_NODE
    }

    tree_view_update(owner)
    view_flush(owner)

    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_move_window_relative`
func window_manager_move_window_relative(_ wm: WindowManager, _ target: Window, _ type: Int32, _ dx: Float, _ dy: Float) -> window_op_error
{
    if window_manager_find_managed_window(wm, target) != nil { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    var dx = dx
    var dy = dy

    if type == TYPE_REL {
        dx += Float(target.frame.origin.x)
        dy += Float(target.frame.origin.y)
    }

    window_manager_animate_window(window_capture(window: target, x: dx, y: dy, w: Float(target.frame.size.width), h: Float(target.frame.size.height)))
    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_resize_window_relative_internal`
func window_manager_resize_window_relative_internal(_ target: Window, _ frame: CGRect, _ direction: Int32, _ dx: Float, _ dy: Float, _ animate: Bool)
{
    let xMod: CGFloat = (direction & HANDLE_LEFT) != 0 ? -1 : (direction & HANDLE_RIGHT)  != 0 ? 1 : 0
    let yMod: CGFloat = (direction & HANDLE_TOP)  != 0 ? -1 : (direction & HANDLE_BOTTOM) != 0 ? 1 : 0

    let fw = Float(max(1, frame.size.width  + CGFloat(dx) * xMod))
    let fh = Float(max(1, frame.size.height + CGFloat(dy) * yMod))
    let fx = (direction & HANDLE_LEFT) != 0 ? Float(frame.origin.x + frame.size.width  - CGFloat(fw)) : Float(frame.origin.x)
    let fy = (direction & HANDLE_TOP)  != 0 ? Float(frame.origin.y + frame.size.height - CGFloat(fh)) : Float(frame.origin.y)

    if animate {
        window_manager_animate_window(window_capture(window: target, x: fx, y: fy, w: fw, h: fh))
    } else {
        axEnhancedUIWorkaround(target.application.ref) {
            window_manager_move_window(target, fx, fy)
            window_manager_resize_window(target, fw, fh)
        }
    }
}

/// `window_manager_resize_window_relative`
func window_manager_resize_window_relative(_ wm: WindowManager, _ target: Window, _ direction: Int32, _ dx: Float, _ dy: Float, _ animate: Bool) -> window_op_error
{
    if let owner = window_manager_find_managed_window(wm, target) {
        if direction == HANDLE_ABS || owner.tree == nil { return WINDOW_OP_ERROR_INVALID_OPERATION }

        guard let node = windowManagerTreeActingCon(owner, target) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

        var didResize = false
        if (direction & HANDLE_TOP)    != 0 { didResize = tree_resize(node, DIR_NORTH, dy) || didResize }
        if (direction & HANDLE_BOTTOM) != 0 { didResize = tree_resize(node, DIR_SOUTH, dy) || didResize }
        if (direction & HANDLE_LEFT)   != 0 { didResize = tree_resize(node, DIR_WEST, dx) || didResize }
        if (direction & HANDLE_RIGHT)  != 0 { didResize = tree_resize(node, DIR_EAST, dx) || didResize }
        if !didResize { return WINDOW_OP_ERROR_INVALID_DST_NODE }

        tree_view_update(owner)
        view_flush(owner)
    } else {
        if direction == HANDLE_ABS {
            if animate {
                window_manager_animate_window(window_capture(window: target, x: Float(target.frame.origin.x), y: Float(target.frame.origin.y), w: dx, h: dy))
            } else {
                axEnhancedUIWorkaround(target.application.ref) { window_manager_resize_window(target, dx, dy) }
            }
        } else {
            window_manager_resize_window_relative_internal(target, window_ax_frame(target), direction, dx, dy, animate)
        }
    }

    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_move_window`
func window_manager_move_window(_ target: Window, _ x: Float, _ y: Float)
{
    target.frame_request.origin = CGPoint(x: CGFloat(x), y: CGFloat(y))

    var position = CGPoint(x: CGFloat(x), y: CGFloat(y))
    guard let positionRef = AXValueCreate(.cgPoint, &position) else { return }

    AXUIElementSetAttributeValue(target.ref, kAXPositionAttribute as CFString, positionRef)
}

/// `window_manager_resize_window`
func window_manager_resize_window(_ target: Window, _ width: Float, _ height: Float)
{
    target.frame_request.size = CGSize(width: CGFloat(width), height: CGFloat(height))

    var size = CGSize(width: CGFloat(width), height: CGFloat(height))
    guard let sizeRef = AXValueCreate(.cgSize, &size) else { return }

    AXUIElementSetAttributeValue(target.ref, kAXSizeAttribute as CFString, sizeRef)
}

/// `window_manager_set_purify_mode`
func window_manager_set_purify_mode(_ wm: WindowManager, _ mode: purify_mode)
{
    wm.purify_mode = mode
    for target in wm.window.values where window_manager_is_window_eligible(target) {
        window_manager_purify_window(wm, target)
    }
}

/// `window_manager_set_opacity`: opacity 0 means the opacity of the focus state (or 1 without window_opacity).
@discardableResult
func window_manager_set_opacity(_ wm: WindowManager, _ target: Window, _ opacity: Float) -> Bool
{
    var opacity = opacity

    if opacity == 0.0 {
        if wm.enable_window_opacity {
            opacity = target.id == wm.focused_window_id ? wm.active_window_opacity : wm.normal_window_opacity
        } else {
            opacity = 1.0
        }
    }

    return scripting_addition_set_opacity(target.id, opacity, wm.window_opacity_duration)
}

/// `window_manager_set_window_opacity`
func window_manager_set_window_opacity(_ wm: WindowManager, _ target: Window, _ opacity: Float)
{
    if !wm.enable_window_opacity              { return }
    if !window_manager_is_window_eligible(target)     { return }
    if target.opacity != 0.0                  { return }

    window_manager_set_opacity(wm, target, opacity)
}

/// `window_manager_set_menubar_opacity`
func window_manager_set_menubar_opacity(_ wm: WindowManager, _ opacity: Float)
{
    wm.menubar_opacity = opacity
    SLSSetMenuBarInsetAndAlpha(connection_global(), 0, 1, opacity)
}

/// `window_manager_set_active_window_opacity`
func window_manager_set_active_window_opacity(_ wm: WindowManager, _ opacity: Float)
{
    wm.active_window_opacity = opacity
    if let target = window_manager_focused_window(wm) { window_manager_set_window_opacity(wm, target, wm.active_window_opacity) }
}

/// `window_manager_set_normal_window_opacity`
func window_manager_set_normal_window_opacity(_ wm: WindowManager, _ opacity: Float)
{
    wm.normal_window_opacity = opacity
    for target in wm.window.values {
        if target.id == wm.focused_window_id { continue }
        if window_manager_is_window_eligible(target) {
            window_manager_set_window_opacity(wm, target, wm.normal_window_opacity)
        }
    }
}

/// `window_manager_adjust_layer`: only for windows without a layer of their own (LAYER_AUTO).
func window_manager_adjust_layer(_ target: Window, _ layer: Int32)
{
    if target.layer != LAYER_AUTO { return }

    scripting_addition_set_layer(target.id, layer)
}

//
// NOTE: The descendants of root in a list of (parent, child) relations, breadth first. Every relation is used once,
// which consumes parentList, so a cycle cannot repeat windows.
//

/// `window_manager_collect_child_windows`
func window_manager_collect_child_windows(_ root: UInt32, _ parentList: inout [UInt32], _ childList: [UInt32]) -> [UInt32]
{
    var result: [UInt32] = []

    var i = -1
    while i < result.count {
        let parent = i < 0 ? root : result[i]

        for j in 0..<parentList.count {
            if parentList[j] != parent { continue }

            parentList[j] = 0
            result.append(childList[j])
        }

        i += 1
    }

    return result
}

//
// NOTE: The child windows (e.g. sheets) follow the layer of their window. With LAYER_AUTO, managed windows (and
// scratchpads with scratchpad_below) go to the below sub-layer and their child windows to the normal one.
//

/// `window_manager_set_window_layer`
func window_manager_set_window_layer(_ target: Window, _ layer: Int32) -> Bool
{
    var parentLayer = layer
    var childLayer = layer

    if layer == LAYER_AUTO {
        let wm = window_manager_global()
        let below = window_manager_find_managed_window(wm, target) != nil || (wm.scratchpad_below && target.scratchpad != nil)
        parentLayer = below ? layerValue(.below) : layerValue(.normal)
        childLayer = layerValue(.normal)
    }

    target.layer = layer
    let result = scripting_addition_set_layer(target.id, parentLayer)
    if !result { return false }

    guard let associated = SLSCopyAssociatedWindows(connection_global(), target.id) as? [NSNumber], !associated.isEmpty else { return result }

    var parentList: [UInt32] = []
    var childList: [UInt32] = []

    for queried in SLS.queryWindows(connection_global(), associated.map { $0.uint32Value }).prefix(associated.count) {
        parentList.append(queried.parent)
        childList.append(queried.id)
    }

    for descendant in window_manager_collect_child_windows(target.id, &parentList, childList) {
        scripting_addition_set_layer(descendant, childLayer)
    }

    return result
}

/// `window_manager_purify_window`
func window_manager_purify_window(_ wm: WindowManager, _ target: Window)
{
    let value: Bool

    if wm.purify_mode == PURIFY_DISABLED {
        value = true
    } else if wm.purify_mode == PURIFY_MANAGED {
        value = window_manager_find_managed_window(wm, target) == nil
    } else /* if wm.purify_mode == PURIFY_ALWAYS */ {
        value = false
    }

    if scripting_addition_set_shadow(target.id, value) {
        if value {
            window_set_flag(target, WINDOW_SHADOW)
        } else {
            window_clear_flag(target, WINDOW_SHADOW)
        }
    }
}

/// `window_manager_find_lost_front_switched_event`
func window_manager_find_lost_front_switched_event(_ wm: WindowManager, _ pid: pid_t) -> Bool
{
    return wm.application_lost_front_switched_event.find(pid) != nil
}

/// `window_manager_remove_lost_front_switched_event`
func window_manager_remove_lost_front_switched_event(_ wm: WindowManager, _ pid: pid_t)
{
    wm.application_lost_front_switched_event.remove(pid)
}

/// `window_manager_add_lost_front_switched_event`
func window_manager_add_lost_front_switched_event(_ wm: WindowManager, _ pid: pid_t)
{
    wm.application_lost_front_switched_event.add(pid, true)
}

/// `window_manager_find_lost_focused_event`
func window_manager_find_lost_focused_event(_ wm: WindowManager, _ windowID: UInt32) -> Bool
{
    return wm.window_lost_focused_event.find(windowID) != nil
}

/// `window_manager_remove_lost_focused_event`
func window_manager_remove_lost_focused_event(_ wm: WindowManager, _ windowID: UInt32)
{
    wm.window_lost_focused_event.remove(windowID)
}

/// `window_manager_add_lost_focused_event`
func window_manager_add_lost_focused_event(_ wm: WindowManager, _ windowID: UInt32)
{
    wm.window_lost_focused_event.add(windowID, true)
}

/// `window_manager_find_window`
func window_manager_find_window(_ wm: WindowManager, _ windowID: UInt32) -> Window?
{
    return wm.window.find(windowID)
}

/// `window_manager_remove_window`
func window_manager_remove_window(_ wm: WindowManager, _ windowID: UInt32)
{
    border_remove(windowID)

    wm.window.remove(windowID)
}

/// `window_manager_add_window`
func window_manager_add_window(_ wm: WindowManager, _ target: Window)
{
    wm.window.add(target.id, target)
}

/// `window_manager_find_application`
func window_manager_find_application(_ wm: WindowManager, _ pid: pid_t) -> Application?
{
    return wm.application.find(pid)
}

/// `window_manager_remove_application`
func window_manager_remove_application(_ wm: WindowManager, _ pid: pid_t)
{
    wm.application.remove(pid)
}

/// `window_manager_add_application`
func window_manager_add_application(_ wm: WindowManager, _ owner: Application)
{
    wm.application.add(owner.pid, owner)
}

/// `window_manager_find_application_windows`
func window_manager_find_application_windows(_ wm: WindowManager, _ owner: Application) -> [Window]
{
    return wm.window.values.filter { $0.application == owner }
}

/// `window_manager_set_window_insertion`
func window_manager_set_window_insertion(_ sm: SpaceManager, _ target: Window?, _ direction: Int32) -> window_op_error
{
    guard let target else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    let owner = space_manager_find_view(sm, window_space(target.id))
    if owner.layout != VIEW_TREE || owner.tree == nil { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    guard let node = tree_find_window(owner.tree, target.id) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    if owner.insertion_point != 0 && owner.insertion_point != target.id {
        if let insert = tree_find_window(owner.tree, owner.insertion_point) {
            insert.insert_dir = 0
            tree_feedback_hide(insert)
        }
    }

    if direction == node.insert_dir {
        node.insert_dir = 0
        tree_feedback_hide(node)
        owner.insertion_point = 0
        return WINDOW_OP_ERROR_SUCCESS
    }

    node.insert_dir = direction
    owner.insertion_point = target.id
    if space_is_visible(owner.sid) { tree_feedback_show(node, direction) }

    return WINDOW_OP_ERROR_SUCCESS
}

//
// NOTE: Stacking a window onto another puts it into the tabbed container of that window, and turns
// the window into a tabbed container first when it is not a tab yet.
//

/// `window_manager_stack_window`
func window_manager_stack_window(_ sm: SpaceManager, _ wm: WindowManager, _ a: Window, _ b: Window) -> window_op_error
{
    if a.id == b.id { return WINDOW_OP_ERROR_SAME_WINDOW }

    guard let aView = window_manager_find_tree_view(wm, a) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }
    if tree_find_window(aView.tree, a.id) == nil { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    if let bView = window_manager_find_managed_window(wm, b) {
        window_manager_unmanage_window(wm, bView, b)
    } else if window_check_flag(b, WINDOW_FLOAT) {
        if !window_manager_is_window_eligible(b) { return WINDOW_OP_ERROR_INVALID_DST_NODE }
        window_clear_flag(b, WINDOW_FLOAT)
        if window_check_flag(b, WINDOW_STICKY) { window_manager_make_window_sticky(sm, wm, b, false) }
    }

    guard let aCon = tree_find_window(aView.tree, a.id) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    if window_space(b.id) != aView.sid {
        space_manager_move_window_to_space(aView.sid, b)
        _ = space_manager_wait_for_window_on_space(b.id, aView.sid, 200)
    }

    let node = con_create(CON_SPLITH)!
    node.window_id = b.id
    tree_insert_relative(aCon, node, STACK)

    window_manager_add_managed_window(wm, b, aView)
    window_manager_adjust_layer(b, layerValue(.below))
    windowManagerTreeApply(aView)

    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_set_window_layout`
func window_manager_set_window_layout(_ wm: WindowManager, _ target: Window?, _ layout: window_layout) -> window_op_error
{
    guard let target, let owner = window_manager_find_tree_view(wm, target) else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let node = windowManagerTreeActingCon(owner, target) else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }

    let parent = node.parent ?? node

    switch layout {
    case WINDOW_LAYOUT_TABBED:       tree_set_layout(node, CON_TABBED)
    case WINDOW_LAYOUT_SPLITH:       tree_set_layout(node, CON_SPLITH)
    case WINDOW_LAYOUT_SPLITV:       tree_set_layout(node, CON_SPLITV)
    case WINDOW_LAYOUT_SPLIT:        tree_set_layout(node, parent.layout == CON_TABBED ? parent.last_split : parent.layout)
    case WINDOW_LAYOUT_TOGGLE:       tree_toggle_layout(node, false)
    case WINDOW_LAYOUT_TOGGLE_SPLIT: tree_toggle_layout(node, true)
    default:                         break
    }

    tree_flatten(owner.tree)
    windowManagerTreeApply(owner)
    return WINDOW_OP_ERROR_SUCCESS
}

//
// NOTE: Warping onto a window places the window right after it, in the container of that window.
//

/// `window_manager_warp_window`
func window_manager_warp_window(_ sm: SpaceManager, _ wm: WindowManager, _ a: Window, _ b: Window) -> window_op_error
{
    if a.id == b.id { return WINDOW_OP_ERROR_SAME_WINDOW }

    let aView = window_manager_find_tree_view(wm, a)
    let bView = window_manager_find_tree_view(wm, b)
    guard let aView else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let bView else { return WINDOW_OP_ERROR_INVALID_DST_VIEW }

    let aCon = tree_find_window(aView.tree, a.id)
    let bCon = tree_find_window(bView.tree, b.id)
    guard let aCon else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }
    guard let bCon else { return WINDOW_OP_ERROR_INVALID_DST_NODE }

    if aView == bView {
        tree_insert_con(aCon, bCon, TREE_AFTER)
        tree_flatten(aView.tree)
        windowManagerTreeApply(aView)
    } else {
        space_manager_untile_window(aView, a)
        window_manager_remove_managed_window(wm, a.id)
        window_manager_add_managed_window(wm, a, bView)
        space_manager_move_window_to_space(bView.sid, a)
        _ = space_manager_wait_for_window_on_space(a.id, bView.sid, 200)
        _ = space_manager_tile_window_on_space_with_insertion_point(sm, a, bView.sid, b.id)
    }

    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_swap_window`
func window_manager_swap_window(_ wm: WindowManager, _ a: Window, _ b: Window) -> window_op_error
{
    if a.id == b.id { return WINDOW_OP_ERROR_SAME_WINDOW }

    let aView = window_manager_find_tree_view(wm, a)
    let bView = window_manager_find_tree_view(wm, b)
    guard let aView else { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }
    guard let bView else { return WINDOW_OP_ERROR_INVALID_DST_VIEW }

    let aCon = tree_find_window(aView.tree, a.id)
    let bCon = tree_find_window(bView.tree, b.id)
    guard let aCon else { return WINDOW_OP_ERROR_INVALID_SRC_NODE }
    guard let bCon else { return WINDOW_OP_ERROR_INVALID_DST_NODE }

    tree_swap(aCon, bCon)

    if aView != bView {
        let aMoved = windowManagerTreeSetView(wm, aCon, bView)
        let bMoved = windowManagerTreeSetView(wm, bCon, aView)
        windowManagerTreeWaitForView(aMoved, bView)
        windowManagerTreeWaitForView(bMoved, aView)
        windowManagerTreeApply(bView)
    }

    windowManagerTreeApply(aView)
    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_minimize_window`
func window_manager_minimize_window(_ target: Window) -> window_op_error
{
    if !window_can_minimize(target) { return WINDOW_OP_ERROR_CANT_MINIMIZE }
    if window_check_flag(target, WINDOW_MINIMIZE) { return WINDOW_OP_ERROR_ALREADY_MINIMIZED }

    let result = AXUIElementSetAttributeValue(target.ref, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    return result == .success ? WINDOW_OP_ERROR_SUCCESS : WINDOW_OP_ERROR_MINIMIZE_FAILED
}

/// `window_manager_deminimize_window`
func window_manager_deminimize_window(_ target: Window) -> window_op_error
{
    if !window_check_flag(target, WINDOW_MINIMIZE) { return WINDOW_OP_ERROR_NOT_MINIMIZED }

    let result = AXUIElementSetAttributeValue(target.ref, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    return result == .success ? WINDOW_OP_ERROR_SUCCESS : WINDOW_OP_ERROR_DEMINIMIZE_FAILED
}

/// `window_manager_close_window`: presses the close button of the window; false without one.
func window_manager_close_window(_ target: Window) -> Bool
{
    var button: CFTypeRef?
    AXUIElementCopyAttributeValue(target.ref, kAXCloseButtonAttribute as CFString, &button)
    guard let button else { return false }

    AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self), kAXPressAction as CFString)
    return true
}

/// `window_manager_send_window_to_space`
func window_manager_send_window_to_space(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ dstSid: UInt64, _ movedByRule: Bool)
{
    let srcSid = window_space(target.id)
    if srcSid == dstSid { return }

    if space_is_visible(srcSid) && (movedByRule || wm.focused_window_id == target.id) {
        if let next = window_manager_find_window_on_space_by_rank_filtering_window(wm, srcSid, 1, target.id) {
            window_manager_focus_window_with_raise(&next.application.psn, next.id, next.ref)
        } else {
            _SLPSSetFrontProcessWithOptions(&process_manager_global().finder_psn, 0, UInt32(kCPSNoWindows))
        }
    }

    if let owner = window_manager_find_managed_window(wm, target) {
        window_manager_unmanage_window(wm, owner, target)
    }

    space_manager_move_window_to_space(dstSid, target)
    _ = space_manager_wait_for_window_on_space(target.id, dstSid, 200)
    SLSSpaceSetFrontPSN(connection_global(), dstSid, target.application.psn)

    if window_manager_should_manage_window(target) {
        window_manager_manage_window(sm, wm, target, dstSid, 0)
    }

    border_refresh_space(srcSid)
    border_refresh_window_space(target)
}

/// `window_manager_apply_grid`
@discardableResult
func window_manager_apply_grid(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ r: UInt32, _ c: UInt32, _ x: UInt32, _ y: UInt32, _ w: UInt32, _ h: UInt32) -> window_op_error
{
    if window_manager_find_managed_window(wm, target) != nil { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    let did = window_display_id(target.id)
    if did == 0 { return WINDOW_OP_ERROR_INVALID_SRC_VIEW }

    var x = x, y = y, w = w, h = h
    if x >= c     { x = c &- 1 }
    if y >= r     { y = r &- 1 }
    if w <= 0     { w = 1 }
    if h <= 0     { h = 1 }
    if w > c &- x { w = c &- x }
    if h > r &- y { h = r &- y }

    var bounds = display_bounds_constrained(did, false)
    let dview = space_manager_find_view(sm, display_space_id(did))

    if hasViewFlag(dview, VIEW_ENABLE_PADDING) {
        bounds.origin.x    += CGFloat(dview.left_padding)
        bounds.size.width  -= CGFloat(dview.left_padding + dview.right_padding)
        bounds.origin.y    += CGFloat(dview.top_padding)
        bounds.size.height -= CGFloat(dview.top_padding + dview.bottom_padding)
    }

    if hasViewFlag(dview, VIEW_ENABLE_GAP) {
        let gap = CGFloat(dview.window_gap)

        if x > 0 {
            bounds.origin.x   += gap
            bounds.size.width -= gap
        }

        if y > 0 {
            bounds.origin.y    += gap
            bounds.size.height -= gap
        }

        if c > x &+ w { bounds.size.width  -= gap }
        if r > y &+ h { bounds.size.height -= gap }
    }

    let cw = Float(bounds.size.width / CGFloat(c))
    let ch = Float(bounds.size.height / CGFloat(r))
    let fx = Float(bounds.origin.x + bounds.size.width  - CGFloat(cw * Float(c &- x)))
    let fy = Float(bounds.origin.y + bounds.size.height - CGFloat(ch * Float(r &- y)))
    let fw = cw * Float(w)
    let fh = ch * Float(h)

    window_manager_animate_window(window_capture(window: target, x: fx, y: fy, w: fw, h: fh))
    return WINDOW_OP_ERROR_SUCCESS
}

/// `window_manager_make_window_floating`
func window_manager_make_window_floating(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ shouldFloat: Bool, _ force: Bool)
{
    if !window_manager_is_window_eligible(target) { return }

    if !force {
        if !window_is_standard(target) || !window_level_is_standard(target) || !window_can_move(target) {
            if !window_check_rule_flag(target, WINDOW_RULE_MANAGED) {
                return
            }
        }
    }

    if shouldFloat {
        if let owner = window_manager_find_managed_window(wm, target) {
            window_manager_unmanage_window(wm, owner, target)
        }
        window_set_flag(target, WINDOW_FLOAT)
    } else {
        window_clear_flag(target, WINDOW_FLOAT)

        if !window_check_flag(target, WINDOW_STICKY) {
            if window_manager_should_manage_window(target) && window_manager_find_managed_window(wm, target) == nil {
                window_manager_manage_window(sm, wm, target, space_manager_active_space(), 0)
            }
        }
    }
}

/// `window_manager_make_window_sticky`
func window_manager_make_window_sticky(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ shouldSticky: Bool)
{
    if !window_manager_is_window_eligible(target) { return }

    if shouldSticky {
        if scripting_addition_set_sticky(target.id, true) {
            if let owner = window_manager_find_managed_window(wm, target) {
                window_manager_unmanage_window(wm, owner, target)
            }
            window_set_flag(target, WINDOW_STICKY)
        }
    } else {
        if scripting_addition_set_sticky(target.id, false) {
            window_clear_flag(target, WINDOW_STICKY)

            if !window_check_flag(target, WINDOW_FLOAT) {
                if window_manager_should_manage_window(target) && window_manager_find_managed_window(wm, target) == nil {
                    window_manager_manage_window(sm, wm, target, space_manager_active_space(), 0)
                }
            }
        }
    }
}

/// `window_manager_toggle_window_shadow`
func window_manager_toggle_window_shadow(_ target: Window)
{
    let shadow = !window_check_flag(target, WINDOW_SHADOW)
    if scripting_addition_set_shadow(target.id, shadow) {
        if shadow {
            window_set_flag(target, WINDOW_SHADOW)
        } else {
            window_clear_flag(target, WINDOW_SHADOW)
        }
    }
}

// NATIVE_FULLSCREEN_WAIT_ITERATIONS
private let nativeFullscreenWaitIterations = 30

/// `window_manager_wait_for_native_fullscreen_transition`
func window_manager_wait_for_native_fullscreen_transition()
{
    var i = 0
    while i < nativeFullscreenWaitIterations && !space_is_user(space_manager_active_space()) {

        //
        // NOTE(asmvik): Window has exited native-fullscreen mode.
        // We need to spin lock until the display is finished animating
        // because we are not actually able to interact with the window.
        //
        // The display_manager API does not work on macOS Monterey.
        //
        // NOTE: The wait is bounded, because the space we wait for may never become active
        // (e.g. the transition was cancelled), and this blocks the event loop.
        //

        usleep(100000)
        i += 1
    }
}

/// `window_manager_toggle_window_native_fullscreen`
func window_manager_toggle_window_native_fullscreen(_ target: Window)
{
    let sid = window_space(target.id)

    //
    // NOTE(asmvik): The window must become the focused window
    // before we can change its fullscreen attribute. We focus the
    // window and spin lock until a potential space animation has finished.
    //

    window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
    var i = 0
    while i < nativeFullscreenWaitIterations && sid != space_manager_active_space() { usleep(100000); i += 1 }

    if !window_is_fullscreen(target) {
        AXUIElementSetAttributeValue(target.ref, axFullscreenAttribute as CFString, kCFBooleanTrue)
    } else {
        AXUIElementSetAttributeValue(target.ref, axFullscreenAttribute as CFString, kCFBooleanFalse)
    }

    //
    // NOTE(asmvik): We toggled the fullscreen attribute and must
    // now spin lock until the post-exit space animation has finished.
    //

    window_manager_wait_for_native_fullscreen_transition()
}

/// `window_manager_toggle_window_zoom`
private func windowManagerToggleWindowZoom(_ wm: WindowManager, _ target: Window, _ zoom: con_zoom)
{
    guard let owner = window_manager_find_tree_view(wm, target) else { return }

    guard let node = tree_find_window(owner.tree, target.id), node != owner.tree else { return }

    var zoom = zoom
    if zoom == CON_ZOOM_PARENT && node.parent == owner.tree { zoom = CON_ZOOM_FULLSCREEN }

    node.zoom = node.zoom == zoom ? CON_ZOOM_NONE : zoom
    windowManagerTreeApply(owner)
}

/// `window_manager_toggle_window_zoom_parent`
func window_manager_toggle_window_zoom_parent(_ wm: WindowManager, _ target: Window)
{
    windowManagerToggleWindowZoom(wm, target, CON_ZOOM_PARENT)
}

/// `window_manager_toggle_window_zoom_fullscreen`
func window_manager_toggle_window_zoom_fullscreen(_ wm: WindowManager, _ target: Window)
{
    windowManagerToggleWindowZoom(wm, target, CON_ZOOM_FULLSCREEN)
}

/// `window_manager_toggle_window_windowed_fullscreen`
func window_manager_toggle_window_windowed_fullscreen(_ target: Window)
{
    let did = window_display_id(target.id)
    if did == 0 { return }

    if window_check_flag(target, WINDOW_WINDOWED) {
        window_clear_flag(target, WINDOW_WINDOWED)
        let frame = target.windowed_frame
        window_manager_animate_window(window_capture(window: target, x: Float(frame.origin.x), y: Float(frame.origin.y), w: Float(frame.size.width), h: Float(frame.size.height)))
    } else {
        window_set_flag(target, WINDOW_WINDOWED)
        target.windowed_frame = target.frame
        let bounds = display_bounds_constrained(did, true)
        window_manager_animate_window(window_capture(window: target, x: Float(bounds.origin.x), y: Float(bounds.origin.y), w: Float(bounds.size.width), h: Float(bounds.size.height)))
    }
}

/// `window_manager_toggle_window_expose`
func window_manager_toggle_window_expose(_ target: Window)
{
    window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
    CoreDock.sendNotification("com.apple.expose.front.awake")
}

/// `window_manager_toggle_window_pip`
func window_manager_toggle_window_pip(_ sm: SpaceManager, _ target: Window)
{
    let did = window_display_id(target.id)
    if did == 0 { return }

    let sid = display_space_id(did)
    let dview = space_manager_find_view(sm, sid)

    var bounds = display_bounds_constrained(did, false)
    if hasViewFlag(dview, VIEW_ENABLE_PADDING) {
        bounds.origin.x    += CGFloat(dview.left_padding)
        bounds.size.width  -= CGFloat(dview.left_padding + dview.right_padding)
        bounds.origin.y    += CGFloat(dview.top_padding)
        bounds.size.height -= CGFloat(dview.top_padding + dview.bottom_padding)
    }

    scripting_addition_scale_window(target.id, Float(bounds.origin.x), Float(bounds.origin.y), Float(bounds.size.width), Float(bounds.size.height))
}

/// `window_manager_validate_windows_on_space`
private func windowManagerValidateWindowsOnSpace(_ wm: WindowManager, _ owner: View, _ windowList: [UInt32])
{
    let viewWindowList = view_find_window_list(owner)

    for i in 0..<viewWindowList.count {
        if windowList.contains(viewWindowList[i]) { continue }

        guard let target = window_manager_find_window(wm, viewWindowList[i]) else { continue }

        //
        // @cleanup
        //
        // :AXBatching
        //
        // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
        // making sure that each window is only moved and resized a single time, when the final layout has been computed.
        // This is necessary to make sure that we do not call the AX API for each modification to the tree.
        //

        view_remove_window(owner, target)
        window_manager_adjust_layer(target, layerValue(.normal))
        window_manager_remove_managed_window(wm, target.id)
        window_manager_purify_window(wm, target)

        setViewFlag(owner, VIEW_IS_DIRTY)
    }
}

/// `window_manager_check_for_windows_on_space`
private func windowManagerCheckForWindowsOnSpace(_ wm: WindowManager, _ owner: View, _ windowList: [UInt32])
{
    for windowID in windowList {
        guard let target = window_manager_find_window(wm, windowID), window_manager_should_manage_window(target) else { continue }

        let existingView = window_manager_find_managed_window(wm, target)
        if let existingView, existingView.layout != VIEW_FLOAT, existingView != owner {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_remove_window(existingView, target)
            window_manager_adjust_layer(target, layerValue(.normal))
            window_manager_remove_managed_window(wm, target.id)
            window_manager_purify_window(wm, target)
            setViewFlag(existingView, VIEW_IS_DIRTY)
        }

        if existingView == nil || (existingView!.layout != VIEW_FLOAT && existingView != owner) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_add_window(owner, target, 0)
            window_manager_adjust_layer(target, layerValue(.below))
            window_manager_add_managed_window(wm, target, owner)
            setViewFlag(owner, VIEW_IS_DIRTY)
        }
    }
}

/// The windows of space_window_list (without minimized windows) as an array.
private func spaceWindows(_ sid: UInt64) -> [UInt32]?
{
    var count: Int32 = 0
    return space_window_list(sid, &count, false)
}

/// `window_manager_validate_and_check_for_windows_on_space`
func window_manager_validate_and_check_for_windows_on_space(_ sm: SpaceManager, _ wm: WindowManager, _ sid: UInt64)
{
    let owner = space_manager_find_view(sm, sid)
    if owner.layout == VIEW_FLOAT { return }

    let windowList = spaceWindows(sid) ?? []
    windowManagerValidateWindowsOnSpace(wm, owner, windowList)
    windowManagerCheckForWindowsOnSpace(wm, owner, windowList)

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    if space_is_visible(owner.sid) && view_is_dirty(owner) {
        view_flush(owner)
    }
}

/// `window_manager_correct_for_mission_control_changes`
func window_manager_correct_for_mission_control_changes(_ sm: SpaceManager, _ wm: WindowManager)
{
    let displays = displayManagerActiveDisplays()

    let animationDuration = wm.window_animation_duration
    wm.window_animation_duration = 0.0

    for did in displays {
        guard let spaceList = displaySpaces(did) else { continue }

        let sid = display_space_id(did)
        for space in spaceList {
            if space == sid {
                window_manager_validate_and_check_for_windows_on_space(sm, wm, sid)
            } else {
                space_manager_mark_view_invalid(sm, space)
            }
        }
    }

    wm.window_animation_duration = animationDuration
}

/// `window_manager_handle_display_add_and_remove`
func window_manager_handle_display_add_and_remove(_ sm: SpaceManager, _ wm: WindowManager, _ did: UInt32)
{
    guard let spaceList = displaySpaces(did) else { return }

    for space in spaceList where space_is_user(space) {
        if let windowList = spaceWindows(space) {
            let owner = space_manager_find_view(sm, space)
            if owner.layout != VIEW_FLOAT {
                windowManagerCheckForWindowsOnSpace(wm, owner, windowList)
            }
        }
        break
    }

    let sid = display_space_id(did)
    for space in spaceList {
        if space == sid {
            space_manager_refresh_view(sm, sid)
        } else {
            space_manager_mark_view_invalid(sm, space)
        }
    }
}

/// `window_manager_init`
func window_manager_init(_ wm: WindowManager)
{
    let systemElement = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemElement, 1.0)
    wm.system_element = systemElement

    wm.ffm_mode = FFM_DISABLED
    wm.purify_mode = PURIFY_DISABLED
    wm.window_origin_mode = WINDOW_ORIGIN_DEFAULT
    wm.enable_mff = false
    wm.enable_window_opacity = false
    wm.menubar_opacity = 1.0
    wm.active_window_opacity = 1.0
    wm.normal_window_opacity = 1.0
    wm.window_opacity_duration = 0.0
    wm.window_animation_duration = 0.0
    wm.window_animation_easing = Int32(ease_out_circ_type.rawValue)
    wm.insert_feedback_color = rgba_color_from_hex(0xffd75f5f)
    wm.enable_window_border = false
    wm.window_border_hide_single = false
    wm.window_border_width = 4.0
    wm.active_window_border_color = rgba_color_from_hex(0xffe1e3e4)
    wm.normal_window_border_color = rgba_color_from_hex(0xff494d64)
    wm.focus_wrapping = FOCUS_WRAPPING_ON
    wm.enable_tab_bar = true
    wm.tab_bar_height = 24
    wm.tab_bar_offset = 0
    wm.tab_bar_icons = true
    wm.tab_bar_style = TAB_BAR_STYLE_GLASS
    wm.tab_bar_backdrop = TAB_BAR_BACKDROP_GLASS
    wm.tab_bar_card_padding = 6
    wm.tab_bar_window_radius = 16
    wm.tab_bar_focused_color = rgba_color_from_hex(0xff285577)
    wm.tab_bar_focused_text_color = rgba_color_from_hex(0xffffffff)
    wm.tab_bar_inactive_color = rgba_color_from_hex(0xff5f676a)
    wm.tab_bar_inactive_text_color = rgba_color_from_hex(0xffffffff)
    wm.tab_bar_unfocused_color = rgba_color_from_hex(0xff222222)
    wm.tab_bar_unfocused_text_color = rgba_color_from_hex(0xff888888)
    wm.tab_bar_backdrop_color = rgba_color_from_hex(0xff48484a)
    _ = TAB_BAR_DEFAULT_FONT.withCString { tab_bar_set_font(UnsafeMutablePointer(mutating: $0)) }
    wm.scratchpad_exclusive = false
    wm.scratchpad_raise = false
    wm.scratchpad_below = false
    wm.scratchpad_grid = (0, 0, 0, 0, 0, 0)

    //
    // NOTE: The tables of the window manager are keyed by window ids and pids (hash_wm and compare_wm).
    //

    wm.application = Table(capacity: 150)
    wm.window = Table(capacity: 150)
    wm.managed_window = Table(capacity: 150)
    wm.window_lost_focused_event = Table(capacity: 150)
    wm.application_lost_front_switched_event = Table(capacity: 150)
}

/// `window_manager_begin`
func window_manager_begin(_ sm: SpaceManager, _ wm: WindowManager)
{
    autoreleasepool {
        for candidate in process_manager_global().process.values {
            if workspace_application_is_observable(candidate) {
                let created = application_create(candidate)

                if application_observe(created) {
                    window_manager_add_application(wm, created)
                    _ = window_manager_add_existing_application_windows(sm, wm, created, -1)
                } else {
                    application_unobserve(created)
                    application_destroy(created)
                }
            } else {
                debug("window_manager_begin: \(describe(candidate)) is not observable, subscribing to activationPolicy changes\n")
                workspace_application_observe_activation_policy(candidate)
            }
        }
    }

    if let target = window_manager_focused_window(wm) {
        wm.last_window_id = target.id
        wm.focused_window_id = target.id
        wm.focused_window_psn = target.application.psn
        window_manager_set_window_opacity(wm, target, wm.active_window_opacity)
    }
}
