import Foundation
import InlineSnapshotTesting
import PropertyBased
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

private func layoutFile(from input: [Int]) -> LayoutFile {
  let values = input.isEmpty ? [0] : input
  let groups = stride(from: 0, to: values.count, by: 2).map { start in
    Array(values[start..<min(start + 2, values.count)])
  }
  let children = groups.enumerated().map { index, group in
    let leaves = group.enumerated().map { leafIndex, value in
      let matcher = LayoutMatcher(
        bundleID: value.isMultiple(of: 2) ? "com.example.app\(value)" : nil,
        app: ["Terminal", "Notes", "Safari", "Éditeur"][value % 4],
        title: value.isMultiple(of: 3) ? nil : "Window \(value) / \(value % 17)",
        role: value.isMultiple(of: 5) ? nil : "AXWindow",
        subrole: value.isMultiple(of: 7) ? nil : "AXStandardWindow")
      return LayoutFile.Node(
        layout: .splitH, lastSplit: .splitV,
        percent: group.count == 1 ? 1 : 0.5, zoom: zoom(value), focusOrder: [],
        window: value.isMultiple(of: 6) ? nil : matcher, children: [])
    }
    if leaves.count == 1 {
      var leaf = leaves[0]
      leaf.percent = 1 / Float(groups.count)
      return leaf
    }
    return LayoutFile.Node(
      layout: layout(group[0]), lastSplit: split(group[0]), percent: 1 / Float(groups.count),
      zoom: zoom(group[0]), focusOrder: index.isMultiple(of: 2) ? [0, 1] : [1, 0], window: nil,
      children: leaves)
  }
  return LayoutFile(
    tree: LayoutFile.Node(
      layout: layout(values[0]), lastSplit: split(values[0]), percent: 1, zoom: zoom(values[0]),
      focusOrder: values[0].isMultiple(of: 2)
        ? Array(children.indices) : Array(children.indices.reversed()),
      window: nil, children: children))
}

private func layout(_ value: Int) -> ConLayout {
  switch value % 3 {
  case 0: .splitH
  case 1: .splitV
  default: .tabbed
  }
}

private func split(_ value: Int) -> ConLayout {
  value.isMultiple(of: 2) ? .splitH : .splitV
}

private func zoom(_ value: Int) -> ConZoom {
  switch value % 3 {
  case 0: .none
  case 1: .parent
  default: .fullscreen
  }
}

//
// NOTE: space --save-layout. The encoding is a snapshot of the JSON of a fixture tree. The save writes into a temporary
// directory that the test passes in, never the configuration directory of the user: the handler resolves that directory
// from the environment, so the tests call saveSpaceLayout directly.
//

