import Carbon
import Foundation
import CPrivate
import Synchronization
import YabaiCore

//
// NOTE: The processes of the session, from the Carbon application events. The event handler runs on the main thread and
// only keeps the process table and posts events; the handlers run on the event loop.
//

final class ProcessManager
{
    var processes: [ProcessKey: Process] = [:]
    var target: EventTargetRef?
    var handler: EventHandlerUPP?
    var eventTypes = (EventTypeSpec(), EventTypeSpec(), EventTypeSpec())
    var handlerRef: EventHandlerRef?
    var frontPID: pid_t = 0
    var lastFrontPID: pid_t = 0
    var switchEventTime: EventTime = 0
    var finderPSN = ProcessSerialNumber()

    /// The Carbon handler changes the process table on the main thread, as the display manager does.
    nonisolated(unsafe) static let shared = ProcessManager()

    /// Called by yabai_main on the main thread, before the event loop starts.
    func begin() -> Bool
    {
        target = GetApplicationEventTarget()
        handler = processHandler
        eventTypes.0 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppLaunched))
        eventTypes.1 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppTerminated))
        eventTypes.2 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppFrontSwitched))

        autoreleasepool {
            addRunningProcesses()
        }

        frontPID = ProcessGetPIDC(SLS.frontProcess())
        lastFrontPID = frontPID
        switchEventTime = GetCurrentEventTime()

        //
        // NOTE: The handler gets the process manager as its context, unretained: ProcessManager.shared lives as long as the
        // daemon, and the handler is never removed.
        //

        var types = [eventTypes.0, eventTypes.1, eventTypes.2]
        var ref: EventHandlerRef?
        let result = InstallEventHandler(self.target, self.handler, 3, &types, Unmanaged.passUnretained(self).toOpaque(), &ref) == noErr
        handlerRef = ref
        return result
    }

    func process(for psn: ProcessSerialNumber) -> Process?
    {
        processes[ProcessKey(psn)]
    }

    /// The space of the first user window of the connection, or nil.
    func activeSpace(forConnection connection: Int32) -> SpaceID?
    {
        let spaces = SpaceID.all
        if spaces.isEmpty { return nil }

        guard let windows = SLS.windows(SLS.connection, owner: UInt32(bitPattern: connection), spaces: spaces, options: 0x2), !windows.isEmpty else { return nil }

        for window in SLS.queryWindows(SLS.connection, windows) {
            if SpaceWindow.isUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes) {
                return window.id.space
            }
        }

        return nil
    }

    fileprivate func createProcess(_ psn: ProcessSerialNumber, _ pid: pid_t) -> Process?
    {
        let processType = ProcessGetTypeC(psn)

        guard let processNameRef = ProcessCopyNameC(psn) else {
            debug("process_create: could not retrieve process name! ignoring..\n")
            return nil
        }

        let processName = processNameRef as String

        if processType == processTypeXPC {
            debug("process_create: xpc service '\(processName)' detected! ignoring..\n")
            return nil
        }

        for blacklisted in processNameBlacklist where processName.bytesEqual(blacklisted) {
            debug("process_create: \(processName) is blacklisted! ignoring..\n")
            return nil
        }

        let result = Process(psn: psn, pid: pid, name: processName)
        result.isTerminated = false
        result.attachRunningApplication()
        return result
    }

    fileprivate static func isBeingDebugged(_ pid: pid_t) -> Bool
    {
        var info = kinfo_proc()
        info.kp_proc.p_flag = 0

        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private func addRunningProcesses()
    {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
        while ProcessGetNextC(&psn) == noErr {
            let pid = ProcessGetPIDC(psn)
            if ProcessManager.isBeingDebugged(pid) {
                debug("process_manager_add_running_processes: process with pid \(pid) is running under a debugger! ignoring..\n")
                continue
            }

            guard let process = createProcess(psn, pid) else { continue }

            if process.name.bytesEqual("Finder") {
                debug("process_manager_add_running_processes: \(describe(process)) was found! caching psn..\n")
                finderPSN = psn
            }

            if processes[ProcessKey(process.psn)] == nil { processes[ProcessKey(process.psn)] = process }
        }
    }
}

private let processNameBlacklist =
[
    "Übersicht",
    "Slack Helper (Plugin)",
    "Google Chrome Helper (Plugin)",
    "qlmanage",
]

// 'XPC!'
private let processTypeXPC: OSType = 0x58504321

private func processHandler(_ ref: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus
{
    let pm = Unmanaged<ProcessManager>.fromOpaque(context!).takeUnretainedValue()

    var psn = ProcessSerialNumber()
    if GetEventParameter(event, EventParamName(kEventParamProcessID), EventParamType(typeProcessSerialNumber), nil, MemoryLayout<ProcessSerialNumber>.size, nil, &psn) != noErr {
        return -1
    }

    switch Int(GetEventKind(event)) {
    case kEventAppLaunched:
        if pm.process(for: psn) != nil {

            //
            // NOTE(asmvik): Some garbage applications (e.g Steam) are reported twice with the same PID and PSN for some hecking reason.
            // It is by definition NOT possible for two processes to exist at the same time with the same PID and PSN.
            // If we detect such a scenario we simply discard the dupe notification..
            //

            return noErr
        }

        let pid = ProcessGetPIDC(psn)
        if ProcessManager.isBeingDebugged(pid) {
            debug("process_handler: process with pid \(pid) is running under a debugger! ignoring..\n")
            return noErr
        }

        guard let process = pm.createProcess(psn, pid) else { return noErr }

        if pm.processes[ProcessKey(process.psn)] == nil { pm.processes[ProcessKey(process.psn)] = process }
        EventLoop.post(.applicationLaunched(Handoff(value: process)))
    case kEventAppTerminated:
        guard let process = pm.process(for: psn) else { return noErr }

        //
        // NOTE: The handlers on the event loop read terminated (isTerminated); posting the event below orders
        // these writes before the handler of the event, as the compiler barrier of the C version did.
        //

        process.isTerminated = true
        pm.processes.removeValue(forKey: ProcessKey(psn))
        process.unobserve()

        EventLoop.post(.applicationTerminated(Handoff(value: process)))
    case kEventAppFrontSwitched:
        guard let process = pm.process(for: psn) else { return noErr }

        EventLoop.post(.applicationFrontSwitched(Handoff(value: process)))
    default:
        break
    }

    return noErr
}
