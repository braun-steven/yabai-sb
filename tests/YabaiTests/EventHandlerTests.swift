import CoreGraphics
import Synchronization
import Testing
@testable import Yabai
import YabaiC

@Test("mouse_event_coalescing")
func mouseEventCoalescing()
{
    let pending = Atomic<UInt32>(0)

    //
    // NOTE: Three events were posted before the handler ran: only the last one is handled. #expect cannot
    // capture the non-copyable Atomic, so the results are taken first.
    //

    _ = pending.wrappingAdd(3, ordering: .acquiringAndReleasing)
    let first = mouseEventIsStale(pending)
    let second = mouseEventIsStale(pending)
    let third = mouseEventIsStale(pending)
    #expect(first)
    #expect(second)
    #expect(!third)

    _ = pending.wrappingAdd(1, ordering: .acquiringAndReleasing)
    let only = mouseEventIsStale(pending)
    #expect(!only)
    #expect(pending.load(ordering: .relaxed) == 0)
}

@Test("application_launch_retry_backoff")
func applicationLaunchRetryBackoff()
{
    //
    // NOTE: The delay doubles from 100ms and is capped at 5s; delays are compared in milliseconds.
    //

    #expect(Int(applicationLaunchRetryDelay(0) * 1000 + 0.5) == 100)
    #expect(Int(applicationLaunchRetryDelay(1) * 1000 + 0.5) == 200)
    #expect(Int(applicationLaunchRetryDelay(5) * 1000 + 0.5) == 3200)
    #expect(Int(applicationLaunchRetryDelay(6) * 1000 + 0.5) == 5000)
    #expect(Int(applicationLaunchRetryDelay(40) * 1000 + 0.5) == 5000)

    var total: Float = 0
    var attempts: Int32 = 0
    while applicationLaunchCanRetry(attempts) {
        total += applicationLaunchRetryDelay(attempts)
        attempts += 1
    }

    #expect(attempts == applicationLaunchMaxAttempts)
    #expect(total > 30 && total < 40)
}

@Test("mouse_resize_handle")
func mouseResizeHandle()
{
    let frame = CGRect(x: 100, y: 100, width: 200, height: 100)

    #expect(mouseResizeDirection(frame, CGPoint(x: 110, y: 110)) == HANDLE_LEFT | HANDLE_TOP)
    #expect(mouseResizeDirection(frame, CGPoint(x: 290, y: 190)) == HANDLE_RIGHT | HANDLE_BOTTOM)

    // NOTE: on a center line only one edge is dragged
    #expect(mouseResizeDirection(frame, CGPoint(x: 200, y: 190)) == HANDLE_BOTTOM)
    #expect(mouseResizeDirection(frame, CGPoint(x: 110, y: 150)) == HANDLE_LEFT)
    #expect(mouseResizeDirection(frame, CGPoint(x: 200, y: 150)) == 0)
}
