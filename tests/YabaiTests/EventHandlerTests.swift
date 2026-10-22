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

//
// NOTE: A window leaves the managers in two ways: windowDestroyed untiles it at once (with the focus hand-over) and
// removeTerminatedWindows batches it (the caller flushes the views it returns). Both then tear the window down the same
// way: the mouse state, the signal, the scratchpad, the window table and the AX notifications.
//

/// What a teardown leaves behind: the tree, the registries, the mouse and scratchpad state, the signals it pushed and
/// the frames of the flush that follows.
private struct TeardownOutcome: Equatable
{
    var tree: String
    var managed: [UInt32]
    var windows: [UInt32]
    var scratchpads: [String]
    var targetScratchpad: String?
    var mouseWindow: UInt32?
    var mouseFocus: UInt32?
    var destroyed: Bool
    var signals: [String]
    var placements: [RecordedPlacement]
}

/// Three tiled windows in a Workspace (w2 is the middle one). The window n carries a scratchpad, the mouse state and an
/// eligible signal subscriber, so that each part of the teardown has something to clear.
@WM private func teardownScenario(_ n: UInt32, eligible: Bool) -> (workspace: Workspace, target: Window)
{
    let workspace = Workspace()
    workspace.open(1, focus: true)
    workspace.open(2)
    workspace.open(3)

    let target = WindowManager.shared.window[wid(n)]!
    target.isEligible = eligible
    target.scratchpad = "pad"
    WindowManager.shared.scratchpads["pad"] = target
    MouseState.shared.window = target
    MouseState.shared.ffmWindowID = target.id

    var signal = EventSignal()
    signal.command = "true"
    EventSignals.shared.table.add(signal, .windowDestroyed)

    _ = Headless.drain()
    return (workspace, target)
}

@WM private func teardownOutcome(_ workspace: Workspace, _ target: Window, signalsFrom first: Int) -> TeardownOutcome
{
    let wm = WindowManager.shared
    return TeardownOutcome(
        tree: workspace.dump,
        managed: wm.managedWindows.keys.map(\.rawValue).sorted(),
        windows: wm.window.keys.map(\.rawValue),
        scratchpads: wm.scratchpads.map { "\($0.key)=\($0.value.id.rawValue)" },
        targetScratchpad: target.scratchpad,
        mouseWindow: MouseState.shared.window?.id.rawValue,
        mouseFocus: MouseState.shared.ffmWindowID?.rawValue,
        destroyed: target.isDestroyed,
        signals: EventSignals.shared.pending.dropFirst(first).map { $0.type.name },
        placements: Headless.drain().placements)
}

/// The outcome of the AX or SkyLight destroyed event of window n, which untiles at once.
@WM private func outcomeOfWindowDestroyed(_ n: UInt32, eligible: Bool = true) -> TeardownOutcome
{
    let (workspace, target) = teardownScenario(n, eligible: eligible)
    let first = EventSignals.shared.pending.count
    EventHandler.shared.windowDestroyed(target)
    return teardownOutcome(workspace, target, signalsFrom: first)
}

/// The outcome of the termination of window n's application, which batches the untile and flushes the view after.
@WM private func outcomeOfTermination(_ n: UInt32) -> TeardownOutcome
{
    let (workspace, target) = teardownScenario(n, eligible: true)
    let first = EventSignals.shared.pending.count
    for view in EventHandler.shared.removeTerminatedWindows([target]) { view.flush() }
    return teardownOutcome(workspace, target, signalsFrom: first)
}

extension DaemonState
{
    @Suite
    @WM struct WindowTeardownTests
    {
        @Test(arguments: [1, 2, 3] as [UInt32])
        func destroyedWindowLeavesTheSameStateOnEveryPath(_ n: UInt32)
        {
            let immediate = outcomeOfWindowDestroyed(n)
            let batched = outcomeOfTermination(n)

            #expect(immediate == batched)
            #expect(immediate.destroyed)
            #expect(!immediate.windows.contains(treeTestWindowBase + n))
            #expect(!immediate.managed.contains(treeTestWindowBase + n))
            #expect(immediate.scratchpads.isEmpty)
            #expect(immediate.targetScratchpad == nil)
            #expect(immediate.mouseWindow == nil)
            #expect(immediate.mouseFocus == nil)
            #expect(immediate.signals == [SignalType.windowDestroyed.name])
        }

        @Test func middleWindowTeardownPinsTheLayout()
        {
            let outcome = outcomeOfWindowDestroyed(2)

            #expect(outcome.tree == "splith\n  w1 0.5000\n  w3 0.5000")
            #expect(outcome.managed == [treeTestWindowBase + 1, treeTestWindowBase + 3])
            #expect(outcome.windows == [treeTestWindowBase + 1, treeTestWindowBase + 3])
            #expect(outcome.placements == [
                RecordedPlacement(windowID: wid(1), x: 0, y: 0, w: 600, h: 800),
                RecordedPlacement(windowID: wid(3), x: 600, y: 0, w: 600, h: 800),
            ])
        }

        @Test func ineligibleWindowPushesNoSignal()
        {
            let outcome = outcomeOfWindowDestroyed(2, eligible: false)

            #expect(outcome.destroyed)
            #expect(outcome.signals.isEmpty)
        }
    }
}
