import Carbon
import Foundation
import CPrivate
import Synchronization
import YabaiCore

final class Process
{
    var psn: ProcessSerialNumber
    var pid: pid_t
    var name: String

    //
    // NOTE: terminated and runningApplicationPointer (the NSRunningApplication at +1) are also written on other threads; the
    // key-value observer reads terminated with acquire ordering (Workspace.swift).
    //

    let runningApplicationPointer = Atomic<UnsafeMutableRawPointer?>(nil)
    var policy = 0
    var launchAttempts = 0
    var launchGivenUp = false
    let terminated = Atomic<Bool>(false)

    init(psn: ProcessSerialNumber, pid: pid_t, name: String)
    {
        self.psn = psn
        self.pid = pid
        self.name = name
    }

    /// Relaxed load; the setter stores with release ordering.
    var isTerminated: Bool
    {
        get { terminated.load(ordering: .relaxed) }
        set { terminated.store(newValue, ordering: .releasing) }
    }

    var hasRunningApplication: Bool { runningApplicationPointer.load(ordering: .relaxed) != nil }

    /// The name and pid of the process, as the debug output prints them.
    var nameAndPID: String { "\(name) (\(pid))" }
}

extension Process
{
    //
    // NOTE: An application that cannot be observed yet is tried again with a growing delay. After
    // maxLaunchAttempts attempts (about 36s) it is given up on, until the user activates it, so that an
    // application that never responds is not polled forever.
    //

    static let maxLaunchAttempts = 12

    static func launchRetryDelay(_ attempt: Int) -> Float
    {
        min(0.1 * Float(1 << min(attempt, 16)), 5.0)
    }

    static func canRetryLaunch(_ attempt: Int) -> Bool
    {
        attempt < maxLaunchAttempts
    }
}

/// A process serial number as a dictionary key: `ProcessSerialNumber` is not `Hashable`.
struct ProcessKey: Hashable
{
    let high: UInt32
    let low: UInt32

    init(_ psn: ProcessSerialNumber)
    {
        high = psn.highLongOfPSN
        low = psn.lowLongOfPSN
    }
}
