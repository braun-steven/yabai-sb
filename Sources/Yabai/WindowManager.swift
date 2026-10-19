import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import AppKit
import YabaiCore

//
// NOTE: WindowManager owns the application, window and managed-window tables, window command state, and reconciliation
// after Mission Control and display changes.
//

/// The outcome of a window command: success, or why it failed (`Response.failUnmanagedWindow` words the failures of
/// unmanaged windows).
enum WindowOperationResult: Sendable
{
    case success
    case invalidSourceView
    case invalidSourceNode
    case invalidDestinationView
    case invalidDestinationNode
    case invalidOperation
    case sameWindow
    case cannotMinimize
    case alreadyMinimized
    case minimizeFailed
    case notMinimized
    case deminimizeFailed
}

/// A value of `window --layout`, named by its token.
enum WindowLayout: String, CaseIterable, Sendable
{
    case tabbed
    case split
    case toggle
    case splitH      = "splith"
    case splitV      = "splitv"
    case toggleSplit = "toggle-split"
}

/// Focus follows mouse (`config focus_follows_mouse`): off, focus the window under the cursor, or also raise it. The
/// raw values are the names the setting prints; `off` sets `.disabled`.
enum FocusFollowsMouse: String, Sendable
{
    case disabled
    case autofocus
    case autoraise
}

/// Which windows lose their shadow (`config window_shadow`, named by its values): none, the managed ones, or all.
enum PurifyMode: String, CaseIterable, Sendable
{
    case disabled = "on"
    case managed  = "float"
    case always   = "off"
}

/// The space a new window is placed on (`config window_origin_display`): where macOS put it, the focused space, or the
/// space under the cursor.
enum WindowOrigin: String, CaseIterable, Sendable
{
    case `default`
    case focused
    case cursor
}

/// The window level of a sub-layer: LAYER_AUTO is 0, the others are CGWindowLevelKey values (which Swift does not import
/// from the C macros that named them).
extension WindowLayer
{
    var level: Int32
    {
        switch self {
        case .auto:   0
        case .below:  CGWindowLevelKey.backstopMenu.rawValue
        case .normal: CGWindowLevelKey.normalWindow.rawValue
        case .above:  CGWindowLevelKey.floatingWindow.rawValue
        }
    }
}

/// `struct scratchpad`
struct Scratchpad
{
    var label: String
    var window: Window
}

/// `struct window_manager`
final class WindowManager
{
    var system_element: AXUIElement?
    var application: [pid_t: Application] = [:]
    var window: [WindowID: Window] = [:]
    var managed_window: [WindowID: View] = [:]
    var window_lost_focused_event = Set<WindowID>()
    var application_lost_front_switched_event = Set<pid_t>()
    var rules: [Rule] = []
    var applications_to_refresh: [Application] = []
    var focused_window_id: WindowID?
    var focused_window_psn = ProcessSerialNumber()
    var pending_focus_window_id: WindowID?
    var pending_focus_time: UInt64 = 0
    var last_window_id: WindowID?
    var enable_mff = false
    var ffm_mode = FocusFollowsMouse.disabled
    var purify_mode = PurifyMode.disabled
    var window_origin_mode = WindowOrigin.default
    var enable_window_opacity = false
    var menubar_opacity: Float = 0
    var active_window_opacity: Float = 0
    var normal_window_opacity: Float = 0
    var window_opacity_duration: Float = 0
    var window_animation_duration: Float = 0
    var window_animation_easing = AnimationEasing.easeInSine
    var insert_feedback_color = rgba_color()
    var enable_window_border = false
    var window_border_hide_single = false
    var window_border_width: Float = 0
    var active_window_border_color = rgba_color()
    var normal_window_border_color = rgba_color()
    var focus_wrapping = FocusWrapping.off
    var enable_tab_bar = false
    var tab_bar_height: Int = 0
    var tab_bar_offset: Int = 0
    var tab_bar_icons = false
    var tab_bar_style = TabBarStyle.glass
    var tab_bar_appearance = TabBarAppearance.dark
    var tab_bar_backdrop = TabBarBackdrop.off
    var tab_bar_card_padding: Int = 0
    var tab_bar_window_radius: Int = 0
    var tab_bar_font_name = ""
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
    var tab_bar_focused_text_color_custom = false
    var tab_bar_inactive_text_color_custom = false
    var tab_bar_unfocused_text_color_custom = false
    var scratchpad_window: [Scratchpad] = []
    var scratchpad_exclusive = false
    var scratchpad_raise = false
    var scratchpad_below = false
    var scratchpad_grid = Grid()
}

