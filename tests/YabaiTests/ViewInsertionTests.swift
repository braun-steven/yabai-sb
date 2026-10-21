import Testing
import Foundation
import InlineSnapshotTesting
import YabaiCore
@testable import Yabai
import YabaiTestSupport

//
// NOTE: Opening and closing windows in a view: View.add and View.remove on a view seeded into the space manager, with
// its windows registered in the window manager like managed windows (without addManagedWindow, which reaches the
// window server and the scripting addition). The view keeps the area set here: View.update asks SkyLight for the
// display, so these views have no auto padding, which would re-layout through it. The trees print with treeDump.
//

private func wid(_ n: UInt32) -> WindowID { WindowID(rawValue: treeTestWindowBase + n) }

/// A tree view of a fake space with fake windows w<n>.
@WM private final class Workspace
{
    static let sid: SpaceID = 0xFFFF_0100

    let view = View(sid: Workspace.sid)
    let application = Application()

    init(area: Area = Area(x: 0, y: 0, w: 1200, h: 800))
    {
        view.layout = .tree
        view.area = area
        SpaceManager.shared.views[Workspace.sid] = view
    }

    var dump: String { treeDump(view.root) }

    func node(_ n: UInt32) -> Con { view.findWindow(wid(n))! }

    /// Opens window n; it gets focus when focus is true, as when the application focuses its new window.
    @discardableResult
    func open(_ n: UInt32, insertionPoint: UInt32? = nil, focus: Bool = false) -> Window
    {
        let target = Window(id: wid(n))
        target.application = application
        WindowManager.shared.window[target.id] = target
        WindowManager.shared.managedWindows[target.id] = view
        if focus { WindowManager.shared.focusedWindowID = target.id }

        view.add(target, insertionPoint: insertionPoint.map(wid))
        return target
    }

    func focus(_ n: UInt32)
    {
        WindowManager.shared.focusedWindowID = wid(n)
        view.tree?.select(nil)
        node(n).focus()
    }

    @discardableResult
    func close(_ n: UInt32) -> Bool
    {
        let target = WindowManager.shared.window[wid(n)]!
        let result = view.remove(target)
        WindowManager.shared.managedWindows[target.id] = nil
        WindowManager.shared.window[target.id] = nil
        return result
    }
}

extension DaemonState
{
    @Suite
    @WM struct ViewInsertionTests
    {
        // MARK: - View.add

        @Test func firstWindowFillsTheView()
        {
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

        @Test func windowOpensAfterTheFocusedWindow()
        {
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

        @Test func unfocusedWindowStaysBehindTheFocusedWindow()
        {
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

        @Test func windowAlreadyInTheTreeIsNotAddedAgain()
        {
            let space = Workspace()
            let target = space.open(1, focus: true)
            space.open(2, focus: true)
            space.view.isDirty = false

            space.view.add(target, insertionPoint: nil)

            #expect(space.view.windowIDs == [wid(1), wid(2)])
            #expect(!space.view.isDirty)
        }

        @Test func withoutAFocusedWindowItOpensAfterTheLastFocusedOne()
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.open(3, focus: true)
            space.focus(1)
            WindowManager.shared.focusedWindowID = nil

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

        @Test func focusedWindowOfAnotherSpaceIsNoAnchor()
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.focus(1)
            WindowManager.shared.focusedWindowID = wid(99)

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

        @Test func windowOpensAfterTheSelectedContainer()
        {
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

        @Test func selectedWindowIsNoContainerAnchor()
        {
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

        @Test func passedInsertionPointIsTheAnchor()
        {
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

        @Test func passedInsertionPointOutsideTheTreeFallsBackToTheFocus()
        {
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
        func insertionPointPlacesTheWindowOnItsSide(_ direction: InsertDirection)
        {
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

        @Test func stackInsertionPointOpensANewTab()
        {
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

        @Test func stackInsertionPointInATabbedContainerAddsATab()
        {
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

        @Test func insertionPointWithoutADirectionIsIgnored()
        {
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

        @Test func windowOpensAsATabOfTheFocusedTab()
        {
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

        @Test func autotilingSplitsTheFocusedWindowAlongItsLongerSide()
        {
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

        @Test func autotilingLeavesTabsAlone()
        {
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

        @Test(arguments: [
            (TreeOrientation.auto, Area(x: 0, y: 0, w: 1200, h: 800), ConLayout.splitH),
            (.auto, Area(x: 0, y: 0, w: 800, h: 1200), .splitV),
            (.auto, Area(x: 0, y: 0, w: 800, h: 800), .splitH),
            (.horizontal, Area(x: 0, y: 0, w: 800, h: 1200), .splitH),
            (.vertical, Area(x: 0, y: 0, w: 1200, h: 800), .splitV),
        ])
        func defaultOrientation(_ orientation: TreeOrientation, area: Area, expected: ConLayout)
        {
            Config.current.space.treeDefaultOrientation = orientation
            let space = Workspace(area: area)
            space.open(1, focus: true)
            space.open(2, focus: true)

            #expect(space.view.root.layout == expected)
            #expect(space.view.root.lastSplit == expected)
        }

        @Test func workspaceTabbedWrapsEveryTopLevelWindow()
        {
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
        func containerFromAnotherDisplayArrivesOnItsSide(_ direction: Direction)
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            let arriving = Con(layout: .splitV)
            treeTestLeaf(arriving, wid(3))
            treeTestLeaf(arriving, wid(4))

            space.view.attach(arriving, from: direction)

            #expect(space.view.windowIDs == (direction == .west ? [wid(1), wid(2), wid(3), wid(4)] : [wid(3), wid(4), wid(1), wid(2)]))
            #expect(space.view.root.focusOrder.first == arriving)
        }

        @Test func containerArrivingInAnEmptyViewGetsTheDefaultOrientation()
        {
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

        @Test func containerTitleNamesTheApplicationsInside()
        {
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
            WindowManager.shared.window[wid(1)]!.title = "Start Page" as CFString
            #expect(space.node(1).title as String? == "Start Page")
            #expect(space.node(2).title as String? == "iTerm2")
        }

        // MARK: - View.remove

        @Test func removingAWindowNotInTheTreeDoesNothing()
        {
            let space = Workspace()
            space.open(1, focus: true)
            let other = Window(id: wid(2))
            space.view.isDirty = false

            #expect(!space.view.remove(other))
            #expect(!space.view.isDirty)

            // a view without a tree
            #expect(!View(sid: 0xFFFF_0101).remove(other))
        }

        @Test func removingAWindowGivesItsShareToItsSiblings()
        {
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

        @Test func removingFlattensPointlessNesting()
        {
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

        @Test func removingTheLastTabClosesItsContainer()
        {
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

        @Test func removingClearsTheInsertionPointOfTheWindow()
        {
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

        @Test func focusCandidateIsTheMostRecentlyFocusedSibling()
        {
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

        @Test func destroyingTheViewUnmanagesItsWindows()
        {
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

        @Test func removingTheLastWindowResetsTheRoot()
        {
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
