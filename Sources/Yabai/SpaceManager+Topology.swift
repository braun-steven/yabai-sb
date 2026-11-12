import CoreFoundation
import Darwin
import Logging
import OrderedCollections
import SortedCollections
import Synchronization
import YabaiCore

//
// NOTE: Keeps the desktop what it was through a display change, while `space_layout` is set. macOS collapses and
// recreates spaces at will when displays come and go, and yabai cannot stop it, so it follows the desktop while nothing
// is happening (`commitTopology`, the TopologyLedger) and puts it back afterwards. A display change freezes
// everything that would act on a half-changed desktop (TopologyTransaction, the `isFrozen` and `holdsWindows` gates at the
// handlers). Once macOS is quiet, `topologyPass` runs again and again: it reads the desktop, takes the next step from
// TopologyRestore.plan and performs it, until spaces, windows, trees and the shown spaces match the commit. It works the
// same for a display that went away and one that returned, because the slots do not depend on the displays: while
// undocked, spaces stand in for the ones macOS destroyed, and when those return the stand-ins are destroyed.
//
// A rule that fires during the freeze uses the indices of the moment; the restore moves a known window back.
//

/// The clock of the disturbances and commits: seconds that also count while the system sleeps. Callable from any thread.
enum TopologyClock {
  static var now: Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
}

/// Counts the display callbacks. A commit compares the count with what the event loop has seen, so it does not read a
/// desktop that is already changing while the event of the callback waits in the queue.
enum TopologyMarks {
  private static let count = Atomic<UInt64>(0)

  /// Callable from any thread.
  static func add() {
    count.add(1, ordering: .relaxed)
  }

  /// Callable from any thread.
  static var current: UInt64 { count.load(ordering: .relaxed) }
}

/// A restore, from its start until the end of the watch.
struct TopologyRestoreRun {
  var commit: TopologyCommit
  var started: Double
  var binding: TopologyBinding?
  var passes = 0
  var failures = 0
  /// How often each window was moved: macOS can accept a move and do nothing.
  var attempts: [WindowID: Int] = [:]
  /// The windows that were moved on purpose since the start, which stay where they were put.
  var skipping: Set<WindowID> = []
  /// The windows that have given up on their slot, after `windowAttempts` moves.
  var abandoned: Set<WindowID> = []
  /// The slots whose view has its label and settings, by the space that stood there.
  var adoptedViews: Set<String> = []
  /// The windows of each space at its last tree install, to install again only after a change.
  var installed: [SpaceID: Set<WindowID>] = [:]
  var shownAttempts = 0
  /// Whether a restoring move is under way, which `noteWindowMove` must not take for a move of the user.
  var isMoving = false
}

extension SpaceManager {
  /// How much older than the first disturbance a commit must be: macOS changes spaces up to 200 ms before the first
  /// callback.
  static let topologyCommitMargin = 0.5

  /// How often the ledger commits without any activity, for what no event reports.
  static let topologyCommitInterval: Duration = .seconds(30)

  /// How long the activity must be over before a commit.
  static let topologyCommitDelay: Duration = .seconds(1)

  /// The wait between two passes of a restore.
  static let topologyPassDelay: Duration = .milliseconds(200)

  /// The wait for a new space to arrive: a pass that does not see it yet would create another one.
  static let topologyCreateDelay: Duration = .milliseconds(600)

  /// The wait after a step that failed, and while Mission Control is open.
  static let topologyRetryDelay: Duration = .milliseconds(500)

  /// The wait between two passes of the watch.
  static let topologyWatchDelay: Duration = .seconds(1)

  /// The most passes of a restore, before the watch.
  static let topologyPassLimit = 100

  /// The most steps of a restore that may fail.
  static let topologyFailureLimit = 8

  /// How often a window is moved before it stays where it is.
  static let topologyWindowAttempts = 5

  /// How often the displays are told to show their spaces.
  static let topologyShownAttempts = 3