/// `g_window_manager` (see the NOTE of g_display_manager)
nonisolated(unsafe) let g_window_manager = WindowManager()

func window_manager_global() -> WindowManager
{
    g_window_manager
}

extension WindowManager
{
    static var shared: WindowManager { g_window_manager }
}

// MOUSE_EVENT_MASK (mouse_handler.h, which Swift does not import: the macro is built from other macros)
let mouseEventMask: UInt32 =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << DockSwipe.eventType)

// MOUSE_EVENT_MASK_FFM
let mouseEventMaskFFM: UInt32 = mouseEventMask | (1 << CGEventType.mouseMoved.rawValue)

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

/// `window_manager_find_lost_front_switched_event`
func window_manager_find_lost_front_switched_event(_ wm: WindowManager, _ pid: pid_t) -> Bool
{
    return wm.application_lost_front_switched_event.contains(pid)
}

/// `window_manager_remove_lost_front_switched_event`
func window_manager_remove_lost_front_switched_event(_ wm: WindowManager, _ pid: pid_t)
{
    wm.application_lost_front_switched_event.remove(pid)
}

/// `window_manager_add_lost_front_switched_event`
func window_manager_add_lost_front_switched_event(_ wm: WindowManager, _ pid: pid_t)
{
    wm.application_lost_front_switched_event.insert(pid)
}

/// `window_manager_find_lost_focused_event`
func window_manager_find_lost_focused_event(_ wm: WindowManager, _ windowID: WindowID) -> Bool
{
    return wm.window_lost_focused_event.contains(windowID)
}

/// `window_manager_remove_lost_focused_event`
func window_manager_remove_lost_focused_event(_ wm: WindowManager, _ windowID: WindowID)
{
    wm.window_lost_focused_event.remove(windowID)
}

/// `window_manager_add_lost_focused_event`
func window_manager_add_lost_focused_event(_ wm: WindowManager, _ windowID: WindowID)
{
    wm.window_lost_focused_event.insert(windowID)
}

/// `window_manager_find_window`
func window_manager_find_window(_ wm: WindowManager, _ windowID: WindowID) -> Window?
{
    return wm.window[windowID]
}

/// `window_manager_remove_window`
func window_manager_remove_window(_ wm: WindowManager, _ windowID: WindowID)
{
    border_remove(windowID)

    wm.window.removeValue(forKey: windowID)
}

/// `window_manager_add_window`
func window_manager_add_window(_ wm: WindowManager, _ target: Window)
{
    if wm.window[target.id] == nil { wm.window[target.id] = target }
}

/// `window_manager_find_application`
func window_manager_find_application(_ wm: WindowManager, _ pid: pid_t) -> Application?
{
    return wm.application[pid]
}

/// `window_manager_remove_application`
func window_manager_remove_application(_ wm: WindowManager, _ pid: pid_t)
{
    wm.application.removeValue(forKey: pid)
}

/// `window_manager_add_application`
func window_manager_add_application(_ wm: WindowManager, _ owner: Application)
{
    if wm.application[owner.pid] == nil { wm.application[owner.pid] = owner }
}

/// `window_manager_find_application_windows`: the windows of the application in id order.
func window_manager_find_application_windows(_ wm: WindowManager, _ owner: Application) -> [Window]
{
    return wm.window.values.filter { $0.application == owner }.sorted { $0.id < $1.id }
}

