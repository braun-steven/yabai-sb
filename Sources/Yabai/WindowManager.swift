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
