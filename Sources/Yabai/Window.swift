import ApplicationServices
import CPrivate
import Logging
import Synchronization
import YabaiCore

/// The ids whose AX destroyed notification arrived on the main thread. The callback writes them (`markAXDestroyed`), and
/// `Window.isValid` reads them, so the events queued for a window before its destroyed event are ignored at once; the
/// id leaves the set when its window is forgotten (`WindowManager.forget`) or its destroyed event finds no window.
private let axDestroyedWindowIDs = Mutex<Set<WindowID>>([])

/// Records that the AX destroyed notification of a window arrived. Returns false when it was already recorded, so the
/// callback posts the destroyed event once per window, even when the application sends the notification twice.
nonisolated func markAXDestroyed(_ id: WindowID) -> Bool {
  axDestroyedWindowIDs.withLock { $0.insert(id).inserted }
}

/// Removes the AX destroyed mark of a window id, once its window is gone.
nonisolated func unmarkAXDestroyed(_ id: WindowID) {
  axDestroyedWindowIDs.withLock { _ = $0.remove(id) }
}

/// What the accessibility API reports about a window, read by `Window.refreshAXState()`. The strings are converted once,
/// when they are read; nil is kept distinct from "" (a role that the application does not report is nil).
struct WindowAXState: Equatable, Sendable {
  var role: String?
  var subrole: String?
  var title: String?
  var isMovable = false
  var isResizable = false
}

// NOTE: A window that yabai tracks, a thin wrapper of its AX element and the window server queries about its id.
@WM final class Window {
  // NOTE: Stays an implicitly unwrapped optional: about 70 readers (`window.application.pid`, `.name`, `.psn`) need a
  // value, and it is set by `init(application:reference:id:)`. Only a window made with `init(id:)` (tests, and a
  // window whose application is set afterwards) has none; no reader has an obvious result for a missing application.
  var application: Application!
  /// The AX element of the window; nil once `destroy()` has run, and for a window made with `init(id:)` until its
  /// element is set.
  var ref: AXUIElement?
  let id: WindowID

  // NOTE: A window stays valid until it is invalidated, and it is invalid at once once its AX destroyed notification
  // arrived (`axDestroyedWindowIDs`, marked on the main thread). Queued events carry its id, not the window, so their
  // handlers look it up on @WM and check `isValid` before using it. Only the destroyed handler on @WM invalidates
  // `valid`, and it tears the window down once; a terminated application removes its windows either way
  // (`EventHandler.removeTerminatedWindows`).
  /// The cross-thread, invalidate-once flag. `invalidate()` clears it from any thread and returns true for the first
  /// call only, so exactly one caller claims the window for teardown. `isValid` also checks the AX destroyed mark.
  let valid = Atomic<Bool>(true)
  /// The AX-observed facts of the window (role, subrole, title, movable and resizable), refreshed by `refreshAXState()`.
  var ax = WindowAXState()
  var frame = CGRect.zero
  var frameRequest = CGRect.zero
  var windowedFrame = CGRect.zero
  var isRoot = false
  var isEligible = false
  var notifications: WindowNotifications = []
  var hasShadow = false
  // NOTE: `isFullscreen` and `isMinimized` stay on `Window`, not in `ax`: the minimize and fullscreen handlers set them
  // from notifications, and `isFullscreen` also merges the fullscreen state of the window's space.
  var isFullscreen = false
  var isMinimized = false
  var isFloating = false
  // NOTE: The frame the window had the last time it was floating (`rememberFloatingFrame`), restored when it floats
  // again (`WindowManager.makeWindowFloating`). Cleared by `WindowManager.forget`.
  var lastFloatingFrame: CGRect?
  var isSticky = false
  var isWindowed = false
  /// Set by `destroy()`, on @WM, when the window is torn down. Queued events and border updates then ignore the window.
  /// Unlike `valid`, it is never set from another thread, and it is not what claims the window: `invalidate()` does
  /// that first, then `destroy()` runs during the teardown.
  var isDestroyed = false

  // NOTE: These record rule effects: `isManagedByRule` remains true while a rule manages the window; `isFullscreenByRule`
  // skips floating it once at creation; `mouseFollowsFocusByRule` overrides the configured value. `insertionByRule` is
  // the insert= of the rule that matched the window as new: the first add of the window to a tree takes it (View.add),
  // so it applies once, and never to a window the rules only re-apply to.
  var isManagedByRule = false
  var isFullscreenByRule = false
  var mouseFollowsFocusByRule: Bool?
  var insertionByRule: InsertDirection?
  var layer = WindowLayer.auto
  var scratchpad: String?