/// `window_manager_set_window_insertion`
func window_manager_set_window_insertion(_ sm: SpaceManager, _ target: Window?, _ direction: InsertDirection) -> WindowOperationResult
{
    guard let target else { return .invalidSourceView }

    guard let sid = target.id.space else { return .invalidSourceView }
    let owner = space_manager_find_view(sm, sid)
    if owner.layout != .tree || owner.tree == nil { return .invalidSourceView }

    guard let node = owner.tree?.find(target.id) else { return .invalidSourceNode }

    if owner.insertionPoint != nil && owner.insertionPoint != target.id {
        if let insert = owner.tree?.find(owner.insertionPoint) {
            insert.insertDirection = nil
            insert.hideFeedback()
        }
    }

    if direction == node.insertDirection {
        node.insertDirection = nil
        node.hideFeedback()
        owner.insertionPoint = nil
        return .success
    }

    node.insertDirection = direction
    owner.insertionPoint = target.id
    if space_is_visible(owner.sid) { node.showFeedback(direction: direction) }

    return .success
}

//
// NOTE: Stacking a window onto another puts it into the tabbed container of that window, and turns
// the window into a tabbed container first when it is not a tab yet.
//

/// `window_manager_stack_window`
func window_manager_stack_window(_ sm: SpaceManager, _ wm: WindowManager, _ a: Window, _ b: Window) -> WindowOperationResult
{
    if a.id == b.id { return .sameWindow }

    guard let aView = wm.treeView(for: a) else { return .invalidSourceNode }
    if aView.tree?.find(a.id) == nil { return .invalidSourceNode }

    if let bView = wm.managedView(for: b) {
        wm.unmanageWindow(b, from: bView)
    } else if b.isFloating {
        if !b.isEligibleForManagement { return .invalidDestinationNode }
        b.isFloating = false
        if b.isSticky { window_manager_make_window_sticky(sm, wm, b, false) }
    }

    guard let aCon = aView.tree?.find(a.id) else { return .invalidSourceNode }

    if b.id.space != aView.sid {
        space_manager_move_window_to_space(aView.sid, b)
        _ = space_manager_wait_for_window_on_space(b.id, aView.sid, 200)
    }

    let node = Con(windowID: b.id)
    aCon.insert(node, toward: .stack)

    wm.addManagedWindow(b, to: aView)
    b.adjustLayer(to: .below)
    wm.treeApply(aView)

    return .success
}

/// `window_manager_set_window_layout`
func window_manager_set_window_layout(_ wm: WindowManager, _ target: Window?, _ layout: WindowLayout) -> WindowOperationResult
{
    guard let target, let owner = wm.treeView(for: target) else { return .invalidSourceView }
    guard let node = wm.treeActingCon(in: owner, for: target) else { return .invalidSourceNode }

    let parent = node.parent ?? node

    switch layout {
    case .tabbed:      node.setLayout(.tabbed)
    case .splitH:      node.setLayout(.splitH)
    case .splitV:      node.setLayout(.splitV)
    case .split:       node.setLayout(parent.layout == .tabbed ? parent.lastSplit : parent.layout)
    case .toggle:      _ = node.toggleLayout(splitOnly: false)
    case .toggleSplit: _ = node.toggleLayout(splitOnly: true)
    }

    owner.tree!.flatten()
    wm.treeApply(owner)
    return .success
}

//
// NOTE: Warping onto a window places the window right after it, in the container of that window.
//