  /// Whether the desktop is kept through display changes.
  var topologyIsEnabled: Bool {
    Config.current.space.spaceLayoutRestore && !Config.current.space.spaceLayouts.isEmpty
  }

  // MARK: The ledger

  //
  // NOTE: A window that the user moves without yabai (Mission Control) leaves no event, so the commits also run on an
  // interval. Reading all the spaces takes a window server call per space: it waits for the end of the activity, not
  // only because of the cost, but because a synchronous query right after a focus change can block for 500 ms.
  //

  /// Commits the desktop when the activity has ended; a commit that is already waiting stays.
  func scheduleTopologyCommit() {
    guard topologyIsEnabled, !topologyCommitPending, !topologyTransaction.isFrozen else { return }

    topologyCommitPending = true
    EventLoop.post(.topologyCommit, after: Self.topologyCommitDelay, key: .topologyCommit)
  }

  /// Adds the desktop to the ledger, unless it is changing.
  func commitTopology() {
    topologyCommitPending = false
    guard topologyIsEnabled else { return }

    defer {
      EventLoop.post(.topologyCommit, after: Self.topologyCommitInterval, key: .topologyCommit)
    }

    let marks = TopologyMarks.current
    guard !topologyTransaction.isFrozen, marks == topologyHandledMarks,
      !MissionControl.shared.isActive, case .success(let inputs?) = spaceLayoutInputs()
    else { return }

    let commit = topologyCommit(inputs)
    if TopologyMarks.current == marks { topologyLedger.add(commit) }
  }

  /// The desktop now. The window lists come from the window server, so they have the windows yabai cannot reach.
  private func topologyCommit(_ inputs: SpaceLayoutInputs) -> TopologyCommit {
    let wm = WindowManager.shared
    var slots: [TopologySlot] = []
    var shown: [String: String] = [:]
    var spaceCount: [WindowID: Int] = [:]

    for (index, list) in inputs.spaces.enumerated() {
      for sid in list {
        guard let uuid = inputs.uuids[sid] else { continue }

        let windows = sid.windows(includingMinimized: true) ?? []
        for window in windows { spaceCount[window, default: 0] += 1 }

        slots.append(
          TopologySlot(
            uuid: uuid, display: inputs.arrangement[index], windows: windows,
            tree: views[sid]?.tree?.snapshot))
      }

      if let sid = inputs.displays[index].currentSpace, let uuid = inputs.uuids[sid] {
        shown[inputs.arrangement[index]] = uuid
      }
    }

    // NOTE: A sticky window is on every space, and a scratchpad window is where its toggle leaves it.
    for index in slots.indices {
      slots[index].windows.removeAll { window in
        spaceCount[window, default: 0] > 1 || wm.window(for: window)?.scratchpad != nil
      }
    }

    return TopologyCommit(
      time: TopologyClock.now, slots: slots, shown: shown,
      active: SpaceID.active.flatMap { inputs.uuids[$0] }, focused: wm.focus.focused)
  }

  // MARK: The transaction

  /// Handles a display callback.
  func topologyDisturbed(at time: Double, displays: Bool) {
    topologyHandledMarks = TopologyMarks.current
    disturbTopology(at: time, displays: displays)
  }

  /// A space was created.
  func topologySpaceCreated() {
    topologyTransaction.touch(at: TopologyClock.now)
    scheduleTopologyPassAtRestoreTime()
  }

  /// A space was destroyed; one that yabai did not destroy itself is a disturbance.
  func topologySpaceDestroyed(_ sid: SpaceID) {
    if expectedSpaceDestroys.remove(sid) == nil {
      disturbTopology(at: TopologyClock.now, displays: false)
    }
  }

  private func disturbTopology(at time: Double, displays: Bool) {
    guard topologyIsEnabled else { return }

    if !topologyTransaction.isFrozen { TopologyLog.record("topology-disturbed") }
    topologyTransaction.disturb(at: time, displays: displays)
    scheduleTopologyPassAtRestoreTime()
  }