  init(id: WindowID) {
    self.id = id
  }

  convenience init(application: Application, reference: AXUIElement, id: WindowID) {
    self.init(id: id)
    self.application = application
    self.ref = reference
    frame = axFrame
    ax.title = readTitle().value
    isRoot = id.parent == nil || hasApplicationAsParent
    hasShadow = id.hasShadow
    isMinimized = reportsMinimized
    refreshAXState()
    isFullscreen = reportsFullscreen || (id.space.map { $0.isFullscreen } ?? false)
    isSticky = id.isSticky
  }

  /// Records the frame of a floating window as the one it returns to when it floats again. A tiled window keeps the
  /// record it has, so it is a no-op for other windows.
  func rememberFloatingFrame() {
    if isFloating { lastFloatingFrame = frame }
  }

  /// False once the window is invalidated, or once its AX destroyed notification arrived (`markAXDestroyed`), which
  /// can happen on the main thread before the destroyed event reaches @WM.
  nonisolated var isValid: Bool {
    valid.load(ordering: .sequentiallyConsistent)
      && !axDestroyedWindowIDs.withLock { $0.contains(id) }
  }

  /// Clears `valid`, and returns true only for the call that cleared it.
  @discardableResult
  nonisolated func invalidate() -> Bool {
    valid.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent)
      .exchanged
  }

  /// The AX title and the error of its call, for the calls that record a timeout (`WindowManager.ifResponsive`).
  func readTitle() -> (value: String?, error: AXError) {
    guard let ref else { return (nil, .invalidUIElement) }
    let (value, error) = ref.attributeValue(kAXTitleAttribute)
    guard error == .success, let value else { return (nil, error) }
    let title: CFString? = castAttribute(value, typeID: CFStringGetTypeID())
    return (title.map { $0 as String }, error)
  }

  var axOrigin: CGPoint {
    return ref?.pointAttribute(kAXPositionAttribute) ?? .zero
  }

  var axFrame: CGRect {
    let origin = ref?.pointAttribute(kAXPositionAttribute) ?? .zero
    let size = ref?.sizeAttribute(kAXSizeAttribute) ?? .zero
    return CGRect(origin: origin, size: size)
  }

  func move(to point: CGPoint) {
    frameRequest.origin = point
    ref?.setAttribute(kAXPositionAttribute, to: point)
  }

  func resizeRelative(
    frame: CGRect, direction: ResizeHandle, dx: Float, dy: Float,
    euiScope: EUIScope = .write
  ) {
    let xMod: CGFloat = direction.contains(.left) ? -1 : direction.contains(.right) ? 1 : 0
    let yMod: CGFloat = direction.contains(.top) ? -1 : direction.contains(.bottom) ? 1 : 0

    let width = Float(max(1, frame.size.width + CGFloat(dx) * xMod))
    let height = Float(max(1, frame.size.height + CGFloat(dy) * yMod))
    let x =
      direction.contains(.left)
      ? Float(frame.origin.x + frame.size.width - CGFloat(width)) : Float(frame.origin.x)
    let y =
      direction.contains(.top)
      ? Float(frame.origin.y + frame.size.height - CGFloat(height)) : Float(frame.origin.y)

    // NOTE: A drag writes every frame inside its EUI scope; the other resizes go through the placement path.
    if euiScope == .write {
      WindowManager.shared.placeWindow(
        WindowPlacement(window: self, x: x, y: y, w: width, h: height))
    } else {
      WindowManager.shared.applyFrame(
        self,
        frame: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)),
        euiScope: euiScope)
    }
  }

  /// Applies a layer only when the window has no configured layer of its own.
  func adjustLayer(to layer: WindowLayer) {
    if self.layer != .auto { return }
    ScriptingAddition.shared.setLayer(layer.level, of: id)
  }

  func toggleShadow() {
    let shadow = !hasShadow
    if ScriptingAddition.shared.setShadow(shadow, of: id) {
      hasShadow = shadow
    }
  }

  var canMoveViaAccessibility: Bool { ref?.isAttributeSettable(kAXPositionAttribute) ?? false }
  var canMove: Bool { ax.isMovable }
  var canResizeViaAccessibility: Bool { ref?.isAttributeSettable(kAXSizeAttribute) ?? false }
  var canResize: Bool { ax.isResizable }
  var canMinimize: Bool { ref?.isAttributeSettable(kAXMinimizedAttribute) ?? false }
  var isUndersized: Bool { frame.width <= 500.0 || frame.height <= 500.0 }

  var reportsMinimized: Bool { ref?.boolAttribute(kAXMinimizedAttribute) ?? false }
  var reportsFullscreen: Bool { ref?.boolAttribute(Self.fullscreenAttribute) ?? false }

  /// The AXFullScreen value (false when it is not a boolean) and the error of its call, for `WindowManager.ifResponsive`.
  func readFullscreen() -> (value: Bool, error: AXError) {
    guard let ref else { return (false, .invalidUIElement) }
    let (value, error) = ref.attributeValue(Self.fullscreenAttribute)
    guard
      let boolean: CFBoolean = value.flatMap({ castAttribute($0, typeID: CFBooleanGetTypeID()) })
    else {
      return (false, error)
    }
    return (CFBooleanGetValue(boolean), error)
  }

  func minimize() throws(WindowOperationError) {
    if !canMinimize { throw .cannotMinimize }
    if isMinimized { throw .alreadyMinimized }

    // A window without an element cannot be minimized: `canMinimize` is false, so it throws above.
    let result = ref?.setAttribute(kAXMinimizedAttribute, to: true)
    if result != .success { throw .minimizeFailed }
  }

  func deminimize() throws(WindowOperationError) {
    if !isMinimized { throw .notMinimized }

    let result = ref?.setAttribute(kAXMinimizedAttribute, to: false)
    if result != .success { throw .deminimizeFailed }
  }

  /// Presses the close button when the window has one.
  func close() -> Bool {
    guard let button = ref?.elementAttribute(kAXCloseButtonAttribute) else { return false }

    button.perform(kAXPressAction)
    return true
  }

  private var axRole: String? { ref?.stringAttribute(kAXRoleAttribute).map { $0 as String } }

  private var axSubrole: String? { ref?.stringAttribute(kAXSubroleAttribute).map { $0 as String } }

  private var hasApplicationAsParent: Bool {
    guard let ref else { return false }
    let (value, error) = ref.attributeValue(kAXParentAttribute)
    guard error == .success else { return false }
    return !(value != nil && !CFEqual(value, application.ref))
  }

  var isReal: Bool {
    guard let role = ax.role, let subrole = ax.subrole else { return false }
    return role == kAXWindowRole as String
      && (subrole == kAXStandardWindowSubrole as String
        || subrole == kAXFloatingWindowSubrole as String || subrole == kAXDialogSubrole as String)
  }

  var isStandard: Bool {
    guard let role = ax.role, let subrole = ax.subrole else { return false }
    return role == kAXWindowRole as String && subrole == kAXStandardWindowSubrole as String
  }

  var isStandardLevel: Bool { id.level == CGWindowLevelForKey(.normalWindow) }

  var isEligibleForManagement: Bool { isRoot && (isReal || isManagedByRule) }

  var shouldBeManaged: Bool {
    if !isRoot { return false }
    if isFloating { return false }
    if id.isSticky { return false }
    if isMinimized { return false }
    if application.isHidden { return false }

    return (isStandard && isStandardLevel && canMove) || isManagedByRule
  }

  var isUnknown: Bool {
    guard let subrole = ax.subrole else { return false }
    return subrole == kAXUnknownSubrole as String
  }

  // NOTE: Windows report other roles and capabilities while minimized or in native fullscreen, so refresh the observed
  // state whenever that state changes. The title is not read here: it is read at discovery and on title-changed
  // events, so these direct calls do not add an AX read that the responsiveness breaker does not cover.
  func refreshAXState() {
    ax.isMovable = canMoveViaAccessibility
    ax.isResizable = canResizeViaAccessibility
    ax.role = axRole
    ax.subrole = axSubrole
  }

  /// The AX context of this window's notifications: its id, not a pointer. A callback can run after the window is gone,
  /// and then it only finds the id (`WindowID(notificationContext:)`).
  var notificationContext: UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: UInt(id.rawValue))
  }

  // NOTE: Notifications use the application observer and the window id as their context. The callback is
  // `Application.applicationNotificationHandler`, whose NOTE documents how the events find the window.
  func observe() -> Bool {
    guard let observerRef = application.observerRef, let ref else { return false }
    guard let context = notificationContext else {
      Logger.windows.debug("\(id): no notification context, not observing")
      return false
    }

    for notification in axWindowNotifications {
      let result = observerRef.add(notification.name, for: ref, context: context)
      if result == .success || result == .notificationAlreadyRegistered {
        notifications.insert(notification.notification)
      } else {
        Logger.windows.debug("\(id): observing \(notification.text) failed with \(result.name)")
      }
    }
    return notifications.isSuperset(of: .all)
  }

  func unobserve() {
    guard !notifications.isEmpty, let observerRef = application.observerRef, let ref else { return }

    for notification in axWindowNotifications
    where notifications.contains(notification.notification) {
      observerRef.remove(notification.name, for: ref)
      notifications.remove(notification.notification)
    }
  }

  // NOTE: The window holds its AX element and its observed state until `destroy()`. `destroy()` clears the role,
  // subrole and title only; the movable and resizable flags are left unchanged.
  func destroy() {
    isDestroyed = true
    ax.role = nil
    ax.subrole = nil
    ax.title = nil
    ref = nil
  }

  static let fullscreenAttribute = "AXFullScreen"
}