extension DaemonState {
  @Suite
  @WM struct LayoutSaveTests {
    @Test func encodingOfTheFixtureTreeIsStable() throws {
      let file = LayoutFile(snapshot: LayoutFixtures.tree, matcher: LayoutFixtures.matcher)
      let json = String(decoding: try LayoutFile.encode(file), as: UTF8.self)

      assertInlineSnapshot(of: json, as: .lines) {
        """
        {
          "tree" : {
            "children" : [
              {
                "children" : [

                ],
                "focusOrder" : [

                ],
                "lastSplit" : "splith",
                "layout" : "splith",
                "percent" : 0.4,
                "window" : {
                  "app" : "Notes",
                  "bundleID" : "com.apple.Notes",
                  "role" : "AXWindow",
                  "subrole" : "AXStandardWindow",
                  "title" : "Draft"
                },
                "zoom" : "none"
              },
              {
                "children" : [
                  {
                    "children" : [
                      {
                        "children" : [

                        ],
                        "focusOrder" : [

                        ],
                        "lastSplit" : "splith",
                        "layout" : "splith",
                        "percent" : 0.5,
                        "window" : {
                          "app" : "Safari",
                          "bundleID" : "com.apple.Safari",
                          "role" : "AXWindow",
                          "subrole" : "AXStandardWindow",
                          "title" : "Work/Inbox"
                        },
                        "zoom" : "none"
                      },
                      {
                        "children" : [

                        ],
                        "focusOrder" : [

                        ],
                        "lastSplit" : "splith",
                        "layout" : "splith",
                        "percent" : 0.5,
                        "zoom" : "none"
                      }
                    ],
                    "focusOrder" : [
                      1,
                      0
                    ],
                    "lastSplit" : "splith",
                    "layout" : "splitv",
                    "percent" : 0.5,
                    "zoom" : "none"
                  },
                  {
                    "children" : [

                    ],
                    "focusOrder" : [

                    ],
                    "lastSplit" : "splith",
                    "layout" : "splith",
                    "percent" : 0.5,
                    "window" : {
                      "app" : "Terminal",
                      "role" : "AXWindow"
                    },
                    "zoom" : "none"
                  }
                ],
                "focusOrder" : [
                  1,
                  0
                ],
                "lastSplit" : "splitv",
                "layout" : "tabbed",
                "percent" : 0.6,
                "zoom" : "parent"
              }
            ],
            "focusOrder" : [
              1,
              0
            ],
            "lastSplit" : "splith",
            "layout" : "splith",
            "percent" : 1,
            "zoom" : "none"
          },
          "version" : 1
        }

        """
      }
    }

    @Test func generatedLayoutFilesEncodeAndDecode() async {
      await propertyCheck(count: 300, input: Gen<Int>.int(in: 0...1_000_000).array(of: 0...40)) {
        values in
        let file = layoutFile(from: values)
        let encoded = try LayoutFile.encode(file)
        let decoded = try LayoutFile.decode(encoded)
        #expect(decoded == file, "\(String(decoding: encoded, as: UTF8.self))")
      }
    }

    /// A fresh directory below the temporary directory, which the caller removes.
    private static func temporaryDirectory() -> String {
      FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path(
        percentEncoded: false)
    }

    @Test func savingWritesTheMatchersOfTheWindows() throws {
      let space = Workspace()
      space.application.name = "Notes"
      space.application.bundleID = "com.apple.Notes"
      space.open(1, focus: true).ax = WindowAXState(
        role: "AXWindow", subrole: "AXStandardWindow", title: "Draft")
      space.open(2, focus: true).ax = WindowAXState(
        role: "AXWindow", subrole: "AXStandardWindow", title: "Inbox")
      space.open(3)
      // NOTE: A window the window manager no longer knows is saved as a leaf without a matcher.
      WindowManager.shared.window[wid(3)] = nil

      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"

      let path = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)
      #expect(path == directory + "/work.json")

      let file = try LayoutFile.decode(Data(contentsOf: URL(filePath: path)))
      let notes = LayoutMatcher(
        bundleID: "com.apple.Notes", app: "Notes", title: "Draft", role: "AXWindow",
        subrole: "AXStandardWindow")
      let inbox = LayoutMatcher(
        bundleID: "com.apple.Notes", app: "Notes", title: "Inbox", role: "AXWindow",
        subrole: "AXStandardWindow")
      #expect(file.tree.children.map(\.window) == [notes, inbox, nil])
      #expect(file.tree.children.allSatisfy { $0.children.isEmpty })
    }

    @Test func savingWithAnInvalidNameWritesNothing() {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      _ = Workspace()

      #expect(throws: CommandError.self) {
        try saveSpaceLayout(name: "../escape", on: Workspace.sid, directory: root)
      }
      #expect(!FileManager.default.fileExists(atPath: root + "/escape.json"))
      #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test func savingAnUnmanagedSpaceFails() {
      let root = Self.temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }

      #expect(throws: CommandError.self) {
        try saveSpaceLayout(name: "work", on: 0xFFFF_0200, directory: root)
      }
      #expect(!FileManager.default.fileExists(atPath: root))
    }
  }
}
