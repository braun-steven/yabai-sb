import CoreFoundation
import OrderedCollections
import SortedCollections
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: A view of a destroyed space waits under its uuid, and the space that returns with that uuid and a new id gets its
// tree, label and settings back (SpaceManager+Parking.swift). The tests pass the window lists, so nothing asks the window
// server.
//

private let uuid = "AAAAAAAA-0000-0000-0000-000000000001"
private let newSid = SpaceID(rawValue: 0xFFFF_0200)

extension DaemonState {
  @Suite
  @WM struct SpaceParkingTests {
    /// A Workspace on a space with a uuid, with its windows w1, w2 and w3 managed.
    private func workspace() -> Workspace {
      let workspace = Workspace()
      workspace.view.uuid = uuid as CFString
      for n: UInt32 in 1...3 {
        let target = workspace.open(n)
        target.isRoot = true
        target.isManagedByRule = true
      }
      return workspace
    }

    /// The windows of the tree in a tabbed container next to w3, as the user arranged them.
    private func tabbedTree() -> TreeSnapshot {
      func leaf(_ n: UInt32, _ percent: Float) -> TreeSnapshot {
        TreeSnapshot(
          layout: .splitH, lastSplit: .splitH, percent: percent, zoom: .none, isSelected: false,
          windowID: wid(n), children: [], focusOrder: [])
      }
      let tabs = TreeSnapshot(
        layout: .tabbed, lastSplit: .splitH, percent: 0.7, zoom: .none, isSelected: false,
        windowID: nil, children: [leaf(1, 0.5), leaf(2, 0.5)], focusOrder: [1, 0])
      return TreeSnapshot(
        layout: .splitH, lastSplit: .splitH, percent: 1, zoom: .none, isSelected: false,
        windowID: nil, children: [tabs, leaf(3, 0.3)], focusOrder: [0, 1])
    }

    @Test func aDestroyedSpaceGivesItsTreeLabelAndSettingsToTheSpaceThatReturns() throws {
      let workspace = workspace()
      let sm = SpaceManager.shared
      let wm = WindowManager.shared
      sm.labels.set(id: Workspace.sid, name: "work")
      workspace.view.windowGap = 17
      workspace.view.overrides = .windowGap
      let tree = workspace.view.root.snapshot
      let windows = workspace.view.windowIDs

      sm.parkView(workspace.view)

      #expect(sm.views[Workspace.sid] == nil)
      #expect(sm.labels.id(named: "work") == nil)
      #expect(workspace.view.tree == nil)
      for windowID in windows {
        #expect(wm.managedView(for: try #require(wm.window(for: windowID))) == nil)
      }

      sm.attachParkedView(uuid: uuid, to: newSid)

      let view = try #require(sm.views[newSid])
      #expect(view === workspace.view)
      #expect(view.sid == newSid)
      #expect(view.windowGap == 17)
      #expect(view.overrides == .windowGap)
      #expect(view.isInvalid)
      #expect(sm.labels.id(named: "work") == newSid)
      #expect(sm.parkedViews.isEmpty)

      #expect(!sm.installReturningTrees { _ in windows })

      #expect(view.tree?.snapshot.windowIDs == tree.windowIDs)
      for windowID in windows {
        #expect(wm.managedView(for: try #require(wm.window(for: windowID))) === view)
      }
      #expect(sm.returningTrees.isEmpty)
    }

    @Test func aSpaceThatTakesThePlaceOfAnotherGetsItsViewAndKeepsItsUuid() throws {
      let workspace = workspace()
      let sm = SpaceManager.shared
      sm.labels.set(id: Workspace.sid, name: "work")
      sm.parkView(workspace.view)

      sm.attachParkedView(uuid: uuid, to: newSid, as: "replacement")

      let view = try #require(sm.views[newSid])
      #expect(view === workspace.view)
      #expect((view.uuid as String?) == "replacement")
      #expect(sm.labels.id(named: "work") == newSid)
      #expect(sm.returningTrees[newSid] != nil)
    }

    @Test func aSpaceWithNothingToGiveBackIsNotKept() {
      let view = View(sid: Workspace.sid)
      view.uuid = uuid as CFString
      SpaceManager.shared.views[Workspace.sid] = view

      SpaceManager.shared.parkView(view)

      #expect(SpaceManager.shared.parkedViews.isEmpty)
      #expect(view.uuid == nil)
    }

    @Test func theOldestParkedViewGoesFirst() {
      let sm = SpaceManager.shared
      for n in 0...SpaceManager.parkedViewLimit {
        let sid = SpaceID(rawValue: 0xFFFF_1000 + UInt64(n))
        let view = View(sid: sid)
        view.uuid = "space-\(n)" as CFString
        view.overrides = .windowGap
        sm.views[sid] = view
        sm.parkView(view)
      }

      #expect(sm.parkedViews.count == SpaceManager.parkedViewLimit)
      #expect(sm.parkedViews["space-0"] == nil)
      #expect(sm.parkedViews["space-\(SpaceManager.parkedViewLimit)"] != nil)
    }

