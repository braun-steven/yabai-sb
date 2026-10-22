import CoreGraphics
import Synchronization
import Testing
@testable import Yabai
import CPrivate
import YabaiCore
import YabaiTestSupport

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
@WM func applicationLaunchRetryBackoff()
{
    //
    // NOTE: The delay doubles from 100ms and is capped at 5s; delays are whole milliseconds.
    //

    #expect(Process.launchRetryDelay(0) == .milliseconds(100))
    #expect(Process.launchRetryDelay(1) == .milliseconds(200))
    #expect(Process.launchRetryDelay(5) == .milliseconds(3200))
    #expect(Process.launchRetryDelay(6) == .milliseconds(5000))
    #expect(Process.launchRetryDelay(40) == .milliseconds(5000))

    var total = Duration.zero
    var attempts = 0
    while Process.canRetryLaunch(attempts) {
        total += Process.launchRetryDelay(attempts)
        attempts += 1
    }

    #expect(attempts == Process.maxLaunchAttempts)
    #expect(total > .seconds(30) && total < .seconds(40))
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

extension DaemonState
{
    @Suite
    @WM struct TerminatedApplicationTests
    {
        //
        // NOTE: The AX destroyed callback of w1 invalidated it and queued its windowDestroyed, but the application's
        // terminate event runs first. Its windows must leave the tree before the flush lays out the view again.
        //

        @Test func removesWindowsInvalidatedBeforeTermination()
        {
            let workspace = Workspace()
            let first = workspace.open(1)
            let second = workspace.open(2)
            let survivor = workspace.open(3)
            survivor.application = Application()
            #expect(first.invalidate())

            let views = EventHandler.shared.removeTerminatedWindows([first, second])

            #expect(views.allSatisfy { $0 === workspace.view })
            for target in [first, second] {
                #expect(target.isDestroyed)
                #expect(WindowManager.shared.window[target.id] == nil)
                #expect(WindowManager.shared.managedWindows[target.id] == nil)
                #expect(workspace.view.findWindow(target.id) == nil)
            }

            workspace.view.flush()
            #expect(Headless.drain().placements == [RecordedPlacement(windowID: survivor.id, x: 0, y: 0, w: 1200, h: 800)])

            // the queued event finds the window destroyed and leaves the rest alone
            EventHandler.shared.windowDestroyed(first)
            #expect(WindowManager.shared.window[survivor.id] === survivor)
            #expect(workspace.view.findWindow(survivor.id) != nil)
        }
    }
}
