import CoreGraphics
import SortedCollections
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The refresh of the spaces whose display changed: a view remembers the display frame of its last update, and a
// view laid out for another frame (its space moved to another display, or the display changed) is stale. A refresh
// pass updates the stale views and flushes the dirty ones that are shown, leaves the view of a dragged window alone,
// and the moves of `moveSpace(_:toDisplay:)` wait until the window server has the space on its new display. Headless
// mode stands in for the display: `Headless.displayFrame` is the frame of the display the space is on now.
//

extension DaemonState {
  @Suite struct SpaceRefreshTests {
    private let start: UInt64 = 5_000_000_000_000
    private let sid = SpaceID(rawValue: 0xFFFF_0111)
    private let other = SpaceID(rawValue: 0xFFFF_0112)
    private let did = DisplayID(rawValue: 0xFFFF_0211)
    private let source = DisplayID(rawValue: 0xFFFF_0212)
    private let oldFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let newFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    /// A view of `sid` with the given state, laid out last for `oldFrame`.
    @WM private func makeView(
      layout: ViewType = .tree, isValid: Bool = true, isDirty: Bool = false
    ) -> View {
      let view = View(sid: sid)
      view.layout = layout
      view.isValid = isValid
      view.isDirty = isDirty
      view.layoutFrame = oldFrame
      return view
    }

    struct StepRow: Sendable, CustomTestStringConvertible {
      var name: String
      var layout: ViewType = .tree
      var isValid = true
      var isDirty = false
      var moved = false
      var hasDisplay = true
      var isVisible = true
      var step: View.RefreshStep

      var testDescription: String { name }
    }

    static let stepRows: [StepRow] = [
      StepRow(name: "up to date, shown", step: .none),
      StepRow(name: "dirty, shown", isDirty: true, step: .flush),
      StepRow(name: "dirty, hidden", isDirty: true, isVisible: false, step: .none),
      StepRow(name: "invalid, shown", isValid: false, step: .update),
      StepRow(name: "invalid, hidden", isValid: false, isVisible: false, step: .update),
      StepRow(name: "moved, shown", moved: true, step: .update),
      StepRow(name: "moved and dirty, shown", isDirty: true, moved: true, step: .update),
      StepRow(name: "moved, hidden", moved: true, isVisible: false, step: .update),
      StepRow(name: "no display", isValid: false, moved: true, hasDisplay: false, step: .none),
      StepRow(name: "float", layout: .float, isValid: false, moved: true, step: .none),
    ]

    @Test(arguments: stepRows)
    @WM func refreshStep(_ row: StepRow) {
      let view = makeView(layout: row.layout, isValid: row.isValid, isDirty: row.isDirty)
      let frame = row.hasDisplay ? (row.moved ? newFrame : oldFrame) : nil

      #expect(view.refreshStep(frame: frame, isVisible: row.isVisible) == row.step)
    }

    @Test @WM func updateRemembersItsDisplayFrame() {
      let workspace = Workspace()
      workspace.open(1)
      Headless.displayFrame = oldFrame
      workspace.view.update()
      #expect(workspace.view.layoutFrame == oldFrame)
      #expect(!workspace.view.needsUpdate)

      Headless.displayFrame = newFrame
      #expect(workspace.view.needsUpdate)
      workspace.view.update()
      #expect(workspace.view.layoutFrame == newFrame)
      #expect(!workspace.view.needsUpdate)
    }

    /// A Workspace with two windows laid out and flushed in `oldFrame`, whose space is now on a display with `newFrame`.
    @WM private func movedWorkspace() -> Workspace {
      let workspace = Workspace()
      workspace.open(1)
      workspace.open(2)
      Headless.displayFrame = oldFrame
      workspace.view.updateAndFlush()
      _ = drainPlacements()
      Headless.displayFrame = newFrame
      return workspace
    }

    @Test @WM func passLaysOutAMovedSpaceForItsNewDisplay() {
      let workspace = movedWorkspace()

      SpaceManager.shared.refreshSpaces(
        [.init(sid: Workspace.sid, frame: newFrame, isVisible: true)], dragged: nil)

      let placements = drainPlacements()
      #expect(placements.count == 2)
      #expect(
        placements.allSatisfy {
          newFrame.contains(CGPoint(x: CGFloat($0.placement.x), y: CGFloat($0.placement.y)))
        })
      #expect(workspace.view.layoutFrame == newFrame)
    }

