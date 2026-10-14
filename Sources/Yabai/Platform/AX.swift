import ApplicationServices
import CPrivate

//
// NOTE: A Swift view of an AXUIElementRef, for the code that the port moves to Swift. AX calls block for as long as the
// application takes to answer, up to the messaging timeout; the callers on the event loop accept that, like the C code.
//

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

    /// `_AXUIElementGetWindow`; 0 if the element is not a window, like `ax_window_id`.
    var windowID: UInt32
    {
        var wid: UInt32 = 0
        _AXUIElementGetWindow(ref, &wid)
        return wid
    }
}
