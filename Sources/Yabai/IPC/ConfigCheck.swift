import Foundation
import YabaiCore

//
// NOTE: `config --check [<file>]` and `yabai --check-config [<file>]` read a yabai.toml (configFileReport): the file is
// decoded (ConfigDocument.decode), lowered to the messages the daemon runs (lowered(locator:)) and each message goes
// through checkMessage. Nothing is applied and no command runs. The offline check runs the same code on the @WM queue
// without a daemon (checkConfigOffline).
//
// NOTE: `config --reload [<file>]` (IPC/ConfigReload.swift) still runs a yabairc, so its check is the extractor check
// (configCheckReport) until C3.3 replaces the reload; a TOML file is refused there (readConfigFile).
//

/// The report of a check. `text` ends with a newline; `failures` counts the failure responses in it.
struct ConfigCheckReport: Equatable {
  let text: String
  let failures: Int
}

/// The check of a yabai.toml: its report (see configFileReport), and the messages of its settings in apply order. The
/// entries are empty when the file does not decode. A file with a failure keeps its entries; the caller decides.
struct ConfigFileCheck {
  let report: ConfigCheckReport
  let entries: [ConfigEntry]
}

/// The report of a yabai.toml read from `path`; `source` is its text. The first lines are the problems of the file, if
/// it does not decode, and then one line for each failure of each setting, in apply order:
/// `<path>:<line>: <keyPath>: <message>`. A message can span several lines, and each line gets the prefix. A setting that
/// checkMessage does not cover (the space domain acts on the session) is a `note:` line and is counted as not checked.
/// The summary is `checked N settings, M failures`, with `, K not checked` when K is not zero. A file that does not decode
/// checks nothing, so its summary has `checked 0 settings`. Reads and changes nothing: the text is the caller's to read.
@WM func configFileReport(path: String, source: String) -> ConfigCheckReport {
  configFileCheck(path: path, source: source).report
}

/// The check of a yabai.toml (see ConfigFileCheck): configFileReport, with the entries that the startup applies.
@WM func configFileCheck(path: String, source: String) -> ConfigFileCheck {
  var lines: [String] = []
  var checked = 0
  var notChecked = 0
  var failures = 0

  let document: ConfigDocument
  do {
    document = try ConfigDocument.decode(source)
  } catch {
    for problem in error.errors {
      failures += 1
      let prefix = linePrefix(path, problem.line, problem.keyPath)
      for line in failureLines(problem.message) { lines.append(prefix + line) }
    }
    let report = withSummary(lines, checked: 0, notChecked: 0, failures: failures)
    return ConfigFileCheck(report: report, entries: [])
  }

  let entries = document.lowered(locator: TOMLKeyLocator(source: source))
  for entry in entries {
    let check = checkArguments(entry.arguments)
    let prefix = linePrefix(path, entry.line, entry.keyPath)

    for failure in check.failures {
      failures += 1
      for line in failureLines(failure) { lines.append(prefix + line) }
    }

    if check.notes.isEmpty {
      checked += 1
    } else {
      notChecked += 1
      for note in check.notes { lines.append("note: " + prefix + note) }
    }
  }

  let report = withSummary(lines, checked: checked, notChecked: notChecked, failures: failures)
  return ConfigFileCheck(report: report, entries: entries)
}

/// The report with its summary line appended.
private func withSummary(_ lines: [String], checked: Int, notChecked: Int, failures: Int)
  -> ConfigCheckReport
{
  var summary = "checked \(checked) settings, \(failures) failures"
  if notChecked > 0 { summary += ", \(notChecked) not checked" }
  let all = lines + [summary]
  return ConfigCheckReport(text: all.map { $0 + "\n" }.joined(), failures: failures)
}

/// The start of a report line about `keyPath` at `line`: `<path>:<line>: <keyPath>: `, without the parts that are unknown.
private func linePrefix(_ path: String, _ line: Int?, _ keyPath: String) -> String {
  var prefix = path
  if let line { prefix += ":\(line)" }
  prefix += ":"
  if !keyPath.isEmpty { prefix += " \(keyPath):" }
  return prefix + " "
}

/// The message of a list of words, as the daemon reads it: the words as `yabai -m` sends them, without the length prefix
/// (MessageLoop.readMessage). The startup runs its messages from it (ConfigLoader.swift), and the check reads them.
@WM func configMessage(_ arguments: [String]) -> Message {
  let encoded = ClientMessage.encode(arguments.map { Array($0.utf8) })
  return Message(Array(encoded.dropFirst(MemoryLayout<Int32>.size)))
}

/// Runs the words of one message through checkMessage, as the daemon would read them.
@WM private func checkArguments(_ arguments: [String]) -> MessageCheck {
  var message = configMessage(arguments)
  return checkMessage(&message)
}