    @Test @WM func passLeavesAnUpToDateSpaceAlone() {
      let workspace = movedWorkspace()

      SpaceManager.shared.refreshSpaces(
        [.init(sid: Workspace.sid, frame: oldFrame, isVisible: true)], dragged: nil)

      #expect(drainPlacements().isEmpty)
      #expect(workspace.view.layoutFrame == oldFrame)
    }

    @Test @WM func passLeavesTheSpaceOfADraggedWindowAlone() {
      let workspace = movedWorkspace()

      SpaceManager.shared.refreshSpaces(
        [.init(sid: Workspace.sid, frame: newFrame, isVisible: true)], dragged: wid(2))

      #expect(drainPlacements().isEmpty)
      #expect(workspace.view.layoutFrame == oldFrame)
    }

    @Test @WM func passSkipsUnknownSpaces() {
      SpaceManager.shared.refreshSpaces(
        [.init(sid: other, frame: newFrame, isVisible: true)], dragged: nil)

      #expect(SpaceManager.shared.views[other] == nil)
    }

    @Test(arguments: [false, true])
    @WM func headlessEntriesAreTheSeededViews(includingHidden: Bool) {
      let sm = SpaceManager.shared
      _ = Workspace()
      sm.views[other] = View(sid: other)
      Headless.activeSpace = Workspace.sid

      let entries = sm.spaceRefreshEntries(includingHidden: includingHidden)
      let shown = SpaceManager.SpaceRefreshEntry(
        sid: Workspace.sid, frame: Headless.displayFrame, isVisible: true)
      let hidden = SpaceManager.SpaceRefreshEntry(
        sid: other, frame: Headless.displayFrame, isVisible: false)
      #expect(
        Set(entries.map(\.sid)) == Set(includingHidden ? [Workspace.sid, other] : [Workspace.sid]))
      #expect(entries.contains(shown))
      #expect(entries.contains(hidden) == includingHidden)
    }

    @Test @WM func moveWaitsForItsDisplay() {
      let sm = SpaceManager.shared
      sm.recordSpaceMove(sid, to: did, at: start)

      #expect(!sm.consumeSpaceMoves(display: { _ in source }, now: start + 100_000_000))
      #expect(!sm.consumeSpaceMoves(display: { _ in nil }, now: start + 1_999_000_000))
      #expect(sm.pendingSpaceMoves.map(\.sid) == [sid])
    }

    @Test @WM func reportedMoveIsDroppedAndOthersWait() {
      let sm = SpaceManager.shared
      sm.recordSpaceMove(sid, to: did, at: start)
      sm.recordSpaceMove(other, to: source, at: start)

      let arrived = sm.consumeSpaceMoves(
        display: { _ in did }, now: start + 100_000_000)
      #expect(arrived)
      #expect(sm.pendingSpaceMoves.map(\.sid) == [other])
      #expect(!sm.consumeSpaceMoves(display: { _ in did }, now: start + 200_000_000))
    }

    @Test(arguments: [2_000_000_000, 5_000_000_000] as [UInt64])
    @WM func expiredMoveIsDropped(after elapsed: UInt64) {
      let sm = SpaceManager.shared
      sm.recordSpaceMove(sid, to: did, at: start)

      #expect(sm.consumeSpaceMoves(display: { _ in source }, now: start + elapsed))
      #expect(sm.pendingSpaceMoves.isEmpty)
    }

    @Test @WM func newerMoveOfASpaceReplacesTheOlder() {
      let sm = SpaceManager.shared
      sm.recordSpaceMove(sid, to: did, at: start)
      sm.recordSpaceMove(sid, to: source, at: start + 100_000_000)

      #expect(
        sm.pendingSpaceMoves == [.init(sid: sid, display: source, time: start + 100_000_000)])
      #expect(!sm.consumeSpaceMoves(display: { _ in did }, now: start + 200_000_000))
      #expect(sm.consumeSpaceMoves(display: { _ in source }, now: start + 200_000_000))
    }
  }
}
