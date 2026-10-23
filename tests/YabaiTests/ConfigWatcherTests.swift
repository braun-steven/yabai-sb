import Foundation
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The change of the daemon's yabai.toml (ConfigWatcher.fileChanged, the `.configFileChanged` event). The headless
// watch never opens a file, so these tests call the event handler directly, with the file written to the temporary
// directory. A failed check notifies, which headless mode records (Headless.notifications). The suite is DaemonState.
//

/// Writes `text` to a new yabai.toml in the temporary directory and returns its path; the caller removes it.
private func writeWatchedFile(_ text: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabai-watch-\(UUID().uuidString).toml"
  ).path
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

extension DaemonState {
  @Suite
  @WM struct ConfigWatcherTests {
    @Test func changedFileIsApplied() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = 12\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      _ = Headless.drain()

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("12\n".utf8))
      #expect(ConfigLoader.shared.lastContents == Array("[config]\nwindow_gap = 12\n".utf8))
      #expect(Headless.drain().notifications.isEmpty)
    }

    @Test func unchangedContentsApplyNothing() async throws {
      DaemonFixture.reset()
      let text = "[config]\nwindow_gap = 12\n"
      let path = try writeWatchedFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array(text.utf8)
      #expect(Golden.run("config window_gap 5") == [])

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
    }

    @Test func autoReloadOffStopsTheWatchAndAppliesNothing() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile(
        "[daemon]\nauto_reload = false\n\n[config]\nwindow_gap = 12\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      // The first load sets auto_reload off in the applied document: the watch is off from then on.
      ConfigLoader.shared.filePath = path
      #expect(Golden.run("config --reload \(path)") == Array("reloaded \(path): 1 changes\n".utf8))
      #expect(ConfigLoader.shared.autoReload == false)
      #expect(Golden.run("config window_gap 5") == [])
      try "[config]\nwindow_gap = 14\n".write(toFile: path, atomically: true, encoding: .utf8)

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
    }

    @Test func failedCheckKeepsTheRunningConfigAndNotifies() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = \"x\"\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      #expect(Golden.run("config window_gap 5") == [])
      _ = Headless.drain()

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(
        Headless.drain().notifications
          == ["configuration: \(path) has 1 errors; kept the running config.."])
      #expect(ConfigLoader.shared.lastContents == Array("[config]\nwindow_gap = \"x\"\n".utf8))
    }

    @Test func fixingTheFileAppliesIt() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = \"x\"\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      #expect(Golden.run("config window_gap 5") == [])
      await EventHandler.shared.handle(.configFileChanged)
      #expect(Golden.run("config window_gap") == Array("5\n".utf8))

      try "[config]\nwindow_gap = 9\n".write(toFile: path, atomically: true, encoding: .utf8)
      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("9\n".utf8))
    }

    @Test func missingFileChangesNothing() async {
      DaemonFixture.reset()
      ConfigLoader.shared.filePath = "/nonexistent/yabai-watch/yabai.toml"
      #expect(Golden.run("config window_gap 5") == [])
      _ = Headless.drain()

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(Headless.drain().notifications.isEmpty)
    }

    @Test func reloadOfAnotherFileKeepsTheWatchedContents() throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = 12\n")
      let other = try writeWatchedFile("[config]\nwindow_gap = 13\n")
      defer {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: other)
      }
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array("[config]\nwindow_gap = 12\n".utf8)

      #expect(
        Golden.run("config --reload \(other)") == Array("reloaded \(other): 1 changes\n".utf8))

      #expect(ConfigLoader.shared.lastContents == Array("[config]\nwindow_gap = 12\n".utf8))
    }
  }
}
