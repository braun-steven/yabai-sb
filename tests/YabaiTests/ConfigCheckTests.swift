import Foundation
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: `config --check [<file>]` (IPC/ConfigCheck.swift) reads a yabai.toml, lowers it and checks each setting without
// applying it (configFileReport). `config --reload` still runs a yabairc and checks it with the extractor (configCheckReport),
// so the yabairc report is tested here too. The handler is tested with files in the temporary directory. The suite is
// DaemonState: the handler runs through handleMessage, and the check must leave the managers and the config as they are.
//

/// A yabai.toml with one bad value (line 2) and one valid setting (line 3).
private let fixtureToml = """
  [config]
  window_gap = "x"
  mouse_follows_focus = true

  """

/// The report of `fixtureToml` read from `path`.
private func fixtureReport(_ path: String) -> String {
  """
  \(path):2: config.window_gap: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer
  checked 2 settings, 1 failures

  """
}

/// Writes `text` to a new `.toml` file in the temporary directory and returns its path; the caller removes it.
private func writeTOMLFile(_ text: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabai-\(UUID().uuidString).toml"
  ).path
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

/// A yabairc with one bad value (line 2), one dynamic line (line 3) and one valid line (line 4).
private let fixtureScript = """
  #!/bin/sh
  yabai -m config window_gap x
  yabai -m config window_gap $GAP
  yabai -m config window_gap 10

  """

/// The yabairc report of `fixtureScript` read from `path`.
private func fixtureScriptReport(_ path: String) -> String {
  """
  \(path):2: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer
  note: \(path):3: not checked: dynamic shell
  checked 2 commands, 1 failures, 1 skipped

  """
}

extension DaemonState {
  @Suite
  @WM struct ConfigCheckTests {
    @Test func reportOfTheFixtureIsExact() {
      let report = configFileReport(path: "/fixture/yabai.toml", source: fixtureToml)
      #expect(report == ConfigCheckReport(text: fixtureReport("/fixture/yabai.toml"), failures: 1))
    }

    @Test func reportOfAValidFileHasNoFailures() {
      let report = configFileReport(
        path: "/fixture/yabai.toml", source: "[config]\nwindow_gap = 10\n")
      #expect(
        report == ConfigCheckReport(text: "checked 1 settings, 0 failures\n", failures: 0))
    }

    @Test(arguments: [
      (
        "[config]\nwindow_gapp = 4\n",
        "/fixture/yabai.toml:2: config.window_gapp: unknown option 'window_gapp'\n"
          + "checked 0 settings, 1 failures\n"
      ),
      (
        "[config\nwindow_gap = 10\n",
        "/fixture/yabai.toml:1: Syntax error: invalid key.\n" + "checked 0 settings, 1 failures\n"
      ),
    ])
    func problemsOfTheFileAreReportedWithTheirLine(_ row: (source: String, text: String)) {
      let report = configFileReport(path: "/fixture/yabai.toml", source: row.source)
      #expect(report == ConfigCheckReport(text: row.text, failures: 1))
    }

    @Test func spaceSettingsAreNotCheckedWithoutTheSession() {
      let report = configFileReport(
        path: "/fixture/yabai.toml", source: "[[space]]\nindex = 1\nlabel = \"chat\"\n")
      #expect(
        report
          == ConfigCheckReport(
            text:
              "note: /fixture/yabai.toml:3: space[0].label: not checked: space commands act on the current session\n"
              + "checked 0 settings, 0 failures, 1 not checked\n",
            failures: 0))
    }

    @Test func checkChangesNothing() {
      DaemonFixture.reset()
      let before = Golden.run("config window_gap")
      _ = configFileReport(path: "/fixture/yabai.toml", source: fixtureToml)
      #expect(Golden.run("config window_gap") == before)
    }

    @Test func checkFileOfTheHandlerIsReadAndReported() throws {
      DaemonFixture.reset()
      let path = try writeTOMLFile(fixtureToml)
      defer { try? FileManager.default.removeItem(atPath: path) }

      // NOTE: A failure response is the failure byte, then the whole report.
      #expect(Golden.run("config --check \(path)") == Array("\u{07}\(fixtureReport(path))".utf8))
    }

    @Test func checkWithoutAFileReadsTheFileOfTheDaemon() throws {
      DaemonFixture.reset()
      let path = try writeTOMLFile("[config]\nwindow_gap = 10\n")
      defer {
        try? FileManager.default.removeItem(atPath: path)
        WindowManager.shared.explicitConfigFile = nil
      }

      WindowManager.shared.explicitConfigFile = path
      #expect(Golden.run("config --check") == Array("checked 1 settings, 0 failures\n".utf8))
    }

    @Test func offlineCheckReadsTheFileLikeTheHandler() throws {
      let path = try writeTOMLFile(fixtureToml)
      defer { try? FileManager.default.removeItem(atPath: path) }

      let (checkedPath, report) = try readConfigFile("--check", explicit: path)
      #expect(checkedPath == path)
      #expect(report == configFileReport(path: path, source: fixtureToml))
    }

    @Test func reloadRefusesATOMLFile() throws {
      DaemonFixture.reset()
      let path = try writeTOMLFile(fixtureToml)
      defer { try? FileManager.default.removeItem(atPath: path) }

      #expect(
        Golden.run("config --reload \(path)")
          == Array(
            "\u{07}config --reload does not read TOML files yet; '\(path)' is a yabai.toml\n".utf8))
    }

    @Test func checkWithTwoFilesIsAFailure() {
      DaemonFixture.reset()
      #expect(
        Golden.run("config --check a b")
          == Array(
            "\u{07}unknown argument 'b' given to command '--check' for domain 'config'\n".utf8))
    }

    @Test func checkIsAcceptedByTheCheckOfAMessage() {
      DaemonFixture.reset()
      var message = Golden.encode("config --check /some/file")
      #expect(checkMessage(&message).failures.isEmpty)
    }

    //
    // NOTE: The yabairc report, used by config --reload until C3.3 replaces the reload.
    //

    @Test func yabaircReportOfTheFixtureIsExact() {
      let report = configCheckReport(path: "/fixture/yabairc", script: fixtureScript)
      #expect(
        report == ConfigCheckReport(text: fixtureScriptReport("/fixture/yabairc"), failures: 1))
    }

    @Test func yabaircReportOfAValidScriptHasNoFailures() {
      let report = configCheckReport(
        path: "/fixture/yabairc", script: "yabai -m config window_gap 10\n")
      #expect(
        report
          == ConfigCheckReport(text: "checked 1 commands, 0 failures, 0 skipped\n", failures: 0))
    }

    @Test(arguments: [
      (
        "yabai -m window --focus west\n",
        "note: /fixture/yabairc:1: not checked: window commands act on the current session\n"
          + "checked 0 commands, 0 failures, 1 skipped\n"
      ),
      (
        "sudo yabai --load-sa\n",
        "note: /fixture/yabairc:1: not checked: not a message\n"
          + "checked 0 commands, 0 failures, 1 skipped\n"
      ),
    ])
    func yabaircDomainsThatActOnTheSessionAreNotChecked(_ row: (script: String, text: String)) {
      let report = configCheckReport(path: "/fixture/yabairc", script: row.script)
      #expect(report == ConfigCheckReport(text: row.text, failures: 0))
    }
  }
}
