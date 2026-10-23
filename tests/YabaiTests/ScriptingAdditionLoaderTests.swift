import Foundation
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The built-in load of the scripting addition (ScriptingAdditionLoader.swift). The tests run headless, so a request
// is recorded and no process starts. The result handler only logs and notifies, and starts a queued run, which headless
// mode never queues. The requests come from the startup (Daemon.run), the Dock restart and a reload (reloadConfig); the
// tests call the same functions with a temporary yabai.toml. Headless mode also keeps the Dock's observer off.
//

/// Writes `text` to a new yabai.toml in the temporary directory and returns its path; the caller removes it.
private func writeLoadFile(_ text: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabai-load-\(UUID().uuidString).toml"
  ).path
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

/// A file with `[daemon] load_scripting_addition` set to `value`.
private func loadText(_ value: Bool) -> String {
  "[daemon]\nload_scripting_addition = \(value)\n"
}

/// The startup of Daemon.run for `path`: the check, each ConfigStep, then the request. The window manager and space
/// manager starts are left out, as in ConfigLoaderTests.
@WM private func startupRequest(_ path: String) {
  let loaded = loadStartupConfig(explicit: path)
  for step in ConfigStep.allCases {
    _ = loaded.apply(step)
  }
  requestScriptingAdditionLoad(reason: "startup")
}

/// Applies `text` to `path` the way `config --reload` does, and discards the signals the reload pushes.
@WM private func reloadFile(_ path: String, _ text: String) throws {
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  _ = reloadConfig(path: path, check: configFileCheck(path: path, source: text))
  EventSignals.shared.discardPending()
}

extension DaemonState {
  @Suite
  @WM struct ScriptingAdditionLoaderTests {
    @Test func requestsAreRecordedInOrder() {
      DaemonFixture.reset()
      ScriptingAdditionLoader.shared.load(reason: "startup")
      ScriptingAdditionLoader.shared.load(reason: "dock_did_restart")
      #expect(Headless.drain().scriptingAdditionLoads == ["startup", "dock_did_restart"])
    }

    @Test func aFailedResultIsNotified() {
      DaemonFixture.reset()
      EventHandler.shared.scriptingAdditionLoaded(.failed("sudo: a password is required"))
      #expect(
        Headless.drain().notifications == [
          "scripting-addition: could not load (sudo: a password is required); see sudoers setup in the man page"
        ])
    }

    @Test func aLoadedResultIsNotNotified() {
      DaemonFixture.reset()
      EventHandler.shared.scriptingAdditionLoaded(.loaded)
      #expect(Headless.drain().notifications.isEmpty)
    }

    @Test func startupWithTheSettingRequestsOneLoad() throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(loadText(true))
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      startupRequest(path)
      #expect(Headless.drain().scriptingAdditionLoads == ["startup"])
    }

    @Test(arguments: [loadText(false), "[config]\nwindow_gap = 7\n"])
    func startupWithoutTheSettingRequestsNoLoad(text: String) throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      startupRequest(path)
      #expect(Headless.drain().scriptingAdditionLoads.isEmpty)
    }

    @Test func dockRestartWithTheSettingRequestsOneLoad() throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(loadText(true))
      defer { try? FileManager.default.removeItem(atPath: path) }
      try reloadFile(path, loadText(true))
      _ = Headless.drain()

      EventHandler.shared.dockDidRestart()
      EventSignals.shared.discardPending()
      #expect(Headless.drain().scriptingAdditionLoads == ["dock_did_restart"])
    }

    @Test func dockRestartWithoutTheSettingRequestsNoLoad() throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(loadText(false))
      defer { try? FileManager.default.removeItem(atPath: path) }
      try reloadFile(path, loadText(false))
      _ = Headless.drain()

      EventHandler.shared.dockDidRestart()
      EventSignals.shared.discardPending()
      #expect(Headless.drain().scriptingAdditionLoads.isEmpty)
    }

    @Test func reloadThatTurnsTheSettingOnRequestsOneLoad() throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(loadText(false))
      defer { try? FileManager.default.removeItem(atPath: path) }
      try reloadFile(path, loadText(false))
      _ = Headless.drain()

      try reloadFile(path, loadText(true))
      #expect(Headless.drain().scriptingAdditionLoads == ["reload"])
    }

    @Test func reloadThatKeepsTheSettingOnRequestsNoLoad() throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(loadText(true))
      defer { try? FileManager.default.removeItem(atPath: path) }
      try reloadFile(path, loadText(true))
      _ = Headless.drain()

      try reloadFile(path, "[config]\nwindow_gap = 9\n" + loadText(true))
      #expect(Headless.drain().scriptingAdditionLoads.isEmpty)
    }

    @Test func reloadThatTurnsTheSettingOffRequestsNoLoad() throws {
      DaemonFixture.reset()
      let path = try writeLoadFile(loadText(true))
      defer { try? FileManager.default.removeItem(atPath: path) }
      try reloadFile(path, loadText(true))
      _ = Headless.drain()

      try reloadFile(path, loadText(false))
      #expect(Headless.drain().scriptingAdditionLoads.isEmpty)
    }
  }
}
