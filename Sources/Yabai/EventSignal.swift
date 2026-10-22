import Carbon
import Darwin
import AppKit
import CPrivate
import YabaiCore
import Logging

//
// NOTE: The signals of the daemon and the signals pushed while the current event is handled. The event handlers
// push them with EventSignals.push, and the event loop runs their commands after each handler (EventSignals.flush).
// The table, the filters and the json are in Sources/YabaiCore/EventSignal.swift.
//

/// The object a signal describes, as the event handler pushes it.
enum SignalSubject
{
    case none
    case application(Application)
    case window(Window)
    case space(SpaceID)
    case display(DisplayID)
    case missionControl(MissionControlMode)

    var application: Application?
    {
        guard case .application(let value) = self else { return nil }
        return value
    }

    var window: Window?
    {
        guard case .window(let value) = self else { return nil }
        return value
    }

    var space: SpaceID?
    {
        guard case .space(let value) = self else { return nil }
        return value
    }

    var display: DisplayID?
    {
        guard case .display(let value) = self else { return nil }
        return value
    }

    var missionControlMode: MissionControlMode?
    {
        guard case .missionControl(let value) = self else { return nil }
        return value
    }
}

/// The signals of the daemon and the signals pushed while the current event is handled.
@WM final class EventSignals
{
    static let shared = EventSignals()

    /// The signals of each event type, in the order they were added.
    var table = SignalTable()

    /// The signals pushed while the current event is handled.
    private(set) var pending: [PendingSignal] = []

    /// Drops the pushed signals without running them (the tests reset them between cases).
    func discardPending() { pending.removeAll() }

    /// Stores a signal of the event that is handled, with the values its commands get, when the event type has
    /// signals. The subject is the object of the event (an application, a window, a space or display id, or the
    /// Mission Control mode).
    func push(_ type: SignalType, _ subject: SignalSubject = .none)
    {
        if table.subscribers(type).isEmpty { return }

        var es = PendingSignal(type)

        switch type {
        case .applicationLaunched, .applicationActivated, .applicationDeactivated, .applicationVisible,
             .applicationTerminated, .applicationFrontSwitched, .applicationHidden:
            es.describeApplication(subject)
        case .windowCreated, .windowFocused, .windowDeminimized, .windowDestroyed,
             .windowMoved, .windowResized, .windowMinimized, .windowTitleChanged:
            es.describeWindow(subject)
        case .spaceCreated, .spaceDestroyed, .spaceChanged:
            es.describeSpace(subject)
        case .displayAdded, .displayMoved, .displayResized, .displayRemoved, .displayChanged:
            es.describeDisplay(subject)
        case .missionControlEnter, .missionControlExit:
            es.describeMissionControl(subject)
        default:
            break
        }

        pending.append(es)
    }

    /// Runs the commands of the signals pushed while the event was handled.
    func flush()
    {
        if pending.isEmpty { return }

        let batch = pending
        pending.removeAll(keepingCapacity: true)

        for es in batch {
            let subscribers = table.subscribers(es.type)
            Logger.signals.debug("transmitting \(es.type.name) to \(subscribers.count) subscriber(s)")

            for signal in subscribers where !es.filters(signal) {
                spawn(signal.command ?? "", es.arguments)
            }
        }
    }

    //
    // NOTE: Swift cannot call fork: it is unavailable, and only async-signal-safe code may run between fork and exec in
    // a multithreaded process, which Swift code is not. So the filters run in the daemon, and posix_spawn starts each
    // command directly; env sets the variables of the event and runs the command.
    //

    private func spawn(_ command: String, _ arguments: [(name: String, value: String)])
    {
        let argv = ["/usr/bin/env"] + arguments.map { "\($0.name)=\($0.value)" } + ["sh", "-c", command]
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }

        var pid: pid_t = 0
        _ = posix_spawn(&pid, cArguments[0], nil, nil, &cArguments, environ_global())
    }
}

