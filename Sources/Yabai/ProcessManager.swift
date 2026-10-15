import Carbon
import Foundation
import CPrivate
import Synchronization
import YabaiCore

//
// NOTE: The processes of the session, from the Carbon application events. The event handler runs on the main thread and
// only keeps the process table and posts events; the handlers run on the event loop. Ported from src/process_manager.c.
//

/// `struct process`: the process owns the malloc'ed name, which its application borrows.
final class Process
{
    var psn: ProcessSerialNumber
    var pid: pid_t
    var name: UnsafeMutablePointer<CChar>!

    //
    // NOTE: terminated and ns_application (the NSRunningApplication at +1) are also written on other threads, and read
    // through the functions below. The key-value observer reads terminated with acquire, as workspace.m did.
    //

    let ns_application = Atomic<UnsafeMutableRawPointer?>(nil)
    var policy: Int32 = 0
    var launch_attempts: Int32 = 0
    var launch_given_up = false
    let terminated = Atomic<Bool>(false)

    init(psn: ProcessSerialNumber, pid: pid_t, name: UnsafeMutablePointer<CChar>)
    {
        self.psn = psn
        self.pid = pid
        self.name = name
    }
}

func process_is_terminated(_ process: Process) -> Bool { process.terminated.load(ordering: .relaxed) }
func process_is_terminated_acquire(_ process: Process) -> Bool { process.terminated.load(ordering: .acquiring) }
func process_set_terminated(_ process: Process, _ terminated: Bool) { process.terminated.store(terminated, ordering: .releasing) }
func process_ns_application(_ process: Process) -> UnsafeMutableRawPointer? { process.ns_application.load(ordering: .relaxed) }
func process_set_ns_application(_ process: Process, _ application: UnsafeMutableRawPointer?) { process.ns_application.store(application, ordering: .releasing) }

/// `struct process_manager`
final class ProcessManager
{
    var process = Table<ProcessSerialNumber, Process>(capacity: 125, hash: { UInt($0.lowLongOfPSN) }, equals: { a, b in
        var a = a, b = b
        return psn_equals(&a, &b)
    })
    var target: EventTargetRef?
    var handler: EventHandlerUPP?
    var type = (EventTypeSpec(), EventTypeSpec(), EventTypeSpec())
    var ref: EventHandlerRef?
    var front_pid: pid_t = 0
    var last_front_pid: pid_t = 0
    var switch_event_time: EventTime = 0
    var finder_psn = ProcessSerialNumber()
}

/// `g_process_manager`: the Carbon handler changes the process table on the main thread, as in C (see the NOTE of
/// g_display_manager).
nonisolated(unsafe) let g_process_manager = ProcessManager()

func process_manager_global() -> ProcessManager
{
    g_process_manager
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

private func processCreate(_ psn: ProcessSerialNumber, _ pid: pid_t) -> Process?
{
    let processType = ProcessGetTypeC(psn)

    guard let processNameRef = ProcessCopyNameC(psn) else {
        debug("process_create: could not retrieve process name! ignoring..\n")
        return nil
    }

    let processName = cfstring_copy(processNameRef)!

    if processType == processTypeXPC {
        debug("process_create: xpc service '\(cName(processName))' detected! ignoring..\n")
        free(processName)
        return nil
    }

    for blacklisted in processNameBlacklist where strcmp(processName, blacklisted) == 0 {
        debug("process_create: \(cName(processName)) is blacklisted! ignoring..\n")
        free(processName)
        return nil
    }

    let result = Process(psn: psn, pid: pid, name: processName)
    process_set_terminated(result, false)
    process_set_ns_application(result, workspace_application_create_running_ns_application(result))
    return result
}

private func processIsBeingDebugged(_ pid: pid_t) -> Bool
{
    var info = kinfo_proc()
    info.kp_proc.p_flag = 0

    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

    sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    return (info.kp_proc.p_flag & P_TRACED) != 0
}

/// `process_manager_active_space_for_psn`: the space of the first user window of the connection, or 0.
func process_manager_active_space_for_psn(_ connection: Int32) -> UInt64
{
    let spaces = missionControlSpaces()
    if spaces.isEmpty { return 0 }

    guard let windows = SLS.windows(connection_global(), owner: UInt32(bitPattern: connection), spaces: spaces, options: 0x2), !windows.isEmpty else { return 0 }

    for window in SLS.queryWindows(connection_global(), windows) {
        if SpaceWindow.isUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes) {
            return window_space(window.id)
        }
    }

    return 0
}

