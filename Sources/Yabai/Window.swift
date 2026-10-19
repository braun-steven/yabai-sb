import ApplicationServices
import CPrivate
import Synchronization
import YabaiCore

// NOTE: A window that yabai tracks, a thin wrapper of its AX element and the window server queries about its id.
final class Window
{
    var application: Application!
    var ref: AXUIElement!
    let id: WindowID

    // NOTE: A window stays valid until it is invalidated. Events already queued for a window hold on to it, so their
    // handlers check that it is still valid before using it. Exactly one caller can invalidate it and then owns its
    // destruction.
    let valid = Atomic<Bool>(true)
    var role: CFString?
    var subrole: CFString?
    var title: CFString?
    var frame = CGRect.zero
    var frameRequest = CGRect.zero
    var windowedFrame = CGRect.zero
    var isRoot = false
    var isEligible = false
    var notifications: WindowNotifications = []
    var hasShadow = false
    var isFullscreen = false
    var isMinimized = false
    var isFloating = false
    var isSticky = false
    var isWindowed = false
    var isMovable = false
    var isResizable = false
    /// Set by `destroy()`; queued events and border updates then ignore the window.
    var isDestroyed = false

    // NOTE: These record rule effects: `isManagedByRule` remains true while a rule manages the window; `isFullscreenByRule`
    // skips floating it once at creation; `mouseFollowsFocusByRule` overrides the configured value.
    var isManagedByRule = false
    var isFullscreenByRule = false
    var mouseFollowsFocusByRule: Bool?
    var opacity: Float = 0
    var layer = WindowLayer.auto
    var scratchpad: String?

    init(id: WindowID)
    {
        self.id = id
    }

    convenience init(application: Application, reference: AXUIElement, id: WindowID)
    {
        self.init(id: id)
        self.application = application
        self.ref = reference
        frame = axFrame
        title = currentTitle()
        isRoot = id.parent == nil || hasApplicationAsParent
        hasShadow = id.hasShadow
        isMinimized = reportsMinimized
        refreshAXProperties()
        isFullscreen = reportsFullscreen || (id.space.map { $0.isFullscreen } ?? false)
        isSticky = id.isSticky
    }

    var isValid: Bool { valid.load(ordering: .sequentiallyConsistent) }

