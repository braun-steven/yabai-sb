import ApplicationServices
import CPrivate
import AppKit
import YabaiCore

//
// NOTE: Focusing windows through synthesized event records, and the window that commands act on.
//

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
    private static func makeKeyWindow(_ process: ProcessSerialNumber, _ windowID: WindowID)
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
            SLS.postEventRecord(bytes, to: process)

            bytes[0x08] = 0x02
            SLS.postEventRecord(bytes, to: process)
        }
    }

    //
    // NOTE: An event record of type 0x0d tells the application of windowID that the window lost (0x02) or gained
    // (0x01) focus, so focus can move between windows of one application without raising them.
    //
    private static func postFocusRecord(to process: ProcessSerialNumber, windowID: WindowID?, state: UInt8)
    {
        withEventRecord { bytes in
            bytes[0x04] = 0xf8
            bytes[0x08] = 0x0d

            bytes[0x8a] = state
            storeWindowID(bytes, at: 0x3c, windowID)
            SLS.postEventRecord(bytes, to: process)
        }
    }

    func focusWithoutRaise(_ target: Window)
    {
        if target.application.psn.isSame(as: focus.focusedPSN) {
            Self.postFocusRecord(to: focus.focusedPSN, windowID: focus.focused, state: 0x02)

            //
            // @hack
            // Artificially delay the activation by 40ms. This is necessary
            // because some applications appear to be confused if both of the
            // events appear instantaneously.
            //
            // NOTE: The activation is posted back to the event loop instead of sleeping,
            // so that the event loop keeps handling events in the meantime.
            //

            EventLoop.post(.windowFocusDeferred(windowID: target.id), after: .milliseconds(40))

            return
        }

        SLS.setFrontProcess(target.application.psn, window: target.id, mode: .userGenerated)
        Self.makeKeyWindow(target.application.psn, target.id)
    }

    func focusWithoutRaiseDeferred(_ target: Window)
    {
        Self.postFocusRecord(to: target.application.psn, windowID: target.id, state: 0x01)

        SLS.setFrontProcess(target.application.psn, window: target.id, mode: .userGenerated)
        Self.makeKeyWindow(target.application.psn, target.id)
    }

    func focusWithRaise(_ target: Window)
    {
        focusWithRaise(process: target.application.psn, windowID: target.id, reference: target.ref)
    }

    /// Focuses a window that is not represented by a managed `Window` model.
    func focusWithRaise(process: ProcessSerialNumber, windowID: WindowID, reference: AXUIElement)
    {
        SLS.setFrontProcess(process, window: windowID, mode: .userGenerated)
        Self.makeKeyWindow(process, windowID)
        reference.perform(kAXRaiseAction)
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

    func setPendingFocus(_ windowID: WindowID)
    {
        focus.setPending(windowID, at: OSTimer.now)
    }

    /// The window of the pending focus, when it has not expired and its window exists. Consuming it drops an expired
    /// pending focus, and one whose window is gone.
    func consumePendingFocusWindow(now: UInt64) -> Window?
    {
        guard let pendingID = focus.consumePending(now: now) else { return nil }

        let target = window(for: pendingID)
        if target == nil { focus.clearPending() }

        return target
    }

    /// The window that commands act on: the pending focus, or else the focused window.
    func actingWindow() -> Window?
    {
        consumePendingFocusWindow(now: OSTimer.now) ?? focusedWindow
    }

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
        if focus.focused == nil { return false }

        return front.isSame(as: focus.focusedPSN)
    }
}
