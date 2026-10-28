import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The query domain on a Workspace view (TreeFixtures.swift) labeled "ws". The queries only read the window server
// about the fake ids. Left out: `query --displays` of a window or space, and the display, space and visibility
// properties: SkyLight reports the user's display for a fake window or space, so the result depends on the session.
// The queries of all displays, spaces or windows read the live session too.
//

/// The fields of a json object response.
private func object(_ response: [UInt8]) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: Data(response)) as? [String: Any])
}

/// A window id as `query` prints it: as a 32-bit signed value, so the fake ids above Int32.max are negative.
private func printed(_ id: WindowID) -> Int {
  Int(Int32(bitPattern: id.rawValue))
}

extension DaemonState {
  @Suite
  @WM struct MessageQueryTests {
    static let windowProperties =
      "id,app,title,role,subrole,has-focus,split-type,stack-index,is-floating,scratchpad,root-window"

    /// A Workspace of Safari windows w1 (focused) and w2 (the acting window), labeled "ws".
    func workspace() -> Workspace {
      let space = Workspace()
      space.application.name = "Safari"
      let first = space.open(1, focus: true)
      first.ax.title = "Document"
      first.ax.role = "AXWindow"
      first.ax.subrole = "AXStandardWindow"
      first.isRoot = true
      space.open(2)
      space.view.updateTree()
      SpaceManager.shared.labels.set(id: Workspace.sid, name: "ws")
      WindowManager.shared.setPendingFocus(wid(2))
      return space
    }

    @Test func windowByID() throws {
      _ = workspace()

      let window = try object(
        Golden.run("query --windows \(Self.windowProperties) --window \(wid(1).rawValue)"))
      #expect(window.count == 11)
      #expect(window["id"] as? Int == printed(wid(1)))
      #expect(window["app"] as? String == "Safari")
      #expect(window["title"] as? String == "Document")
      #expect(window["role"] as? String == "AXWindow")
      #expect(window["subrole"] as? String == "AXStandardWindow")
      #expect(window["root-window"] as? Bool == true)
      #expect(window["has-focus"] as? Bool == true)
      #expect(window["split-type"] as? String == "vertical")
      #expect(window["stack-index"] as? Int == 0)
      #expect(window["is-floating"] as? Bool == false)
      #expect(window["scratchpad"] as? String == "")
    }

    @Test func windowLabel() throws {
      _ = workspace()
      #expect(Golden.run("window \(wid(1).rawValue) --label far") == [])

      let labeled = try object(Golden.run("query --windows label,id --window far"))
      #expect(labeled.count == 2)
      #expect(labeled["label"] as? String == "far")
      #expect(labeled["id"] as? Int == printed(wid(1)))

      let other = try object(Golden.run("query --windows label --window \(wid(2).rawValue)"))
      #expect(other["label"] as? String == "")
    }

    @Test func actingWindow() throws {
      _ = workspace()

      #expect(
        Golden.escaped(Golden.run("query --windows id,app,has-focus --window"))
          == "{\"app\":\"Safari\",\"has-focus\":false,\"id\":\(printed(wid(2)))}\\n")
    }

    @Test func windowOfATabbedContainer() throws {
      let space = workspace()
      space.view.root.setLayout(.tabbed)

      let window = try object(
        Golden.run("query --windows split-type,stack-index --window \(wid(2).rawValue)"))
      #expect(window["split-type"] as? String == "none")
      #expect(window["stack-index"] as? Int == 2)
    }

    @Test func unknownWindow() {
      _ = workspace()

      #expect(
        Golden.escaped(Golden.run("query --windows --window \(wid(9).rawValue)"))
          == "could not locate window with the specified id '\(printed(wid(9)))'.\\n")
      #expect(
        Golden.escaped(Golden.run("query --spaces --window \(wid(9).rawValue)"))
          == "could not locate window with the specified id '\(printed(wid(9)))'.\\n")
    }

    @Test func spacesOfAWindowOnNoSpace() {
      _ = workspace()

      // NOTE: SkyLight knows no space of a fake window
      #expect(Golden.run("query --spaces --window \(wid(1).rawValue)") == [])
    }

    @Test func treeOfALabeledSpace() throws {
      _ = workspace()

      let tree = try object(Golden.run("query --tree --space ws"))
      #expect(tree["type"] as? String == "workspace")
      #expect(tree["layout"] as? String == "splith")
      let nodes = try #require(tree["nodes"] as? [[String: Any]])
      #expect(nodes.map { $0["window"] as? Int } == [printed(wid(1)), printed(wid(2))])
      #expect(nodes.map { $0["focused"] as? Bool } == [true, false])
      #expect(nodes.map { $0["percent"] as? Double } == [0.5, 0.5])
      #expect(nodes.map { ($0["frame"] as? [String: Any])?["x"] as? Int } == [0, 600])
    }

    @Test func treeOfAFloatingSpace() {
      let space = workspace()
      space.view.layout = .float

      #expect(
        Golden.escaped(Golden.run("query --tree --space ws"))
          == "the selected space does not use the tree layout.\\n")
    }

    @Test func labeledSpace() throws {
      _ = workspace()

      let info = try object(
        Golden.run(
          "query --spaces id,label,type,first-window,last-window,windows,has-focus --space ws"))
      #expect(info.count == 7)
      #expect(info["id"] as? Int == Int(Workspace.sid.rawValue))
      #expect(info["label"] as? String == "ws")
      #expect(info["type"] as? String == "tree")
      #expect(info["first-window"] as? Int == printed(wid(1)))
      #expect(info["last-window"] as? Int == printed(wid(2)))
      #expect(info["has-focus"] as? Bool == false)
      // NOTE: the windows of a space come from SkyLight, which knows no fake window
      #expect(info["windows"] as? [Int] == [])
      #expect(Golden.escaped(Golden.run("query --windows --space ws")) == "[]\\n")
    }

    @Test func spaceWithoutAView() {
      SpaceManager.shared.labels.set(id: Workspace.sid, name: "ws")

      // NOTE: before SpaceManager.begin a query does not create a view
      #expect(
        Golden.escaped(Golden.run("query --spaces --space ws"))
          == "could not retrieve space details.\\n")
      #expect(SpaceManager.shared.views.isEmpty)
    }

    // NOTE: a 'recent' selector without a recent display or space prints nothing.
    @Test(arguments: [
      "query --tree --space recent",
      "query --spaces --space recent",
      "query --windows --space recent",
      "query --displays --display recent",
      "query --spaces --display recent",
      "query --windows --display recent",
    ])
    func recentWithoutARecentSpacePrintsNothing(_ command: String) {
      #expect(Golden.run(command) == [])
    }
  }
}
