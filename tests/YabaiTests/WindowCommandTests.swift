import CoreGraphics
import SortedCollections
import Testing
import Foundation
import CustomDump
import InlineSnapshotTesting
import YabaiCore
@testable import Yabai
import YabaiTestSupport

//
// NOTE: Window commands end to end: a message runs through handleMessage (Golden.run) against a Workspace view
// (TreeFixtures.swift) whose acting window is set with setPendingFocus, and the tests check the response, the tree and
// the headless placements. Only commands whose paths stay off the window server up to the flush are run here. Left
// out: --focus of a window, --space, --display, --stack of two windows, --insert, --toggle split, the mouse selector,
// and --move, --grid and relative --resize of unmanaged windows, which ask SkyLight for the window's space, focus a
// window, move it to a space or reach AX.
//

extension Workspace
{
    /// Makes window n the focused window and the acting window of the next command.
    func act(_ n: UInt32)
    {
        focus(n)
        WindowManager.shared.setPendingFocus(wid(n))
    }

    /// Lays the view out in the headless display frame and flushes it, so that a command records only its changes.
    func settle()
    {
        view.updateAndFlush()
        _ = Headless.drain()
    }

    /// The windows in tree order.
    var order: String
    {
        view.root.windowIDs.map { "w\($0.rawValue - treeTestWindowBase)" }.joined(separator: " ")
    }
}

/// The result of a window command: the response, the tree and the placements of its flush.
struct CommandResult
{
    var response: String
    var tree: String
    var placements: [PlacementLine]
}

/// A window command with the tokens w<n> replaced by the ids of the fake windows.
func windowCommand(_ arguments: String) -> String
{
    let tokens = arguments.split(separator: " ").map { token in
        if token.first == "w", let n = UInt32(token.dropFirst()) { return String(wid(n).rawValue) }
        return String(token)
    }
    return (["window"] + tokens).joined(separator: " ")
}

@WM func run(_ arguments: String, in space: Workspace) -> CommandResult
{
    let response = Golden.run(windowCommand(arguments))
    return CommandResult(response: String(decoding: response, as: UTF8.self), tree: space.dump, placements: drainPlacements())
}

/// A row of a parameterized command test: the command (w<n> are window ids), its failure and the resulting tree.
struct CommandCase: CustomTestStringConvertible, Sendable
{
    var command: String
    /// The message of a failure; nil when the command succeeds with an empty response.
    var failure: String? = nil
    var result: String

    var response: String { failure.map { String(UnicodeScalar(Response.failureByte)) + $0 } ?? "" }

    var testDescription: String { command }
}

extension DaemonState
{
    @Suite
    @WM struct WindowCommandTests
    {
        /// w1 | w2 | w3 in the headless display frame, w2 acting.
        private func row() -> Workspace
        {
            let space = Workspace()
            for n: UInt32 in 1...3 { space.open(n, focus: true) }
            space.act(2)
            space.settle()
            return space
        }

        /// w1 | T[w2 w3 w4] | w5 in the headless display frame, w3 acting.
        private func stack() -> Workspace
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.open(5, focus: true)
            space.focus(2)
            space.view.insertionPoint = wid(2)
            space.node(2).insertDirection = .stack
            space.open(3, focus: true)
            space.view.insertionPoint = wid(3)
            space.node(3).insertDirection = .stack
            space.open(4, focus: true)
            space.act(3)
            space.settle()
            return space
        }

        // MARK: - Fixtures

        @Test func fixtures()
        {
            assertInlineSnapshot(of: row().dump, as: .lines) {
                """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """
            }
            assertInlineSnapshot(of: stack().dump, as: .lines) {
                """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """
            }
        }

        // MARK: - Commands on w1 | w2 | w3

