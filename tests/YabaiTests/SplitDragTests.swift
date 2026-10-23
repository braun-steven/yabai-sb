import CoreGraphics
import Synchronization
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The split drag (P13.2) on a Workspace view (TreeFixtures.swift), through the handlers that the event loop runs. The
// event tap is not involved: it needs the window server, and the tests call the handlers in the order the tap posts them.
// A drag event is counted in pendingSplitDragged as the tap counts it. The Workspace view has no gap, so the boundary of
// two windows side by side is at x 600 of a 1200 by 800 view.
//

extension DaemonState {
  @Suite
  @WM struct SplitDragTests {
    /// Two windows in a split of the view: side by side, or stacked when vertical is true.
    private func twoWindows(vertical: Bool = false) -> Workspace {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2)
      if vertical { space.view.root.layout = .splitV }
      space.view.updateTree()
      space.view.flush()
      return space
    }

    /// A drag event at the point, counted as the tap counts it before the event loop takes it.
    private static func move(_ x: CGFloat, _ y: CGFloat) {
      _ = pendingSplitDragged.wrappingAdd(1, ordering: .acquiringAndReleasing)
      EventHandler.shared.splitDragMoved(CGPoint(x: x, y: y))
    }

    private static func near(_ actual: Float, _ expected: Float) -> Bool {
      abs(actual - expected) < 1e-4
    }

    @Test func flushStoresTheVisiblePathForTheTap() {
      let space = twoWindows()

      let layout = SplitDragCache.layout(for: Workspace.sid)
      #expect(layout?.nodes.map(\.childCount) == [2, 0, 0])
      #expect(layout?.tiledWindowIDs == [wid(1), wid(2)])
      #expect(layout?.areas.count == 3)
      #expect(layout?.gap == space.view.windowGapValue)
    }

    @Test func zoomedWindowRemovesTheLayout() {
      let space = twoWindows()
      space.node(1).zoom = .parent
      space.view.flush()

      #expect(SplitDragCache.layout(for: Workspace.sid) == nil)
    }

    @Test func drawingTheDragMovesTheGapFromTheStart() {
      let space = twoWindows()

      EventHandler.shared.beginSplitDrag(at: CGPoint(x: 600, y: 400), in: space.view)
      #expect(MouseState.shared.splitDrag != nil)

      // NOTE: 120 of 1200 points is a change of 0.1 for the first child.
      Self.move(720, 400)
      #expect(Self.near(space.node(1).percent, 0.6))
      #expect(Self.near(space.node(2).percent, 0.4))

      // NOTE: The mouse up applies the final point from the start, not from the last frame.
      EventHandler.shared.splitDragEnded(CGPoint(x: 1000, y: 400))
      #expect(MouseState.shared.splitDrag == nil)
      #expect(Self.near(space.node(1).percent, 0.8333))
      #expect(Self.near(space.node(2).percent, 0.1667))
      #expect(abs(space.node(1).area.w - 1000) < 0.5)
      #expect(space.view.isDirty == false)
    }

    @Test func dragClampsBothChildrenAtTheMinimum() {
      let space = twoWindows()

      EventHandler.shared.beginSplitDrag(at: CGPoint(x: 600, y: 400), in: space.view)
      Self.move(1400, 400)
      EventHandler.shared.splitDragEnded(CGPoint(x: 1400, y: 400))

      // NOTE: The second child would be at -0.1667, so it stops at the minimum and the first gives up the rest.
      #expect(Self.near(space.node(1).percent, 0.95))
      #expect(Self.near(space.node(2).percent, 0.05))
      #expect(Self.near(space.node(1).percent + space.node(2).percent, 1))
    }

    @Test func verticalSplitMovesWithTheYAxis() {
      let space = twoWindows(vertical: true)

      // NOTE: A stacked pair has its gap at y 400, and only the vertical offset counts.
      EventHandler.shared.beginSplitDrag(at: CGPoint(x: 600, y: 400), in: space.view)
      EventHandler.shared.splitDragEnded(CGPoint(x: 100, y: 640))

      #expect(Self.near(space.node(1).percent, 0.8))
      #expect(Self.near(space.node(2).percent, 0.2))
    }

    @Test func pointInsideAWindowStartsNoDrag() {
      let space = twoWindows()

      EventHandler.shared.beginSplitDrag(at: CGPoint(x: 300, y: 400), in: space.view)
      #expect(MouseState.shared.splitDrag == nil)
    }

    @Test func floatingViewStartsNoDrag() {
      let space = twoWindows()
      space.view.layout = .float

      EventHandler.shared.beginSplitDrag(at: CGPoint(x: 600, y: 400), in: space.view)
      #expect(MouseState.shared.splitDrag == nil)
    }

    @Test func dragEndsWhenItsWindowCloses() {
      let space = twoWindows()

      EventHandler.shared.beginSplitDrag(at: CGPoint(x: 600, y: 400), in: space.view)
      #expect(space.close(2))
      Self.move(720, 400)

      #expect(MouseState.shared.splitDrag == nil)
    }
  }
}
