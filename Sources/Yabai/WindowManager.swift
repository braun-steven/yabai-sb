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

/// The window level of a sub-layer: 0 for `auto`, otherwise the CGWindowLevelKey value of the layer.
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

/// A window assigned to a scratchpad label.
struct Scratchpad
{
    var label: String
    var window: Window
}

/// The windows and applications yabai tracks, and the window settings.
final class WindowManager
{
    // NOTE: The single window manager, used by the event loop and the IPC handlers it runs.
    nonisolated(unsafe) static let shared = WindowManager()

    var systemElement: AXUIElement?
    var application: [pid_t: Application] = [:]
    var window: [WindowID: Window] = [:]
    var managedWindows: [WindowID: View] = [:]
    var windowLostFocusedEvents = Set<WindowID>()
    var applicationLostFrontSwitchedEvents = Set<pid_t>()
    var rules: [Rule] = []
    var applicationsToRefresh: [Application] = []
    var focusedWindowID: WindowID?
    var focusedWindowPSN = ProcessSerialNumber()
    var pendingFocusWindowID: WindowID?
    var pendingFocusTime: UInt64 = 0
    var lastWindowID: WindowID?
    var mouseFollowsFocusEnabled = false
    var focusFollowsMouseMode = FocusFollowsMouse.disabled
    var purifyMode = PurifyMode.disabled
    var windowOriginMode = WindowOrigin.default
    var windowOpacityEnabled = false
    var menuBarOpacity: Float = 0
    var activeWindowOpacity: Float = 0
    var normalWindowOpacity: Float = 0
    var windowOpacityDuration: Float = 0
    var windowAnimationDuration: Float = 0
    var windowAnimationEasing = AnimationEasing.easeInSine
    var insertionFeedbackColor = RGBAColor()
    var windowBorderEnabled = false
    var windowBorderHideSingle = false
    var windowBorderWidth: Float = 0
    var activeWindowBorderColor = RGBAColor()
    var normalWindowBorderColor = RGBAColor()
    var focusWrapping = FocusWrapping.off
    var tabBarEnabled = false
    var tabBarHeight: Int = 0
    var tabBarOffset: Int = 0
    var tabBarIcons = false
    var tabBarStyle = TabBarStyle.glass
    var tabBarAppearance = TabBarAppearance.dark
    var tabBarBackdrop = TabBarBackdrop.off
    var tabBarCardPadding: Int = 0
    var tabBarWindowRadius: Int = 0
    var tabBarFontName = ""
    var tabBarFont: CTFont?
    var tabBarFocusedColor = RGBAColor()
    var tabBarFocusedTextColor = RGBAColor()
    var tabBarInactiveColor = RGBAColor()
    var tabBarInactiveTextColor = RGBAColor()
    var tabBarUnfocusedColor = RGBAColor()
    var tabBarBackdropColor = RGBAColor()
    var tabBarUnfocusedTextColor = RGBAColor()
    var tabBarFocusedColorIsCustom = false
    var tabBarInactiveColorIsCustom = false
    var tabBarUnfocusedColorIsCustom = false
    var tabBarBackdropColorIsCustom = false
    var tabBarFocusedTextColorIsCustom = false
    var tabBarInactiveTextColorIsCustom = false
    var tabBarUnfocusedTextColorIsCustom = false
    var scratchpads: [Scratchpad] = []
    var scratchpadExclusive = false
    var scratchpadRaise = false
    var scratchpadBelow = false
    var scratchpadGrid = Grid()
}

/// The mouse events the event tap receives.
let mouseEventMask: UInt32 =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << DockSwipe.eventType)

/// The mouse events the event tap receives while focus follows the mouse.
let mouseEventMaskFFM: UInt32 = mouseEventMask | (1 << CGEventType.mouseMoved.rawValue)
