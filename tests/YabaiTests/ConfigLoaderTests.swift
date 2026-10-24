import Foundation
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The startup file (ConfigLoader.swift). Daemon.run calls loadStartupConfig, then the steps of ConfigStep between the
// manager starts. These tests call the same functions with the fixture, in the same order, except the starts themselves:
// WindowManager.begin and SpaceManager.begin read the window server, so they are not called. Entries that need a space
// (`[[space]]`) and `space_layout` (which posts a re-layout) are not in the fixture files.
//

/// Writes `text` to a new yabai.toml in the temporary directory and returns its path; the caller removes it.
private func writeStartupFile(_ text: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabai-startup-\(UUID().uuidString).toml"
  ).path
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

/// A file with a window gap, a tab bar font, a rule and a signal.
private let startupText = """
  [config]
  window_gap = 7
  tab_bar_font = "Helvetica:14"

  [[rule]]
  app = "^Keep$"
  manage = false

  [[signal]]
  event = "window_focused"
  action = "true"
  """

private enum RecordedStartupStep: Equatable, Sendable {
  case notificationRegistration
  case manager(StartupManagerStep)
}

private final class StartupLifecycleRecorder: Sendable {
  private struct State: Sendable {
    var events: [RecordedStartupStep] = []
  }

  private let state = Mutex(State())

  func registerNotifications() {
    state.withLock { $0.events.append(.notificationRegistration) }
  }

  func run(_ step: StartupManagerStep) -> ConfigReconcileResult {
    state.withLock { current in
      current.events.append(.manager(step))
      switch step {
      case .settings, .managerSettings, .spaces, .rulesAndSignals:
        return ConfigReconcileResult(changes: 1)
      default:
        return ConfigReconcileResult()
      }
    }
  }

  var events: [RecordedStartupStep] { state.withLock { $0.events } }
}

extension DaemonState {
  @Suite
  @WM struct ConfigLoaderTests {
    @Test func eachKindOfEntryRunsInItsStep() {
      let rows: [(ConfigEntry.Target, ConfigStep)] = [
        (.option(.windowGap), .settings),
        (.option(.spaceLayout), .settings),
        (.option(.tabBarFont), .managerSettings),
        (.option(.externalBar), .managerSettings),
        (.spaceLabel(index: 11), .spaces),
        (.spacePin(index: 11), .spaces),
        (.spaceOption(index: 11, .layout), .spaces),
        (.rule, .rulesAndSignals),
        (.signal, .rulesAndSignals),
      ]
      for (target, step) in rows {
        #expect(configStep(of: target) == step, "\(target)")
      }
    }

    @Test func notificationsAndRulesAreReadyBeforeWindowTiling() {
      let recorder = StartupLifecycleRecorder()

      registerStartupNotifications {
        recorder.registerNotifications()
      }
      let result = startStartupManagerLifecycle { recorder.run($0) }

      #expect(
        recorder.events == [
          .notificationRegistration,
          .manager(.spaceDefaults),
          .manager(.settings),
          .manager(.initializeWindowManager),
          .manager(.beginSpaceManager),
          .manager(.managerSettings),
          .manager(.spaces),
          .manager(.rulesAndSignals),
          .manager(.beginWindowManager),
          .manager(.updateWindowNotifications),
          .manager(.startConfigObserver),
          .manager(.applyMenuBarAlpha),
          .manager(.requestScriptingAdditionLoad),
          .manager(.syncConfigWatcher),
        ])
      #expect(result.changes == ConfigStep.allCases.count)
    }

