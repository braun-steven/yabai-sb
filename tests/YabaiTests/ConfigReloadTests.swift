import Foundation
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: `config --reload [<file>]` (IPC/ConfigReload.swift) checks a yabai.toml as `config --check` does, then reconciles it
// with the running state for each ConfigStep (ConfigLoader.reconcile). Nothing is run as a shell script: the headless log
// records no config file. `config --overrides` lists what the running state changed since the last load
// (configOverrideLines). The suite is DaemonState: the reload changes the managers and the config, which the fixture resets.
// The files are written to the temporary directory.
//

/// Writes `text` to a new yabai.toml in the temporary directory and returns its path; the caller removes it.
private func writeReloadFile(_ text: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabai-reload-\(UUID().uuidString).toml"
  ).path
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

/// A file with a window gap and a rule: the state that a reload puts back.
private let reloadText = """
  [config]
  window_gap = 10

  [[rule]]
  app = "^Keep$"
  manage = false

  """

/// The response of a successful reload of `path` that changed `changes` settings.
private func reloadedText(_ path: String, changes: Int) -> [UInt8] {
  Array("reloaded \(path): \(changes) changes\n".utf8)
}

extension DaemonState {
  @Suite
  @WM struct ConfigReloadTests {
    @Test func failureChangesNothing() throws {
      DaemonFixture.reset()
      let text = "[config]\nwindow_gap = \"x\"\n"
      let path = try writeReloadFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config window_gap 5") == [])
      #expect(Golden.run("rule --add label=keep app=Keep manage=off") == [])
      _ = Headless.drain()

      let report = configFileReport(path: path, source: text)
      #expect(Golden.run("config --reload \(path)") == Array("\u{07}\(report.text)".utf8))

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(WindowManager.shared.rules.count == 1)
      #expect(Headless.drain().configEntries.isEmpty)
    }

