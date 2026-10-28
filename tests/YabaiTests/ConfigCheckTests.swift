import Foundation
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: `config --check [<file>]` (IPC/ConfigCheck.swift) reads a yabai.toml, lowers it and checks each setting without
// applying it (configFileReport). The handler is tested with files in the temporary directory. The suite is
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
      #expect(Golden.run("config --check \(path)") == Array("\(fixtureReport(path))".utf8))
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

      let check = try readConfigFile(explicit: path)
      #expect(check.path == path)
      #expect(check.report == configFileReport(path: path, source: fixtureToml))
    }

    // NOTE: a FIFO with no writer would block the read forever, so only a regular file is read.
    @Test func checkOfAFIFOIsRefusedWithoutReadingIt() throws {
      DaemonFixture.reset()
      let path = FileManager.default.temporaryDirectory.appendingPathComponent(
        "yabai-\(UUID().uuidString).toml"
      ).path
      try #require(mkfifo(path, 0o600) == 0)
      defer { unlink(path) }

      #expect(
        Golden.run("config --check \(path)")
          == Array("cannot read config file '\(path)'\n".utf8))
      #expect(throws: ConfigFileReadError.unreadable(path)) {
        try readConfigFile(ConfigFileChoice(chosen: path, ignored: []))
      }
    }

    @Test func checkWithTwoFilesIsAFailure() {
      DaemonFixture.reset()
      #expect(
        Golden.run("config --check a b")
          == Array(
            "unknown argument 'b' given to command '--check' for domain 'config'\n".utf8))
    }

    @Test func checkIsAcceptedByTheCheckOfAMessage() {
      DaemonFixture.reset()
      var message = Golden.encode("config --check /some/file")
      #expect(checkMessage(&message).failures.isEmpty)
    }

    @Test func exampleFileChecksClean() throws {
      let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "examples/yabai.toml")
      let source = try String(contentsOf: url, encoding: .utf8)
      let report = configFileReport(path: "examples/yabai.toml", source: source)
      #expect(report == ConfigCheckReport(text: "checked 23 settings, 0 failures\n", failures: 0))
    }
  }
}
