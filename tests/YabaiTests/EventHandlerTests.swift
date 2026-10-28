import CPrivate
import Carbon
import CoreGraphics
import OrderedCollections
import SortedCollections
import Synchronization
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

@Test("mouse_event_coalescing")
func mouseEventCoalescing() {
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
@WM func applicationLaunchRetryBackoff() {
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

extension DaemonState {
  @Suite
  @WM struct ProcessTerminationTests {
    @Test func terminationClearsLostFrontSwitchForUnobservedApplication() {
      let pid: pid_t = 0x7FFF_FFFE
      let psn = ProcessSerialNumber(highLongOfPSN: 0xFFFF_FFFE, lowLongOfPSN: 0xFFFF_FFFD)
      let key = ProcessKey(psn)
      let pm = ProcessManager.shared
      let manager = WindowManager.shared
      let previousProcess = pm.processes[key]
      let previouslyLost = manager.focus.hasLostFrontSwitchedEvent(for: pid)

      defer {
        pm.processes[key] = previousProcess
        if previouslyLost {
          manager.focus.addLostFrontSwitchedEvent(for: pid)
        } else {
          manager.focus.removeLostFrontSwitchedEvent(for: pid)
        }
      }

      pm.processes[key] = Process(psn: psn, pid: pid, name: "termination-test")
      manager.focus.addLostFrontSwitchedEvent(for: pid)

      EventHandler.shared.carbonProcessTerminated(key)

      #expect(pm.processes[key] == nil)
      #expect(!manager.focus.hasLostFrontSwitchedEvent(for: pid))
    }
  }
}

extension DaemonState {
  @Suite
  @WM struct WindowFocusEventTests {
    @Test func missingTargetRecordsLostFocusAndKeepsPendingRequest() {
      let requestedWindow = wid(30)
      let missingWindow = wid(31)
      WindowManager.shared.focus.setPending(requestedWindow, at: 1)
      pendingWindowFocus.store(true, ordering: .releasing)
      defer {
        WindowManager.shared.focus.clearPending()
        WindowManager.shared.focus.removeLostFocusedEvent(for: missingWindow)
        pendingWindowFocus.store(false, ordering: .releasing)
      }

      EventHandler.shared.windowFocused(missingWindow)

      #expect(WindowManager.shared.focus.hasLostFocusedEvent(for: missingWindow))
      #expect(WindowManager.shared.focus.pending?.windowID == requestedWindow)
      let isPending = pendingWindowFocus.load(ordering: .acquiring)
      #expect(!isPending)
    }

    @Test func minimizedTargetRecordsLostFocusAndKeepsPendingRequest() {
      let workspace = Workspace()
      let minimized = workspace.open(1)
      let requestedWindow = wid(32)
      minimized.isMinimized = true
      WindowManager.shared.focus.setPending(requestedWindow, at: 1)
      pendingWindowFocus.store(true, ordering: .releasing)
      defer {
        WindowManager.shared.focus.clearPending()
        WindowManager.shared.focus.removeLostFocusedEvent(for: minimized.id)
        pendingWindowFocus.store(false, ordering: .releasing)
      }

      EventHandler.shared.windowFocused(minimized.id)

      #expect(WindowManager.shared.focus.hasLostFocusedEvent(for: minimized.id))
      #expect(WindowManager.shared.focus.pending?.windowID == requestedWindow)
      let isPending = pendingWindowFocus.load(ordering: .acquiring)
      #expect(!isPending)
    }

    @Test func staleTargetIsIgnoredAndKeepsPendingRequest() {
      let workspace = Workspace()
      let stale = workspace.open(1)
      let requestedWindow = wid(33)
      #expect(stale.invalidate())
      WindowManager.shared.focus.setPending(requestedWindow, at: 1)
      pendingWindowFocus.store(true, ordering: .releasing)
      defer {
        WindowManager.shared.focus.clearPending()
        pendingWindowFocus.store(false, ordering: .releasing)
      }

      EventHandler.shared.windowFocused(stale.id)

      #expect(!WindowManager.shared.focus.hasLostFocusedEvent(for: stale.id))
      #expect(WindowManager.shared.focus.pending?.windowID == requestedWindow)
      let isPending = pendingWindowFocus.load(ordering: .acquiring)
      #expect(!isPending)
    }

    @Test func lateFocusDoesNotClearAnotherWindowPendingFocus() {
      let workspace = Workspace()
      let late = workspace.open(1, focus: true)
      _ = workspace.open(2)
      let requestedWindow = workspace.open(3)
      late.mouseFollowsFocusByRule = false
      MouseState.shared.ffmWindowID = late.id
      WindowManager.shared.focus.setPending(requestedWindow.id, at: 1)
      defer { WindowManager.shared.focus.clearPending() }

      EventHandler.shared.windowDidReceiveFocus(late)

      #expect(WindowManager.shared.focus.focused == late.id)
      #expect(WindowManager.shared.focus.pending?.windowID == requestedWindow.id)
      #expect(MouseState.shared.ffmWindowID == nil)
    }

    @Test func reportedFocusClearsItsMatchingPendingRequest() {
      let workspace = Workspace()
      let target = workspace.open(1)
      target.mouseFollowsFocusByRule = false
      MouseState.shared.ffmWindowID = target.id
      WindowManager.shared.focus.setPending(target.id, at: 1)
      defer { WindowManager.shared.focus.clearPending() }

      EventHandler.shared.windowDidReceiveFocus(target)

      #expect(WindowManager.shared.focus.pending == nil)
    }
  }
}

@Test("mouse_resize_handle")
func mouseResizeHandle() {
  let frame = CGRect(x: 100, y: 100, width: 200, height: 100)

  #expect(ResizeHandle(at: CGPoint(x: 110, y: 110), in: frame) == [.left, .top])
  #expect(ResizeHandle(at: CGPoint(x: 290, y: 190), in: frame) == [.right, .bottom])

  // NOTE: on a center line only one edge is dragged
  #expect(ResizeHandle(at: CGPoint(x: 200, y: 190), in: frame) == .bottom)
  #expect(ResizeHandle(at: CGPoint(x: 110, y: 150), in: frame) == .left)
  #expect(ResizeHandle(at: CGPoint(x: 200, y: 150), in: frame) == [])
}

//
// NOTE: A window of a hidden application keeps its cached frame current: a `window --move` while the application is
// hidden used to leave `query --windows` on the old frame. The fake window has no AX element, so its AX frame is zero.
//

extension DaemonState {
  @Suite
  @WM struct HiddenApplicationFrameTests {
    @WM private func hiddenFloatingWindow() -> Window {
      let application = Application()
      application.isHidden = true
      let target = Window(id: wid(40))
      target.application = application
      target.isFloating = true
      target.frame = CGRect(x: 2982, y: 520, width: 440, height: 418)
      WindowManager.shared.window[target.id] = target

      let signal = EventSignal(command: "true")
      EventSignals.shared.table.add(signal, .windowMoved)
      EventSignals.shared.table.add(signal, .windowResized)
      return target
    }

    @Test func movedUpdatesTheCachedOriginWithoutASignal() async {
      let target = hiddenFloatingWindow()
      let before = EventSignals.shared.pending.count

      await EventHandler.shared.handle(.windowMoved(windowID: target.id))

      #expect(target.frame == CGRect(x: 0, y: 0, width: 440, height: 418))
      #expect(target.lastFloatingFrame == target.frame)
      #expect(EventSignals.shared.pending.count == before)
    }

    @Test func resizedUpdatesTheCachedFrameWithoutASignal() async {
      let target = hiddenFloatingWindow()
      let before = EventSignals.shared.pending.count

      await EventHandler.shared.handle(.windowResized(windowID: target.id))

      #expect(target.frame == .zero)
      #expect(target.lastFloatingFrame == .zero)
      #expect(EventSignals.shared.pending.count == before)
    }
  }
}

extension DaemonState {
  @Suite
  @WM struct TerminatedApplicationTests {
    //
    // NOTE: The AX destroyed callback of w1 invalidated it and queued its windowDestroyed, but the application's
    // terminate event runs first. Its windows must leave the tree before the flush lays out the view again.
    //

    @Test func removesWindowsInvalidatedBeforeTermination() {
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
      #expect(
        Headless.drain().placements == [
          RecordedPlacement(windowID: survivor.id, x: 0, y: 0, w: 1200, h: 800)
        ])

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
private struct TeardownOutcome: Equatable {
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
@WM private func teardownScenario(_ n: UInt32, eligible: Bool) -> (
  workspace: Workspace, target: Window
) {
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

  let signal = EventSignal(command: "true")
  EventSignals.shared.table.add(signal, .windowDestroyed)

  _ = Headless.drain()
  return (workspace, target)
}

@WM private func teardownOutcome(_ workspace: Workspace, _ target: Window, signalsFrom first: Int)
  -> TeardownOutcome
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
@WM private func outcomeOfWindowDestroyed(_ n: UInt32, eligible: Bool = true) -> TeardownOutcome {
  let (workspace, target) = teardownScenario(n, eligible: eligible)
  let first = EventSignals.shared.pending.count
  EventHandler.shared.windowDestroyed(target)
  return teardownOutcome(workspace, target, signalsFrom: first)
}

/// The outcome of the termination of window n's application, which batches the untile and flushes the view after.
@WM private func outcomeOfTermination(_ n: UInt32) -> TeardownOutcome {
  let (workspace, target) = teardownScenario(n, eligible: true)
  let first = EventSignals.shared.pending.count
  for view in EventHandler.shared.removeTerminatedWindows([target]) { view.flush() }
  return teardownOutcome(workspace, target, signalsFrom: first)
}

extension DaemonState {
  @Suite
  @WM struct WindowTeardownTests {
    @Test(arguments: [1, 2, 3] as [UInt32])
    func destroyedWindowLeavesTheSameStateOnEveryPath(_ n: UInt32) {
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

    @Test func middleWindowTeardownPinsTheLayout() {
      let outcome = outcomeOfWindowDestroyed(2)

      #expect(outcome.tree == "splith\n  w1 0.5000\n  w3 0.5000")
      #expect(outcome.managed == [treeTestWindowBase + 1, treeTestWindowBase + 3])
      #expect(outcome.windows == [treeTestWindowBase + 1, treeTestWindowBase + 3])
      #expect(
        outcome.placements == [
          RecordedPlacement(windowID: wid(1), x: 0, y: 0, w: 600, h: 800),
          RecordedPlacement(windowID: wid(3), x: 600, y: 0, w: 600, h: 800),
        ])
    }

    @Test func ineligibleWindowPushesNoSignal() {
      let outcome = outcomeOfWindowDestroyed(2, eligible: false)

      #expect(outcome.destroyed)
      #expect(outcome.signals.isEmpty)
    }

    //
    // NOTE: Each window is torn down once. A second destroyed event for the same window finds it destroyed, and a
    // queued destroyed event after a termination finds it removed: both push nothing.
    //

    @Test func secondDestroyedEventForTheSameWindowPushesNothing() async {
      let (_, target) = teardownScenario(2, eligible: true)
      let before = EventSignals.shared.pending.count

      await EventHandler.shared.handle(.windowDestroyed(windowID: target.id))
      await EventHandler.shared.handle(.windowDestroyed(windowID: target.id))

      #expect(target.isDestroyed)
      #expect(EventSignals.shared.pending.count == before + 1)
      #expect(WindowManager.shared.window[target.id] == nil)
      #expect(WindowManager.shared.window[wid(1)] != nil)
    }

    //
    // NOTE: The queued destroyed event of a window that the termination of its application already removed finds no
    // window, so it pushes nothing and leaves the other windows alone.
    //

    @Test func destroyedEventAfterTerminationPushesNothingMore() async {
      let (_, target) = teardownScenario(2, eligible: true)
      let before = EventSignals.shared.pending.count

      _ = EventHandler.shared.removeTerminatedWindows([target])
      await EventHandler.shared.handle(.windowDestroyed(windowID: target.id))

      #expect(EventSignals.shared.pending.count == before + 1)
      #expect(WindowManager.shared.window[target.id] == nil)
      #expect(WindowManager.shared.window[wid(1)] != nil)
      #expect(WindowManager.shared.window[wid(3)] != nil)
    }

    @Test func eventsForAnUnknownWindowDoNothing() async {
      let (workspace, _) = teardownScenario(2, eligible: true)
      let before = EventSignals.shared.pending.count
      let dump = workspace.dump
      let unknown = wid(99)
      WindowManager.shared.focus.addLostFocusedEvent(for: unknown)

      await EventHandler.shared.handle(.windowDestroyed(windowID: unknown))
      await EventHandler.shared.handle(.windowMinimized(windowID: unknown))
      await EventHandler.shared.handle(.windowDeminimized(windowID: unknown))

      #expect(EventSignals.shared.pending.count == before)
      #expect(workspace.dump == dump)
      #expect(WindowManager.shared.window[wid(1)] != nil)
      #expect(WindowManager.shared.window[wid(3)] != nil)
      // NOTE: a deminimized event drops the lost focus event of the id, as for an invalid window
      #expect(!WindowManager.shared.focus.hasLostFocusedEvent(for: unknown))
    }

    @Test func notificationContextCarriesTheWindowId() {
      let target = Window(id: wid(7))

      #expect(WindowID(notificationContext: target.notificationContext) == target.id)
      #expect(WindowID(notificationContext: nil) == nil)
    }

    //
    // NOTE: The AX destroyed callback marks the id on the main thread. The window is invalid at once, so the events
    // queued before its destroyed event are ignored, as when the callback invalidated it. The destroyed event on @WM
    // then tears it down once and drops the mark (forget).
    //

    @Test func axDestroyedMarkIgnoresQueuedEventsUntilTheDestroyedEventTearsDown() async {
      let (workspace, target) = teardownScenario(2, eligible: true)
      let before = EventSignals.shared.pending.count
      let dump = workspace.dump

      #expect(markAXDestroyed(target.id))
      #expect(!target.isValid)
      #expect(!target.isDestroyed)

      await EventHandler.shared.handle(.windowMoved(windowID: target.id))
      await EventHandler.shared.handle(.windowMinimized(windowID: target.id))
      #expect(workspace.dump == dump)
      #expect(!target.isMinimized)
      #expect(EventSignals.shared.pending.count == before)
      #expect(WindowManager.shared.window[target.id] === target)

      await EventHandler.shared.handle(.windowDestroyed(windowID: target.id))
      #expect(target.isDestroyed)
      #expect(WindowManager.shared.window[target.id] == nil)
      #expect(EventSignals.shared.pending.count == before + 1)
      #expect(WindowManager.shared.window[wid(1)] != nil)
      #expect(WindowManager.shared.window[wid(3)] != nil)

      // NOTE: the mark is gone with the window: marking the id again is new. Clear it again for the other tests.
      #expect(markAXDestroyed(target.id))
      unmarkAXDestroyed(target.id)
    }

    @Test func axDestroyedMarkIsNewOnlyOnce() {
      let id = wid(9)
      defer { unmarkAXDestroyed(id) }

      #expect(markAXDestroyed(id))
      #expect(!markAXDestroyed(id))
    }
  }
}

extension DaemonState {
  @Suite
  @WM struct WindowForgetTests {
    //
    // NOTE: removeWindow forgets the state keyed by the id of the window it removes, and only that: the entries of the
    // windows that stay are kept.
    //

    @Test func removeWindowForgetsTheStateKeyedByItsId() {
      let wm = WindowManager.shared
      let workspace = Workspace()
      let target = workspace.open(1, focus: true)
      let other = workspace.open(2)

      Border.trackForTest(target.id)
      Border.trackForTest(other.id)
      wm.focus.addLostFocusedEvent(for: target.id)
      wm.focus.addLostFocusedEvent(for: other.id)
      MouseState.shared.window = target
      MouseState.shared.ffmWindowID = target.id
      MouseState.shared.feedbackWindowID = target.id
      MouseState.shared.feedbackDirection = .west

      wm.removeWindow(target.id)

      #expect(wm.window[target.id] == nil)
      #expect(wm.managedWindows[target.id] == nil)
      #expect(!Border.isTracked(target.id))
      #expect(!wm.focus.hasLostFocusedEvent(for: target.id))
      #expect(MouseState.shared.window == nil)
      #expect(MouseState.shared.ffmWindowID == nil)
      #expect(MouseState.shared.feedbackWindowID == nil)
      #expect(MouseState.shared.feedbackDirection == nil)

      #expect(wm.window[other.id] === other)
      #expect(wm.managedWindows[other.id] != nil)
      #expect(Border.isTracked(other.id))
      #expect(wm.focus.hasLostFocusedEvent(for: other.id))

      // NOTE: the feedback of another window is left alone when a window is removed
      MouseState.shared.feedbackWindowID = other.id
      MouseState.shared.feedbackDirection = .east
      wm.removeWindow(target.id)
      #expect(MouseState.shared.feedbackWindowID == other.id)
      #expect(MouseState.shared.feedbackDirection == .east)

      Border.remove(other.id)
      wm.focus.removeLostFocusedEvent(for: other.id)
      MouseState.shared.window = nil
      MouseState.shared.ffmWindowID = nil
      MouseState.shared.feedbackWindowID = nil
      MouseState.shared.feedbackDirection = nil
    }
  }
}

extension DaemonState {
  @Test("mission_control_exit_without_session_still_signals") @WM
  func missionControlExitWithoutSessionStillSignals() {
    //
    // NOTE: An exit without an active session (for example after a missed AX show notification) still pushes the
    // mission_control_exit signal with mode inactive, as it did before the fallback check moved to AX.
    //

    let signal = EventSignal(command: "true")
    EventSignals.shared.table.add(signal, .missionControlExit)

    MissionControl.shared.mode = .showDesktop
    let first = EventSignals.shared.pending.count
    EventHandler.shared.missionControlExit()
    EventHandler.shared.missionControlExit()

    #expect(MissionControl.shared.mode == .inactive)
    #expect(
      EventSignals.shared.pending.dropFirst(first).map { $0.type.name } == [
        "mission_control_exit", "mission_control_exit",
      ])
  }
}

extension DaemonState {
  @Test("mission_control_hides_borders_until_exit") @WM
  func missionControlHidesBordersUntilExit() {
    //
    // NOTE: Mission Control moves the windows in its overview without moving them in the window server, so the borders
    // are hidden from its show notification until its exit.
    //

    #expect(!Border.isHiddenForMissionControl)
    EventHandler.shared.missionControlShowDesktop()
    #expect(Border.isHiddenForMissionControl)
    EventHandler.shared.missionControlExit()
    #expect(!Border.isHiddenForMissionControl)
  }
}

extension DaemonState {
  @Test(
    "focus_follows_mouse_enters_mission_control_when_its_overlay_is_shown",
    arguments: [true, false])
  @WM
  func ffmEntersMissionControlWhenOverlayIsShown(shown: Bool) {
    //
    // NOTE: An opening of Mission Control without the front change of its enter: focus follows mouse finds the overlay
    // before a change of focus, enters Mission Control (so the guards of later moves apply) and changes nothing.
    //

    // NOTE: Reset by hand: the exit of a .show session would query the window server for its spaces.
    defer {
      EventLoop.cancel(key: .missionControlCheck)
      MissionControl.shared.mode = .inactive
      Border.setHiddenForMissionControl(false)
    }

    #expect(!MissionControl.shared.isActive)
    #expect(EventHandler.shared.ffmMissionControlIsOpen(overlayIsShown: { shown }) == shown)
    #expect(MissionControl.shared.mode == (shown ? .show : .inactive))
    #expect(Border.isHiddenForMissionControl == shown)
  }
}

@Test(
  "mission_control_overlay_is_a_dock_window_at_layer_20_over_a_display",
  arguments: [
    ("Dock", 20, CGRect(x: 0, y: 0, width: 1512, height: 982), true),
    ("Dock", 20, CGRect(x: 400, y: 900, width: 700, height: 82), false),
    ("Dock", 18, CGRect(x: 0, y: 0, width: 1512, height: 982), false),
    ("Finder", 20, CGRect(x: 0, y: 0, width: 1512, height: 982), false),
  ])
func missionControlOverlay(owner: String, layer: Int, bounds: CGRect, expected: Bool) {
  let info: [String: Any] = [
    kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
    kCGWindowBounds as String: bounds.dictionaryRepresentation,
  ]
  let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
  #expect(MissionControl.containsOverlay([info], displays: displays) == expected)
}

extension DaemonState {
  @Suite
  @WM struct FocusFollowsMouseRecheckTests {
    //
    // NOTE: A move that a pending focus follows mouse request holds schedules one re-check, and the focus event of the
    // request brings it forward. Only the held moves are driven here: a move that goes on hit tests the window server.
    //

    @Test func heldMoveWaitsAndTheFocusEventResolvesIt() {
      let workspace = Workspace()
      let target = workspace.open(1)
      target.mouseFollowsFocusByRule = false
      Config.current.window.focusFollowsMouse = .autofocus
      MouseState.shared.ffmWindowID = target.id
      defer { EventLoop.cancel(key: .ffmRecheck) }

      EventHandler.shared.ffmPointerMoved(to: CGPoint(x: 50, y: 50))
      #expect(MouseState.shared.ffmRecheck.state == .waiting)

      // a second held move of the same request schedules nothing new
      EventHandler.shared.ffmPointerMoved(to: CGPoint(x: 60, y: 50))
      #expect(MouseState.shared.ffmRecheck.state == .waiting)

      EventHandler.shared.windowDidReceiveFocus(target)
      #expect(MouseState.shared.ffmWindowID == nil)
      #expect(MouseState.shared.ffmRecheck.state == .resolved)
    }

    @Test func requestWithoutHeldMoveSchedulesNoRecheck() {
      let workspace = Workspace()
      let target = workspace.open(1)
      target.mouseFollowsFocusByRule = false
      Config.current.window.focusFollowsMouse = .autofocus
      MouseState.shared.ffmWindowID = target.id

      EventHandler.shared.windowDidReceiveFocus(target)
      #expect(MouseState.shared.ffmRecheck.state == .idle)
    }

    @Test func disabledModeHoldsNothing() {
      let workspace = Workspace()
      let target = workspace.open(1)
      MouseState.shared.ffmWindowID = target.id

      EventHandler.shared.ffmPointerMoved(to: CGPoint(x: 50, y: 50))
      #expect(MouseState.shared.ffmRecheck.state == .idle)

      // a re-check without a held move does nothing (and asks the window server nothing)
      EventHandler.shared.ffmRecheck()
      #expect(MouseState.shared.ffmRecheck.state == .idle)
      MouseState.shared.ffmWindowID = nil
    }
  }
}
