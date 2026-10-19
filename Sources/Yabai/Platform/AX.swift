import ApplicationServices
import CPrivate
import YabaiCore

//
// NOTE: A Swift view of an AXUIElementRef, for the code that the port moves to Swift. AX calls block for as long as the
// application takes to answer, up to the messaging timeout; the callers on the event loop accept that, like the C code.
//

/// The name of an AXError for the debug output, as `ax_error_str` (src/application.h) has it.
func axErrorName(_ error: AXError) -> String
{
    switch error {
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
    @unknown default:                        return "\(error.rawValue)"
    }
}

struct AXElement
{
    let ref: AXUIElement

    /// `_AXUIElementCreateWithRemoteToken`: the element of another process by its remote token, as
    /// `window_manager_discovery.c` builds it (pid, the 'coco' magic and an element id).
    init?(remoteToken: Data)
    {
        guard let ref = _AXUIElementCreateWithRemoteToken(remoteToken as CFData) else { return nil }
        self.ref = ref
    }

    init(_ ref: AXUIElement)
    {
        self.ref = ref
    }

    /// `AXUIElementCopyAttributeValue`; nil if the call fails.
    func attribute(_ name: String) -> CFTypeRef?
    {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// `kAXTitleAttribute` (`window_title`)
    var title: String?
    {
        return attribute(kAXTitleAttribute) as? String
    }

    /// `kAXRoleAttribute` (`window_ax_role`)
    var role: String?
    {
        return attribute(kAXRoleAttribute) as? String
    }

    /// `kAXSubroleAttribute` (`window_ax_subrole`)
    var subrole: String?
    {
        return attribute(kAXSubroleAttribute) as? String
    }

    /// `_AXUIElementGetWindow`; nil if the element is not a window, like `ax_window_id`.
    var windowID: WindowID?
    {
        var wid: UInt32 = 0
        _AXUIElementGetWindow(ref, &wid)
        return WindowID(nonzero: wid)
    }
}
