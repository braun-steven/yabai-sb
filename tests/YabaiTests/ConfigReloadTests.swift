import Foundation
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: `config --reload [<file>]` (IPC/ConfigReload.swift) checks the file, then resets the config, removes the rules and
// signals and runs the file again. The run is recorded in the headless log (Headless.configFiles) instead of spawning the
// shell. The suite is DaemonState: the reload changes the managers and the config, which the fixture resets.
//

/// Writes `script` to a new file in the temporary directory and returns its path; the caller removes it.
private func writeReloadScript(_ script: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabairc-reload-\(UUID().uuidString)"
  ).path
  try script.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

/// A yabairc with one bad value (line 1), which the check reports.
private let badReloadScript = "yabai -m config window_gap x\n"

/// A yabairc that sets one value.
private let goodReloadScript = "yabai -m config window_gap 10\n"

/// The response of a successful reload of `path`.
private func reloadedText(_ path: String) -> [UInt8] {
  Array("reloaded \(path)\n".utf8)
}

extension DaemonState {
  @Suite
  @WM struct ConfigReloadTests {
    /// Sets a window gap, a rule and a signal, which a successful reload resets or removes.
    @WM private static func setSomeState() {
      #expect(Golden.run("config window_gap 5") == [])
      #expect(Golden.run("rule --add label=keep app=Keep manage=off") == [])
      #expect(Golden.run("signal --add label=keep event=window_created action=true") == [])
    }

    @Test func failureChangesNothing() throws {
      DaemonFixture.reset()
      let path = try writeReloadScript(badReloadScript)
      defer { try? FileManager.default.removeItem(atPath: path) }
      Self.setSomeState()
      _ = Headless.drain()

      let report = configCheckReport(path: path, script: badReloadScript)
      #expect(Golden.run("config --reload \(path)") == Array("\u{07}\(report.text)".utf8))

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(WindowManager.shared.rules.count == 1)
      #expect(EventSignals.shared.table.list().count == 1)
      #expect(Headless.drain().configFiles.isEmpty)
    }

    @Test func successResetsTheConfigRemovesRulesAndSignalsAndRunsTheFile() throws {
      DaemonFixture.reset()
      let path = try writeReloadScript(goodReloadScript)
      defer { try? FileManager.default.removeItem(atPath: path) }
      Self.setSomeState()
      #expect(Golden.run("config window_border on") == [])
      #expect(Golden.run("config layout float") == [])
      #expect(Golden.run("config focus_follows_mouse autofocus") == [])
      _ = Headless.drain()

      #expect(Golden.run("config --reload \(path)") == reloadedText(path))

      #expect(Golden.run("config window_gap") == Array("0\n".utf8))
      #expect(Golden.run("config window_border") == Array("off\n".utf8))
      #expect(Golden.run("config layout") == Array("tree\n".utf8))
      #expect(Golden.run("config focus_follows_mouse") == Array("disabled\n".utf8))
      #expect(WindowManager.shared.rules.isEmpty)
      #expect(EventSignals.shared.table.list().isEmpty)
      #expect(Headless.drain().configFiles == [path])
    }

    @Test func reloadWithoutAFileRunsTheConfigFileOfTheDaemon() throws {
      DaemonFixture.reset()
      let path = try writeReloadScript(goodReloadScript)
      defer {
        try? FileManager.default.removeItem(atPath: path)
        WindowManager.shared.explicitConfigFile = nil
      }
      WindowManager.shared.explicitConfigFile = path
      _ = Headless.drain()

      #expect(Golden.run("config --reload") == reloadedText(path))
      #expect(Headless.drain().configFiles == [path])
    }

    @Test func reloadTwiceRunsTheFileTwiceAndLeavesNoRules() throws {
      DaemonFixture.reset()
      let path = try writeReloadScript(goodReloadScript)
      defer { try? FileManager.default.removeItem(atPath: path) }
      _ = Headless.drain()

      #expect(Golden.run("rule --add label=keep app=Keep manage=off") == [])
      #expect(Golden.run("config --reload \(path)") == reloadedText(path))
      #expect(Golden.run("rule --add label=keep app=Keep manage=off") == [])
      #expect(Golden.run("config --reload \(path)") == reloadedText(path))

      #expect(WindowManager.shared.rules.isEmpty)
      #expect(Headless.drain().configFiles == [path, path])
    }

    @Test func missingFileIsAFailureThatChangesNothing() {
      DaemonFixture.reset()
      Self.setSomeState()
      _ = Headless.drain()

      #expect(
        Golden.run("config --reload /nonexistent/yabairc")
          == Array("\u{07}cannot read config file '/nonexistent/yabairc'\n".utf8))
      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(Headless.drain().configFiles.isEmpty)
    }

    @Test func twoFilesIsAFailure() {
      DaemonFixture.reset()
      #expect(
        Golden.run("config --reload a b")
          == Array(
            "\u{07}unknown argument 'b' given to command '--reload' for domain 'config'\n".utf8))
    }

    @Test func resetRestoresTheTabBarFontDebugOutputAndExternalBar() throws {
      DaemonFixture.reset()
      let path = try writeReloadScript(goodReloadScript)
      defer {
        try? FileManager.default.removeItem(atPath: path)
        Log.verbose.store(false, ordering: .relaxed)
      }
      #expect(Golden.run("config tab_bar_font Helvetica:14") == [])
      #expect(Golden.run("config debug_output on") == [])
      #expect(Golden.run("config external_bar main:40:0") == [])
      #expect(Golden.run("config display_arrangement_order vertical") == [])
      _ = Headless.drain()

      #expect(Golden.run("config --reload \(path)") == reloadedText(path))

      #expect(Golden.run("config tab_bar_font") == Array("system:12\n".utf8))
      #expect(WindowManager.shared.tabBarFont == nil)
      #expect(Log.verbose.load(ordering: .relaxed) == false)
      #expect(Golden.run("config external_bar") == Array("off:0:0\n".utf8))
      #expect(Golden.run("config display_arrangement_order") == Array("default\n".utf8))
    }

    // NOTE: The space layout is set on the config directly: the `config space_layout` command schedules a re-layout on the
    // event loop, which the test must not post.
    @Test func resetClearsSpaceLayouts() throws {
      DaemonFixture.reset()
      let path = try writeReloadScript(goodReloadScript)
      defer { try? FileManager.default.removeItem(atPath: path) }
      Config.current.space.spaceLayoutSpec = "10"

      #expect(Golden.run("config --reload \(path)") == reloadedText(path))
      #expect(Golden.run("config space_layout") == Array("off\n".utf8))
    }

    @Test func checkOfAReloadInTheYabaircIsNoted() {
      let report = configCheckReport(path: "/fixture/yabairc", script: "yabai -m config --reload\n")
      #expect(
        report
          == ConfigCheckReport(
            text:
              "note: /fixture/yabairc:1: reloads the yabairc, which runs it again: a bare config --reload there loops\n"
              + "checked 0 commands, 0 failures, 1 skipped\n",
            failures: 0))
    }

    @Test func checkOfAReloadWithTwoFilesIsAFailure() {
      var message = Golden.encode("config --reload a b")
      #expect(
        checkMessage(&message).failures == [
          "unknown argument 'b' given to command '--reload' for domain 'config'\n"
        ])
    }
  }
}
