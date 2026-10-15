import Carbon
import Foundation
import CPrivate
import YabaiC
import YabaiCore

//
// NOTE: The processes of the session, from the Carbon application events. The event handler runs on the main thread and
// only keeps the process table and posts events; the handlers run on the event loop. struct process and struct
// process_manager stay C while window_manager*.c reads them (finder_psn, the process table). Ported from
// src/process_manager.c.
//

private let processNameBlacklist =
[
    "Übersicht",
    "Slack Helper (Plugin)",
    "Google Chrome Helper (Plugin)",
    "qlmanage",
]

// 'XPC!'
private let processTypeXPC: OSType = 0x58504321

private func processCreate(_ psn: ProcessSerialNumber, _ pid: pid_t) -> UnsafeMutablePointer<process>?
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

    let result = malloc(MemoryLayout<process>.size)!.bindMemory(to: process.self, capacity: 1)
    result.initialize(to: process(psn: psn, pid: pid, name: processName, ns_application: nil, policy: 0, launch_attempts: 0, launch_given_up: false, terminated: false))
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
    let pm = context!.assumingMemoryBound(to: process_manager.self)

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

        _table_add(&pm.pointee.process, &process.pointee.psn, Int32(MemoryLayout<ProcessSerialNumber>.size), process)
        EventLoop.post(.applicationLaunched(Handoff(value: process)))
    case kEventAppTerminated:
        guard let process = process_manager_find_process(pm, &psn) else { return noErr }

        //
        // NOTE: The handlers on the event loop read terminated (process_is_terminated); posting the event below orders
        // these writes before the handler of the event, as the compiler barrier of the C version did.
        //

        process_set_terminated(process, true)
        table_remove(&pm.pointee.process, &psn)
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

private func processManagerAddRunningProcesses(_ pm: UnsafeMutablePointer<process_manager>)
{
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
    while ProcessGetNextC(&psn) == noErr {
        let pid = ProcessGetPIDC(psn)
        if processIsBeingDebugged(pid) {
            debug("process_manager_add_running_processes: process with pid \(pid) is running under a debugger! ignoring..\n")
            continue
        }

        guard let process = processCreate(psn, pid) else { continue }

        if strcmp(process.pointee.name, "Finder") == 0 {
            debug("process_manager_add_running_processes: \(describe(process)) was found! caching psn..\n")
            pm.pointee.finder_psn = psn
        }

        _table_add(&pm.pointee.process, &process.pointee.psn, Int32(MemoryLayout<ProcessSerialNumber>.size), process)
    }
}

/// `process_manager_begin`: called by yabai_main on the main thread, before the event loop starts.
@_cdecl("process_manager_begin")
func process_manager_begin(_ pm: UnsafeMutablePointer<process_manager>) -> Bool
{
    pm.pointee.target = GetApplicationEventTarget()
    pm.pointee.handler = processHandler
    pm.pointee.type.0 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppLaunched))
    pm.pointee.type.1 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppTerminated))
    pm.pointee.type.2 = EventTypeSpec(eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppFrontSwitched))
    table_init(&pm.pointee.process, 125, { key in UInt(key!.load(as: ProcessSerialNumber.self).lowLongOfPSN) }, { keyA, keyB in
        psn_equals(keyA!.assumingMemoryBound(to: ProcessSerialNumber.self), keyB!.assumingMemoryBound(to: ProcessSerialNumber.self)) ? 1 : 0
    })

    autoreleasepool {
        processManagerAddRunningProcesses(pm)
    }

    pm.pointee.front_pid = ProcessGetPIDC(SLS.frontProcess())
    pm.pointee.last_front_pid = pm.pointee.front_pid
    pm.pointee.switch_event_time = GetCurrentEventTime()

    //
    // NOTE: The handler gets pm as its context: g_process_manager lives as long as the daemon, and the handler is
    // never removed.
    //

    return withUnsafeMutablePointer(to: &pm.pointee.type) { types in
        types.withMemoryRebound(to: EventTypeSpec.self, capacity: 3) { types in
            InstallEventHandler(pm.pointee.target, pm.pointee.handler, 3, types, UnsafeMutableRawPointer(pm), &pm.pointee.ref) == noErr
        }
    }
}

/// `process_manager_find_process`
func process_manager_find_process(_ pm: UnsafeMutablePointer<process_manager>, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> UnsafeMutablePointer<process>?
{
    return table_find(&pm.pointee.process, psn)?.assumingMemoryBound(to: process.self)
}

/// `process_destroy`
func process_destroy(_ process: UnsafeMutablePointer<process>)
{
    workspace_application_destroy_running_ns_application(process)
    free(process.pointee.name)
    free(process)
}