        nonisolated static let rowCases: [CommandCase] = [
            CommandCase(command: "--ratio rel:0.1", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.4333
                  w3 0.2333
                """),
            CommandCase(command: "--ratio rel:-0.1", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.2333
                  w3 0.4333
                """),
            CommandCase(command: "--ratio abs:0.5", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.5000
                  w3 0.1667
                """),
            CommandCase(command: "--ratio abs:0.99", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.6167
                  w3 0.0500
                """),
            CommandCase(command: "--ratio abs:0.01", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.0500
                  w3 0.6167
                """),
            CommandCase(command: "--ratio foo:0.5", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.5000
                  w3 0.1667
                """),
            CommandCase(command: "w3 --ratio abs:0.5", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.1667
                  w3 0.5000
                """),
            CommandCase(command: "--ratio 0.5", failure: "unknown value '0.5' given to command '--ratio' for domain 'window'\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--resize right:100:0", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.4028
                  w3 0.2639
                """),
            CommandCase(command: "--resize left:-100:0", result: """
                splith focus=1,2,0
                  w1 0.2639
                  w2 0.4028
                  w3 0.3333
                """),
            CommandCase(command: "--resize bottom_right:100:100", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.4028
                  w3 0.2639
                """),
            CommandCase(command: "--resize top:0:50", failure: "cannot resize the container in that direction.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--resize abs:100:100", failure: "cannot use absolute resizing on a managed window.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--split vertical", result: """
                splith focus=1,2,0
                  w1 0.3333
                  splitv 0.3333
                    w2 1.0000
                  w3 0.3333
                """),
            CommandCase(command: "--split toggle", result: """
                splith focus=1,2,0
                  w1 0.3333
                  splitv 0.3333
                    w2 1.0000
                  w3 0.3333
                """),
            CommandCase(command: "--split diagonal", failure: "unknown value 'diagonal' given to command '--split' for domain 'window'\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--layout tabbed", result: """
                splith
                  tabbed(splith) 1.0000 focus=1,2,0
                    w1 0.3333
                    w2 0.3333
                    w3 0.3333
                """),
            CommandCase(command: "--layout splitv", result: """
                splitv focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--layout toggle", result: """
                splith
                  tabbed(splith) 1.0000 focus=1,2,0
                    w1 0.3333
                    w2 0.3333
                    w3 0.3333
                """),
            CommandCase(command: "--layout toggle-split", result: """
                splitv focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--layout split", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--layout grid", failure: "unknown value 'grid' given to command '--layout' for domain 'window'\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--swap east", result: """
                splith focus=2,1,0
                  w1 0.3333
                  w3 0.3333
                  w2 0.3333
                """),
            CommandCase(command: "--swap w1", result: """
                splith
                  w2 0.3333
                  w1 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--swap w2", failure: "cannot swap a window with itself.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--swap north", failure: "could not locate a northward managed window.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--warp east", result: """
                splith focus=2,1,0
                  w1 0.3333
                  w3 0.3333
                  w2 0.3333
                """),
            CommandCase(command: "--warp west", result: """
                splith focus=0,2,1
                  w2 0.3333
                  w1 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--warp south", result: """
                splitv focus=1,0
                  splith 0.5000 focus=1,0
                    w1 0.5000
                    w3 0.5000
                  w2 0.5000
                """),
            CommandCase(command: "--warp w3", result: """
                splith focus=2,1,0
                  w1 0.3333
                  w3 0.3333
                  w2 0.3333
                """),
            CommandCase(command: "--warp w1", result: """
                splith focus=1,0,2
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--warp w2", failure: "cannot warp a window onto itself.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--focus parent --layout splitv", result: """
                splitv focus=1,2,0 *
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--focus parent --ratio abs:0.5", failure: "cannot adjust ratio of a root node.\n", result: """
                splith focus=1,2,0 *
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "--swap east --swap west", result: """
                splith focus=1,2,0
                  w1 0.3333
                  w2 0.3333
                  w3 0.3333
                """),
            CommandCase(command: "w1 --swap east --ratio abs:0.5", result: """
                splith
                  w2 0.3333
                  w1 0.5000
                  w3 0.1667
                """),
        ]

        @Test(arguments: rowCases) func commandOnARow(_ test: CommandCase)
        {
            let space = row()
            let result = run(test.command, in: space)

            #expect(result.response == test.response)
            expectNoDifference(result.tree, test.result)
            expectPlaced(space)
        }