/// `window_manager_warp_window`
func window_manager_warp_window(_ sm: SpaceManager, _ wm: WindowManager, _ a: Window, _ b: Window) -> WindowOperationResult
{
    if a.id == b.id { return .sameWindow }

    let aView = wm.treeView(for: a)
    let bView = wm.treeView(for: b)
    guard let aView else { return .invalidSourceView }
    guard let bView else { return .invalidDestinationView }

    let aCon = aView.tree?.find(a.id)
    let bCon = bView.tree?.find(b.id)
    guard let aCon else { return .invalidSourceNode }
    guard let bCon else { return .invalidDestinationNode }

    if aView == bView {
        aCon.place(.after, of: bCon)
        aView.tree!.flatten()
        wm.treeApply(aView)
    } else {
        space_manager_untile_window(aView, a)
        wm.removeManagedWindow(a.id)
        wm.addManagedWindow(a, to: bView)
        space_manager_move_window_to_space(bView.sid, a)
        _ = space_manager_wait_for_window_on_space(a.id, bView.sid, 200)
        _ = space_manager_tile_window_on_space_with_insertion_point(sm, a, bView.sid, b.id)
    }

    return .success
}

/// `window_manager_swap_window`
func window_manager_swap_window(_ wm: WindowManager, _ a: Window, _ b: Window) -> WindowOperationResult
{
    if a.id == b.id { return .sameWindow }

    let aView = wm.treeView(for: a)
    let bView = wm.treeView(for: b)
    guard let aView else { return .invalidSourceView }
    guard let bView else { return .invalidDestinationView }

    let aCon = aView.tree?.find(a.id)
    let bCon = bView.tree?.find(b.id)
    guard let aCon else { return .invalidSourceNode }
    guard let bCon else { return .invalidDestinationNode }

    aCon.swap(with: bCon)

    if aView != bView {
        let aMoved = wm.treeSetView(aCon, to: bView)
        let bMoved = wm.treeSetView(bCon, to: aView)
        wm.treeWaitForView(aMoved, bView)
        wm.treeWaitForView(bMoved, aView)
        wm.treeApply(bView)
    }

    wm.treeApply(aView)
    return .success
}

