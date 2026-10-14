import CoreFoundation
import CPrivate

//
// NOTE: Swift wrappers of the CoreDock functions in CPrivate.h, for the code that the port moves to Swift.
//

enum CoreDock
{
    /// `CoreDockGetAutoHideEnabled` (`display_manager_dock_hidden`)
    static var autoHideEnabled: Bool
    {
        return CoreDockGetAutoHideEnabled()
    }

    /// `CoreDockGetOrientationAndPinning`; `display_manager_dock_orientation` uses the orientation.
    static var orientationAndPinning: (orientation: Int32, pinning: Int32)
    {
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        CoreDockGetOrientationAndPinning(&orientation, &pinning)
        return (orientation, pinning)
    }

    /// `CoreDockSendNotification`, e.g. `com.apple.expose.awake` for Mission Control.
    static func sendNotification(_ name: String)
    {
        CoreDockSendNotification(name as CFString, 0)
    }
}