    @Test func fileIsAppliedInItsSteps() throws {
      DaemonFixture.reset()
      let path = try writeStartupFile(startupText)
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      let loaded = loadStartupConfig(explicit: path)
      #expect(loaded.entries != nil)
      #expect(loaded.notices.isEmpty)

      #expect(loaded.apply(.settings).failures == 0)
      #expect(Golden.run("config window_gap") == Array("7\n".utf8))
      #expect(Golden.run("config tab_bar_font") == Array("system:12\n".utf8))
      #expect(WindowManager.shared.rules.isEmpty)
      #expect(Headless.drain().configEntries.map(\.arguments) == [["config", "window_gap", "7"]])

      #expect(loaded.apply(.managerSettings).failures == 0)
      #expect(Golden.run("config tab_bar_font") == Array("Helvetica:14\n".utf8))

      #expect(loaded.apply(.spaces).failures == 0)
      #expect(loaded.apply(.rulesAndSignals).failures == 0)
      #expect(WindowManager.shared.rules.count == 1)
      #expect(EventSignals.shared.table.list().count == 1)
      #expect(
        Headless.drain().configEntries.map(\.arguments)
          == [
            ["config", "tab_bar_font", "Helvetica:14"],
            ["rule", "--add", "app=^Keep$", "manage=off"],
            ["signal", "--add", "event=window_focused", "action=true"],
          ])
    }

    @Test func invalidFileAppliesNothing() throws {
      DaemonFixture.reset()
      let path = try writeStartupFile(
        "[config]\nwindow_gap = \"x\"\n\n[[rule]]\napp = \"^Keep$\"\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      let loaded = loadStartupConfig(explicit: path)
      #expect(loaded.entries == nil)
      #expect(loaded.notices == ["\(path) has 1 errors; using defaults.."])
      for step in ConfigStep.allCases {
        #expect(loaded.apply(step).failures == 0)
      }
      #expect(Golden.run("config window_gap") == Array("0\n".utf8))
      #expect(WindowManager.shared.rules.isEmpty)
      #expect(Headless.drain().configEntries.isEmpty)
    }

    @Test func startupConfigLoadedIsOnlyForAFileThatPassedTheCheck() throws {
      DaemonFixture.reset()
      let path = try writeStartupFile(startupText)
      defer { try? FileManager.default.removeItem(atPath: path) }
      let invalid = try writeStartupFile("[config]\nwindow_gap = \"x\"\n")
      defer { try? FileManager.default.removeItem(atPath: invalid) }
      _ = Headless.drain()

      if case .configLoaded(let file, let changes)? = loadStartupConfig(explicit: path).loadedEvent(
        changes: 5)
      {
        #expect(file == path)
        #expect(changes == 5)
      } else {
        Issue.record("a file that passed the check announces no config_loaded")
      }
      #expect(loadStartupConfig(explicit: invalid).loadedEvent(changes: 5) == nil)
      #expect(
        loadStartupConfig(explicit: "/nonexistent/yabai-startup.toml").loadedEvent(changes: 5)
          == nil)
    }

    @Test func configLoadedPushesItsEnvironment() {
      DaemonFixture.reset()
      #expect(Golden.run("signal --add event=config_loaded action=true") == [])

      EventHandler.shared.configLoaded(file: "/example/yabai.toml", changes: 4)

      let pushed = EventSignals.shared.pending
      #expect(pushed.map(\.type) == [.configLoaded])
      #expect(
        pushed.first?.arguments.map { $0.name } == ["YABAI_CONFIG_FILE", "YABAI_CONFIG_CHANGES"])
      #expect(pushed.first?.arguments.map { $0.value } == ["/example/yabai.toml", "4"])
      EventSignals.shared.discardPending()
    }

    @Test func missingFileUsesTheDefaults() {
      DaemonFixture.reset()
      let path = "/nonexistent/yabai-startup.toml"

      let loaded = loadStartupConfig(explicit: path)
      #expect(loaded.path == path)
      #expect(loaded.entries == nil)
      #expect(loaded.notices == ["file '\(path)' does not exist.."])
      #expect(loaded.apply(.settings).failures == 0)
      #expect(Golden.run("config window_gap") == Array("0\n".utf8))
    }

    @Test func aFailingSettingIsCountedAndTheOthersStillRun() throws {
      DaemonFixture.reset()
      // NOTE: A tab bar font without a size passes the check and fails when it is applied (TabBar.setFont).
      let path = try writeStartupFile("[config]\ntab_bar_font = \"bogus\"\nwindow_gap = 4\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      let loaded = loadStartupConfig(explicit: path)
      #expect(loaded.entries != nil)
      #expect(loaded.apply(.settings).failures == 0)
      #expect(loaded.apply(.managerSettings).failures == 1)
      #expect(Golden.run("config window_gap") == Array("4\n".utf8))
      #expect(Golden.run("config tab_bar_font") == Array("system:12\n".utf8))
    }

    @Test func exampleAppliesWithoutAFailure() throws {
      DaemonFixture.reset()
      let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "examples/yabai.toml")
      _ = Headless.drain()

      let loaded = loadStartupConfig(explicit: url.path)
      #expect(loaded.entries?.isEmpty == false)
      for step in ConfigStep.allCases {
        #expect(loaded.apply(step).failures == 0)
      }
    }
  }
}
