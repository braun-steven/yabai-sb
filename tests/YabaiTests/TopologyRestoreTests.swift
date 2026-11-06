import CoreFoundation
import OrderedCollections
import SortedCollections
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The planning is tested in YabaiCoreTests/TopologyLedgerTests.swift, against a desktop that behaves like macOS. These
// tests cover what the daemon adds to it, without the window server: the gates of the freeze and the views of the slots.
//

private let otherSid = SpaceID(rawValue: 0xFFFF_0300)

extension DaemonState {
  @Suite
  @WM struct TopologyRestoreTests {
    /// Turns on the space layout, which is what turns on the restore.
    private func enableRestore() throws {
      Config.current.space.spaceLayouts = [try #require(SpaceLayout(parsing: "2"))]
    }

    private func run() -> TopologyRestoreRun {
      TopologyRestoreRun(
        commit: TopologyCommit(time: 0, slots: [], shown: [:], active: nil, focused: nil),
        started: 0)
    }

    @Test func nothingIsFrozenWithoutASpaceLayout() {
      let sm = SpaceManager.shared
      sm.topologyDisturbed(at: TopologyClock.now, displays: true)

      #expect(!sm.topologyTransaction.isFrozen)
    }

    @Test func aDisplayChangeFreezesAndStopsTheCommits() throws {
      try enableRestore()
      let sm = SpaceManager.shared

      sm.topologyDisturbed(at: TopologyClock.now, displays: true)
      #expect(sm.topologyTransaction.phase == .disturbed)
      #expect(sm.topologyTransaction.holdsWindows)

      sm.scheduleTopologyCommit()
      #expect(!sm.topologyCommitPending)
    }

    @Test func theLayoutPassWaitsForTheRestore() throws {
      try enableRestore()
      let sm = SpaceManager.shared
      sm.topologyDisturbed(at: TopologyClock.now, displays: true)

      EventHandler.shared.spaceLayoutReconcile()

      #expect(sm.spaceLayoutPasses == 0)
    }

    @Test func aSpaceThatYabaiDestroyedDoesNotDisturb() throws {
      try enableRestore()
      let sm = SpaceManager.shared
      sm.expectedSpaceDestroys.insert(otherSid)

      sm.topologySpaceDestroyed(otherSid)

      #expect(!sm.topologyTransaction.isFrozen)
      #expect(sm.expectedSpaceDestroys.isEmpty)
    }

    @Test func aSpaceThatMacOSDestroyedDisturbs() throws {
      try enableRestore()
      let sm = SpaceManager.shared

      sm.topologySpaceDestroyed(otherSid)

      #expect(sm.topologyTransaction.phase == .disturbed)
      #expect(!sm.topologyTransaction.displaysChanged)
    }

    @Test func aWindowMovedDuringARestoreStaysWhereItWasPut() {
      let sm = SpaceManager.shared
      sm.topologyRestore = run()

      sm.noteWindowMove([wid(1)])

      #expect(sm.topologyRestore?.skipping == [wid(1)])
    }

    @Test func aMoveOfTheRestoreItselfIsNoMoveOnPurpose() {
      let sm = SpaceManager.shared
      var restore = run()
      restore.isMoving = true
      sm.topologyRestore = restore

      sm.noteWindowMove([wid(1)])

      #expect(sm.topologyRestore?.skipping.isEmpty == true)
    }

    @Test func aReturningSpaceGetsTheViewAndLabelOfItsStandIn() {
      let workspace = Workspace()
      let sm = SpaceManager.shared
      sm.labels.set(id: Workspace.sid, name: "work")
      workspace.view.windowGap = 17
      workspace.view.overrides = .windowGap

      sm.moveView(from: Workspace.sid, to: otherSid, uuid: "original")

      #expect(sm.views[Workspace.sid] == nil)
      #expect(sm.views[otherSid] === workspace.view)
      #expect(workspace.view.sid == otherSid)
      #expect(workspace.view.uuid as String? == "original")
      #expect(sm.labels.id(named: "work") == otherSid)
    }

    @Test func aTreeDoesNotKeepAWindowThatLeftTheSpace() throws {
      let workspace = Workspace()
      for n: UInt32 in 1...2 {
        let target = workspace.open(n)
        target.isRoot = true
        target.isManagedByRule = true
      }
      let snapshot = TreeSnapshot(
        layout: .splitH, lastSplit: .splitH, percent: 1, zoom: .none, isSelected: false,
        windowID: nil,
        children: [
          TreeSnapshot(
            layout: .splitH, lastSplit: .splitH, percent: 1, zoom: .none, isSelected: false,
            windowID: wid(1), children: [], focusOrder: [])
        ], focusOrder: [0])

      WindowManager.shared.installTree(snapshot, on: workspace.view, windows: [wid(1)])

      #expect(workspace.view.windowIDs == [wid(1)])
    }
  }
}