    @Test func aReturningSpaceWithoutAParkedViewChangesNothing() {
      SpaceManager.shared.attachParkedView(uuid: uuid, to: newSid)
      #expect(SpaceManager.shared.views[newSid] == nil)
    }

    @Test func aTreeWaitsForItsMissingWindowsAndThenHasAllOfThem() throws {
      let workspace = workspace()
      let sm = SpaceManager.shared
      let view = workspace.view
      view.tree?.destroy()
      view.tree = Con(snapshot: tabbedTree())

      sm.parkView(view)
      sm.attachParkedView(uuid: uuid, to: newSid)

      // w1 is still on another space.
      #expect(sm.installReturningTrees { _ in [wid(2), wid(3)] })
      #expect(view.tree?.snapshot.windowIDs == [wid(2), wid(3)])
      #expect(sm.returningTrees[newSid]?.attempts == 1)

      #expect(!sm.installReturningTrees { _ in [wid(1), wid(2), wid(3)] })
      #expect(view.tree?.snapshot == tabbedTree())
    }

    @Test func aTreeStopsWaitingAfterItsAttempts() {
      let workspace = workspace()
      let sm = SpaceManager.shared
      sm.parkView(workspace.view)
      sm.attachParkedView(uuid: uuid, to: newSid)

      for _ in 1..<SpaceManager.returningTreeAttempts {
        #expect(sm.installReturningTrees { _ in [wid(1)] })
      }
      #expect(!sm.installReturningTrees { _ in [wid(1)] })
      #expect(sm.returningTrees.isEmpty)
    }

    @Test func aTreeKeepsWaitingWhenItsSpaceIsDestroyedAgainFirst() {
      let workspace = workspace()
      let sm = SpaceManager.shared
      let view = workspace.view
      view.tree?.destroy()
      view.tree = Con(snapshot: tabbedTree())

      sm.parkView(view)
      sm.attachParkedView(uuid: uuid, to: newSid)
      sm.parkView(view)
      sm.attachParkedView(uuid: uuid, to: Workspace.sid)

      #expect(!sm.installReturningTrees { _ in [wid(1), wid(2), wid(3)] })
      #expect(view.tree?.snapshot == tabbedTree())
    }

    @Test func aClosedWindowIsNoMissingWindow() {
      let workspace = workspace()
      let sm = SpaceManager.shared
      sm.parkView(workspace.view)
      sm.attachParkedView(uuid: uuid, to: newSid)
      WindowManager.shared.window[wid(1)] = nil

      #expect(!sm.installReturningTrees { _ in [wid(2), wid(3)] })
      #expect(
        workspace.view.windowIDs.sorted(by: { $0.rawValue < $1.rawValue }) == [wid(2), wid(3)])
    }

    @Test func installingATreeTakesItsWindowsFromOtherViewsAndKeepsTheOthers() throws {
      let workspace = workspace()
      let wm = WindowManager.shared
      let target = View(sid: newSid)
      target.layout = .tree
      target.area = workspace.view.area
      SpaceManager.shared.views[newSid] = target

      let extra = Window(id: wid(9))
      extra.application = workspace.application
      extra.isRoot = true
      extra.isManagedByRule = true
      wm.window[extra.id] = extra
      wm.managedWindows[extra.id] = target
      target.add(extra, insertionPoint: nil)

      let complete = wm.installTree(
        tabbedTree(), on: target, windows: [wid(1), wid(2), wid(3), wid(9)])

      #expect(complete)
      #expect(Set(target.windowIDs) == [wid(1), wid(2), wid(3), wid(9)])
      #expect(workspace.view.windowIDs.isEmpty)
      #expect(wm.managedView(for: try #require(wm.window(for: wid(1)))) === target)
      #expect(wm.managedView(for: extra) === target)
    }

    @Test func aFloatingViewTakesNoTree() {
      let view = View(sid: newSid)
      view.layout = .float

      #expect(WindowManager.shared.installTree(tabbedTree(), on: view, windows: [wid(1)]))
      #expect(view.tree == nil)
    }

    @Test func viewsFollowTheirUuidToANewIdAndParkedViewsReturn() throws {
      let workspace = workspace()
      let sm = SpaceManager.shared
      sm.labels.set(id: Workspace.sid, name: "work")
      let parkedSid = SpaceID(rawValue: 0xFFFF_0300)
      let parked = View(sid: parkedSid)
      parked.uuid = "parked" as CFString
      parked.overrides = .windowGap
      sm.views[parkedSid] = parked
      sm.parkView(parked)
      let returned = SpaceID(rawValue: 0xFFFF_0301)

      sm.rekeyViews(spaces: [(newSid, uuid as CFString), (returned, "parked" as CFString)])

      #expect(sm.views[Workspace.sid] == nil)
      #expect(sm.views[newSid] === workspace.view)
      #expect(workspace.view.sid == newSid)
      #expect(sm.labels.id(named: "work") == newSid)
      #expect(sm.views[returned] === parked)
    }
  }
}
