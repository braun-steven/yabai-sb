import Foundation
import InlineSnapshotTesting
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

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
