import CPrivate
import Carbon
import Foundation
import Logging
import Synchronization
import YabaiCore

//
// NOTE: Carbon's process callback runs on the main thread and only posts ProcessKey values. The event loop owns and
// accesses this process table; startup enumeration completes before the callback is installed.
//

@WM final class ProcessManager {
  var processes: [ProcessKey: Process] = [:]
  var frontPID: pid_t = 0
  var lastFrontPID: pid_t = 0
  var switchEventTime: EventTime = 0
  var finderPSN = ProcessSerialNumber()

  /// The Carbon handler posts process keys; the event loop owns the process table.
  nonisolated static let shared = ProcessManager()

  /// Called by Daemon.run on the main thread: enumerates the running processes on the event loop's queue, then
  /// installs the Carbon handler, which runs only once the main run loop does.
  nonisolated func begin() -> Bool {
    WM.sync {
      autoreleasepool {
        ProcessManager.shared.addRunningProcesses()
      }

      ProcessManager.shared.frontPID = ProcessGetPIDC(SLS.frontProcess())
      ProcessManager.shared.lastFrontPID = ProcessManager.shared.frontPID
      ProcessManager.shared.switchEventTime = GetCurrentEventTime()
    }

    var types = [
      EventTypeSpec(
        eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppLaunched)),
      EventTypeSpec(
        eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppTerminated)),
      EventTypeSpec(
        eventClass: OSType(kEventClassApplication), eventKind: UInt32(kEventAppFrontSwitched)),
    ]
    return InstallEventHandler(GetApplicationEventTarget(), processHandler, 3, &types, nil, nil)
      == noErr
  }

  func process(for key: ProcessKey) -> Process? {
    processes[key]
  }

  /// The space of the first user window of the connection, or nil (also when the connection is unknown).
  func activeSpace(forConnection connection: Int32?) -> SpaceID? {
    guard let connection else { return nil }

    let spaces = SpaceID.all
    if spaces.isEmpty { return nil }

    guard
      let windows = SLS.windows(SLS.connection, owner: connection, spaces: spaces, options: 0x2),
      !windows.isEmpty
    else { return nil }

    for window in SLS.queryWindows(SLS.connection, windows) {
      if SpaceWindow.isUserWindow(
        parentID: window.parent, level: window.level, tags: window.tags,
        attributes: window.attributes)
      {
        return window.id.space
      }
    }

    return nil
  }

  func processLaunched(_ key: ProcessKey) -> Process? {
    guard processes[key] == nil else {

      //
      // NOTE: Carbon can report the same launch twice with the same PID and PSN (for example Steam). A PID and
      // PSN pair cannot identify two simultaneous processes, so discard the duplicate notification.
      //

      return nil
    }

    let psn = ProcessSerialNumber(key)
    let pid = ProcessGetPIDC(psn)
    if ProcessManager.isBeingDebugged(pid) {
      Logger.processes.debug("process with pid \(pid) is running under a debugger, ignoring")
      return nil
    }

    guard let process = createProcess(psn, pid) else { return nil }
    processes[key] = process
    return process
  }

  func processTerminated(_ key: ProcessKey) -> Process? {
    guard let process = processes.removeValue(forKey: key) else { return nil }

    //
    // NOTE: The key-value observer on the main thread (Workspace.swift) reads terminated with acquire ordering;
    // isTerminated stores it with release ordering.
    //

    process.isTerminated = true
    process.unobserve()
    return process
  }

  func processFrontSwitched(_ key: ProcessKey) -> Process? {
    processes[key]
  }

  private func createProcess(_ psn: ProcessSerialNumber, _ pid: pid_t) -> Process? {
    let processType = ProcessGetTypeC(psn)

    guard let processNameRef = ProcessCopyNameC(psn) else {
      Logger.processes.debug("could not retrieve process name, ignoring")
      return nil
    }

    let processName = processNameRef as String

    if processType == processTypeXPC {
      Logger.processes.debug("xpc service '\(processName)' detected, ignoring")
      return nil
    }

    if processNameBlacklist.contains(processName) {
      Logger.processes.debug("\(processName) is blacklisted, ignoring")
      return nil
    }

    let result = Process(psn: psn, pid: pid, name: processName)
    result.isTerminated = false
    result.attachRunningApplication()
    return result
  }

  fileprivate static func isBeingDebugged(_ pid: pid_t) -> Bool {
    var info = kinfo_proc()
    info.kp_proc.p_flag = 0

    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

    sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    return (info.kp_proc.p_flag & P_TRACED) != 0
  }

  private func addRunningProcesses() {
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
    while ProcessGetNextC(&psn) == noErr {
      let pid = ProcessGetPIDC(psn)
      if ProcessManager.isBeingDebugged(pid) {
        Logger.processes.debug("process with pid \(pid) is running under a debugger, ignoring")
        continue
      }

      guard let process = createProcess(psn, pid) else { continue }

      if process.name == "Finder" {
        Logger.processes.debug("\(process.nameAndPID) was found, caching its psn")
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
private let processTypeXPC: OSType = 0x5850_4321

extension ProcessSerialNumber {
  fileprivate init(_ key: ProcessKey) {
    self.init(highLongOfPSN: key.high, lowLongOfPSN: key.low)
  }
}

private func processHandler(
  _ ref: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
  var psn = ProcessSerialNumber()
  if GetEventParameter(
    event, EventParamName(kEventParamProcessID), EventParamType(typeProcessSerialNumber), nil,
    MemoryLayout<ProcessSerialNumber>.size, nil, &psn) != noErr
  {
    return -1
  }

  switch Int(GetEventKind(event)) {
  case kEventAppLaunched:
    EventLoop.post(.carbonProcessLaunched(ProcessKey(psn)))
  case kEventAppTerminated:
    EventLoop.post(.carbonProcessTerminated(ProcessKey(psn)))
  case kEventAppFrontSwitched:
    EventLoop.post(.carbonProcessFrontSwitched(ProcessKey(psn)))
  default:
    break
  }

  return noErr
}