extension PendingSignal
{
    @WM fileprivate mutating func describeApplication(_ subject: SignalSubject)
    {
        let pm = ProcessManager.shared

        switch type {
        case .applicationLaunched, .applicationActivated, .applicationDeactivated, .applicationVisible:
            let application = subject.application!

            addArgument("YABAI_PROCESS_ID", "\(application.pid)")

            app = application.name
        case .applicationTerminated:
            let application = subject.application!

            addArgument("YABAI_PROCESS_ID", "\(application.pid)")

            app = application.name

            //
            // NOTE(asmvik): We always receive an application_front_switched event *before* an application_terminated
            // event. We need to know the difference between a front_switched + application_terminated sequence and a regular
            // application switch followed by a user-initiated termination of the previously focused application. The system
            // events are triggered within an interval that appear to be impossible to match even with a user automated sequence.
            // The dt threshold below is triple the average interval computed, to allow for some leeway.
            //

            let dt = GetCurrentEventTime() - pm.switchEventTime
            if dt >= Double(Float(0.05)) {
                active = pm.frontPID == application.pid
            } else {
                active = pm.lastFrontPID == application.pid
            }
        case .applicationFrontSwitched:
            addArgument("YABAI_PROCESS_ID", "\(pm.frontPID)")
            addArgument("YABAI_RECENT_PROCESS_ID", "\(pm.lastFrontPID)")
        case .applicationHidden:
            let application = subject.application!

            addArgument("YABAI_PROCESS_ID", "\(application.pid)")

            app = application.name
            active = pm.frontPID == application.pid
        default:
            break
        }
    }

    @WM fileprivate mutating func describeWindow(_ subject: SignalSubject)
    {
        let target = subject.window!
        let focusedWindowID = WindowManager.shared.focus.focused

        switch type {
        case .windowCreated, .windowFocused, .windowDeminimized:
            addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: target.id.rawValue))")

            app   = target.application.name
            title = target.cachedTitle
        case .windowDestroyed:
            addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: target.id.rawValue))")

            app = target.application.map { $0.name } ?? "<unknown>"
            active = focusedWindowID == target.id
        case .windowMoved, .windowResized, .windowMinimized, .windowTitleChanged:
            addArgument("YABAI_WINDOW_ID", "\(Int32(bitPattern: target.id.rawValue))")

            app   = target.application.name
            title = target.cachedTitle
            active = focusedWindowID == target.id
        default:
            break
        }
    }

    /// Describes a space signal: the id of the space, and for a space change the current and the recent space.
    @WM mutating func describeSpace(_ subject: SignalSubject)
    {
        switch type {
        case .spaceCreated:
            let sid = subject.space!
            let index = sid.missionControlIndex ?? 0

            addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid.rawValue))")
            addArgument("YABAI_SPACE_INDEX", "\(index)")
        case .spaceDestroyed:
            let sid = subject.space!

            addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid.rawValue))")
        case .spaceChanged:
            let sm = SpaceManager.shared
            let sid = sm.currentSpaceID
            let recentSid = sm.lastSpaceID

            let index = sid.flatMap { $0.missionControlIndex } ?? 0
            let recentIndex = recentSid.flatMap { $0.missionControlIndex } ?? 0

            addArgument("YABAI_SPACE_ID", "\(Int64(bitPattern: sid?.rawValue ?? 0))")
            addArgument("YABAI_RECENT_SPACE_ID", "\(Int64(bitPattern: recentSid?.rawValue ?? 0))")

            addArgument("YABAI_SPACE_INDEX", "\(index)")
            addArgument("YABAI_RECENT_SPACE_INDEX", "\(recentIndex)")
        default:
            break
        }
    }

    /// Describes a display signal: the id of the display, and for a display change the current and the recent display.
    @WM mutating func describeDisplay(_ subject: SignalSubject)
    {
        switch type {
        case .displayAdded, .displayMoved, .displayResized:
            let did = subject.display!
            let index = did.arrangement ?? 0

            addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did.rawValue))")
            addArgument("YABAI_DISPLAY_INDEX", "\(index)")
        case .displayRemoved:
            let did = subject.display!

            addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did.rawValue))")
        case .displayChanged:
            let dm = DisplayManager.shared
            let did = dm.currentDisplayID
            let recentDid = dm.lastDisplayID

            let index = did.flatMap { $0.arrangement } ?? 0
            let recentIndex = recentDid.flatMap { $0.arrangement } ?? 0

            addArgument("YABAI_DISPLAY_ID", "\(Int32(bitPattern: did?.rawValue ?? 0))")
            addArgument("YABAI_RECENT_DISPLAY_ID", "\(Int32(bitPattern: recentDid?.rawValue ?? 0))")

            addArgument("YABAI_DISPLAY_INDEX", "\(index)")
            addArgument("YABAI_RECENT_DISPLAY_INDEX", "\(recentIndex)")
        default:
            break
        }
    }

    fileprivate mutating func describeMissionControl(_ subject: SignalSubject)
    {
        let mode = subject.missionControlMode!
        addArgument("YABAI_MISSION_CONTROL_MODE", mode.name)
    }
}
