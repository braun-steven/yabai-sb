import ApplicationServices
import CPrivate
import Synchronization
import YabaiCore

// NOTE: A window that yabai tracks, a thin wrapper of its AX element and the window server queries about its id.
final class Window
{
    var application: Application!
    var ref: AXUIElement!
    var id: WindowID

    // NOTE: A window stays valid until it is invalidated. Events already queued for a window hold on to it, so their
    // handlers check that it is still valid before using it. Exactly one caller can invalidate it and then owns its
    // destruction.
    let valid = Atomic<Bool>(true)
    var role: CFString?
    var subrole: CFString?
    var title: CFString?
    var frame = CGRect.zero
    var frame_request = CGRect.zero
    var windowed_frame = CGRect.zero
    var is_root = false
    var is_eligible = false
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
        is_root = id.parent == nil || hasApplicationAsParent
        hasShadow = id.hasShadow
        isMinimized = reportsMinimized
        refreshAXProperties()
        isFullscreen = reportsFullscreen || (id.space.map { space_is_fullscreen($0) } ?? false)
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
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXTitleAttribute as CFString, &value)
        return value.map { unsafeDowncast($0, to: CFString.self) }
    }

    var axOrigin: CGPoint
    {
        var origin = CGPoint.zero
        var positionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXPositionAttribute as CFString, &positionRef)
        if let positionRef {
            AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &origin)
        }
        return origin
    }

    var axFrame: CGRect
    {
        var result = CGRect.zero
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(ref, kAXSizeAttribute as CFString, &sizeRef)
        if let positionRef {
            AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &result.origin)
        }
        if let sizeRef {
            AXValueGetValue(unsafeDowncast(sizeRef, to: AXValue.self), .cgSize, &result.size)
        }
        return result
    }

    func move(to point: CGPoint)
    {
        frame_request.origin = point

        var position = point
        guard let positionRef = AXValueCreate(.cgPoint, &position) else { return }

        AXUIElementSetAttributeValue(ref, kAXPositionAttribute as CFString, positionRef)
    }

    func resize(width: Float, height: Float)
    {
        frame_request.size = CGSize(width: CGFloat(width), height: CGFloat(height))

        var size = CGSize(width: CGFloat(width), height: CGFloat(height))
        guard let sizeRef = AXValueCreate(.cgSize, &size) else { return }

        AXUIElementSetAttributeValue(ref, kAXSizeAttribute as CFString, sizeRef)
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
            window_manager_animate_window(window_capture(window: self, x: x, y: y, w: width, h: height))
        } else {
            axEnhancedUIWorkaround(application.ref) {
                move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                resize(width: width, height: height)
            }
        }
    }

    /// Applies a layer only when the window has no configured layer of its own.
    func adjustLayer(to layer: WindowLayer)
    {
        if self.layer != .auto { return }
        scripting_addition_set_layer(id, layer.level)
    }

    private func attributeIsSettable(_ attribute: String) -> Bool
    {
        var result: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(ref, attribute as CFString, &result) != .success {
            result = false
        }
        return result.boolValue
    }

    var canMoveViaAccessibility: Bool { attributeIsSettable(kAXPositionAttribute) }
    var canMove: Bool { isMovable }
    var canResizeViaAccessibility: Bool { attributeIsSettable(kAXSizeAttribute) }
    var canResize: Bool { isResizable }
    var canMinimize: Bool { attributeIsSettable(kAXMinimizedAttribute) }
    var isUndersized: Bool { frame.width <= 500.0 || frame.height <= 500.0 }

    private func booleanAttribute(_ attribute: CFString) -> Bool
    {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, attribute, &value) == .success, let value else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    var reportsMinimized: Bool { booleanAttribute(kAXMinimizedAttribute as CFString) }
    var reportsFullscreen: Bool { booleanAttribute(Self.fullscreenAttribute as CFString) }

    private var axRole: CFString?
    {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXRoleAttribute as CFString, &value)
        return value.map { unsafeDowncast($0, to: CFString.self) }
    }

    private var axSubrole: CFString?
    {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXSubroleAttribute as CFString, &value)
        return value.map { unsafeDowncast($0, to: CFString.self) }
    }

    var roleString: String { role.map { $0 as String } ?? "" }
    var subroleString: String { subrole.map { $0 as String } ?? "" }

    private var hasApplicationAsParent: Bool
    {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXParentAttribute as CFString, &value) == .success else { return false }
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

    var isEligibleForManagement: Bool { is_root && (isReal || isManagedByRule) }

    var shouldBeManaged: Bool
    {
        if !is_root { return false }
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
            let result = AXObserverAddNotification(observerRef, ref, notification.name as CFString, Unmanaged.passUnretained(self).toOpaque())
            if result == .success || result == .notificationAlreadyRegistered {
                notifications.insert(notification.notification)
            } else {
                debug("Window.observe: \(notification.text) failed with error \(axErrorName(result))\n")
            }
        }
        return notifications.isSuperset(of: .all)
    }

    func unobserve()
    {
        let observerRef = application.observerRef!
        for notification in axWindowNotifications where notifications.contains(notification.notification) {
            AXObserverRemoveNotification(observerRef, ref, notification.name as CFString)
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
    static func == (a: Window, b: Window) -> Bool { a === b }
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
        if let uuid = SLS.managedDisplay(connection_global(), forWindow: self) { return uuid }
        let frame = SLS.windowBounds(connection_global(), self) ?? .zero
        return SLS.bestManagedDisplay(connection_global(), forRect: frame)
    }

    var displayID: DisplayID?
    {
        guard let uuid = displayUUID else { return nil }
        return Yabai.displayID(uuid)
    }

    private var displaySpace: SpaceID?
    {
        guard let uuid = displayUUID else { return nil }
        return SLS.currentSpace(connection_global(), forDisplay: uuid)
    }

    // The first space of the window, or the current space of its display when the server reports none.
    var space: SpaceID?
    {
        let first = SLS.spaces(connection_global(), forWindows: [self]).first.flatMap { SpaceID(nonzero: $0.rawValue) }
        return first ?? displaySpace
    }

    // More than one space indicates a sticky window.
    var spaces: [SpaceID] { SLS.spaces(connection_global(), forWindows: [self]) }
    var isSticky: Bool { spaces.count > 1 }
    var hasShadow: Bool { (tags & 0x8) == 0 }
    var opacity: Float { SLS.windowAlpha(connection_global(), self) }

    private var queriedWindow: SLS.QueriedWindow?
    {
        let windows = SLS.queryWindows(connection_global(), [self])
        return windows.count == 1 ? windows[0] : nil
    }

    var parent: WindowID? { queriedWindow?.parent }
    var level: Int32 { queriedWindow?.level ?? 0 }

    // Use the bounded sublevel request first when available.
    var subLevel: Int32
    {
        var result: Int32 = 0
        if SLSGetWindowSubLevelBounded(connection_global(), rawValue, &result) { return result }
        return SLS.windowSubLevel(connection_global(), self)
    }

    var tags: UInt64 { queriedWindow?.tags ?? 0 }
}
