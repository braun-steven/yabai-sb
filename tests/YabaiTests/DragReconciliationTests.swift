import CoreGraphics
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: A window dragged across displays (#2843): the window server puts it on the space of the display it is over,
// and the display change reconciles that space before the drop. Reconciliation leaves the dragged window in its source
// tree until the drop, so the drop starts from the source view, as sway's seatop_move_tiling re-arranges nothing before
// the drop. A window that reconciliation does take from another view leaves that view re-tiled, and the view is flushed
// with the owner, so its display shows no gap.
//

/// The tiled windows w1, w2 and w3 of a Workspace (the source display), and an empty tree view of another space (the
/// target display), with the messages and placements of opening them drained.
@WM private func dragWorkspaces() -> (source: Workspace, target: View) {
  let source = Workspace()
  for n: UInt32 in 1...3 {
    let window = source.open(n)
    window.isRoot = true
    window.isManagedByRule = true
  }
  source.view.isDirty = false

  let target = View(sid: SpaceID(0xFFFF_0102))
  target.layout = .tree
  target.area = Area(x: 1200, y: 0, w: 1200, h: 800)
  SpaceManager.shared.views[target.sid] = target
  _ = Headless.drain()
  return (source, target)
}

extension DaemonState {
  @Suite
  @WM struct DragReconciliationTests {
    struct DraggedRow: Sendable, CustomTestStringConvertible {
      var action: MouseAction
      var hasWindow: Bool
      var isDragged: Bool
      var testDescription: String { "\(action) window \(hasWindow)" }
    }

    nonisolated static let draggedRows: [DraggedRow] = [
      .init(action: .none, hasWindow: false, isDragged: false),
      .init(action: .none, hasWindow: true, isDragged: false),
      .init(action: .move, hasWindow: false, isDragged: false),
      .init(action: .move, hasWindow: true, isDragged: true),
      .init(action: .resize, hasWindow: true, isDragged: true),
    ]

    @Test(arguments: draggedRows)
    func draggedWindowIsTheWindowOfADragInProgress(_ row: DraggedRow) {
      let ms = MouseState.shared
      let target = Window(id: wid(7))
      ms.currentAction = row.action
      ms.window = row.hasWindow ? target : nil

      #expect(ms.draggedWindowID == (row.isDragged ? target.id : nil))
    }

    @Test func reconciliationLeavesTheDraggedWindowInItsSourceTree() {
      let (source, target) = dragWorkspaces()
      let wm = WindowManager.shared
      let ms = MouseState.shared
      ms.currentAction = .move
      ms.window = wm.window[wid(2)]

      // the window server has w2 on the target space while it is dragged over the target display
      let sources = wm.reconcileWindows(on: target, against: [wid(2)], dragged: ms.draggedWindowID)
      wm.validateWindows(on: source.view, against: [wid(1), wid(3)], dragged: ms.draggedWindowID)

      #expect(sources.isEmpty)
      #expect(source.dump == "splith focus=2,1,0\n  w1 0.3333\n  w2 0.3333\n  w3 0.3333")
      #expect(target.windowIDs.isEmpty)
      #expect(wm.managedView(for: wm.window[wid(2)]!) === source.view)
      #expect(!source.view.isDirty)
      #expect(!target.isDirty)
      #expect(Headless.drain().messages.isEmpty)
    }

    @Test func reconciliationOfTheDraggedSpaceFlushesNothing() {
      let (source, target) = dragWorkspaces()
      let wm = WindowManager.shared

      wm.reconcileAndFlush(target, against: [wid(2)], dragged: wid(2))

      #expect(source.view.windowIDs == [wid(1), wid(2), wid(3)])
      #expect(Headless.drain().placements.isEmpty)
    }

    @Test func reconciliationFlushesTheViewAWindowWasTakenFrom() {
      let (source, target) = dragWorkspaces()
      let wm = WindowManager.shared

      // no drag: w2 moved to the target display, and the source display re-tiles without a gap
      wm.reconcileAndFlush(target, against: [wid(2)], dragged: nil)

      #expect(source.dump == "splith focus=1,0\n  w1 0.5000\n  w3 0.5000")
      #expect(target.windowIDs == [wid(2)])
      #expect(wm.managedView(for: wm.window[wid(2)]!) === target)
      #expect(!source.view.isDirty)
      let placements = Headless.drain().placements
      #expect(placements.contains(RecordedPlacement(windowID: wid(1), x: 0, y: 0, w: 600, h: 800)))
      #expect(
        placements.contains(RecordedPlacement(windowID: wid(3), x: 600, y: 0, w: 600, h: 800)))
    }

    @Test func reconciliationReturnsEachSourceViewOnce() {
      let (source, target) = dragWorkspaces()
      let wm = WindowManager.shared

      let sources = wm.reconcileWindows(on: target, against: [wid(1), wid(2)])

      #expect(sources.count == 1)
      #expect(sources.first === source.view)
      #expect(source.view.isDirty)
    }

    @Test func theDropAfterADragStartsFromTheSourceView() {
      let (source, target) = dragWorkspaces()
      let wm = WindowManager.shared
      let ms = MouseState.shared
      let dragged = wm.window[wid(2)]!
      ms.currentAction = .move
      ms.window = dragged

      // the display change during the drag reconciles the target space
      wm.reconcileAndFlush(target, against: [dragged.id], dragged: ms.draggedWindowID)
      // the view endDrag hands to the drop
      #expect(wm.managedView(for: dragged) === source.view)

      // once the drag has ended, reconciliation takes the window again
      ms.currentAction = .none
      wm.reconcileAndFlush(target, against: [dragged.id], dragged: ms.draggedWindowID)
      #expect(wm.managedView(for: dragged) === target)
      #expect(source.dump == "splith focus=1,0\n  w1 0.5000\n  w3 0.5000")
    }
  }
}
