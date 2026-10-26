import Foundation
import InlineSnapshotTesting
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: Opening and closing windows in a view: View.add and View.remove on a Workspace view (TreeFixtures.swift). The
// view keeps the area set here, as auto padding stays off: it would lay the view out again in the headless display
// frame. The trees print with treeDump.
//

extension DaemonState {
  @Suite
  @WM struct ViewInsertionTests {
    // MARK: - View.add

    @Test func firstWindowFillsTheView() {
      let space = Workspace()
      space.open(1, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          w1 1.0000
        """
      }
      #expect(space.node(1).area == Area(x: 0, y: 0, w: 1200, h: 800))
      #expect(space.view.isDirty)
    }

    @Test func windowOpensAfterTheFocusedWindow() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.focus(1)
      space.open(4, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0,3,2
          w1 0.2500
          w4 0.2500
          w2 0.2500
          w3 0.2500
        """
      }
    }

    @Test func unfocusedWindowStaysBehindTheFocusedWindow() {
      // NOTE: a window moved here or made tiled does not take the focus of its containers
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          w1 0.5000
          w2 0.5000
        """
      }
      #expect(space.view.root.focusedDescendant == space.node(1))
    }

    @Test func windowAlreadyInTheTreeIsNotAddedAgain() {
      let space = Workspace()
      let target = space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.isDirty = false

      space.view.add(target, insertionPoint: nil)

      #expect(space.view.windowIDs == [wid(1), wid(2)])
      #expect(!space.view.isDirty)
    }

    @Test func withoutAFocusedWindowItOpensAfterTheLastFocusedOne() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.focus(1)
      WindowManager.shared.focus.focusChanged(to: nil)

      space.open(4)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0,3,2
          w1 0.2500
          w4 0.2500
          w2 0.2500
          w3 0.2500
        """
      }
    }

    @Test func focusedWindowOfAnotherSpaceIsNoAnchor() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.focus(1)
      WindowManager.shared.focus.focusChanged(to: wid(99))