    @discardableResult
    func invalidate() -> Bool
    {
        valid.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent).exchanged
    }

    var cachedTitle: String { title.map { $0 as String } ?? "" }

    func currentTitle() -> CFString?
    {
        return ref.stringAttribute(kAXTitleAttribute)
    }

    var axOrigin: CGPoint
    {
        return ref.pointAttribute(kAXPositionAttribute) ?? .zero
    }

    var axFrame: CGRect
    {
        let origin = ref.pointAttribute(kAXPositionAttribute) ?? .zero
        let size = ref.sizeAttribute(kAXSizeAttribute) ?? .zero
        return CGRect(origin: origin, size: size)
    }

    func move(to point: CGPoint)
    {
        frameRequest.origin = point
        ref.setAttribute(kAXPositionAttribute, to: point)
    }

    func resize(width: Float, height: Float)
    {
        frameRequest.size = CGSize(width: CGFloat(width), height: CGFloat(height))
        ref.setAttribute(kAXSizeAttribute, to: CGSize(width: CGFloat(width), height: CGFloat(height)))
    }

    func resizeRelative(frame: CGRect, direction: ResizeHandle, dx: Float, dy: Float, animate: Bool)
    {
        let xMod: CGFloat = direction.contains(.left) ? -1 : direction.contains(.right) ? 1 : 0
        let yMod: CGFloat = direction.contains(.top) ? -1 : direction.contains(.bottom) ? 1 : 0

        let width = Float(max(1, frame.size.width + CGFloat(dx) * xMod))
        let height = Float(max(1, frame.size.height + CGFloat(dy) * yMod))
        let x = direction.contains(.left) ? Float(frame.origin.x + frame.size.width - CGFloat(width)) : Float(frame.origin.x)
        let y = direction.contains(.top) ? Float(frame.origin.y + frame.size.height - CGFloat(height)) : Float(frame.origin.y)

        if animate {
            WindowManager.shared.animateWindow(WindowPlacement(window: self, x: x, y: y, w: width, h: height))
        } else {
            application.ref.withEnhancedUserInterfaceDisabled {
                move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                resize(width: width, height: height)
            }
        }
    }

    /// Applies a layer only when the window has no configured layer of its own.
    func adjustLayer(to layer: WindowLayer)
    {
        if self.layer != .auto { return }
        ScriptingAddition.shared.setLayer(layer.level, of: id)
    }

    func toggleShadow()
    {
        let shadow = !hasShadow
        if ScriptingAddition.shared.setShadow(shadow, of: id) {
            hasShadow = shadow
        }
    }

    var canMoveViaAccessibility: Bool { ref.isAttributeSettable(kAXPositionAttribute) }
    var canMove: Bool { isMovable }
    var canResizeViaAccessibility: Bool { ref.isAttributeSettable(kAXSizeAttribute) }
    var canResize: Bool { isResizable }
    var canMinimize: Bool { ref.isAttributeSettable(kAXMinimizedAttribute) }
    var isUndersized: Bool { frame.width <= 500.0 || frame.height <= 500.0 }

    var reportsMinimized: Bool { ref.boolAttribute(kAXMinimizedAttribute) }
    var reportsFullscreen: Bool { ref.boolAttribute(Self.fullscreenAttribute) }

    func minimize() -> WindowOperationResult
    {
        if !canMinimize { return .cannotMinimize }
        if isMinimized { return .alreadyMinimized }

        let result = ref.setAttribute(kAXMinimizedAttribute, to: true)
        return result == .success ? .success : .minimizeFailed
    }

    func deminimize() -> WindowOperationResult
    {
        if !isMinimized { return .notMinimized }

        let result = ref.setAttribute(kAXMinimizedAttribute, to: false)
        return result == .success ? .success : .deminimizeFailed
    }

    /// Presses the close button when the window has one.
    func close() -> Bool
    {
        guard let button = ref.elementAttribute(kAXCloseButtonAttribute) else { return false }

        button.perform(kAXPressAction)
        return true
    }

    private var axRole: CFString? { ref.stringAttribute(kAXRoleAttribute) }

    private var axSubrole: CFString? { ref.stringAttribute(kAXSubroleAttribute) }

    var roleString: String { role.map { $0 as String } ?? "" }
    var subroleString: String { subrole.map { $0 as String } ?? "" }

    private var hasApplicationAsParent: Bool
    {
        let (value, error) = ref.attributeValue(kAXParentAttribute)
        guard error == .success else { return false }
        return !(value != nil && !CFEqual(value, application.ref))
    }

    var isReal: Bool
    {
        guard let role, let subrole else { return false }
        return CFEqual(role, kAXWindowRole as CFString) &&
               (CFEqual(subrole, kAXStandardWindowSubrole as CFString) ||
                CFEqual(subrole, kAXFloatingWindowSubrole as CFString) ||
                CFEqual(subrole, kAXDialogSubrole as CFString))
    }

    var isStandard: Bool
    {
        guard let role, let subrole else { return false }
        return CFEqual(role, kAXWindowRole as CFString) && CFEqual(subrole, kAXStandardWindowSubrole as CFString)
    }

    var isStandardLevel: Bool { id.level == CGWindowLevelForKey(.normalWindow) }

    var isEligibleForManagement: Bool { isRoot && (isReal || isManagedByRule) }

    var shouldBeManaged: Bool
    {
        if !isRoot { return false }
        if isFloating { return false }
        if id.isSticky { return false }
        if isMinimized { return false }
        if application.isHidden { return false }

        return (isStandard && isStandardLevel && canMove) || isManagedByRule
    }

    var isUnknown: Bool
    {
        guard let subrole else { return false }
        return CFEqual(subrole, kAXUnknownSubrole as CFString)
    }

    // NOTE: Windows report other roles and capabilities while minimized or in native fullscreen, so refresh these cached
    // properties whenever that state changes.
    func refreshAXProperties()
    {
        isMovable = canMoveViaAccessibility
        isResizable = canResizeViaAccessibility
        role = axRole
        subrole = axSubrole
    }

    // NOTE: Notifications use the application observer and the window as an unretained context. The callback is
    // `Application.applicationNotificationHandler`, whose NOTE documents window ownership.
    func observe() -> Bool
    {
        let observerRef = application.observerRef!
        for notification in axWindowNotifications {
            let result = observerRef.add(notification.name, for: ref, context: Unmanaged.passUnretained(self).toOpaque())
            if result == .success || result == .notificationAlreadyRegistered {
                notifications.insert(notification.notification)
            } else {
                debug("Window.observe: \(notification.text) failed with error \(result.name)\n")
            }
        }
        return notifications.isSuperset(of: .all)
    }

    func unobserve()
    {
        let observerRef = application.observerRef!
        for notification in axWindowNotifications where notifications.contains(notification.notification) {
            observerRef.remove(notification.name, for: ref)
            notifications.remove(notification.notification)
        }
    }

    // NOTE: The window holds its AX element, role, subrole and title until `destroy()`.
    func destroy()
    {
        isDestroyed = true
        role = nil
        subrole = nil
        title = nil
        ref = nil
    }

    static let fullscreenAttribute = "AXFullScreen"
}

