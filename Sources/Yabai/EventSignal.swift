import Carbon
import Darwin
import YabaiC
import YabaiCore

//
// NOTE: The signals of the daemon and the signals pushed while the current event is handled. The C event handlers
// push them through event_signal_push, and the event loop runs their commands after each handler
// (eventSignalFlush). Ported from src/event_signal.c; the table, the filters and the json are in
// Sources/YabaiCore/EventSignal.swift.
//

/// `g_signal_event`
@WM var eventSignals = SignalTable()

/// `g_signal_storage`: the signals pushed while the current event is handled.
@WM var pendingSignals: [PendingSignal] = []

/// `mission_control_mode_str` (src/mission_control.c), which Swift cannot read (a static C array).
private let missionControlModeNames = ["inactive", "show", "show-all-windows", "show-front-windows", "show-desktop"]

//
// NOTE: The C version forked a copy of the daemon for each event with signals, and that copy forked and exec'd a
// process for each command. Swift cannot call fork (it is unavailable: only async-signal-safe code may run between
// fork and exec in a multithreaded process, which Swift code is not), so the filters run here and posix_spawn starts
// each command directly. env sets the variables of the event and runs the command, as before.
//

private func eventSignalSpawn(_ command: String, _ arguments: [(name: String, value: String)])
{
    let argv = ["/usr/bin/env"] + arguments.map { "\($0.name)=\($0.value)" } + ["sh", "-c", command]
    var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { cArguments.forEach { free($0) } }

    var pid: pid_t = 0
    _ = posix_spawn(&pid, cArguments[0], nil, nil, &cArguments, environ_global())
}

/// `event_signal_flush`: runs the commands of the signals pushed while the event was handled.
@WM func eventSignalFlush()
{
    if pendingSignals.isEmpty { return }

    let pending = pendingSignals
    pendingSignals.removeAll(keepingCapacity: true)

    for es in pending {
        let subscribers = eventSignals.subscribers(es.type)
        debug("event_signal_flush: transmitting \(es.type.name) to \(subscribers.count) subscriber(s)\n")

        for signal in subscribers where !es.filters(signal) {
            eventSignalSpawn(signal.command ?? "", es.arguments)
        }
    }
}

private func string(_ s: UnsafeMutablePointer<CChar>?) -> String?
{
    s.map { String(cString: $0) }
}

private func describeApplication(_ es: inout PendingSignal, _ context: UnsafeMutableRawPointer?)
{
    let pm = process_manager_global()!.pointee

    switch es.type {
    case .applicationLaunched, .applicationActivated, .applicationDeactivated, .applicationVisible:
        let app = context!.assumingMemoryBound(to: application.self).pointee

        es.addArgument("YABAI_PROCESS_ID", "\(app.pid)")

        es.app = string(app.name)
    case .applicationTerminated:
        let app = context!.assumingMemoryBound(to: application.self).pointee

        es.addArgument("YABAI_PROCESS_ID", "\(app.pid)")

        es.app = string(app.name)

        //
        // NOTE(asmvik): We always receive an application_front_switched event *before* an application_terminated
        // event. We need to know the difference between a front_switched + application_terminated sequence and a regular
        // application switch followed by a user-initiated termination of the previously focused application. The system
        // events are triggered within an interval that appear to be impossible to match even with a user automated sequence.
        // The dt threshold below is triple the average interval computed, to allow for some leeway.
        //

        let dt = GetCurrentEventTime() - pm.switch_event_time
        if dt >= Double(Float(0.05)) {
            es.active = pm.front_pid == app.pid
        } else {
            es.active = pm.last_front_pid == app.pid
        }
    case .applicationFrontSwitched:
        es.addArgument("YABAI_PROCESS_ID", "\(pm.front_pid)")
        es.addArgument("YABAI_RECENT_PROCESS_ID", "\(pm.last_front_pid)")
    case .applicationHidden:
        let app = context!.assumingMemoryBound(to: application.self).pointee

        es.addArgument("YABAI_PROCESS_ID", "\(app.pid)")

        es.app = string(app.name)
        es.active = pm.front_pid == app.pid
    default:
        break
    }
}

private func describeWindow(_ es: inout PendingSignal, _ context: UnsafeMutableRawPointer?)
{
    let target = context!.assumingMemoryBound(to: window.self)
    let focusedWindowID = window_manager_global()!.pointee.focused_window_id

    switch es.type {
    case .windowCreated, .windowFocused, .windowDeminimized:
        es.addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: target.pointee.id))")

        es.app   = string(target.pointee.application.pointee.name)
        es.title = string(window_title_ts(target))
    case .windowDestroyed:
        es.addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: target.pointee.id))")

        es.app = target.pointee.application.map { string($0.pointee.name) } ?? "<unknown>"
        es.active = focusedWindowID == target.pointee.id
    case .windowMoved, .windowResized, .windowMinimized, .windowTitleChanged:
        es.addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: target.pointee.id))")

        es.app   = string(target.pointee.application.pointee.name)
        es.title = string(window_title_ts(target))
        es.active = focusedWindowID == target.pointee.id
    default:
        break
    }
}

