import ApplicationServices
import Dispatch
import CPrivate
import AppKit

//
// NOTE: Focusing windows through synthesized event records, and the window that commands act on. Ported from
// src/window_manager_focus.c.
//

/// The options of `_SLPSSetFrontProcessWithOptions`: activate a process for a user action, or without raising any of
/// its windows.
enum FrontProcessMode: UInt32
{
    case userGenerated = 0x200
    case noWindows     = 0x400
}

// the size of the event records that SLPSPostEventRecordTo sends (g_event_bytes of yabai.c, 0x100 bytes)
private let eventRecordSize = 0x100

/// Runs the body with a zeroed event record, which it fills and posts.
private func withEventRecord(_ fill: (UnsafeMutablePointer<UInt8>) -> Void)
{
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: eventRecordSize) { buffer in
        let bytes = buffer.baseAddress!
        bytes.initialize(repeating: 0, count: eventRecordSize)
        fill(bytes)
    }
}

/// Writes a window id into an event record at the offset.
private func storeWindowID(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ windowID: UInt32)
{
    UnsafeMutableRawPointer(bytes + offset).storeBytes(of: windowID, as: UInt32.self)
}

/// `window_manager_make_key_window`
private func windowManagerMakeKeyWindow(_ windowPsn: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: UInt32)
{
    //
    // :SynthesizedEvent
    //
    // NOTE(asmvik): These events will be picked up by an event-tap
    // registered at the "Annotated Session" location; specifying that an
    // event-tap is placed at the point where session events have been
    // annotated to flow to an application.
    //

    withEventRecord { bytes in
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        storeWindowID(bytes, 0x3c, windowID)
        (bytes + 0x20).update(repeating: 0xff, count: 0x10)

        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(windowPsn, bytes)

        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(windowPsn, bytes)
    }
}

//
// NOTE: An event record of type 0x0d tells the application of window_id that the window lost (0x02) or
// gained (0x01) focus, so that focus can move between windows of one application without raising them.
//

/// `window_manager_post_focus_record`
private func windowManagerPostFocusRecord(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: UInt32, _ state: UInt8)
{
    withEventRecord { bytes in
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d

        bytes[0x8a] = state
        storeWindowID(bytes, 0x3c, windowID)
        SLPSPostEventRecordTo(psn, bytes)
    }
}

/// `window_manager_focus_window_without_raise`
func window_manager_focus_window_without_raise(_ windowPsn: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: UInt32)
{
    let wm = window_manager_global()

    if psn_equals(windowPsn, &wm.focused_window_psn) {
        windowManagerPostFocusRecord(&wm.focused_window_psn, wm.focused_window_id, 0x02)

        //
        // @hack
        // Artificially delay the activation by 40ms. This is necessary
        // because some applications appear to be confused if both of
        // the events appear instantaneously.
        //
        // NOTE: The activation is posted back to the event loop instead of sleeping,
        // so that the event loop keeps handling events in the meantime.
        //

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
            EventLoop.post(.windowFocusDeferred(windowID: windowID))
        }

        return
    }

    _SLPSSetFrontProcessWithOptions(windowPsn, windowID, FrontProcessMode.userGenerated.rawValue)
    windowManagerMakeKeyWindow(windowPsn, windowID)
}

/// `window_manager_focus_window_without_raise_deferred`
func window_manager_focus_window_without_raise_deferred(_ target: Window)
{
    windowManagerPostFocusRecord(&target.application.psn, target.id, 0x01)

    _SLPSSetFrontProcessWithOptions(&target.application.psn, target.id, FrontProcessMode.userGenerated.rawValue)
    windowManagerMakeKeyWindow(&target.application.psn, target.id)
}

//
// NOTE: The C version had a disabled alternative (#if 0) that focused through the scripting addition
// (scripting_addition_focus_window, SA_OPCODE_WINDOW_FOCUS), whose Dock function is not found on macOS 27.
//

/// `window_manager_focus_window_with_raise`
func window_manager_focus_window_with_raise(_ windowPsn: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: UInt32, _ windowRef: AXUIElement)
{
    _SLPSSetFrontProcessWithOptions(windowPsn, windowID, FrontProcessMode.userGenerated.rawValue)
    windowManagerMakeKeyWindow(windowPsn, windowID)
    AXUIElementPerformAction(windowRef, kAXRaiseAction as CFString)
}

/// `window_manager_focused_application`
func window_manager_focused_application(_ wm: WindowManager) -> Application?
{
    let psn = SLS.frontProcess()
    return window_manager_find_application(wm, ProcessGetPIDC(psn))
}

/// `window_manager_focused_window`
func window_manager_focused_window(_ wm: WindowManager) -> Window?
{
    guard let owner = window_manager_focused_application(wm) else { return nil }

    let windowID = application_focused_window(owner)
    return window_manager_find_window(wm, windowID)
}

//
// NOTE: A window focused by a command only reports its focus once the application has processed the
// activation, which can take longer than it takes to send the next command. Until then, the next command
// acts on the window that was asked to be focused, instead of the one the application still reports.
//

// PENDING_FOCUS_TIMEOUT_MS
private let pendingFocusTimeoutMs: Float = 500.0

/// `window_manager_set_pending_focus`
func window_manager_set_pending_focus(_ wm: WindowManager, _ windowID: UInt32)
{
    wm.pending_focus_window_id = windowID
    wm.pending_focus_time = read_os_timer()
}

/// `window_manager_pending_focus_window`
func window_manager_pending_focus_window(_ wm: WindowManager) -> Window?
{
    if wm.pending_focus_window_id == 0 { return nil }

    let dt = os_timer_ms_between(wm.pending_focus_time, read_os_timer())
    let target = dt < pendingFocusTimeoutMs ? window_manager_find_window(wm, wm.pending_focus_window_id) : nil
    if target == nil { wm.pending_focus_window_id = 0 }

    return target
}

/// `window_manager_acting_window`
func window_manager_acting_window(_ wm: WindowManager) -> Window?
{
    return window_manager_pending_focus_window(wm) ?? window_manager_focused_window(wm)
}
