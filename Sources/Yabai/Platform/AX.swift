import ApplicationServices
import CPrivate
import YabaiCore

//
// NOTE: Swift wrappers of the Accessibility calls. AX calls block for as long as the application takes to answer, up to
// the messaging timeout; the callers on the event loop accept that.
//

extension AXError
{
    /// The name of the error for the debug output.
    var name: String
    {
        switch self {
        case .success:                           return "kAXErrorSuccess"
        case .failure:                           return "kAXErrorFailure"
        case .illegalArgument:                   return "kAXErrorIllegalArgument"
        case .invalidUIElement:                  return "kAXErrorInvalidUIElement"
        case .invalidUIElementObserver:          return "kAXErrorInvalidUIElementObserver"
        case .cannotComplete:                    return "kAXErrorCannotComplete"
        case .attributeUnsupported:              return "kAXErrorAttributeUnsupported"
        case .actionUnsupported:                 return "kAXErrorActionUnsupported"
        case .notificationUnsupported:           return "kAXErrorNotificationUnsupported"
        case .notImplemented:                    return "kAXErrorNotImplemented"
        case .notificationAlreadyRegistered:     return "kAXErrorNotificationAlreadyRegistered"
        case .notificationNotRegistered:         return "kAXErrorNotificationNotRegistered"
        case .apiDisabled:                       return "kAXErrorAPIDisabled"
        case .noValue:                           return "kAXErrorNoValue"
        case .parameterizedAttributeUnsupported: return "kAXErrorParameterizedAttributeUnsupported"
        case .notEnoughPrecision:                return "kAXErrorNotEnoughPrecision"
        @unknown default:                        return "\(rawValue)"
        }
    }
}

extension AXUIElement
{
    /// The window id of the element; nil if the element is not a window.
    var windowID: WindowID?
    {
        var wid: UInt32 = 0
        _AXUIElementGetWindow(self, &wid)
        return WindowID(nonzero: wid)
    }

    /// The pid that the AX element stores at offset 0x10.
    var pid: pid_t
    {
        return Unmanaged.passUnretained(self).toOpaque().load(fromByteOffset: 0x10, as: pid_t.self)
    }

    /// `AXUIElementCreateSystemWide`
    static func systemWide() -> AXUIElement { return AXUIElementCreateSystemWide() }

    /// `AXUIElementCreateApplication`
    static func application(_ pid: pid_t) -> AXUIElement { return AXUIElementCreateApplication(pid) }

    /// `_AXUIElementCreateWithRemoteToken`: the element of another process by its remote token (pid, the 'coco' magic
    /// and an element id).
    static func element(remoteToken: Data) -> AXUIElement?
    {
        return _AXUIElementCreateWithRemoteToken(remoteToken as CFData)
    }

    /// `AXUIElementSetMessagingTimeout`
    func setMessagingTimeout(_ seconds: Float) { AXUIElementSetMessagingTimeout(self, seconds) }

    /// `AXUIElementCopyAttributeValue` with its error, for callers that tell failures apart.
    func attributeValue(_ name: String) -> (value: CFTypeRef?, error: AXError)
    {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        return (value, error)
    }

    /// The value of the attribute; nil if the call fails.
    func attribute(_ name: String) -> CFTypeRef?
    {
        let (value, error) = attributeValue(name)
        return error == .success ? value : nil
    }

    /// A string attribute (role, subrole, title); nil if the call fails.
    func stringAttribute(_ name: String) -> CFString?
    {
        return attribute(name).map { unsafeDowncast($0, to: CFString.self) }
    }

    /// A boolean attribute; false if the call fails.
    func boolAttribute(_ name: String) -> Bool
    {
        guard let value = attribute(name) else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    /// An element attribute (window, close button, focused window); nil if the call fails.
    func elementAttribute(_ name: String) -> AXUIElement?
    {
        return attribute(name).map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    /// An array attribute (the windows of an application); nil if the call fails.
    func arrayAttribute(_ name: String) -> CFArray?
    {
        return attribute(name).map { unsafeDowncast($0, to: CFArray.self) }
    }

    /// A CGPoint attribute (position); nil if the call fails.
    func pointAttribute(_ name: String) -> CGPoint?
    {
        guard let value = attribute(name) else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point)
        return point
    }

    /// A CGSize attribute (size); nil if the call fails.
    func sizeAttribute(_ name: String) -> CGSize?
    {
        guard let value = attribute(name) else { return nil }
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size)
        return size
    }

    /// `AXUIElementSetAttributeValue` with a boolean.
    @discardableResult func setAttribute(_ name: String, to value: Bool) -> AXError
    {
        return AXUIElementSetAttributeValue(self, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// `AXUIElementSetAttributeValue` with a CGPoint; .failure without a call when the AXValue cannot be created.
    @discardableResult func setAttribute(_ name: String, to point: CGPoint) -> AXError
    {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    /// `AXUIElementSetAttributeValue` with a CGSize; .failure without a call when the AXValue cannot be created.
    @discardableResult func setAttribute(_ name: String, to size: CGSize) -> AXError
    {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    /// `AXUIElementIsAttributeSettable`; false if the call fails.
    func isAttributeSettable(_ name: String) -> Bool
    {
        var result: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(self, name as CFString, &result) != .success { return false }
        return result.boolValue
    }

    /// `AXUIElementPerformAction`
    @discardableResult func perform(_ action: String) -> AXError
    {
        return AXUIElementPerformAction(self, action as CFString)
    }

    /// `AXUIElementCopyElementAtPosition`, asked of the system-wide element: the element at the point.
    func element(at point: CGPoint) -> AXUIElement?
    {
        var element: AXUIElement?
        AXUIElementCopyElementAtPosition(self, Float(point.x), Float(point.y), &element)
        return element
    }

    /// The attribute that some applications use to animate frame changes.
    static var enhancedUserInterfaceAttribute: String { return "AXEnhancedUserInterface" }

    /// Turns AXEnhancedUserInterface off around the body, which some applications need to apply a frame at once.
    func withEnhancedUserInterfaceDisabled(_ body: () -> Void)
    {
        let enabled = boolAttribute(Self.enhancedUserInterfaceAttribute)
        if enabled { setAttribute(Self.enhancedUserInterfaceAttribute, to: false) }
        body()
        if enabled { setAttribute(Self.enhancedUserInterfaceAttribute, to: true) }
    }
}

extension AXObserver
{
    /// `AXObserverCreate`; nil if the call fails.
    static func create(pid: pid_t, callback: AXObserverCallback) -> AXObserver?
    {
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success else { return nil }
        return observer
    }

    /// `AXObserverAddNotification`
    @discardableResult func add(_ notification: String, for element: AXUIElement, context: UnsafeMutableRawPointer?) -> AXError
    {
        return AXObserverAddNotification(self, element, notification as CFString, context)
    }

    /// `AXObserverRemoveNotification`
    @discardableResult func remove(_ notification: String, for element: AXUIElement) -> AXError
    {
        return AXObserverRemoveNotification(self, element, notification as CFString)
    }

    /// `AXObserverGetRunLoopSource`
    var runLoopSource: CFRunLoopSource { return AXObserverGetRunLoopSource(self) }
}
