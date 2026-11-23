import CoreGraphics
import Foundation
import InlineSnapshotTesting
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The scroll layout of a view (ScrollView.swift) on a Workspace view (TreeFixtures.swift) of 1200x800 at the
// origin, whose display is the same area, without gaps: windows open as columns, the strip scrolls to the focused
// column, and the windows out of view are parked at the edge with the default peek of 24 points left on screen, which
// the strip keeps room for: columns of the default 0.5 are 588 wide, half of 1200 less 24. The placements are those of
// headless flushes.
//

extension DaemonState {
  @Suite
  @WM struct ScrollViewTests {
    /// The frame that the view places window n at.
    private func frame(_ space: Workspace, _ n: UInt32) -> Area {
      space.view.frame(for: space.node(n))
    }

    // MARK: - Columns

    @Test func windowsOpenAsColumnsRightOfTheFocusedColumn() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.focus(1)
      space.open(3, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0,2
          w1 0.3333
          w3 0.3333
          w2 0.3333
        """
      }
    }

    @Test func aLoneColumnFillsTheView() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)

      #expect(frame(space, 1) == Area(x: 0, y: 0, w: 1200, h: 800))
    }

    @Test func columnsAreTheirShareOfTheViewWide() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)

      // They fit, so they are centered.
      #expect(frame(space, 1) == Area(x: 12, y: 0, w: 588, h: 800))
      #expect(frame(space, 2) == Area(x: 600, y: 0, w: 588, h: 800))
    }

    @Test func theStripScrollsToANewColumnAndParksTheColumnsOutOfView() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)

      #expect(space.view.scroll.offset == 564)
      #expect(frame(space, 1) == Area(x: -564, y: 0, w: 588, h: 800))
      #expect(space.node(1).isScrolledOut)
      #expect(frame(space, 2) == Area(x: 24, y: 0, w: 588, h: 800))
      #expect(frame(space, 3) == Area(x: 612, y: 0, w: 588, h: 800))
      #expect(!space.node(3).isScrolledOut)
    }

    @Test(arguments: [1, 24, 40])
    func aColumnOutOfViewShowsThePeek(peek: Int) {
      Config.current.space.scrollPeek = peek
      let space = threeColumns()

      let parked = frame(space, 1)
      #expect(parked.x + parked.w == Float(peek))
      #expect(frame(space, 3).x + frame(space, 3).w == 1200)
    }

    @Test func noColumnCoversTheViewFromEdgeToEdge() {
      Config.current.space.scrollColumnWidth = 1
      let space = threeColumns()
      space.view.focusWindow(wid(2))

      // The middle column leaves room for a strip on each side, the last one for a strip on its left.
      #expect(frame(space, 2) == Area(x: 24, y: 0, w: 1152, h: 800))
      #expect(frame(space, 3).w == 1176)
    }

    @Test func focusingAColumnOutOfViewScrollsToIt() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      _ = Headless.drain()

      space.view.focusWindow(wid(1))

      #expect(space.view.scroll.offset == 0)
      #expect(
        drainPlacements().map(\.description) == [
          "w1: 0,0 588x800", "w2: 588,0 588x800", "w3: 1176,0 588x800",
        ])
    }

    @Test func focusingAColumnInViewDoesNotScroll() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      _ = Headless.drain()

      space.view.focusWindow(wid(2))

      #expect(space.view.scroll.offset == 564)
      #expect(drainPlacements().isEmpty)
    }

    @Test func centerAlwaysCentersTheFocusedColumn() {
      Config.current.space.scrollCenter = .always
      Config.current.space.scrollColumnWidth = 0.4
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)

      // Columns of 470 at 0, 470 and 940: the third centered in 1200.
      #expect(space.view.scroll.offset == 575)
      #expect(frame(space, 3) == Area(x: 365, y: 0, w: 470, h: 800))
    }

    @Test func closingAColumnScrollsBackWithinTheStrip() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.close(3)

      #expect(space.view.scroll.offset == -12)
      #expect(frame(space, 1) == Area(x: 12, y: 0, w: 588, h: 800))
      #expect(frame(space, 2) == Area(x: 600, y: 0, w: 588, h: 800))
    }

    @Test func aColumnKeepsItsOwnWidth() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(1).columnWidth = 0.25
      space.view.updateTree()

      // 294 and 588 wide, so the strip fits and is centered.
      #expect(frame(space, 1) == Area(x: 159, y: 0, w: 294, h: 800))
      #expect(frame(space, 2) == Area(x: 453, y: 0, w: 588, h: 800))
    }

    @Test func balanceGivesEveryColumnTheDefaultWidth() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(1).columnWidth = 0.25

      space.view.resetColumnWidths()

      #expect(space.node(1).columnWidth == 0)
    }

    @Test func theColumnWidthIsKeptInSnapshots() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).columnWidth = 0.75

      let rebuilt = Con(snapshot: space.view.root.snapshot)

      #expect(rebuilt.children.map(\.columnWidth) == [0, 0.75])
    }

    // MARK: - The strip

    @Test func aReorientedRootBecomesOneColumn() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.root.layout = .splitV

      space.view.updateTree()

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          splitv 1.0000 focus=1,0
            w1 0.5000
            w2 0.5000
        """
      }
      #expect(frame(space, 1) == Area(x: 0, y: 0, w: 1200, h: 400))
    }

