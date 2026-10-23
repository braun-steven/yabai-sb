import CustomDump
import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: space --restore-layout on a Workspace view. The restore reads its directory from the environment in the handler,
// so the tests call restoreSpaceLayout with a temporary directory, which they remove. The fixture is the tree of
// LayoutFixtures with the fake windows w1 to w4: w1 Notes "Draft", w2 Safari "Work/Inbox", w3 Notes "Inbox" and w4
// Terminal "shell" (without a bundle id).
//

/// Opens window n of the fixture with the application and title of its matcher, without focus.
@WM private func openFixtureWindow(
  _ space: Workspace, _ n: UInt32, bundle: String?, app: String, title: String
) {
  let window = space.open(n)
  let application = Application()
  application.name = app
  application.bundleID = bundle
  window.application = application
  window.ax = WindowAXState(role: "AXWindow", subrole: "AXStandardWindow", title: title)
}

/// The fixture tree with the fake window ids (the snapshot of LayoutFixtures holds the raw ids 1 to 4).
@WM private func fixtureTree() -> TreeSnapshot {
  func shifted(_ node: TreeSnapshot) -> TreeSnapshot {
    var copy = node
    copy.isSelected = false
    copy.windowID = node.windowID.map { wid($0.rawValue) }
    copy.children = node.children.map(shifted)
    return copy
  }
  return shifted(LayoutFixtures.tree)
}

/// Replaces the tree of the view with `tree` as undoTreeCommand does, and lays it out.
@WM private func setTree(_ space: Workspace, _ tree: TreeSnapshot) {
  let root = Con(snapshot: tree)
  root.area = space.view.area
  let old = space.view.tree
  space.view.tree = root
  space.view.insertionPoint = nil
  old?.destroy()

  WindowManager.shared.treeApply(space.view)
  _ = Headless.drain()
}

/// A space with the fixture windows in the fixture tree.
@WM private func fixtureSpace() -> Workspace {
  let space = Workspace()
  openFixtureWindow(space, 1, bundle: "com.apple.Notes", app: "Notes", title: "Draft")
  openFixtureWindow(space, 2, bundle: "com.apple.Safari", app: "Safari", title: "Work/Inbox")
  openFixtureWindow(space, 3, bundle: "com.apple.Notes", app: "Notes", title: "Inbox")
  openFixtureWindow(space, 4, bundle: nil, app: "Terminal", title: "shell")
  setTree(space, fixtureTree())
  return space
}

/// The four windows in a flat row, in the order 4, 3, 2, 1: a tree that is not the fixture.
@WM private func flatRow() -> TreeSnapshot {
  let leaves = [4, 3, 2, 1].map { n in
    TreeSnapshot(
      layout: .splitH, lastSplit: .splitH, percent: 0.25, zoom: .none, isSelected: false,
      windowID: wid(UInt32(n)), children: [], focusOrder: [])
  }
  return TreeSnapshot(
    layout: .splitH, lastSplit: .splitH, percent: 0, zoom: .none, isSelected: false,
    windowID: nil, children: leaves, focusOrder: [0, 1, 2, 3])
}

/// A fresh directory below the temporary directory, which the test removes.
private func temporaryDirectory() -> String {
  FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path(
    percentEncoded: false)
}

extension DaemonState {
  @Suite
  @WM struct LayoutRestoreTests {
    @Test func restoringTheSavedTreeGivesItBack() throws {
      let space = fixtureSpace()
      let saved = space.dump
      #expect(saved.contains("tabbed(splitv)"))

      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"
      _ = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      setTree(space, flatRow())
      #expect(space.dump != saved)

      let reply = try restoreSpaceLayout(name: "work", on: Workspace.sid, directory: directory)
      #expect(reply == "restored 4 of 4 windows\n")
      expectNoDifference(space.dump, saved)
    }

    @Test func aClosedWindowIsLeftOutAndTheRestWidensToFillTheLayout() throws {
      let space = fixtureSpace()

      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"
      _ = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      space.close(2)
      WindowManager.shared.forget(wid(2))

      let reply = try restoreSpaceLayout(name: "work", on: Workspace.sid, directory: directory)
      #expect(reply == "restored 3 of 4 windows\n")
      // NOTE: The splitv of w2 and w3 keeps w3 alone, so w3 takes its share; the tab keeps w3 and w4.
      expectNoDifference(
        space.dump,
        """
        splith focus=1,0
          w1 0.4000
          tabbed(splitv) 0.6000 focus=1,0
            w3 0.5000
            w4 0.5000
        """)
    }

    @Test func aWindowThatMatchesNoSlotOpensAfterTheFocusedWindowWithoutFocus() throws {
      let space = fixtureSpace()

      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"
      _ = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      openFixtureWindow(space, 5, bundle: "com.apple.Notes", app: "Notes", title: "Scratch")
      space.focus(2)

      let reply = try restoreSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      #expect(reply == "restored 4 of 4 windows\n")
      #expect(space.order == "w1 w2 w5 w3 w4")
      #expect(WindowManager.shared.focus.focused == wid(2))
    }

    @Test func aFileWithNoWindowOnTheSpaceChangesNothing() throws {
      let space = fixtureSpace()

      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"
      _ = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      for n: UInt32 in 1...4 {
        space.close(n)
        WindowManager.shared.forget(wid(n))
      }
      // NOTE: A Mail window matches no slot, unlike a Notes one, which would take the Notes slots.
      openFixtureWindow(space, 5, bundle: "com.apple.mail", app: "Mail", title: "Scratch")
      let before = space.dump

      do {
        _ = try restoreSpaceLayout(name: "work", on: Workspace.sid, directory: directory)
        Issue.record("the layout was restored without a matching window")
      } catch {
        #expect(error.description == "no window of layout 'work' is on this space.\n")
      }
      expectNoDifference(space.dump, before)
    }

    @Test func undoBringsBackTheTreeBeforeTheRestore() throws {
      let space = fixtureSpace()
      let saved = space.dump

      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"
      _ = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      setTree(space, flatRow())
      let scrambled = space.dump

      // NOTE: The dispatcher runs the restore through recordingTreeUndo, since the command changes the tree.
      var reply = ""
      try recordingTreeUndo(on: space.view) { () throws(CommandError) in
        reply = try restoreSpaceLayout(name: "work", on: Workspace.sid, directory: directory)
      }
      #expect(reply == "restored 4 of 4 windows\n")
      expectNoDifference(space.dump, saved)

      try undoTreeCommand(on: Workspace.sid)
      expectNoDifference(space.dump, scrambled)
      #expect(space.view.history.entries.isEmpty)
    }

    @Test func restoreRefusesAMissingFileAndAnUnmanagedSpace() throws {
      let space = fixtureSpace()
      let before = space.dump

      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(atPath: root) }
      let directory = root + "/yabai/layouts"
      _ = try saveSpaceLayout(name: "work", on: Workspace.sid, directory: directory)

      do {
        _ = try restoreSpaceLayout(name: "missing", on: Workspace.sid, directory: directory)
        Issue.record("a missing file was read")
      } catch {
        #expect(error.description == "could not read layout '\(directory)/missing.json'.\n")
      }

      do {
        _ = try restoreSpaceLayout(name: "work", on: 0xFFFF_0200, directory: directory)
        Issue.record("a layout was restored on an unmanaged space")
      } catch {
        #expect(error.description == "cannot restore a layout on a non-managed space.\n")
      }
      expectNoDifference(space.dump, before)
    }
  }
}
