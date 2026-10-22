import Foundation
import Testing
import YabaiCore
@testable import Yabai

//
// NOTE: `config --check` (IPC/ConfigCheck.swift) reads a yabairc and parses its `yabai -m` messages without applying them.
// The report of a script is tested on its text; the handler is tested with files in the temporary directory. The suite is
// DaemonState: the handler runs through handleMessage, and the check must leave the managers and the config as they are.
//

/// A yabairc with one bad value (line 2), one dynamic line (line 3) and one valid line (line 4).
private let fixtureScript = """
    #!/bin/sh
    yabai -m config window_gap x
    yabai -m config window_gap $GAP
    yabai -m config window_gap 10

    """

/// The report of `fixtureScript` read from `path`.
private func fixtureReport(_ path: String) -> String
{
    """
    \(path):2: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer
    note: \(path):3: not checked: dynamic shell
    checked 2 commands, 1 failures, 1 skipped

    """
}

/// Writes `script` to a new file in the temporary directory and returns its path; the caller removes it.
private func writeScriptFile(_ script: String) throws -> String
{
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("yabairc-\(UUID().uuidString)").path
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

extension DaemonState
{
    @Suite
    @WM struct ConfigCheckTests
    {
        @Test func reportOfTheFixtureIsExact()
        {
            let report = configCheckReport(path: "/fixture/yabairc", script: fixtureScript)
            #expect(report == ConfigCheckReport(text: fixtureReport("/fixture/yabairc"), failures: 1))
        }

        @Test func reportOfAValidScriptHasNoFailures()
        {
            let report = configCheckReport(path: "/fixture/yabairc", script: "yabai -m config window_gap 10\n")
            #expect(report == ConfigCheckReport(text: "checked 1 commands, 0 failures, 0 skipped\n", failures: 0))
        }

        @Test(arguments: [
            ("yabai -m window --focus west\n", "note: /fixture/yabairc:1: not checked: window commands act on the current session\n"
                + "checked 0 commands, 0 failures, 1 skipped\n"),
            ("sudo yabai --load-sa\n", "note: /fixture/yabairc:1: not checked: not a message\n"
                + "checked 0 commands, 0 failures, 1 skipped\n"),
        ])
        func domainsThatActOnTheSessionAreNotChecked(_ row: (script: String, text: String))
        {
            let report = configCheckReport(path: "/fixture/yabairc", script: row.script)
            #expect(report == ConfigCheckReport(text: row.text, failures: 0))
        }

        @Test func checkChangesNothing()
        {
            DaemonFixture.reset()
            let before = Golden.run("config window_gap")
            _ = configCheckReport(path: "/fixture/yabairc", script: fixtureScript)
            #expect(Golden.run("config window_gap") == before)
        }

        @Test func checkFileOfTheHandlerIsReadAndReported() throws
        {
            DaemonFixture.reset()
            let path = try writeScriptFile(fixtureScript)
            defer { try? FileManager.default.removeItem(atPath: path) }

            // NOTE: A failure response is the failure byte, then the whole report.
            #expect(Golden.run("config --check \(path)") == Array("\u{07}\(fixtureReport(path))".utf8))
        }

        @Test func checkWithoutAFileReadsTheConfigFileOfTheDaemon() throws
        {
            DaemonFixture.reset()
            let path = try writeScriptFile("yabai -m config window_gap 10\n")
            defer {
                try? FileManager.default.removeItem(atPath: path)
                WindowManager.shared.explicitConfigFile = nil
            }

            WindowManager.shared.explicitConfigFile = path
            #expect(Golden.run("config --check") == Array("checked 1 commands, 0 failures, 0 skipped\n".utf8))
        }

        @Test func checkWithTwoFilesIsAFailure()
        {
            DaemonFixture.reset()
            #expect(Golden.run("config --check a b") == Array("\u{07}unknown argument 'b' given to command '--check' for domain 'config'\n".utf8))
        }

        @Test func checkIsAcceptedByTheCheckOfAMessage()
        {
            DaemonFixture.reset()
            var message = Golden.encode("config --check /some/file")
            #expect(checkMessage(&message).failures.isEmpty)
        }
    }
}
