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

/// `window_manager_validate_windows_on_space`
private func windowManagerValidateWindowsOnSpace(_ wm: WindowManager, _ owner: View, _ windowList: [WindowID])
{
    let viewWindowList = owner.windowIDs

    for i in 0..<viewWindowList.count {
        if windowList.contains(viewWindowList[i]) { continue }

        guard let target = wm.window(for: viewWindowList[i]) else { continue }

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
        guard let target = wm.window(for: windowID), target.shouldBeManaged else { continue }

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
                    wm.addApplication(created)
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