extension Window: Equatable
{
    nonisolated static func == (a: Window, b: Window) -> Bool { a === b }
}

struct WindowNotifications: OptionSet, Sendable
{
    let rawValue: UInt8

    static let miniaturized   = WindowNotifications(rawValue: 1 << 0)
    static let deminiaturized = WindowNotifications(rawValue: 1 << 1)
    static let destroyed      = WindowNotifications(rawValue: 1 << 2)

    static let all: WindowNotifications = [.miniaturized, .deminiaturized, .destroyed]
}

private let axWindowNotifications: [(notification: WindowNotifications, name: String, text: String)] =
[
    (.miniaturized,   kAXWindowMiniaturizedNotification,   "kAXWindowMiniaturizedNotification"),
    (.deminiaturized, kAXWindowDeminiaturizedNotification, "kAXWindowDeminiaturizedNotification"),
    (.destroyed,      kAXUIElementDestroyedNotification,   "kAXUIElementDestroyedNotification"),
]

extension WindowID
{
    private var displayUUID: String?
    {
        if let uuid = SLS.managedDisplay(SLS.connection, forWindow: self) { return uuid }
        let frame = SLS.windowBounds(SLS.connection, self) ?? .zero
        return SLS.bestManagedDisplay(SLS.connection, forRect: frame)
    }

    var displayID: DisplayID?
    {
        guard let uuid = displayUUID else { return nil }
        return DisplayID(uuid: uuid)
    }

    private var displaySpace: SpaceID?
    {
        guard let uuid = displayUUID else { return nil }
        return SLS.currentSpace(SLS.connection, forDisplay: uuid)
    }

    // The first space of the window, or the current space of its display when the server reports none.
    var space: SpaceID?
    {
        let first = SLS.spaces(SLS.connection, forWindows: [self]).first.flatMap { SpaceID(nonzero: $0.rawValue) }
        return first ?? displaySpace
    }

    // More than one space indicates a sticky window.
    var spaces: [SpaceID] { SLS.spaces(SLS.connection, forWindows: [self]) }
    var isSticky: Bool { spaces.count > 1 }
    var hasShadow: Bool { (tags & 0x8) == 0 }
    var opacity: Float { SLS.windowAlpha(SLS.connection, self) ?? 0 }

    private var queriedWindow: SLS.QueriedWindow?
    {
        let windows = SLS.queryWindows(SLS.connection, [self])
        return windows.count == 1 ? windows[0] : nil
    }

    var parent: WindowID? { queriedWindow?.parent }
    var level: Int32 { queriedWindow?.level ?? 0 }

    // Use the bounded sublevel request first when available.
    var subLevel: Int32
    {
        return SLS.windowSubLevelBounded(SLS.connection, self) ?? SLS.windowSubLevel(SLS.connection, self)
    }

    var tags: UInt64 { queriedWindow?.tags ?? 0 }
}
