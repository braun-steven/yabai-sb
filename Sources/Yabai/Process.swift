import Carbon
import Foundation
import CPrivate
import Synchronization
import YabaiCore

@WM final class Process
{
    let psn: ProcessSerialNumber
    let pid: pid_t
    let name: String

    //
    // NOTE: terminated and runningApplicationPointer (the NSRunningApplication at +1) are written on the event loop; the
    // key-value observer on the main thread reads terminated with acquire ordering (Workspace.swift). policy (the
    // activation policy) is stored by isObservable on the event loop and compared and stored by the key-value observer
    // on the main thread, relaxed (Workspace.swift).
    //

    let runningApplicationPointer = Atomic<UnsafeMutableRawPointer?>(nil)
    let policy = Atomic<Int>(0)
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
    nonisolated var nameAndPID: String { "\(name) (\(pid))" }
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
struct ProcessKey: Hashable, Sendable
{
    let high: UInt32
    let low: UInt32

    init(_ psn: ProcessSerialNumber)
    {
        high = psn.highLongOfPSN
        low = psn.lowLongOfPSN
    }
}