  private func scheduleTopologyPassAtRestoreTime() {
    guard topologyTransaction.phase == .disturbed else { return }

    let wait = max(topologyTransaction.restoreTime - TopologyClock.now, 0)
    EventLoop.post(.topologyPass, after: .seconds(wait), key: .topologyPass)
  }

  /// A window moved through yabai. Unless the restore moved it, it was moved on purpose and stays there.
  func noteWindowMove(_ windows: [WindowID]) {
    guard var run = topologyRestore, !run.isMoving else { return }

    run.skipping.formUnion(windows)
    topologyRestore = run
  }

  // MARK: The restore

  private func scheduleTopologyPass(after delay: Duration) {
    EventLoop.post(.topologyPass, after: delay, key: .topologyPass)
  }

  /// Runs one pass of the restore or of the watch.
  func topologyPass() {
    let now = TopologyClock.now

    if topologyTransaction.phase == .stable { return }

    // NOTE: A display callback whose event is still in the queue: its handler schedules the next pass.
    if TopologyMarks.current != topologyHandledMarks { return }

    if MissionControl.shared.isActive {
      scheduleTopologyPass(after: Self.topologyRetryDelay)
      return
    }

    if topologyTransaction.phase == .disturbed {
      if now < topologyTransaction.restoreTime {
        scheduleTopologyPassAtRestoreTime()
        return
      }
      if !beginTopologyRestore(at: now) { return }
    }

    guard var run = topologyRestore else {
      endTopologyTransaction("no restore")
      return
    }

    run.passes += 1
    topologyRestore = run

    if topologyTransaction.phase == .restoring,
      run.passes > Self.topologyPassLimit || run.failures > Self.topologyFailureLimit
    {
      TopologyLog.record("restore-gave-up", "passes=\(run.passes) failures=\(run.failures)")
      Logger.spaces.notice("giving up on the restore of the desktop: it did not converge")
      endTopologyTransaction("gave up")
      return
    }

    let inputs: SpaceLayoutInputs
    switch spaceLayoutInputs() {
    case .success(let read?): inputs = read
    case .success(nil):
      endTopologyTransaction("no layout for the displays")
      return
    case .failure:
      topologyRestore?.failures += 1
      scheduleTopologyPass(after: Self.topologyRetryDelay)
      return
    }

    let observed = topologyObserved(inputs)
    guard
      let plan = TopologyRestore.plan(
        run.commit, observed: observed, target: inputs.target, pinned: pinnedSpaces(),
        skipping: run.skipping.union(run.abandoned),
        visible: { inputs.displays[$0].currentSpace })
    else {
      endTopologyTransaction("the layout has another number of spaces")
      return
    }

    //
    // NOTE: The spaces are in place when the watch starts, so a space that is off now means macOS is at it again, and
    // macOS changes spaces before the display callback. Acting on that would create a space for one that is on its way.
    //
    if topologyTransaction.phase == .watching && !plan.spacesAreDone {
      TopologyLog.record("restore-watch-disturbed", "\(plan.step)")
      disturbTopology(at: now, displays: false)
      return
    }

    topologyRestore?.binding = plan.binding
    adoptTopologyViews(run.commit, plan.binding, observed)

    if !plan.spacesAreDone {
      performTopologyStep(plan.step, inputs)
    } else if !plan.moves.isEmpty {
      performTopologyMoves(plan.moves)
    } else {
      installTopologyTrees(run.commit, plan.binding, observed)
      finishTopologyPass(plan, observed, inputs, at: now)
    }
  }

  /// Starts the restore from the newest commit before the disturbance; false when there is none.
  private func beginTopologyRestore(at now: Double) -> Bool {
    let time = topologyTransaction.firstChange - Self.topologyCommitMargin
    guard let commit = topologyLedger.commit(before: time) else {
      endTopologyTransaction("no commit")
      return false
    }

    TopologyLog.record(
      "restore-begin",
      "waited=\(now - topologyTransaction.firstChange) commit-age=\(now - commit.time)")

    topologyTransaction.beginRestore()
    topologyRestore = TopologyRestoreRun(
      commit: commit, started: now, skipping: topologyRestore?.skipping ?? [])
    return true
  }