extension Window: Equatable {
  nonisolated static func == (a: Window, b: Window) -> Bool { a === b }
}

struct WindowNotifications: OptionSet, Sendable {
  let rawValue: UInt8

  static let miniaturized = WindowNotifications(rawValue: 1 << 0)
  static let deminiaturized = WindowNotifications(rawValue: 1 << 1)
  static let destroyed = WindowNotifications(rawValue: 1 << 2)

  static let all: WindowNotifications = [.miniaturized, .deminiaturized, .destroyed]
}

private let axWindowNotifications:
  [(notification: WindowNotifications, name: String, text: String)] =
    [
      (.miniaturized, kAXWindowMiniaturizedNotification, "kAXWindowMiniaturizedNotification"),
      (.deminiaturized, kAXWindowDeminiaturizedNotification, "kAXWindowDeminiaturizedNotification"),
      (.destroyed, kAXUIElementDestroyedNotification, "kAXUIElementDestroyedNotification"),
    ]

extension WindowID {
  /// The id that a window's AX notification carries as its context; nil for 0, which no window has.
  init?(notificationContext context: UnsafeMutableRawPointer?) {
    guard let context else { return nil }
    self.init(nonzero: UInt32(truncatingIfNeeded: UInt(bitPattern: context)))
  }

  private var displayUUID: String? {
    if let uuid = SLS.managedDisplay(SLS.connection, forWindow: self) { return uuid }
    let frame = SLS.windowBounds(SLS.connection, self) ?? .zero
    return SLS.bestManagedDisplay(SLS.connection, forRect: frame)
  }