        /// Every window of the view is at the frame of its container: the command flushed what it changed.
        private func expectPlaced(_ space: Workspace, sourceLocation: SourceLocation = #_sourceLocation)
        {
            for windowID in space.view.root.windowIDs {
                let frame = WindowManager.shared.window[windowID]!.frame
                #expect(!space.view.needsFlush(windowID: windowID, frame: frame), sourceLocation: sourceLocation)
            }
        }

        // MARK: - Commands on w1 | T[w2 w3 w4] | w5

        nonisolated static let stackCases: [CommandCase] = [
            CommandCase(command: "--ratio abs:0.5", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.5000 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.1667
                """),
            CommandCase(command: "--resize right:100:0", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.4028 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.2639
                """),
            CommandCase(command: "--layout splitv", result: """
                splith focus=1,2,0
                  w1 0.3333
                  splitv 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--layout split", result: """
                splith focus=1,2,0
                  w1 0.3333
                  splith 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--layout toggle", result: """
                splith focus=1,2,0
                  w1 0.3333
                  splith 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--layout tabbed", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--split horizontal", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    splith 0.3333
                      w3 1.0000
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--warp west", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=0,2,1
                    w3 0.3333
                    w2 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--warp east", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=2,1,0
                    w2 0.3333
                    w4 0.3333
                    w3 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--warp north", result: """
                splitv
                  w3 0.5000
                  splith 0.5000 focus=1,2,0
                    w1 0.3333
                    tabbed(splith) 0.3333 focus=1,0
                      w2 0.5000
                      w4 0.5000
                    w5 0.3333
                """),
            CommandCase(command: "--warp w1", result: """
                splith focus=1,0,2,3
                  w1 0.2500
                  w3 0.2500
                  tabbed(splith) 0.2500 focus=1,0
                    w2 0.5000
                    w4 0.5000
                  w5 0.2500
                """),
            CommandCase(command: "--swap w1", result: """
                splith
                  w3 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    w1 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--focus parent --ratio abs:0.5", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.5000 focus=1,2,0 *
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.1667
                """),
            CommandCase(command: "--focus parent --layout splitv", result: """
                splitv focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0 *
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--focus parent --warp east", result: """
                splith focus=2,1,0
                  w1 0.3333
                  w5 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0 *
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                """),
            CommandCase(command: "--focus parent --swap w1", result: """
                splith
                  w3 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0 *
                    w2 0.3333
                    w1 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--focus parent --focus parent --focus child --ratio abs:0.5", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.5000 focus=1,2,0 *
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.1667
                """),
            CommandCase(command: "--focus child", failure: "could not locate a container to focus.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--stack w3", failure: "cannot stack a window onto itself.\n", result: """
                splith focus=1,2,0
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
            CommandCase(command: "--focus parent --focus parent --layout splitv", result: """
                splitv focus=1,2,0 *
                  w1 0.3333
                  tabbed(splith) 0.3333 focus=1,2,0
                    w2 0.3333
                    w3 0.3333
                    w4 0.3333
                  w5 0.3333
                """),
        ]

        @Test(arguments: stackCases) func commandOnAStack(_ test: CommandCase)
        {
            let space = stack()
            let result = run(test.command, in: space)

            #expect(result.response == test.response)
            expectNoDifference(result.tree, test.result)
            expectPlaced(space)
        }

        // MARK: - Selectors on w1 | T[w2 w3 w4] | w5

        nonisolated static let selectorCases: [CommandCase] = [
            CommandCase(command: "--swap west", result: "w1 w3 w2 w4 w5"),
            CommandCase(command: "--swap east", result: "w1 w2 w4 w3 w5"),
            CommandCase(command: "--swap north", failure: "could not locate a northward managed window.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap south", failure: "could not locate a southward managed window.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap prev", result: "w1 w3 w2 w4 w5"),
            CommandCase(command: "--swap next", result: "w1 w2 w4 w3 w5"),
            CommandCase(command: "--swap first", result: "w3 w2 w1 w4 w5"),
            CommandCase(command: "--swap last", result: "w1 w2 w5 w4 w3"),
            CommandCase(command: "--swap largest", result: "w3 w2 w1 w4 w5"),
            CommandCase(command: "--swap smallest", failure: "cannot swap a window with itself.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap recent", result: "w1 w2 w5 w4 w3"),
            CommandCase(command: "--swap stack.prev", result: "w1 w3 w2 w4 w5"),
            CommandCase(command: "--swap stack.next", result: "w1 w2 w4 w3 w5"),
            CommandCase(command: "--swap stack.first", result: "w1 w3 w2 w4 w5"),
            CommandCase(command: "--swap stack.last", result: "w1 w2 w4 w3 w5"),
            CommandCase(command: "--swap stack.recent", result: "w1 w2 w4 w3 w5"),
            CommandCase(command: "--swap stack.2", failure: "cannot swap a window with itself.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap stack.3", result: "w1 w2 w4 w3 w5"),
            CommandCase(command: "--swap stack.4", failure: "could not locate the stacked window in position 4.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap stack.0", failure: "value 'stack.0' is not a valid option for WINDOW_SEL\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap w5", result: "w1 w2 w5 w4 w3"),
            CommandCase(command: "--swap w99", failure: "could not locate window with the specified id '-65437'.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "--swap", failure: "value '' is not a valid option for WINDOW_SEL\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "w1 --swap stack.next", failure: "could not locate the next stacked window.\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "w1 --swap next", result: "w2 w1 w3 w4 w5"),
            CommandCase(command: "w5 --swap prev", result: "w1 w2 w3 w5 w4"),
            CommandCase(command: "stack.next --swap stack.first", result: "w1 w4 w3 w2 w5"),
            CommandCase(command: "w99 --swap w1", failure: "could not locate the window to act on!\n", result: "w1 w2 w3 w4 w5"),
            CommandCase(command: "recent --swap first", result: "w5 w2 w3 w4 w1"),
        ]

        @Test(arguments: selectorCases) func selectorOnAStack(_ test: CommandCase)
        {
            let space = stack()
            Headless.activeSpace = Workspace.sid
            WindowManager.shared.focus.setLast(wid(5))

            let result = run(test.command, in: space)

            #expect(result.response == test.response)
            #expect(space.order == test.result)
            expectPlaced(space)
        }

        @Test(arguments: [
            ("--swap first", "could not locate the first managed window.\n"),
            ("--swap last", "could not locate the last managed window.\n"),
            ("--swap prev", "could not locate the prev managed window.\n"),
            ("--swap next", "could not locate the next managed window.\n"),
            ("--swap largest", "could not locate window with the largest area.\n"),
            ("--swap smallest", "could not locate window with the smallest area.\n"),
            ("--swap stack.next", "could not locate the next stacked window.\n"),
            ("--swap recent", "could not locate the most recently focused window.\n"),
        ])
        func selectorsWithoutAnActiveSpaceOrARecentWindow(_ command: String, failure: String)
        {
            // NOTE: the tree selectors except the directions and stack.* look in the tree of the active space
            let space = stack()
            let result = run(command, in: space)

            #expect(result.response == CommandCase(command: command, failure: failure, result: "").response)
            #expect(space.order == "w1 w2 w3 w4 w5")
        }

        @Test func recentSelectsOnlyAManagedWindow()
        {
            let space = stack()
            let other = Window(id: wid(9))
            WindowManager.shared.window[other.id] = other
            WindowManager.shared.focus.setLast(other.id)

            let result = run("--swap recent", in: space)

            #expect(result.response == "\u{07}could not locate the most recently focused window.\n")
        }

        // MARK: - Placements

        @Test func ratioPlacesTheResizedWindows()
        {
            let space = row()

            let result = run("--ratio abs:0.5", in: space)

            assertInlineSnapshot(of: result.placements, as: .descriptionLines) {
                """
                w2: 480,0 720x900
                w3: 1200,0 240x900
                """
            }
        }

        @Test func zoomParentOfAWindowOnTheSpaceFillsTheSpace()
        {
            let space = row()

            let zoomed = run("--toggle zoom-parent", in: space)
            #expect(space.node(2).zoom == .fullscreen)
            assertInlineSnapshot(of: zoomed.placements, as: .descriptionLines) {
                """
                w2: 0,0 1440x900
                """
            }

            let restored = run("--toggle zoom-parent", in: space)
            #expect(space.node(2).zoom == ConZoom.none)
            assertInlineSnapshot(of: restored.placements, as: .descriptionLines) {
                """
                w2: 480,0 480x900
                """
            }
        }

        @Test func zoomParentOfATabFillsItsContainer()
        {
            let space = stack()

            let zoomed = run("--toggle zoom-parent", in: space)
            #expect(space.node(3).zoom == .parent)
            assertInlineSnapshot(of: zoomed.placements, as: .descriptionLines) {
                """
                w3: 480,0 480x900
                """
            }

            let fullscreen = run("--toggle zoom-fullscreen", in: space)
            #expect(space.node(3).zoom == .fullscreen)
            assertInlineSnapshot(of: fullscreen.placements, as: .descriptionLines) {
                """
                w3: 0,0 1440x900
                """
            }

            let restored = run("--toggle zoom-fullscreen", in: space)
            #expect(space.node(3).zoom == ConZoom.none)
            assertInlineSnapshot(of: restored.placements, as: .descriptionLines) {
                """
                w3: 486,30 468x864
                """
            }
            expectPlaced(space)
        }

        // MARK: - Failures

        nonisolated static let onlyWindowCases: [CommandCase] = [
            CommandCase(command: "--ratio abs:0.5", failure: "cannot adjust ratio of a root node.\n", result: "splith\n  w1 1.0000"),
            CommandCase(command: "--resize right:10:0", failure: "cannot resize the container in that direction.\n", result: "splith\n  w1 1.0000"),
            CommandCase(command: "--swap w1", failure: "cannot swap a window with itself.\n", result: "splith\n  w1 1.0000"),
            CommandCase(command: "--warp east", failure: "could not move the container in that direction.\n", result: "splith\n  w1 1.0000"),
            CommandCase(command: "--warp w1", failure: "cannot warp a window onto itself.\n", result: "splith\n  w1 1.0000"),
            CommandCase(command: "--layout splitv", result: "splitv\n  w1 1.0000"),
            CommandCase(command: "--split vertical", result: "splitv\n  w1 1.0000"),
            CommandCase(command: "--toggle zoom-parent", result: "splith\n  w1 1.0000"),
            CommandCase(command: "--focus parent", result: "splith *\n  w1 1.0000"),
        ]

        @Test(arguments: onlyWindowCases) func commandOnTheOnlyWindow(_ test: CommandCase)
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.act(1)
            space.settle()

            let result = run(test.command, in: space)

            #expect(result.response == test.response)
            expectNoDifference(result.tree, test.result)
            #expect(result.placements.isEmpty)
        }

        nonisolated static let unmanagedCases: [CommandCase] = [
            CommandCase(command: "--ratio abs:0.5", failure: "cannot adjust ratio of a non-managed window.\n", result: ""),
            CommandCase(command: "--swap w1", failure: "the acting window is not managed.\n", result: ""),
            CommandCase(command: "w1 --swap w9", failure: "the selected window is not managed.\n", result: ""),
            CommandCase(command: "--warp w1", failure: "the acting window is not managed.\n", result: ""),
            CommandCase(command: "w1 --warp w9", failure: "the selected window is not managed.\n", result: ""),
            CommandCase(command: "--warp east", failure: "could not locate an eastward managed window.\n", result: ""),
            CommandCase(command: "--layout splitv", failure: "the acting window is not managed.\n", result: ""),
            CommandCase(command: "--split vertical", failure: "the acting window is not managed.\n", result: ""),
            CommandCase(command: "--toggle zoom-parent", result: ""),
            CommandCase(command: "--stack w1", failure: "the acting window is not managed.\n", result: ""),
        ]

        @Test(arguments: unmanagedCases) func commandOnAnUnmanagedWindow(_ test: CommandCase)
        {
            let space = row()
            let before = space.dump
            let other = Window(id: wid(9))
            WindowManager.shared.window[other.id] = other
            WindowManager.shared.setPendingFocus(other.id)

            let result = run(test.command, in: space)

            #expect(result.response == test.response)
            expectNoDifference(result.tree, before)
            #expect(result.placements.isEmpty)
        }

        @Test func absoluteResizeOfAnUnmanagedWindowAnimatesItsFrame()
        {
            _ = row()
            let other = Window(id: wid(9))
            other.frame = CGRect(x: 100, y: 50, width: 300, height: 200)
            WindowManager.shared.window[other.id] = other
            WindowManager.shared.setPendingFocus(other.id)

            let result = Golden.run(windowCommand("--resize abs:640:480"))

            #expect(result.isEmpty)
            #expect(drainPlacements().map(\.description) == ["w9: 100,50 640x480"])
        }

        @Test func focusInADirectionWithoutANeighborFails() throws
        {
            // NOTE: a neighbor would be focused through the window server, so the test makes sure there is none
            let space = row()
            try #require(space.node(2).neighbor(.north, wrapping: Config.current.window.focusWrapping, hasOutput: false).target == nil)

            let result = run("--focus north", in: space)

            #expect(result.response == "\u{07}could not locate a container to focus.\n")
            #expect(result.placements.isEmpty)
        }

        @Test func focusCandidateOfAClosingWindow()
        {
            let space = row()
            let wm = WindowManager.shared
            let closing = wm.window[wid(2)]!

            // the focused window hands focus to the window focused before it in its container
            #expect(wm.treeFocusCandidate(in: space.view, for: closing) == wid(3))
            #expect(wm.treeFocusCandidate(in: nil, for: closing) == nil)

            // a window that is not focused hands over nothing
            space.focus(1)
            #expect(wm.treeFocusCandidate(in: space.view, for: closing) == nil)

            // NOTE: macOS can focus another window of the application before it reports the window destroyed; the
            // candidate is then the window focused before w2, which is now w1
            wm.focus.setLast(wid(2))
            #expect(wm.treeFocusCandidate(in: space.view, for: closing) == wid(1))
            wm.window[wid(1)]!.application = Application()
            #expect(wm.treeFocusCandidate(in: space.view, for: closing) == wid(1), "w1 is in the same view")
            wm.managedWindows[wid(1)] = nil
            #expect(wm.treeFocusCandidate(in: space.view, for: closing) == nil)

            space.view.layout = .float
            space.focus(2)
            #expect(wm.treeFocusCandidate(in: space.view, for: closing) == nil)
        }

        @Test func focusAfterCloseOfAHiddenSpaceDoesNothing()
        {
            let space = row()
            WindowManager.shared.focus.clearPending()

            WindowManager.shared.treeFocusAfterClose(in: space.view, windowID: nil)
            WindowManager.shared.treeFocusAfterClose(in: space.view, windowID: wid(1))

            #expect(WindowManager.shared.focus.pending == nil)
        }

        @Test func commandWithoutAnActingWindow()
        {
            let space = row()
            WindowManager.shared.focus.clearPending()

            let result = run("--ratio abs:0.5", in: space)

            #expect(result.response == "\u{07}could not locate the window to act on!\n")
        }

        @Test(arguments: ["--ratio abs:nan", "--ratio rel:nan", "--ratio abs:inf", "--resize right:nan:0", "--resize right:inf:0"])
        func nonFiniteValuesLeaveTheTree(_ command: String)
        {
            let space = row()
            let before = space.dump

            let result = run(command, in: space)

            #expect(result.response.hasPrefix("\u{07}unknown value"))
            expectNoDifference(result.tree, before)
        }

        @Test(arguments: [Float.nan, .infinity, -.infinity])
        func nonFiniteResizeLeavesTheShares(_ delta: Float)
        {
            let space = row()
            let before = space.dump

            #expect(!space.node(2).resize(.east, by: delta))
            expectNoDifference(space.dump, before)
        }

        // MARK: - Ratio arithmetic

        struct RatioCase: Sendable, CustomTestStringConvertible
        {
            var percent: Float
            var type: ValueType?
            var ratio: Float
            var delta: Float

            var testDescription: String { "\(percent) \(type.map { "\($0)" } ?? "nil"):\(ratio)" }
        }

        @Test(arguments: [
            RatioCase(percent: 0.5, type: .rel, ratio: 0.1, delta: 100),
            RatioCase(percent: 0.5, type: .rel, ratio: -0.1, delta: -100),
            RatioCase(percent: 0.5, type: .abs, ratio: 0.3, delta: -200),
            RatioCase(percent: 0.5, type: nil, ratio: 0.3, delta: -200),
            RatioCase(percent: 0.5, type: .abs, ratio: 0.5, delta: 0),
            RatioCase(percent: 0.5, type: .abs, ratio: 1.5, delta: 450),
            RatioCase(percent: 0.5, type: .abs, ratio: -1, delta: -450),
            RatioCase(percent: 0.9, type: .rel, ratio: 0.2, delta: 50),
            RatioCase(percent: 0.1, type: .rel, ratio: -0.2, delta: -50),
            RatioCase(percent: 0.5, type: .abs, ratio: 0.05, delta: -450),
            RatioCase(percent: 0.5, type: .abs, ratio: 0.95, delta: 450),
            RatioCase(percent: 0.01, type: .rel, ratio: 0, delta: 40),
        ])
        func ratioDelta(_ test: RatioCase)
        {
            let delta = WindowManager.ratioDelta(from: test.percent, type: test.type, ratio: test.ratio, size: 1000)
            #expect(abs(delta - test.delta) < 1e-3)
        }

        @Test func ratioDeltaScalesWithTheSize()
        {
            #expect(WindowManager.ratioDelta(from: 0.25, type: .abs, ratio: 0.5, size: 0) == 0)
            #expect(abs(WindowManager.ratioDelta(from: 0.25, type: .abs, ratio: 0.5, size: 1440) - 360) < 1e-3)
        }
    }
}
