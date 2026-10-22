import Logging

//
// NOTE: The notification types of the window server connection, registered by Daemon.run with SLSRegisterConnectionNotifyProc.
// Registration follows the declaration order below, so keep it when a case is added. The payload of each type is the id
// of the object it names: UInt64 for a space, UInt32 for a window. The window server sends a payload of the expected size,
// but the handler still checks the length before it reads.
//

/// A window server connection notification type.
enum SLSNotification: UInt32, CaseIterable
{
    /// A space was created; the payload is its `SpaceID` (UInt64).
    case spaceCreated = 1327

    /// A space was destroyed; the payload is its `SpaceID` (UInt64).
    case spaceDestroyed = 1328

    /// A window was ordered in or out; the payload is its `WindowID` (UInt32).
    case windowOrdered = 808

    //
    // NOTE: Moves, resizes and hides of windows that have a border. Border.swift updates the border of the window.
    //

    /// A window moved; the payload is its `WindowID` (UInt32).
    case windowMoved = 806

    /// A window was resized; the payload is its `WindowID` (UInt32).
    case windowResized = 807

    /// A window's content or appearance changed; the payload is its `WindowID` (UInt32).
    case windowChanged = 815

    /// A window was hidden; the payload is its `WindowID` (UInt32).
    case windowHidden = 816

    /// Cmd-tab was pressed. The handler reads no payload.
    case cmdTab = 1202

    /// A window was destroyed; the payload is its `WindowID` (UInt32).
    case windowDestroyed = 804

    /// Decodes a payload of type `T` with `loadUnaligned`. nil when there is no buffer or it is shorter than `T`.
    static func payload<T: BitwiseCopyable>(_ data: UnsafeMutableRawPointer?, _ length: Int, as type: T.Type) -> T?
    {
        guard let data, length >= MemoryLayout<T>.size else { return nil }
        return data.loadUnaligned(as: T.self)
    }
}