/// `event_signal_describe_space`
func describeSpace(_ es: inout PendingSignal, _ context: UnsafeMutableRawPointer?)
{
    switch es.type {
    case .spaceCreated:
        let sid = UInt64(UInt(bitPattern: context))
        let index = space_manager_mission_control_index(sid)

        es.addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid))")
        es.addArgument("YABAI_SPACE_INDEX", "\(index)")
    case .spaceDestroyed:
        let sid = UInt64(UInt(bitPattern: context))

        es.addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid))")
    case .spaceChanged:
        let sm = space_manager_global()!.pointee
        let sid = sm.current_space_id
        let recentSid = sm.last_space_id

        let index = space_manager_mission_control_index(sid)
        let recentIndex = space_manager_mission_control_index(recentSid)

        es.addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid))")
        es.addArgument("YABAI_RECENT_SPACE_ID", "\(Int64(bitPattern: recentSid))")

        es.addArgument("YABAI_SPACE_INDEX", "\(index)")
        es.addArgument("YABAI_RECENT_SPACE_INDEX", "\(recentIndex)")
    default:
        break
    }
}

/// `event_signal_describe_display`
func describeDisplay(_ es: inout PendingSignal, _ context: UnsafeMutableRawPointer?)
{
    switch es.type {
    case .displayAdded, .displayMoved, .displayResized:
        let did = UInt32(truncatingIfNeeded: UInt(bitPattern: context))
        let index = display_manager_display_id_arrangement(did)

        es.addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did))")
        es.addArgument("YABAI_DISPLAY_INDEX", "\(index)")
    case .displayRemoved:
        let did = UInt32(truncatingIfNeeded: UInt(bitPattern: context))

        es.addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did))")
    case .displayChanged:
        let dm = display_manager_global()!.pointee
        let did = dm.current_display_id
        let recentDid = dm.last_display_id

        let index = display_manager_display_id_arrangement(did)
        let recentIndex = display_manager_display_id_arrangement(recentDid)

        es.addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did))")
        es.addArgument("YABAI_RECENT_DISPLAY_ID", "\(Int32(bitPattern: recentDid))")

        es.addArgument("YABAI_DISPLAY_INDEX", "\(index)")
        es.addArgument("YABAI_RECENT_DISPLAY_INDEX", "\(recentIndex)")
    default:
        break
    }
}

private func describeMissionControl(_ es: inout PendingSignal, _ context: UnsafeMutableRawPointer?)
{
    let mode = Int(bitPattern: context)
    es.addArgument("YABAI_MISSION_CONTROL_MODE", missionControlModeNames[mode])
}

/// `event_signal_push`: stores a signal of the event that is handled, with the values its commands get, when the
/// event type has signals. The context is the object of the event (an application, a window, a space or display id,
/// the Mission Control mode).
@WM func eventSignalPush(_ type: SignalType, _ context: UnsafeMutableRawPointer?)
{
    if eventSignals.subscribers(type).isEmpty { return }

    var es = PendingSignal(type)

    switch type {
    case .applicationLaunched, .applicationActivated, .applicationDeactivated, .applicationVisible,
         .applicationTerminated, .applicationFrontSwitched, .applicationHidden:
        describeApplication(&es, context)
    case .windowCreated, .windowFocused, .windowDeminimized, .windowDestroyed,
         .windowMoved, .windowResized, .windowMinimized, .windowTitleChanged:
        describeWindow(&es, context)
    case .spaceCreated, .spaceDestroyed, .spaceChanged:
        describeSpace(&es, context)
    case .displayAdded, .displayMoved, .displayResized, .displayRemoved, .displayChanged:
        describeDisplay(&es, context)
    case .missionControlEnter, .missionControlExit:
        describeMissionControl(&es, context)
    default:
        break
    }

    pendingSignals.append(es)
}

@_cdecl("event_signal_push")
func event_signal_push(_ type: signal_type, _ context: UnsafeMutableRawPointer?)
{
    guard let signalType = SignalType(rawValue: Int(type.rawValue)) else { return }
    let object = Handoff(value: context)
    WM.assumeIsolated { eventSignalPush(signalType, object.value) }
}
