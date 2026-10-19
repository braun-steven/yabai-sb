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

/// Why a window operation failed (`checkManaged` in MessageWindow.swift words the failures of unmanaged windows).
enum WindowOperationError: Error, Sendable
{
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
@WM final class WindowManager
{
    // NOTE: The single window manager, used by the event loop and the IPC handlers it runs.
    static let shared = WindowManager()

    var systemElement: AXUIElement?
    var application: [pid_t: Application] = [:]
    var window: [WindowID: Window] = [:]
    var managedWindows: [WindowID: View] = [:]
    // NOTE: The tab bar registry is owned and accessed only by the event loop thread. The mouse event tap reads the
    // separate `tabBarHits` snapshot in `TabBar.swift`; bars are embedded in their owner, which redraws them on changes.
    var tabBars: [TabBar] = []
    var windowLostFocusedEvents = Set<WindowID>()
    var applicationLostFrontSwitchedEvents = Set<pid_t>()
    var rules: [Rule] = []
    var applicationsToRefresh: [Application] = []
    var focusedWindowID: WindowID?
    var focusedWindowPSN = ProcessSerialNumber()
    var pendingFocusWindowID: WindowID?
    var pendingFocusTime: UInt64 = 0
    var lastWindowID: WindowID?
    var tabBarFont: CTFont?
    var scratchpads: [Scratchpad] = []
    /// Set while an operation moves windows without animating them; see withoutAnimations(_:).
    var animationsSuppressed = false
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