  var displayID: DisplayID? {
    guard let uuid = displayUUID else { return nil }
    return DisplayID(uuid: uuid)
  }

  private var displaySpace: SpaceID? {
    guard let uuid = displayUUID else { return nil }
    return SLS.currentSpace(SLS.connection, forDisplay: uuid)
  }

  // The first space of the window, or the current space of its display when the server reports none.
  var space: SpaceID? {
    let first = SLS.spaces(SLS.connection, forWindows: [self]).first.flatMap {
      SpaceID(nonzero: $0.rawValue)
    }
    return first ?? displaySpace
  }

  // More than one space indicates a sticky window.
  var spaces: [SpaceID] { SLS.spaces(SLS.connection, forWindows: [self]) }
  var isSticky: Bool { spaces.count > 1 }
  var hasShadow: Bool { (tags & 0x8) == 0 }

  private var queriedWindow: SLS.QueriedWindow? {
    let windows = SLS.queryWindows(SLS.connection, [self])
    return windows.count == 1 ? windows[0] : nil
  }

  var parent: WindowID? { queriedWindow?.parent }
  var level: Int32 { queriedWindow?.level ?? 0 }

  // Use the bounded sublevel request first when available.
  var subLevel: Int32 {
    return SLS.windowSubLevelBounded(SLS.connection, self)
      ?? SLS.windowSubLevel(SLS.connection, self)
  }

  var tags: UInt64 { queriedWindow?.tags ?? 0 }
}