    @Test func aWindowInAColumnSplitsItsColumn() {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, insertionPoint: 2, focus: true, insertByRule: .south)

      #expect(frame(space, 2) == Area(x: 600, y: 0, w: 588, h: 400))
      #expect(frame(space, 3) == Area(x: 600, y: 400, w: 588, h: 400))
    }

    @Test func atAWallAColumnOutOfViewStaysOnTheDisplay() {
      let space = Workspace(layout: .scroll)
      space.view.scroll.walls = [.left]
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)

      #expect(frame(space, 1) == Area(x: 0, y: 0, w: 588, h: 800))
      #expect(space.node(1).isScrolledOut)
    }

    // MARK: - Commands

    /// A scroll view with columns w1, w2 and w3, the last focused.
    private func threeColumns() -> Workspace {
      let space = Workspace(layout: .scroll)
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      return space
    }

    private func window(_ n: UInt32) -> Window { WindowManager.shared.window[wid(n)]! }

    @Test func warpSwapsAColumnWithItsNeighbour() throws {
      let space = threeColumns()
      try WindowManager.shared.treeMove(direction: .west, for: window(3))

      #expect(space.view.root.children.map { $0.windowID } == [wid(1), wid(3), wid(2)])
    }

    @Test func warpTakesAWindowOutOfItsColumn() throws {
      let space = threeColumns()
      space.focus(2)
      space.open(4, insertionPoint: 2, focus: true, insertByRule: .south)
      try WindowManager.shared.treeMove(direction: .east, for: window(4))

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=2,1,3,0
          w1 0.2500
          splitv 0.2500
            w2 1.0000
          w4 0.2500
          w3 0.2500
        """
      }
    }

    @Test func aWindowLeftAloneInItsColumnMovesAndSizesTheWholeColumn() throws {
      let space = threeColumns()
      space.focus(2)
      space.open(4, insertionPoint: 2, focus: true, insertByRule: .south)
      try WindowManager.shared.treeMove(direction: .east, for: window(4))
      // w2 is now alone in its column container.
      try WindowManager.shared.treeMove(direction: .west, for: window(2))
      try WindowManager.shared.adjustWindowRatio(for: window(2), type: .abs, ratio: 0.3)

      let root = space.view.root
      #expect(root.children.map(\.windowIDs) == [[wid(2)], [wid(1)], [wid(4)], [wid(3)]])
      #expect(root.children[0].columnWidth == 0.3)
    }

    @Test func warpAcrossTheStripStaysInTheColumn() throws {
      let space = threeColumns()
      #expect(throws: WindowOperationError.self) {
        try WindowManager.shared.treeMove(direction: .north, for: window(3))
      }
      #expect(space.view.root.layout == .splitH)
      #expect(space.view.root.children.count == 3)
    }

    @Test func warpWithinAColumnMovesTheWindowInIt() throws {
      let space = threeColumns()
      space.open(4, insertionPoint: 3, focus: true, insertByRule: .south)
      try WindowManager.shared.treeMove(direction: .north, for: window(4))

      #expect(space.view.root.children[2].children.map { $0.windowID } == [wid(4), wid(3)])
    }

    @Test(arguments: [(ValueType.abs, Float(0.75), Float(0.75)), (.rel, 0.1, 0.6), (.abs, 3, 1)])
    func ratioSetsTheWidthOfTheColumn(type: ValueType, ratio: Float, width: Float) throws {
      let space = threeColumns()
      try WindowManager.shared.adjustWindowRatio(for: window(2), type: type, ratio: ratio)

      #expect(space.node(2).columnWidth == width)
    }

    @Test func theRightEdgeOfResizeWidensTheColumn() throws {
      let space = threeColumns()
      try WindowManager.shared.resizeWindow(window(3), direction: .right, dx: 120, dy: 0)

      // The edge moves by as much as asked.
      #expect(frame(space, 3).w == 708)
    }

    @Test func layoutOfAWindowAloneInItsColumnChangesThatColumn() throws {
      let space = threeColumns()
      try WindowManager.shared.setWindowLayout(window(2), .tabbed)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=2,1,0
          w1 0.3333
          tabbed(splitv) 0.3333
            w2 1.0000
          w3 0.3333
        """
      }
    }

    @Test func centerCentersTheColumn() throws {
      Config.current.space.scrollColumnWidth = 0.4
      let space = threeColumns()
      space.open(4, focus: true)
      space.view.focusWindow(wid(3))

      try WindowManager.shared.centerColumn(of: window(3))

      // Columns of 470 at 0, 470, 940 and 1410: the third centered in 1200.
      #expect(frame(space, 3) == Area(x: 365, y: 0, w: 470, h: 800))
    }

    // MARK: - Leaving the strip

    @Test func aWindowParkedAtAWallIsNotInView() {
      let space = Workspace(layout: .scroll)
      space.view.scroll.walls = [.left]
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)

      #expect(!space.view.isWhollyInView(wid(1)))
      #expect(space.view.isWhollyInView(wid(3)))
    }

    @Test func leavingTheScrollLayoutPutsParkedWindowsBackOnTheDisplay() {
      _ = threeColumns()
      _ = Headless.drain()

      SpaceManager.shared.setLayout(.float, for: Workspace.sid)

      #expect(drainPlacements().map(\.description) == ["w1: 0,0 588x800"])
    }

    @Test func aParkedWindowThatLeavesTheStripIsPutBackOnTheDisplay() {
      let space = threeColumns()
      _ = Headless.drain()

      WindowManager.shared.unmanage(window(1), from: space.view, options: [])

      #expect(drainPlacements().first?.description == "w1: 0,0 588x800")
    }

    @Test(arguments: [true, false])
    func flattenKeepsTheColumnsOfAStrip(isStrip: Bool) {
      // A column holding only a side-by-side group, as after the window below that group left the column.
      let root = Con(layout: .splitH)
      root.isStrip = isStrip
      let column = treeTestSplit(root, .splitV)
      let group = treeTestSplit(column, .splitH)
      treeTestLeaf(group, wid(1))
      treeTestLeaf(group, wid(2))
      treeTestLeaf(root, wid(3))

      root.flatten()

      // A tree spreads the group over the root; a strip keeps it in its column.
      #expect(root.children.count == (isStrip ? 2 : 3))
    }

    // MARK: - Animation

    /// A scroll view whose windows the fake window server has at x = 24, with slides recorded instead of sent.
    private func animatedSpace(duration: Int = 1) -> (Workspace, () -> [String]) {
      Config.current.space.scrollAnimationDuration = duration
      let space = threeColumns()
      var moves: [String] = []
      let animator = ScrollAnimator.shared
      animator.animatesInHeadlessMode = true
      animator.currentBounds = { _ in CGRect(x: 24, y: 0, width: 588, height: 800) }
      animator.slide = { id, x, _ in
        moves.append("w\(id.rawValue - treeTestWindowBase): \(x)")
        return true
      }
      return (space, { moves })
    }

    private func placements(_ space: Workspace) -> [WindowPlacement] {
      (1...3).map { n in
        let frame = frame(space, UInt32(n))
        return WindowPlacement(window: window(UInt32(n)), x: frame.x, y: frame.y, w: frame.w, h: frame.h)
      }
    }

    @Test func windowsThatOnlyMoveSlideAndTheRestArePlacedAtOnce() {
      let (space, _) = animatedSpace(duration: 200)
      let immediate = ScrollAnimator.shared.animate(space.view, placements(space))

      // w2 already sits at 24; w1 (parked) and w3 move without being resized.
      #expect(immediate.map(\.window.id) == [wid(2)])
      #expect(ScrollAnimator.shared.isSliding(wid(1)))
      #expect(ScrollAnimator.shared.isSliding(wid(3)))
    }

    @Test func theLastFrameEndsTheSlideAndPlacesTheWindowsAtOnce() async throws {
      let (space, moves) = animatedSpace()
      _ = ScrollAnimator.shared.animate(space.view, placements(space))
      try await Task.sleep(for: .milliseconds(5))

      ScrollAnimator.shared.tick()

      #expect(!ScrollAnimator.shared.isAnimating(Workspace.sid))
      #expect(moves().sorted() == ["w1: -564", "w3: 612"])
    }

    @Test func withoutAnAnswerFromTheScriptingAdditionWindowsArePlacedAtOnce() {
      let (space, _) = animatedSpace(duration: 200)
      ScrollAnimator.shared.slide = { _, _, _ in false }
      _ = ScrollAnimator.shared.animate(space.view, placements(space))

      ScrollAnimator.shared.tick()

      #expect(!ScrollAnimator.shared.isAnimating(Workspace.sid))
      #expect(ScrollAnimator.shared.animate(space.view, placements(space)).count == 3)
    }

    @Test func aWindowThatLeavesTheStripStopsSliding() {
      let (space, moves) = animatedSpace(duration: 200)
      _ = ScrollAnimator.shared.animate(space.view, placements(space))
      WindowManager.shared.managedWindows[wid(1)] = nil

      ScrollAnimator.shared.tick()

      #expect(moves().allSatisfy { $0.hasPrefix("w3") })
      #expect(!ScrollAnimator.shared.isSliding(wid(1)))
    }
  }
}
