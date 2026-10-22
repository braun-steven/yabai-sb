import Foundation
import YabaiCore

//
// NOTE: `config --check [<file>]` reads a yabairc, extracts its `yabai -m` messages (extractYabaiCommands) and checks each
// one with checkMessage. Nothing is applied and no command runs: the file is read and its messages are only parsed.
// `config --reload [<file>]` (IPC/ConfigReload.swift) starts with the same checkConfigFile.
//

/// The report of `config --check`. `text` ends with a newline; `failures` counts the failure responses in it.
struct ConfigCheckReport: Equatable
{
    let text: String
    let failures: Int
}

/// The report of the yabairc `script`, read from `path`: a `<path>:<line>: <text>` line for each line of each failure, a
/// `note: <path>:<line>: …` line for each command that is not checked, and the summary
/// `checked N commands, M failures, K skipped`. A command is checked when its message was parsed. It is skipped when the
/// extractor did not extract it (`not checked: dynamic shell` and the like) or when checkMessage reports a note for it
/// (domains that act on the session: not parsed). M counts the failure responses, one per failing command; a failure that
/// lists several problems prints one line each. Reads nothing and changes nothing: the file is the caller's to read.
@WM func configCheckReport(path: String, script: String) -> ConfigCheckReport
{
    var lines: [String] = []
    var checked = 0
    var skipped = 0
    var failures = 0

    for command in extractYabaiCommands(script) {
        guard let arguments = command.arguments else {
            skipped += 1
            lines.append("note: \(path):\(command.line): not checked: \(command.skipped ?? "unknown")")
            continue
        }

        // NOTE: The daemon reads a message without its length prefix (MessageLoop.readMessage), so the prefix is dropped.
        let encoded = ClientMessage.encode(arguments.map { Array($0.utf8) })
        var message = Message(Array(encoded.dropFirst(MemoryLayout<Int32>.size)))
        let check = checkMessage(&message)

        for failure in check.failures {
            failures += 1
            for line in failureLines(failure) { lines.append("\(path):\(command.line): \(line)") }
        }

        if check.notes.isEmpty {
            checked += 1
        } else {
            skipped += 1
            for note in check.notes { lines.append("note: \(path):\(command.line): \(note)") }
        }
    }

    lines.append("checked \(checked) commands, \(failures) failures, \(skipped) skipped")
    return ConfigCheckReport(text: lines.map { $0 + "\n" }.joined(), failures: failures)
}

/// The lines of a failure text: its trailing newline dropped, then one line per newline left in it.
private func failureLines(_ failure: String) -> [String]
{
    var bytes = Array(failure.utf8)
    if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
    return bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
}

/// The file argument of `config --check [<file>]` or `config --reload [<file>]` (`command` names it in a failure): none
/// (nil), or one token. A further token is a failure.
@WM func configFileArgument(_ command: String, _ message: inout Message) throws(CommandError) -> String?
{
    let file = message.next()
    let extra = message.next()
    if extra.isValid {
        throw CommandError("unknown argument '\(extra)' given to command '\(command)' for domain 'config'\n")
    }

    return file.isValid ? file.string : nil
}

/// Reads and checks the file of `config --check|--reload [<file>]` (`command`): the file given, else the file the daemon
/// loads (the -c path or the first existing candidate). Returns that path and the report. Nothing is applied.
@WM func checkConfigFile(_ command: String, _ message: inout Message) throws(CommandError) -> (path: String, report: ConfigCheckReport)
{
    let explicit = try configFileArgument(command, &message) ?? WindowManager.shared.explicitConfigFile
    guard let path = Daemon.configFileChoice(explicit: explicit)?.chosen else {
        throw CommandError("could not locate config file\n")
    }

    guard let data = FileManager.default.contents(atPath: path) else {
        throw CommandError("cannot read config file '\(path)'\n")
    }

    return (path, configCheckReport(path: path, script: String(decoding: data, as: UTF8.self)))
}

/// Writes `config --check [<file>]`: the report, and a failure response when the report has a failure.
@WM func handleConfigCheck(_ rsp: inout Response, _ message: inout Message) throws(CommandError)
{
    let (_, report) = try checkConfigFile("--check", &message)
    let text = ResponseText(stringLiteral: report.text)
    if report.failures > 0 {
        rsp.fail(CommandError(text))
    } else {
        rsp.write(text)
    }
}
