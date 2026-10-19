import ApplicationServices
import Dispatch
import CPrivate
import AppKit
import YabaiCore

//
// NOTE: Focusing windows through synthesized event records, and the window that commands act on.
//

/// The options of `_SLPSSetFrontProcessWithOptions`: activate a process for a user action, or without raising any of
/// its windows.
enum FrontProcessMode: UInt32
{
    case userGenerated = 0x200
    case noWindows     = 0x400
}

/// The size of the event records that SLPSPostEventRecordTo sends.
private let eventRecordSize = 0x100

extension WindowManager
{
    /// Runs the body with a zeroed event record, which it fills and posts.
    private static func withEventRecord(_ fill: (UnsafeMutablePointer<UInt8>) -> Void)
    {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: eventRecordSize) { buffer in
            let bytes = buffer.baseAddress!
            bytes.initialize(repeating: 0, count: eventRecordSize)
            fill(bytes)
        }
    }

    /// Writes a window id into an event record at the offset; 0 for no window, as the window server reads it.
    private static func storeWindowID(_ bytes: UnsafeMutablePointer<UInt8>, at offset: Int, _ windowID: WindowID?)
    {
        UnsafeMutableRawPointer(bytes + offset).storeBytes(of: windowID?.rawValue ?? 0, as: UInt32.self)
    }

    /// Posts the synthesized events that make an application window key.
    private static func makeKeyWindow(_ process: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: WindowID)
    {
        //
        // :SynthesizedEvent
        //
        // NOTE: These events are picked up by an event tap at the "Annotated Session" location, so they flow to an
        // application as session events.
        //

        withEventRecord { bytes in
            bytes[0x04] = 0xf8
            bytes[0x3a] = 0x10
            storeWindowID(bytes, at: 0x3c, windowID)
            (bytes + 0x20).update(repeating: 0xff, count: 0x10)

            bytes[0x08] = 0x01
            SLPSPostEventRecordTo(process, bytes)

            bytes[0x08] = 0x02
            SLPSPostEventRecordTo(process, bytes)
        }
    }

    //
    // NOTE: An event record of type 0x0d tells the application of windowID that the window lost (0x02) or gained
    // (0x01) focus, so focus can move between windows of one application without raising them.
    //
    private static func postFocusRecord(to process: UnsafeMutablePointer<ProcessSerialNumber>, windowID: WindowID?, state: UInt8)
    {
        withEventRecord { bytes in
            bytes[0x04] = 0xf8
            bytes[0x08] = 0x0d

            bytes[0x8a] = state
            storeWindowID(bytes, at: 0x3c, windowID)
            SLPSPostEventRecordTo(process, bytes)
        }
    }

    func focusWithoutRaise(_ target: Window)
    {
        if psn_equals(&target.application.psn, &focusedWindowPSN) {
            Self.postFocusRecord(to: &focusedWindowPSN, windowID: focusedWindowID, state: 0x02)

            //
            // @hack
            // Artificially delay the activation by 40ms. This is necessary
            // because some applications appear to be confused if both of the
            // events appear instantaneously.
            //
            // NOTE: The activation is posted back to the event loop instead of sleeping,
            // so that the event loop keeps handling events in the meantime.
            //

            let windowID = target.id
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
                EventLoop.post(.windowFocusDeferred(windowID: windowID))
            }

            return
        }

        _SLPSSetFrontProcessWithOptions(&target.application.psn, target.id.rawValue, FrontProcessMode.userGenerated.rawValue)
        Self.makeKeyWindow(&target.application.psn, target.id)
    }

    func focusWithoutRaiseDeferred(_ target: Window)
    {
        Self.postFocusRecord(to: &target.application.psn, windowID: target.id, state: 0x01)

        _SLPSSetFrontProcessWithOptions(&target.application.psn, target.id.rawValue, FrontProcessMode.userGenerated.rawValue)
        Self.makeKeyWindow(&target.application.psn, target.id)
    }

    func focusWithRaise(_ target: Window)
    {
        focusWithRaise(process: &target.application.psn, windowID: target.id, reference: target.ref)
    }

    /// Focuses a window that is not represented by a managed `Window` model.
    func focusWithRaise(process: UnsafeMutablePointer<ProcessSerialNumber>, windowID: WindowID, reference: AXUIElement)
    {
        _SLPSSetFrontProcessWithOptions(process, windowID.rawValue, FrontProcessMode.userGenerated.rawValue)
        Self.makeKeyWindow(process, windowID)
        AXUIElementPerformAction(reference, kAXRaiseAction as CFString)
    }

    var focusedApplication: Application?
    {
        let process = SLS.frontProcess()
        return application(for: ProcessGetPIDC(process))
    }

    var focusedWindow: Window?
    {
        guard let owner = focusedApplication else { return nil }
        guard let windowID = owner.focusedWindowID else { return nil }
        return window(for: windowID)
    }

    //
    // NOTE: A window focused by a command only reports its focus once the application has processed the
    // activation, which can take longer than it takes to send the next command. Until then, the next command
    // acts on the window that was asked to be focused, instead of the one the application still reports.
    //

    /// How long a pending focus stays valid, in milliseconds.
    private var pendingFocusTimeoutMs: Float { 500.0 }

    func setPendingFocus(_ windowID: WindowID)
    {
        pendingFocusWindowID = windowID
        pendingFocusTime = read_os_timer()
    }

    var pendingFocusWindow: Window?
    {
        guard let pendingID = pendingFocusWindowID else { return nil }

        let dt = os_timer_ms_between(pendingFocusTime, read_os_timer())
        let target = dt < pendingFocusTimeoutMs ? window(for: pendingID) : nil
        if target == nil { pendingFocusWindowID = nil }

        return target
    }

    var actingWindow: Window? { pendingFocusWindow ?? focusedWindow }

    //
    // NOTE: Asking the frontmost application for its focused window is an accessibility round trip, which
    // blocks for up to the accessibility timeout when the application does not respond. When the front
    // process still owns the window that last received focus, and no focus change has been reported since,
    // that window is still the focused one and the question can be skipped. The display and space of the
    // window are always looked up again.
    //

    func canUseKnownFocus(front: ProcessSerialNumber, pendingFocus: Bool) -> Bool
    {
        if pendingFocus { return false }
        if focusedWindowID == nil { return false }

        var front = front
        return psn_equals(&front, &focusedWindowPSN)
    }
}
