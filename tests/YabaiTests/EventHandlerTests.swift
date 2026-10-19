import CoreGraphics
import Synchronization
import Testing
@testable import Yabai
import CPrivate
import YabaiCore

@Test("mouse_event_coalescing")
func mouseEventCoalescing()
{
    let pending = Atomic<UInt32>(0)

    //
    // NOTE: Three events were posted before the handler ran: only the last one is handled. #expect cannot
    // capture the non-copyable Atomic, so the results are taken first.
    //

    _ = pending.wrappingAdd(3, ordering: .acquiringAndReleasing)
    let first = EventHandler.isStale(pending)
    let second = EventHandler.isStale(pending)
    let third = EventHandler.isStale(pending)
    #expect(first)
    #expect(second)
    #expect(!third)

    _ = pending.wrappingAdd(1, ordering: .acquiringAndReleasing)
    let only = EventHandler.isStale(pending)
    #expect(!only)
    #expect(pending.load(ordering: .relaxed) == 0)
}

@Test("application_launch_retry_backoff")
func applicationLaunchRetryBackoff()
{
    //
    // NOTE: The delay doubles from 100ms and is capped at 5s; delays are compared in milliseconds.
    //

    #expect(Int(Process.launchRetryDelay(0) * 1000 + 0.5) == 100)
    #expect(Int(Process.launchRetryDelay(1) * 1000 + 0.5) == 200)
    #expect(Int(Process.launchRetryDelay(5) * 1000 + 0.5) == 3200)
    #expect(Int(Process.launchRetryDelay(6) * 1000 + 0.5) == 5000)
    #expect(Int(Process.launchRetryDelay(40) * 1000 + 0.5) == 5000)

    var total: Float = 0
    var attempts = 0
    while Process.canRetryLaunch(attempts) {
        total += Process.launchRetryDelay(attempts)
        attempts += 1
    }

    #expect(attempts == Process.maxLaunchAttempts)
    #expect(total > 30 && total < 40)
}

@Test("mouse_resize_handle")
func mouseResizeHandle()
{
    let frame = CGRect(x: 100, y: 100, width: 200, height: 100)

    #expect(ResizeHandle(at: CGPoint(x: 110, y: 110), in: frame) == [.left, .top])
    #expect(ResizeHandle(at: CGPoint(x: 290, y: 190), in: frame) == [.right, .bottom])

    // NOTE: on a center line only one edge is dragged
    #expect(ResizeHandle(at: CGPoint(x: 200, y: 190), in: frame) == .bottom)
    #expect(ResizeHandle(at: CGPoint(x: 110, y: 150), in: frame) == .left)
    #expect(ResizeHandle(at: CGPoint(x: 200, y: 150), in: frame) == [])
}