/// `window_manager_minimize_window`
func window_manager_minimize_window(_ target: Window) -> WindowOperationResult
{
    if !target.canMinimize { return .cannotMinimize }
    if target.isMinimized { return .alreadyMinimized }

    let result = AXUIElementSetAttributeValue(target.ref, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    return result == .success ? .success : .minimizeFailed
}

/// `window_manager_deminimize_window`
func window_manager_deminimize_window(_ target: Window) -> WindowOperationResult
{
    if !target.isMinimized { return .notMinimized }

    let result = AXUIElementSetAttributeValue(target.ref, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    return result == .success ? .success : .deminimizeFailed
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
func window_manager_send_window_to_space(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ dstSid: SpaceID, _ movedByRule: Bool)
{
    let srcSid = target.id.space
    if srcSid == dstSid { return }

    if let srcSid, space_is_visible(srcSid) && (movedByRule || wm.focused_window_id == target.id) {
        if let next = window_manager_find_window_on_space_by_rank_filtering_window(wm, srcSid, 1, target.id) {
            window_manager_focus_window_with_raise(&next.application.psn, next.id, next.ref)
        } else {
            _SLPSSetFrontProcessWithOptions(&process_manager_global().finder_psn, 0, FrontProcessMode.noWindows.rawValue)
        }
    }

    if let owner = wm.managedView(for: target) {
        wm.unmanageWindow(target, from: owner)
    }

    space_manager_move_window_to_space(dstSid, target)
    _ = space_manager_wait_for_window_on_space(target.id, dstSid, 200)
    SLSSpaceSetFrontPSN(connection_global(), dstSid.rawValue, target.application.psn)

    if target.shouldBeManaged {
        wm.manageWindow(target, on: dstSid, inserting: nil)
    }

    border_refresh_space(srcSid)
    border_refresh_window_space(target)
}

/// `window_manager_apply_grid`
@discardableResult
func window_manager_apply_grid(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ grid: Grid) -> WindowOperationResult
{
    let r = grid.rows, c = grid.columns
    if wm.managedView(for: target) != nil { return .invalidSourceView }

    guard let did = target.id.displayID else { return .invalidSourceView }

    var x = grid.x, y = grid.y, w = grid.width, h = grid.height
    if x >= c     { x = c &- 1 }
    if y >= r     { y = r &- 1 }
    if w <= 0     { w = 1 }
    if h <= 0     { h = 1 }
    if w > c &- x { w = c &- x }
    if h > r &- y { h = r &- y }

    var bounds = display_bounds_constrained(did, false)

    //
    // NOTE: Without a space of the display, the grid is applied without padding and gaps (the view of such a
    // space has none).
    //

    let dview = display_space_id(did).map { space_manager_find_view(sm, $0) }

    if let dview, dview.isPaddingEnabled {
        bounds.origin.x    += CGFloat(dview.leftPadding)
        bounds.size.width  -= CGFloat(dview.leftPadding + dview.rightPadding)
        bounds.origin.y    += CGFloat(dview.topPadding)
        bounds.size.height -= CGFloat(dview.topPadding + dview.bottomPadding)
    }

    if let dview, dview.isGapEnabled {
        let gap = CGFloat(dview.windowGap)

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
    return .success
}

/// `window_manager_make_window_floating`
func window_manager_make_window_floating(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ shouldFloat: Bool, _ force: Bool)
{
    if !target.isEligibleForManagement { return }

    if !force {
        if !target.isStandard || !target.isStandardLevel || !target.canMove {
            if !target.isManagedByRule {
                return
            }
        }
    }

    if shouldFloat {
        if let owner = wm.managedView(for: target) {
            wm.unmanageWindow(target, from: owner)
        }
        target.isFloating = true
    } else {
        target.isFloating = false

        if !target.isSticky {
            if target.shouldBeManaged && wm.managedView(for: target) == nil {
                if let sid = space_manager_active_space() { wm.manageWindow(target, on: sid, inserting: nil) }
            }
        }
    }
}

/// `window_manager_make_window_sticky`
func window_manager_make_window_sticky(_ sm: SpaceManager, _ wm: WindowManager, _ target: Window, _ shouldSticky: Bool)
{
    if !target.isEligibleForManagement { return }

    if shouldSticky {
        if scripting_addition_set_sticky(target.id, true) {
            if let owner = wm.managedView(for: target) {
                wm.unmanageWindow(target, from: owner)
            }
            target.isSticky = true
        }
    } else {
        if scripting_addition_set_sticky(target.id, false) {
            target.isSticky = false

            if !target.isFloating {
                if target.shouldBeManaged && wm.managedView(for: target) == nil {
                    if let sid = space_manager_active_space() { wm.manageWindow(target, on: sid, inserting: nil) }
                }
            }
        }
    }
}

/// `window_manager_toggle_window_shadow`
func window_manager_toggle_window_shadow(_ target: Window)
{
    let shadow = !target.hasShadow
    if scripting_addition_set_shadow(target.id, shadow) {
        target.hasShadow = shadow
    }
}

// NATIVE_FULLSCREEN_WAIT_ITERATIONS
private let nativeFullscreenWaitIterations = 30

/// `window_manager_wait_for_native_fullscreen_transition`
func window_manager_wait_for_native_fullscreen_transition()
{
    var i = 0
    while i < nativeFullscreenWaitIterations && !(space_manager_active_space().map(space_is_user) ?? false) {

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
    let sid = target.id.space

    //
    // NOTE(asmvik): The window must become the focused window
    // before we can change its fullscreen attribute. We focus the
    // window and spin lock until a potential space animation has finished.
    //

    window_manager_focus_window_with_raise(&target.application.psn, target.id, target.ref)
    var i = 0
    while i < nativeFullscreenWaitIterations && sid != space_manager_active_space() { usleep(100000); i += 1 }

    if !target.reportsFullscreen {
        AXUIElementSetAttributeValue(target.ref, Window.fullscreenAttribute as CFString, kCFBooleanTrue)
    } else {
        AXUIElementSetAttributeValue(target.ref, Window.fullscreenAttribute as CFString, kCFBooleanFalse)
    }

    //
    // NOTE(asmvik): We toggled the fullscreen attribute and must
    // now spin lock until the post-exit space animation has finished.
    //

    window_manager_wait_for_native_fullscreen_transition()
}

/// `window_manager_toggle_window_zoom`
private func windowManagerToggleWindowZoom(_ wm: WindowManager, _ target: Window, _ zoom: ConZoom)
{
    guard let owner = wm.treeView(for: target) else { return }

    guard let node = owner.tree?.find(target.id), node != owner.tree else { return }

    var zoom = zoom
    if zoom == .parent && node.parent == owner.tree { zoom = .fullscreen }

    node.zoom = node.zoom == zoom ? .none : zoom
    wm.treeApply(owner)
}

/// `window_manager_toggle_window_zoom_parent`
func window_manager_toggle_window_zoom_parent(_ wm: WindowManager, _ target: Window)
{
    windowManagerToggleWindowZoom(wm, target, .parent)
}

/// `window_manager_toggle_window_zoom_fullscreen`
func window_manager_toggle_window_zoom_fullscreen(_ wm: WindowManager, _ target: Window)
{
    windowManagerToggleWindowZoom(wm, target, .fullscreen)
}

/// `window_manager_toggle_window_windowed_fullscreen`
func window_manager_toggle_window_windowed_fullscreen(_ target: Window)
{
    guard let did = target.id.displayID else { return }

    if target.isWindowed {
        target.isWindowed = false
        let frame = target.windowed_frame
        window_manager_animate_window(window_capture(window: target, x: Float(frame.origin.x), y: Float(frame.origin.y), w: Float(frame.size.width), h: Float(frame.size.height)))
    } else {
        target.isWindowed = true
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
    guard let did = target.id.displayID else { return }

    //
    // NOTE: Without a space of the display, the bounds are not reduced by padding (the view of such a space has none).
    //

    let dview = display_space_id(did).map { space_manager_find_view(sm, $0) }

    var bounds = display_bounds_constrained(did, false)
    if let dview, dview.isPaddingEnabled {
        bounds.origin.x    += CGFloat(dview.leftPadding)
        bounds.size.width  -= CGFloat(dview.leftPadding + dview.rightPadding)
        bounds.origin.y    += CGFloat(dview.topPadding)
        bounds.size.height -= CGFloat(dview.topPadding + dview.bottomPadding)
    }

    scripting_addition_scale_window(target.id, Float(bounds.origin.x), Float(bounds.origin.y), Float(bounds.size.width), Float(bounds.size.height))
}

/// `window_manager_validate_windows_on_space`
private func windowManagerValidateWindowsOnSpace(_ wm: WindowManager, _ owner: View, _ windowList: [WindowID])
{
    let viewWindowList = owner.windowIDs

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

        owner.remove(target)
        target.adjustLayer(to: .normal)
        wm.removeManagedWindow(target.id)
        wm.purifyWindow(target)

        owner.isDirty = true
    }
}

/// `window_manager_check_for_windows_on_space`
private func windowManagerCheckForWindowsOnSpace(_ wm: WindowManager, _ owner: View, _ windowList: [WindowID])
{
    for windowID in windowList {
        guard let target = window_manager_find_window(wm, windowID), target.shouldBeManaged else { continue }

        let existingView = wm.managedView(for: target)
        if let existingView, existingView.layout != .float, existingView != owner {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            existingView.remove(target)
            target.adjustLayer(to: .normal)
            wm.removeManagedWindow(target.id)
            wm.purifyWindow(target)
            existingView.isDirty = true
        }

        if existingView == nil || (existingView!.layout != .float && existingView != owner) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            owner.add(target, insertionPoint: nil)
            target.adjustLayer(to: .below)
            wm.addManagedWindow(target, to: owner)
            owner.isDirty = true
        }
    }
}

/// The windows of space_window_list (without minimized windows) as an array.
private func spaceWindows(_ sid: SpaceID) -> [WindowID]?
{
    return space_window_list(sid, false)
}

/// `window_manager_validate_and_check_for_windows_on_space`
func window_manager_validate_and_check_for_windows_on_space(_ sm: SpaceManager, _ wm: WindowManager, _ sid: SpaceID)
{
    let owner = space_manager_find_view(sm, sid)
    if owner.layout == .float { return }

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

    if space_is_visible(owner.sid) && owner.isDirty {
        owner.flush()
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
            if let sid, space == sid {
                window_manager_validate_and_check_for_windows_on_space(sm, wm, sid)
            } else {
                space_manager_mark_view_invalid(sm, space)
            }
        }
    }

    wm.window_animation_duration = animationDuration
}

/// `window_manager_handle_display_add_and_remove`
func window_manager_handle_display_add_and_remove(_ sm: SpaceManager, _ wm: WindowManager, _ did: DisplayID)
{
    guard let spaceList = displaySpaces(did) else { return }

    for space in spaceList where space_is_user(space) {
        if let windowList = spaceWindows(space) {
            let owner = space_manager_find_view(sm, space)
            if owner.layout != .float {
                windowManagerCheckForWindowsOnSpace(wm, owner, windowList)
            }
        }
        break
    }

    let sid = display_space_id(did)
    for space in spaceList {
        if let sid, space == sid {
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

    wm.ffm_mode = .disabled
    wm.purify_mode = .disabled
    wm.window_origin_mode = .default
    wm.enable_mff = false
    wm.enable_window_opacity = false
    wm.menubar_opacity = 1.0
    wm.active_window_opacity = 1.0
    wm.normal_window_opacity = 1.0
    wm.window_opacity_duration = 0.0
    wm.window_animation_duration = 0.0
    wm.window_animation_easing = .easeOutCirc
    wm.insert_feedback_color = rgba_color_from_hex(0xffd75f5f)
    wm.enable_window_border = false
    wm.window_border_hide_single = false
    wm.window_border_width = 4.0
    wm.active_window_border_color = rgba_color_from_hex(0xffe1e3e4)
    wm.normal_window_border_color = rgba_color_from_hex(0xff494d64)
    wm.focus_wrapping = .on
    wm.enable_tab_bar = true
    wm.tab_bar_height = 24
    wm.tab_bar_offset = 0
    wm.tab_bar_icons = true
    wm.tab_bar_style = .glass
    wm.tab_bar_appearance = .dark
    wm.tab_bar_backdrop = .blur
    wm.tab_bar_card_padding = 6
    wm.tab_bar_window_radius = 16
    wm.tab_bar_focused_color = rgba_color_from_hex(0xff285577)
    wm.tab_bar_focused_text_color = rgba_color_from_hex(0xffffffff)
    wm.tab_bar_inactive_color = rgba_color_from_hex(0xff5f676a)
    wm.tab_bar_inactive_text_color = rgba_color_from_hex(0xffffffff)
    wm.tab_bar_unfocused_color = rgba_color_from_hex(0xff222222)
    wm.tab_bar_unfocused_text_color = rgba_color_from_hex(0xff888888)
    wm.tab_bar_backdrop_color = rgba_color_from_hex(0xff48484a)
    _ = tab_bar_set_font(tabBarDefaultFont)
    wm.scratchpad_exclusive = false
    wm.scratchpad_raise = false
    wm.scratchpad_below = false
    wm.scratchpad_grid = Grid()

    wm.application = [:]
    wm.window = [:]
    wm.managed_window = [:]
    wm.window_lost_focused_event = []
    wm.application_lost_front_switched_event = []
}

/// `window_manager_begin`
func window_manager_begin(_ sm: SpaceManager, _ wm: WindowManager)
{
    autoreleasepool {
        // Applications in pid order, so their windows tile in the same order every start.
        for candidate in process_manager_global().process.values.sorted(by: { $0.pid < $1.pid }) {
            if workspace_application_is_observable(candidate) {
                let created = Application(process: candidate)

                if created.observe() {
                    window_manager_add_application(wm, created)
                    _ = window_manager_add_existing_application_windows(sm, wm, created, nil)
                } else {
                    created.unobserve()
                    created.destroy()
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
        wm.setWindowOpacity(target, to: wm.active_window_opacity)
    }
}