private func processHandler(_ ref: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus
{
    let pm = Unmanaged<ProcessManager>.fromOpaque(context!).takeUnretainedValue()

    var psn = ProcessSerialNumber()
    if GetEventParameter(event, EventParamName(kEventParamProcessID), EventParamType(typeProcessSerialNumber), nil, MemoryLayout<ProcessSerialNumber>.size, nil, &psn) != noErr {
        return -1
    }

    switch Int(GetEventKind(event)) {
    case kEventAppLaunched:
        if process_manager_find_process(pm, &psn) != nil {

            //
            // NOTE(asmvik): Some garbage applications (e.g Steam) are reported twice with the same PID and PSN for some hecking reason.
            // It is by definition NOT possible for two processes to exist at the same time with the same PID and PSN.
            // If we detect such a scenario we simply discard the dupe notification..
            //

            return noErr
        }

        let pid = ProcessGetPIDC(psn)
        if processIsBeingDebugged(pid) {
            debug("process_handler: process with pid \(pid) is running under a debugger! ignoring..\n")
            return noErr
        }

        guard let process = processCreate(psn, pid) else { return noErr }

        pm.process.add(process.psn, process)
        EventLoop.post(.applicationLaunched(Handoff(value: process)))
    case kEventAppTerminated:
        guard let process = process_manager_find_process(pm, &psn) else { return noErr }

        //
        // NOTE: The handlers on the event loop read terminated (process_is_terminated); posting the event below orders
        // these writes before the handler of the event, as the compiler barrier of the C version did.
        //

        process_set_terminated(process, true)
        pm.process.remove(psn)
        workspace_application_unobserve(process)

        EventLoop.post(.applicationTerminated(Handoff(value: process)))
    case kEventAppFrontSwitched:
        guard let process = process_manager_find_process(pm, &psn) else { return noErr }

        EventLoop.post(.applicationFrontSwitched(Handoff(value: process)))
    default:
        break
    }

    return noErr
}

private func processManagerAddRunningProcesses(_ pm: ProcessManager)
{
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
    while ProcessGetNextC(&psn) == noErr {
        let pid = ProcessGetPIDC(psn)
        if processIsBeingDebugged(pid) {
            debug("process_manager_add_running_processes: process with pid \(pid) is running under a debugger! ignoring..\n")
            continue
        }

        guard let process = processCreate(psn, pid) else { continue }

        if strcmp(process.name, "Finder") == 0 {
            debug("process_manager_add_running_processes: \(describe(process)) was found! caching psn..\n")
            pm.finder_psn = psn
        }

        pm.process.add(process.psn, process)
    }
}

/// `process_manager_begin`: called by yabai_main on the main thread, before the event loop starts.
func process_manager_begin(_ pm: ProcessManager) -> Bool
{
    pm.target = GetApplicationEventTarget()
    pm.handler = processHandler
    pm.type.0 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppLaunched))
    pm.type.1 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppTerminated))
    pm.type.2 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppFrontSwitched))

    autoreleasepool {
        processManagerAddRunningProcesses(pm)
    }

    pm.front_pid = ProcessGetPIDC(SLS.frontProcess())
    pm.last_front_pid = pm.front_pid
    pm.switch_event_time = GetCurrentEventTime()

    //
    // NOTE: The handler gets pm as its context, unretained: g_process_manager lives as long as the daemon, and the
    // handler is never removed.
    //

    let target = pm.target
    let handler = pm.handler
    var types = [pm.type.0, pm.type.1, pm.type.2]
    var ref: EventHandlerRef?
    let result = InstallEventHandler(target, handler, 3, &types, Unmanaged.passUnretained(pm).toOpaque(), &ref) == noErr
    pm.ref = ref
    return result
}

/// `process_manager_find_process`
func process_manager_find_process(_ pm: ProcessManager, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> Process?
{
    return pm.process.find(psn.pointee)
}

/// `process_destroy`
func process_destroy(_ process: Process)
{
    workspace_application_destroy_running_ns_application(process)
    free(process.name)
    process.name = nil
}