//
// NOTE: The yabairc report (used only by config --reload until C3.3). Its lines are the `yabai -m` messages of the script.
//

/// The report of the yabairc `script`, read from `path`: a `<path>:<line>: <text>` line for each line of each failure, a
/// `note: <path>:<line>: …` line for each command that is not checked, and the summary
/// `checked N commands, M failures, K skipped`. A command is checked when its message was parsed. It is skipped when the
/// extractor did not extract it (`not checked: dynamic shell` and the like) or when checkMessage reports a note for it
/// (domains that act on the session: not parsed). M counts the failure responses, one per failing command; a failure that
/// lists several problems prints one line each. Reads nothing and changes nothing: the file is the caller's to read.
@WM func configCheckReport(path: String, script: String) -> ConfigCheckReport {
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

    let check = checkArguments(arguments)

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
private func failureLines(_ failure: String) -> [String] {
  var bytes = Array(failure.utf8)
  if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
  return bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map {
    String(decoding: $0, as: UTF8.self)
  }
}

/// The file argument of `config --check [<file>]` or `config --reload [<file>]` (`command` names it in a failure): none
/// (nil), or one token. A further token is a failure.
@WM func configFileArgument(_ command: String, _ message: inout Message) throws(CommandError)
  -> String?
{
  let file = message.next()
  let extra = message.next()
  if extra.isValid {
    throw CommandError(
      "unknown argument '\(extra)' given to command '\(command)' for domain 'config'\n")
  }

  return file.isValid ? file.string : nil
}

/// Reads the file of `config --check|--reload [<file>]` (`command`) for a message: the file given, else the file the
/// daemon loads. Returns that path and the report. Nothing is applied.
@WM func checkConfigFile(_ command: String, _ message: inout Message) throws(CommandError) -> (
  path: String, report: ConfigCheckReport
) {
  let explicit =
    try configFileArgument(command, &message) ?? WindowManager.shared.explicitConfigFile
  return try readConfigFile(command, explicit: explicit)
}

/// Reads and checks the file of `command` (`--check` or `--reload`): `explicit` (the -c path or a file argument) when
/// given, else the file that the command loads. `--check` loads the yabai.toml search (Daemon.configFile); `--reload`
/// runs the yabairc search (Daemon.configFileChoice), and a TOML file is refused there, as it cannot be run yet.
@WM func readConfigFile(_ command: String, explicit: String?) throws(CommandError) -> (
  path: String, report: ConfigCheckReport
) {
  if command == "--check" {
    guard let path = Daemon.configFile(explicit: explicit)?.chosen else {
      throw CommandError("could not locate config file\n")
    }
    let text = try readConfigText(path)
    return (path, configFileReport(path: path, source: text))
  }

  guard let path = Daemon.configFileChoice(explicit: explicit)?.chosen else {
    throw CommandError("could not locate config file\n")
  }
  if ConfigFileSearch.isTOML(path) {
    throw CommandError("config --reload does not read TOML files yet; '\(path)' is a yabai.toml\n")
  }
  let text = try readConfigText(path)
  return (path, configCheckReport(path: path, script: text))
}

/// The text of a config file; a file that cannot be read is a failure.
private func readConfigText(_ path: String) throws(CommandError) -> String {
  guard let data = FileManager.default.contents(atPath: path) else {
    throw CommandError("cannot read config file '\(path)'\n")
  }
  return String(decoding: data, as: UTF8.self)
}

/// Writes `config --check [<file>]`: the report, and a failure response when the report has a failure.
@WM func handleConfigCheck(_ rsp: inout Response, _ message: inout Message) throws(CommandError) {
  let (_, report) = try checkConfigFile("--check", &message)
  let text = ResponseText(stringLiteral: report.text)
  if report.failures > 0 {
    rsp.fail(CommandError(text))
  } else {
    rsp.write(text)
  }
}

/// `yabai --check-config [<file>]`: checks a yabai.toml as `config --check` does, without a running daemon, and returns the
/// exit status. The report goes to stdout, or to stderr when it has a failure; a file that cannot be read or found fails.
/// Called through WM.sync from main.swift, with no window server (the managers are only read for the rules' labels).
@WM func checkConfigOffline(_ file: String?) -> Int32 {
  do {
    let (_, report) = try readConfigFile("--check", explicit: file)
    let fd = report.failures > 0 ? STDERR_FILENO : STDOUT_FILENO
    Client.writeAll(fd, Array(report.text.utf8))
    return report.failures > 0 ? EXIT_FAILURE : EXIT_SUCCESS
  } catch {
    Client.writeAll(STDERR_FILENO, error.text.bytes)
    return EXIT_FAILURE
  }
}