    @Test func reloadAppliesTheFileAndPutsRuntimeChangesBack() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile(reloadText)
      defer { try? FileManager.default.removeItem(atPath: path) }
      // The first load sets the gap (1 change) and the rule list (its replacement, then its one rule: 2 changes).
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 3))

      #expect(Golden.run("config window_gap 5") == [])
      #expect(Golden.run("rule --add label=extra app=Extra manage=off") == [])
      _ = Headless.drain()

      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 3))
      #expect(Golden.run("config window_gap") == Array("10\n".utf8))
      #expect(WindowManager.shared.rules.count == 1)
    }

    @Test func reloadOfAnUnchangedFileChangesAndRecordsNothing() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile(reloadText)
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 3))
      _ = Headless.drain()

      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 0))
      #expect(Headless.drain().configEntries.isEmpty)
    }

    @Test func reloadPutsABackRuntimeTabBarFont() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile("[config]\ntab_bar_font = \"Helvetica:14\"\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 1))

      #expect(Golden.run("config tab_bar_font system:12") == [])
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 1))
      #expect(Golden.run("config tab_bar_font") == Array("Helvetica:14\n".utf8))
    }

    @Test func reloadWithoutAFileReadsTheFileOfTheDaemon() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile(reloadText)
      defer {
        try? FileManager.default.removeItem(atPath: path)
        WindowManager.shared.explicitConfigFile = nil
      }
      WindowManager.shared.explicitConfigFile = path

      #expect(Golden.run("config --reload") == reloadedText(path, changes: 3))
    }

    @Test func missingFileIsAFailureThatChangesNothing() {
      DaemonFixture.reset()
      #expect(Golden.run("config window_gap 5") == [])
      _ = Headless.drain()

      #expect(
        Golden.run("config --reload /nonexistent/yabai.toml")
          == Array("\u{07}cannot read config file '/nonexistent/yabai.toml'\n".utf8))
      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(Headless.drain().configEntries.isEmpty)
    }

    @Test func twoFilesIsAFailure() {
      DaemonFixture.reset()
      #expect(
        Golden.run("config --reload a b")
          == Array(
            "\u{07}unknown argument 'b' given to command '--reload' for domain 'config'\n".utf8))
    }

    @Test func checkOfAReloadIsNotNoted() {
      var message = Golden.encode("config --reload /some/file.toml")
      let check = checkMessage(&message)
      #expect(check.failures.isEmpty)
      #expect(check.notes.isEmpty)
    }

    @Test func checkOfAReloadWithTwoFilesIsAFailure() {
      var message = Golden.encode("config --reload a b")
      #expect(
        checkMessage(&message).failures == [
          "unknown argument 'b' given to command '--reload' for domain 'config'\n"
        ])
    }

    @Test func overridesAreEmptyWhenNothingIsSet() {
      DaemonFixture.reset()
      #expect(Golden.run("config --overrides") == [])
    }

    @Test func aRuntimeOptionIsListedUntilTheReloadPutsTheFileBack() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile(reloadText)
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 3))

      #expect(Golden.run("config window_gap 30") == [])
      #expect(Golden.run("config --overrides") == Array("window_gap 30 (file: 10)\n".utf8))

      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 1))
      #expect(Golden.run("config window_gap") == Array("10\n".utf8))
      #expect(Golden.run("config --overrides") == [])
    }

    @Test func rulesAndSignalsAreListedWhenTheyDifferFromTheFile() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile("[config]\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 0))

      #expect(Golden.run("rule --add label=keep app=Keep manage=off") == [])
      #expect(Golden.run("config --overrides") == Array("rules: overridden\n".utf8))

      #expect(Golden.run("signal --add label=keep event=window_created action=true") == [])
      #expect(
        Golden.run("config --overrides") == Array("rules: overridden\nsignals: overridden\n".utf8))
    }

    @Test func overridesWithoutAFileCompareWithTheDefaults() {
      DaemonFixture.reset()
      // NOTE: The startup captures the defaults at its settings step, even without a file (LoadedConfig.apply).
      LoadedConfig(path: nil, document: nil, log: [], notices: []).apply(.settings)

      #expect(Golden.run("config window_gap 30") == [])
      #expect(Golden.run("config --overrides") == Array("window_gap 30 (file: 0)\n".utf8))
    }

    @Test func reloadPushesConfigLoadedWithItsEnvironment() throws {
      DaemonFixture.reset()
      // NOTE: The signal is in the file: a reload replaces the signal list with the file's, so a runtime signal would go.
      // A push needs a signal of the type (or a subscriber). The action is not run: the test never flushes.
      let text = "[[signal]]\nevent = \"config_loaded\"\naction = \"true\"\n"
      let path = try writeReloadFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      let outcome = reloadConfig(configFileCheck(path: path, source: text))
      guard case .reloaded(_, let result) = outcome else {
        Issue.record("the reload of a valid file failed")
        return
      }
      // The signal list is replaced (1) and its one signal runs as a message (1).
      #expect(result.changes == 2)

      let pushed = EventSignals.shared.pending
      #expect(pushed.map(\.type) == [.configLoaded])
      #expect(
        pushed.first?.arguments.map { $0.name } == ["YABAI_CONFIG_FILE", "YABAI_CONFIG_CHANGES"])
      #expect(pushed.first?.arguments.map { $0.value } == [path, "2"])
      EventSignals.shared.discardPending()
    }

    @Test func failedCheckPushesNoConfigLoaded() throws {
      DaemonFixture.reset()
      #expect(Golden.run("signal --add event=config_loaded action=true") == [])
      let text = "[config]\nwindow_gap = \"x\"\n"
      let path = try writeReloadFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      guard
        case .failed = reloadConfig(configFileCheck(path: path, source: text))
      else {
        Issue.record("the check of an invalid file passed")
        return
      }
      #expect(EventSignals.shared.pending.isEmpty)
    }

    @Test func usedUpOneShotRuleIsNotAddedAgain() throws {
      DaemonFixture.reset()
      let text = reloadText + "[[rule]]\napp = \"^Once$\"\nmanage = false\none_shot = true\n"
      let path = try writeReloadFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 4))

      // NOTE: As a window that the one-shot rule matched would: mark it, then remove it.
      let wm = WindowManager.shared
      for index in wm.rules.indices where wm.rules[index].oneShot { wm.rules[index].matched = true }
      wm.removeOneShotRules()
      #expect(wm.rules.count == 1)

      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 0))
      #expect(wm.rules.count == 1)
      #expect(Golden.run("config --overrides") == [])
    }

    @Test func changedOneShotRuleIsAddedAgain() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile(
        reloadText + "[[rule]]\napp = \"^Once$\"\nmanage = false\none_shot = true\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 4))
      let wm = WindowManager.shared
      for index in wm.rules.indices where wm.rules[index].oneShot { wm.rules[index].matched = true }
      wm.removeOneShotRules()

      try (reloadText + "[[rule]]\napp = \"^Twice$\"\nmanage = false\none_shot = true\n")
        .write(toFile: path, atomically: true, encoding: .utf8)
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 3))
      #expect(wm.rules.map(\.oneShot) == [false, true])
    }

    @Test func runtimeFailureKeepsSuccessfulRulesAndTheChangedFileAsApplied() throws {
      DaemonFixture.reset()
      let path = try writeReloadFile(reloadText)
      ConfigLoader.shared.filePath = path
      defer { try? FileManager.default.removeItem(atPath: path) }
      #expect(Golden.run("config --reload \(path)") == reloadedText(path, changes: 3))
      #expect(WindowManager.shared.rules.map { $0.app?.text } == ["^Keep$"])
      _ = Headless.drain()
      EventSignals.shared.discardPending()

      let changed = """
        [config]
        window_gap = 11

        [[rule]]
        app = "^Near$"
        manage = false

        [[rule]]
        app = "^Far$"
        space = 99
        """
      try changed.write(toFile: path, atomically: true, encoding: .utf8)
      let check = configFileCheck(path: path, source: changed)
      #expect(check.report.failures == 0)

      let failure = "rule[1]: could not locate space with mission-control index '99'."
      #expect(
        Golden.run("config --reload \(path)")
          == Array("\u{07}reloaded \(path): 3 changes, 1 failures\n\(failure)\n".utf8))
      #expect(Golden.run("config window_gap") == Array("11\n".utf8))
      #expect(WindowManager.shared.rules.count == 1)
      #expect(WindowManager.shared.rules.first?.app?.text == "^Near$")
      #expect(WindowManager.shared.rules.first?.effects.manage == false)
      #expect(ConfigLoader.shared.applied == check.document)
      #expect(ConfigLoader.shared.lastContents == Array(changed.utf8))

      let appliedEntries = Headless.drain().configEntries
      #expect(
        appliedEntries.map(\.arguments) == [
          ["config", "window_gap", "11"],
          ["rule", "--add", "app=^Near$", "manage=off"],
          ["rule", "--add", "app=^Far$", "space=99"],
        ])
      let pendingSignalCount = EventSignals.shared.pending.count

      // fileChanged is the watcher event path; equal text must not try the failed rule again.
      ConfigWatcher.shared.fileChanged()

      #expect(Headless.drain().configEntries.isEmpty)
      #expect(EventSignals.shared.pending.count == pendingSignalCount)
      #expect(WindowManager.shared.rules.first?.app?.text == "^Near$")
      #expect(Golden.run("config window_gap") == Array("11\n".utf8))
    }

    @Test func overridesTakeNoArgument() {
      DaemonFixture.reset()
      #expect(
        Golden.run("config --overrides a")
          == Array(
            "\u{07}unknown argument 'a' given to command '--overrides' for domain 'config'\n".utf8))
      var message = Golden.encode("config --overrides a")
      #expect(checkMessage(&message).failures.count == 1)
    }
  }
}
