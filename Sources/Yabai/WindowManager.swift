import AppKit
import ApplicationServices
import CPrivate
import CoreGraphics
import Foundation
import OrderedCollections
import SortedCollections
import YabaiCore

//
// NOTE: WindowManager owns the application, window and managed-window tables, window command state, and reconciliation
// after Mission Control and display changes.
//

/// Why a window operation failed (`checkManaged` in MessageWindow.swift words the failures of unmanaged windows).
enum WindowOperationError: Error, Sendable {
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
enum FocusFollowsMouse: String, Sendable {
  case disabled
  case autofocus
  case autoraise
}

/// Which windows lose their shadow (`config window_shadow`, named by its values): none, the managed ones, or all.
enum PurifyMode: String, CaseIterable, Sendable {
  case disabled = "on"
  case managed = "float"
  case always = "off"
}

/// The space a new window is placed on (`config window_origin_display`): where macOS put it, the focused space, or the
/// space under the cursor.
enum WindowOrigin: String, CaseIterable, Sendable {
  case `default`
  case focused
  case cursor
}

/// The window level of a sub-layer: 0 for `auto`, otherwise the CGWindowLevelKey value of the layer.
extension WindowLayer {
  var level: Int32 {
    switch self {
    case .auto: 0
    case .below: CGWindowLevelKey.backstopMenu.rawValue
    case .normal: CGWindowLevelKey.normalWindow.rawValue
    case .above: CGWindowLevelKey.floatingWindow.rawValue
    }
  }
}

/// The windows and applications yabai tracks, and the window settings.
@WM final class WindowManager {
  // NOTE: The single window manager, used by the event loop and the IPC handlers it runs.
  static let shared = WindowManager()

  var systemElement: AXUIElement?
  var application: [pid_t: Application] = [:]
  var window: SortedDictionary<WindowID, Window> = [:]
  var managedWindows: [WindowID: View] = [:]
  // NOTE: The tab bar registry is owned and accessed only by the event loop thread. The mouse event tap reads the
  // separate `tabBarHits` snapshot in `TabBar.swift`; bars are embedded in their owner, which redraws them on changes.
  var tabBars: OrderedSet<TabBar> = []
  // NOTE: The focused window, the window before it, a pending focus request and the lost focus events live in
  // FocusState (FocusState.swift).
  var focus = FocusState()
  var rules = RuleSet()
  /// The config file given with -c, or nil. Set once at startup; `config --check` without a file checks it.
  var explicitConfigFile: String?
  var applicationsToRefresh: OrderedSet<Application> = []
  var tabBarFont: CTFont?
  /// The scratchpad windows by label, in the order they were assigned.
  var scratchpads: OrderedDictionary<String, Window> = [:]
  /// The window labels of `window --label`: each window has one label, and a label names one window.
  var labels = LabelList<WindowID>()
  // NOTE: The breaker of the AX calls to applications that do not answer (AXBreaker.swift). Only the non-essential calls
  // consult it (`ifResponsive`); the calls that record their outcome go through `recordAXResult`.
  var axBreaker = AXBreaker()
  /// The tiled windows that something else moved or resized off their tile, checked again once the changes have
  /// settled (`EventHandler.windowFrameRecheck`).
  var frameRecheckWindows: OrderedSet<WindowID> = []
  /// The last cursor warp onto a floating window of a moved space, followed while macOS still places the window on its
  /// new display (`WindowManager.followWarp(of:)`).
  var followedWarp: FollowedWarp?
}

/// A cursor warp to the center of a window (`point`), made at `time`.
struct FollowedWarp {
  var windowID: WindowID
  var point: CGPoint
  var time: UInt64
}

/// The mouse events the event tap receives.
let mouseEventMask: UInt32 =
  (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
  | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
  | (1 << CGEventType.rightMouseUp.rawValue) | (1 << CGEventType.rightMouseDragged.rawValue)
  | (1 << DockSwipe.eventType) | (1 << CGEventType.mouseMoved.rawValue)