  private func topologyObserved(_ inputs: SpaceLayoutInputs) -> TopologyObserved {
    var windows: [SpaceID: [WindowID]] = [:]
    for sid in inputs.uuids.keys {
      windows[sid] = sid.windows(includingMinimized: true) ?? []
    }

    return TopologyObserved(
      displays: inputs.arrangement, spaces: inputs.spaces, user: inputs.user, uuids: inputs.uuids,
      windows: windows)
  }

  //
  // NOTE: The label and settings of a slot live in a view. When a stand-in took a slot it took the parked view of the
  // space it replaced, and when that space returns it gets the view back from the stand-in, once: after that the
  // stand-in has a new view, until it is destroyed.
  //

  /// Gives the spaces on the slots the views of the slots.
  private func adoptTopologyViews(
    _ commit: TopologyCommit, _ binding: TopologyBinding, _ observed: TopologyObserved
  ) {
    let sids = Dictionary(
      observed.uuids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

    for (slot, bound) in zip(commit.slots, binding.spaces) {
      guard let bound, bound != slot.uuid, let sid = sids[bound],
        topologyRestore?.adoptedViews.contains(slot.uuid) == false
      else { continue }

      topologyRestore?.adoptedViews.insert(slot.uuid)
      if parkedViews[slot.uuid] != nil {
        attachParkedView(uuid: slot.uuid, to: sid, as: bound)
      } else if let old = sids[slot.uuid] {
        moveView(from: old, to: sid, uuid: bound)
      }
    }
  }

  /// Gives a space the view of another space, with its label; the other space gets a new view when it asks for one.
  func moveView(from old: SpaceID, to sid: SpaceID, uuid: String) {
    guard let view = views[old] else { return }

    TopologyLog.record("view-moved", "\(old.rawValue) to \(sid.rawValue)")

    let label = labels.name(of: old)
    _ = labels.remove(id: old)

    views[old] = nil
    views[sid]?.destroy()
    views[sid] = view
    view.sid = sid
    view.uuid = uuid as CFString
    view.isValid = false

    if let label { labels.set(id: sid, name: label) }
  }

  private func performTopologyStep(_ step: SpaceLayoutStep, _ inputs: SpaceLayoutInputs) {
    switch perform(step, inputs) {
    case .failed:
      topologyRestore?.failures += 1
      scheduleTopologyPass(after: Self.topologyRetryDelay)
    case .done, .performed:
      if case .create = step {
        scheduleTopologyPass(after: Self.topologyCreateDelay)
      } else {
        scheduleTopologyPass(after: Self.topologyPassDelay)
      }
    }
  }

  private func performTopologyMoves(_ moves: [TopologyMove]) {
    guard var run = topologyRestore else { return }

    run.isMoving = true
    topologyRestore = run

    for move in moves {
      var windows: [WindowID] = []
      for window in move.windows {
        run.attempts[window, default: 0] += 1
        if run.attempts[window, default: 0] > Self.topologyWindowAttempts {
          TopologyLog.record("restore-window-gave-up", "\(window.rawValue)")
          run.abandoned.insert(window)
        } else {
          windows.append(window)
        }
      }
      if !windows.isEmpty { move.space.moveWindows(windows) }
    }

    run.isMoving = false
    topologyRestore = run
    scheduleTopologyPass(after: Self.topologyPassDelay)
  }

  //
  // NOTE: Taking the windows of each space first puts every window in the view of its space, and takes it out of a view it
  // only passed through. A hidden view stays dirty until it is shown.
  //

  /// Gives the views the windows of their spaces, and the trees of the slots.
  private func installTopologyTrees(
    _ commit: TopologyCommit, _ binding: TopologyBinding, _ observed: TopologyObserved
  ) {
    let wm = WindowManager.shared
    let sids = Dictionary(
      observed.uuids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

    for (slot, bound) in zip(commit.slots, binding.spaces) {
      guard let bound, let sid = sids[bound] else { continue }

      let onSpace = Set(observed.windows[sid] ?? [])
      if topologyRestore?.installed[sid] == onSpace { continue }
      topologyRestore?.installed[sid] = onSpace

      wm.validateAndCheckForWindows(on: sid)

      guard let tree = slot.tree else { continue }

      let view = view(for: sid)
      let complete = wm.installTree(tree, on: view, windows: Array(onSpace))
      TopologyLog.record(
        "restore-tree", "\(sid.rawValue) \(view.tree?.snapshot.shape ?? "") complete=\(complete)")
    }
  }

  /// The spaces and windows are in place: shows the spaces, focuses the window, and ends the restore or the watch.
  private func finishTopologyPass(
    _ plan: TopologyPlan, _ observed: TopologyObserved, _ inputs: SpaceLayoutInputs,
    at now: Double
  ) {
    guard let run = topologyRestore else { return }

    if topologyTransaction.phase == .watching {
      if topologyTransaction.watchHasEnded(at: now) {
        endTopologyTransaction("done")
      } else {
        scheduleTopologyPass(after: Self.topologyWatchDelay)
      }
      return
    }

    // NOTE: See TopologyTransaction.swift: the focus is left alone without a change of the displays, or after the user's.
    if topologyTransaction.restoresFocus {
      if showTopologySpaces(plan, observed, inputs) {
        scheduleTopologyPass(after: Self.topologyPassDelay)
        return
      }

      let wm = WindowManager.shared
      if let focused = run.commit.focused, wm.focus.focused != focused {
        wm.focusWindow(id: focused, warpsMouse: false)
      }
    } else {
      TopologyLog.record(
        "restore-focus-skipped",
        topologyTransaction.userFocused ? "user-focused" : "no-display-change")
    }

    TopologyLog.record("restore-done", "took=\(now - run.started) passes=\(run.passes)")
    topologyTransaction.finishRestore(at: now)

    if topologyTransaction.phase == .watching {
      scheduleTopologyPass(after: Self.topologyWatchDelay)
    } else {
      endTopologyTransaction("done")
    }
  }

  /// Tells the displays to show their spaces, the active space last; true when one had to change.
  private func showTopologySpaces(
    _ plan: TopologyPlan, _ observed: TopologyObserved, _ inputs: SpaceLayoutInputs
  ) -> Bool {
    guard let run = topologyRestore, run.shownAttempts < Self.topologyShownAttempts else {
      return false
    }

    let shown = TopologyRestore.shown(run.commit, binding: plan.binding, observed: observed)
    let active = run.commit.active.flatMap { uuid in observed.uuids.first { $0.value == uuid }?.key
    }
    let wrong = shown.filter { inputs.displays[$0.key].currentSpace != $0.value }.map(\.value)

    if wrong.isEmpty { return false }

    topologyRestore?.shownAttempts += 1
    for sid in wrong.filter({ $0 != active }) + wrong.filter({ $0 == active }) {
      TopologyLog.record("restore-show", "\(sid.rawValue)")
      _ = ScriptingAddition.shared.focusSpace(sid)
    }
    return true
  }

  /// Ends the transaction, and lets everything that waited for it run.
  private func endTopologyTransaction(_ reason: String) {
    TopologyLog.record("topology-stable", reason)

    if let run = topologyRestore, let binding = run.binding {
      topologyLedger.adopt(binding, of: run.commit)
    }

    topologyRestore = nil
    returningTrees = [:]
    topologyTransaction.finish()

    refreshDisplaySpaces(includingHidden: true)
    scheduleSpaceLayout(after: .zero, resetPasses: true)
    schedulePinReconcile(after: .zero, resetPasses: true)
    scheduleTopologyCommit()
  }
}