      space.open(3)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0,2
          w1 0.3333
          w3 0.3333
          w2 0.3333
        """
      }
    }

    @Test func windowOpensAfterTheSelectedContainer() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).split(.vertical)
      space.open(3, focus: true)
      space.view.root.select(space.node(3).parent)

      space.open(4, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=2,1,0
          w1 0.3333
          splitv 0.3333 focus=1,0 *
            w2 0.5000
            w3 0.5000
          w4 0.3333
        """
      }
    }

    @Test func selectedWindowIsNoContainerAnchor() {
      // NOTE: only a selected container (focus parent) is an anchor; a selected leaf falls back to the focus
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.node(1).isSelected = true

      space.open(4, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=3,2,1,0
          w1 0.2500 *
          w2 0.2500
          w3 0.2500
          w4 0.2500
        """
      }
    }

    @Test func passedInsertionPointIsTheAnchor() {
      // NOTE: a restored or moved window opens next to the window passed in, not next to the focused one
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)

      space.open(4, insertionPoint: 1)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=3,1,2,0
          w1 0.2500
          w4 0.2500
          w2 0.2500
          w3 0.2500
        """
      }
    }

    @Test func passedInsertionPointOutsideTheTreeFallsBackToTheFocus() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.focus(1)

      space.open(3, insertionPoint: 99, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0,2
          w1 0.3333
          w3 0.3333
          w2 0.3333
        """
      }
    }

    @Test(arguments: [InsertDirection.north, .east, .south, .west])
    func insertionPointPlacesTheWindowOnItsSide(_ direction: InsertDirection) {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.insertionPoint = wid(1)
      space.node(1).insertDirection = direction

      space.open(3, focus: true)

      #expect(space.view.insertionPoint == nil)
      #expect(space.node(1).insertDirection == nil)
      let expected: [InsertDirection: String] = [
        .north: """
        splith
          splitv 0.5000
            w3 0.5000
            w1 0.5000
          w2 0.5000
        """,
        .east: """
        splith focus=1,2,0
          w1 0.3333
          w3 0.3333
          w2 0.3333
        """,
        .south: """
        splith
          splitv 0.5000 focus=1,0
            w1 0.5000
            w3 0.5000
          w2 0.5000
        """,
        .west: """
        splith focus=0,2,1
          w3 0.3333
          w1 0.3333
          w2 0.3333
        """,
      ]
      #expect(space.dump == expected[direction])
    }

    @Test func stackInsertionPointOpensANewTab() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.insertionPoint = wid(2)
      space.node(2).insertDirection = .stack

      space.open(3, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0
          w1 0.5000
          tabbed(splith) 0.5000 focus=1,0
            w2 0.5000
            w3 0.5000
        """
      }
    }

    @Test func stackInsertionPointInATabbedContainerAddsATab() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).setLayout(.tabbed)
      space.open(3, focus: true)
      space.view.insertionPoint = wid(2)
      space.node(2).insertDirection = .stack

      space.open(4, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          tabbed(splith) 1.0000 focus=2,3,1,0
            w1 0.2500
            w2 0.2500
            w4 0.2500
            w3 0.2500
        """
      }
    }

    @Test func insertionPointWithoutADirectionIsIgnored() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.focus(1)
      space.view.insertionPoint = wid(2)

      space.open(3, focus: true)

      #expect(space.view.insertionPoint == wid(2))
      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0,2
          w1 0.3333
          w3 0.3333
          w2 0.3333
        """
      }
    }

    @Test func windowOpensAsATabOfTheFocusedTab() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.node(2).setLayout(.tabbed)
      space.focus(2)

      space.open(4, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          tabbed(splith) 1.0000 focus=2,1,3,0
            w1 0.2500
            w2 0.2500
            w4 0.2500
            w3 0.2500
        """
      }
    }

    @Test func autotilingSplitsTheFocusedWindowAlongItsLongerSide() {
      Config.current.space.treeAutotiling = true
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      // w2 is 600 wide and 800 high: it splits vertically, then w3 (600x400) horizontally
      space.open(3, focus: true)
      space.open(4, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0
          w1 0.5000
          splitv 0.5000 focus=1,0
            w2 0.5000
            splith 0.5000 focus=1,0
              w3 0.5000
              w4 0.5000
        """
      }
      #expect(space.node(4).area == Area(x: 900, y: 400, w: 300, h: 400))
    }

    @Test func autotilingLeavesTabsAlone() {
      Config.current.space.treeAutotiling = true
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).setLayout(.tabbed)

      space.open(3, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          tabbed(splith) 1.0000 focus=2,1,0
            w1 0.3333
            w2 0.3333
            w3 0.3333
        """
      }
    }

    // MARK: - A window moved here (window --display, window --space)

    @Test func movedWindowIsTheSiblingAfterTheFocusedWindowWithoutAutotiling() {
      // NOTE: sway cmd_move_container: V[T B] with T focused last takes R as V[T R B]; autotiling would nest H[T R]
      Config.current.space.treeAutotiling = true
      let space = Workspace(area: Area(x: 0, y: 0, w: 800, h: 1200))
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.focus(1)
      WindowManager.shared.focus.focusChanged(to: wid(99))

      space.open(3, besideFocus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splitv focus=1,0,2
          w1 0.3333
          w3 0.3333
          w2 0.3333
        """
      }
    }

    @Test func movedWindowBecomesTheTabAfterTheFocusedTab() {
      Config.current.space.treeAutotiling = true
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.node(2).setLayout(.tabbed)
      space.focus(2)
      WindowManager.shared.focus.focusChanged(to: wid(99))

      space.open(4, besideFocus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0
          w1 0.5000
          tabbed(splitv) 0.5000 focus=1,0,2
            w2 0.3333
            w4 0.3333
            w3 0.3333
        """
      }
    }

    @Test func movedWindowIgnoresTheSelectedContainer() {
      let space = Workspace()
      // NOTE: a new window opens after the selected container (focus parent), a moved window after the focused window
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).split(.vertical)
      space.open(3, focus: true)
      space.focus(2)
      space.view.root.select(space.node(2).parent)
      WindowManager.shared.focus.focusChanged(to: wid(99))

      space.open(4, besideFocus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0
          w1 0.5000
          splitv 0.5000 focus=1,0,2 *
            w2 0.3333
            w4 0.3333
            w3 0.3333
        """
      }
    }

    @Test func movedWindowFillsAnEmptyView() {
      Config.current.space.treeAutotiling = true
      let space = Workspace()

      space.open(1, besideFocus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          w1 1.0000
        """
      }
    }

    @Test(arguments: [
      (TreeOrientation.auto, Area(x: 0, y: 0, w: 1200, h: 800), ConLayout.splitH),
      (.auto, Area(x: 0, y: 0, w: 800, h: 1200), .splitV),
      (.auto, Area(x: 0, y: 0, w: 800, h: 800), .splitH),
      (.horizontal, Area(x: 0, y: 0, w: 800, h: 1200), .splitH),
      (.vertical, Area(x: 0, y: 0, w: 1200, h: 800), .splitV),
    ])
    func defaultOrientation(_ orientation: TreeOrientation, area: Area, expected: ConLayout) {
      Config.current.space.treeDefaultOrientation = orientation
      let space = Workspace(area: area)
      space.open(1, focus: true)
      space.open(2, focus: true)

      #expect(space.view.root.layout == expected)
      #expect(space.view.root.lastSplit == expected)
    }

    @Test func workspaceTabbedWrapsEveryTopLevelWindow() {
      Config.current.space.treeWorkspaceTabbed = true
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.focus(1)
      space.open(3, focus: true)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          tabbed(splith) 1.0000 focus=1,0,2
            w1 0.3333
            w3 0.3333
            w2 0.3333
        """
      }
    }

    @Test(arguments: [Direction.west, .east])
    func containerFromAnotherDisplayArrivesOnItsSide(_ direction: Direction) {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      let arriving = Con(layout: .splitV)
      treeTestLeaf(arriving, wid(3))
      treeTestLeaf(arriving, wid(4))

      space.view.attach(arriving, from: direction)

      #expect(
        space.view.windowIDs
          == (direction == .west
            ? [wid(1), wid(2), wid(3), wid(4)] : [wid(3), wid(4), wid(1), wid(2)]))
      #expect(space.view.root.focusOrder.first == arriving)
    }

    @Test func containerArrivingInAnEmptyViewGetsTheDefaultOrientation() {
      Config.current.space.treeDefaultOrientation = .vertical
      let space = Workspace()
      let arriving = Con(layout: .splitH)
      treeTestLeaf(arriving, wid(1))
      treeTestLeaf(arriving, wid(2))

      space.view.attach(arriving, from: .north)
      space.view.updateTree()

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splitv
          splith 1.0000
            w1 0.5000
            w2 0.5000
        """
      }
    }

    // MARK: - Tab titles

    @Test func containerTitleNamesTheApplicationsInside() {
      let space = Workspace()
      space.application.name = "Safari"
      let terminal = Application()
      terminal.name = "iTerm2"
      space.open(1, focus: true)
      space.open(2, focus: true).application = terminal
      space.node(2).split(.vertical)
      space.open(3, focus: true)
      space.view.insertionPoint = wid(3)
      space.node(3).insertDirection = .stack
      space.open(4, focus: true).application = terminal

      #expect(space.view.root.title as String? == "H[Safari V[iTerm2 T[Safari iTerm2]]]")

      // a window shows its own title, or the name of its application without one
      WindowManager.shared.window[wid(1)]!.ax.title = "Start Page"
      #expect(space.node(1).title as String? == "Start Page")
      #expect(space.node(2).title as String? == "iTerm2")
    }

    // MARK: - insert= of a rule

    // NOTE: the rule effect of a new window must place it as window --insert does: the same tree as the insertion
    // set by hand on the focused window, here the window 1 of the tree.
    @Test(arguments: [InsertDirection.north, .east, .south, .west, .stack])
    func ruleInsertionGivesTheTreeOfWindowInsert(_ direction: InsertDirection) {
      let manual = Workspace()
      manual.open(1, focus: true)
      manual.open(2, focus: true)
      manual.focus(1)
      manual.view.insertionPoint = wid(1)
      manual.node(1).insertDirection = direction
      manual.open(3, focus: true)
      let expected = manual.dump

      let rule = Workspace()
      rule.open(1, focus: true)
      rule.open(2, focus: true)
      rule.focus(1)
      rule.open(3, focus: true, insertByRule: direction)

      #expect(rule.dump == expected)
      #expect(rule.view.insertionPoint == nil)
      #expect(rule.node(1).insertDirection == nil)
    }

    @Test func ruleInsertionWinsOverAutotiling() {
      Config.current.space.treeAutotiling = true
      let space = Workspace()
      space.open(1, focus: true)
      // NOTE: autotiling alone would put w2 to the east, next to w1
      space.open(2, focus: true, insertByRule: .north)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splitv
          w2 0.5000
          w1 0.5000
        """
      }
    }

    @Test func ruleInsertionFollowsTheFocusOfTheTreeNotTheSystem() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      // NOTE: the system focus is a window that is not in this tree; the tree still focuses w2
      WindowManager.shared.focus.focusChanged(to: wid(9))

      space.open(3, insertByRule: .stack)

      #expect(space.node(2).parent?.layout == .tabbed)
      #expect(space.node(3).parent === space.node(2).parent)
    }

    @Test func ruleInsertionIntoAnEmptyViewIsIgnored() {
      let space = Workspace()
      let target = space.open(1, focus: true, insertByRule: .stack)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          w1 1.0000
        """
      }
      #expect(space.view.insertionPoint == nil)
      #expect(target.insertionByRule == nil)
    }

    // NOTE: the insertion is taken by the first add of the window and leaves nothing pending for the next window.
    @Test func ruleInsertionAppliesOnceAndLeavesNothingPending() {
      let space = Workspace()
      space.open(1, focus: true)
      let target = space.open(2, focus: true, insertByRule: .north)
      #expect(target.insertionByRule == nil)
      #expect(space.view.insertionPoint == nil)
      #expect(space.node(1).insertDirection == nil)

      space.open(3, focus: true)

      #expect(space.view.insertionPoint == nil)
      #expect(!space.dump.contains("tabbed"))
    }

    // MARK: - View.remove

    @Test func removingAWindowNotInTheTreeDoesNothing() {
      let space = Workspace()
      space.open(1, focus: true)
      let other = Window(id: wid(2))
      space.view.isDirty = false

      #expect(!space.view.remove(other))
      #expect(!space.view.isDirty)

      // a view without a tree
      #expect(!View(sid: 0xFFFF_0101).remove(other))
    }

    @Test func removingAWindowGivesItsShareToItsSiblings() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.open(3, focus: true)
      space.view.isDirty = false

      #expect(space.close(2))

      #expect(space.view.isDirty)
      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0
          w1 0.5000
          w3 0.5000
        """
      }
      #expect(space.node(3).area == Area(x: 600, y: 0, w: 600, h: 800))
    }

    @Test func removingFlattensPointlessNesting() {
      // h[w1 v[w2 h[w3 w4]]]: closing w2 leaves v[h[w3 w4]] inside h, which flattens into h[w1 w3 w4]
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).split(.vertical)
      space.open(3, focus: true)
      space.node(3).split(.horizontal)
      space.open(4, focus: true)
      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=1,0
          w1 0.5000
          splitv 0.5000 focus=1,0
            w2 0.5000
            splith 0.5000 focus=1,0
              w3 0.5000
              w4 0.5000
        """
      }

      space.close(2)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith focus=2,1,0
          w1 0.5000
          w3 0.2500
          w4 0.2500
        """
      }
    }

    @Test func removingTheLastTabClosesItsContainer() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.insertionPoint = wid(2)
      space.node(2).insertDirection = .stack
      space.open(3, focus: true)

      space.close(2)
      space.close(3)

      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          w1 1.0000
        """
      }
      #expect(space.node(1).area == Area(x: 0, y: 0, w: 1200, h: 800))
    }

    @Test func removingClearsTheInsertionPointOfTheWindow() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.insertionPoint = wid(2)
      space.node(2).insertDirection = .south

      space.close(1)
      #expect(space.view.insertionPoint == wid(2))

      space.close(2)
      #expect(space.view.insertionPoint == nil)
    }

    @Test func focusCandidateIsTheMostRecentlyFocusedSibling() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).split(.vertical)
      space.open(3, focus: true)
      space.open(4, focus: true)
      space.focus(1)
      space.focus(3)
      let wm = WindowManager.shared

      // w3 is focused: w4 and w2 are behind it in its container, w4 more recently
      let target = wm.window[wid(3)]!
      #expect(wm.treeFocusCandidate(in: space.view, for: target) == wid(4))
      space.close(3)
      #expect(space.view.root.focusedDescendant == space.node(4))

      // the last window of a container: the most recently focused window of the closest ancestor
      space.close(4)
      space.focus(2)
      #expect(wm.treeFocusCandidate(in: space.view, for: wm.window[wid(2)]!) == wid(1))

      // a window that was not focused gives no candidate
      #expect(wm.treeFocusCandidate(in: space.view, for: wm.window[wid(1)]!) == nil)
    }

    @Test func destroyingTheViewUnmanagesItsWindows() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.node(2).split(.vertical)
      space.open(3, focus: true)
      space.view.uuid = "fake" as CFString

      space.view.destroy()

      #expect(space.view.tree == nil)
      #expect(space.view.uuid == nil)
      #expect(WindowManager.shared.managedWindows.isEmpty)
      // the windows stay known to the window manager
      #expect(WindowManager.shared.window[wid(3)] != nil)
    }

    @Test func removingTheLastWindowResetsTheRoot() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.root.setLayout(.splitV)
      #expect(space.view.root.layout == .splitV)

      space.close(1)
      space.close(2)

      #expect(space.view.root.children.isEmpty)
      #expect(space.view.windowIDs.isEmpty)
      #expect(space.view.tiledCount == 0)

      // the next window gets the default orientation again
      space.open(3, focus: true)
      assertInlineSnapshot(of: space.dump, as: .lines) {
        """
        splith
          w3 1.0000
        """
      }
      #expect(space.view.root.lastSplit == .splitH)
      #expect(space.node(3).area == Area(x: 0, y: 0, w: 1200, h: 800))
    }
  }
}
