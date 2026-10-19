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
