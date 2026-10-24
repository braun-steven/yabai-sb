import Foundation
import YabaiCore

//
// NOTE: `config --check [<file>]` and `yabai --check-config [<file>]` read a yabai.toml (configFileReport): the file is
// decoded (ConfigDocument.decode), lowered to the messages the daemon runs (lowered(locator:)) and each message goes
// through checkMessage. Nothing is applied and no command runs. The offline check runs the same code on the @WM queue
// without a daemon (checkConfigOffline).
//
// NOTE: `config --reload [<file>]` (IPC/ConfigReload.swift) reads and checks the file the same way, then reconciles it.
//

/// The report of a check. `text` ends with a newline; `failures` counts the failure responses in it.
struct ConfigCheckReport: Equatable {
  let text: String
  let failures: Int
}

/// The check of a yabai.toml: its report (see configFileReport), and the document it decodes to. The document is nil when
/// the file does not decode. A file with a failure keeps its document; the caller decides.
struct ConfigFileCheck {
  /// The file that was checked.
  let path: String
  let report: ConfigCheckReport
  let document: ConfigDocument?
  /// The text that was checked (the reload keeps it as the last loaded contents).
  let source: String
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

/// The check of a yabai.toml (see ConfigFileCheck): configFileReport, with the document that the startup applies.
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
    return ConfigFileCheck(path: path, report: report, document: nil, source: source)
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
  return ConfigFileCheck(path: path, report: report, document: document, source: source)
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

/// The lines of a failure text: its trailing newline dropped, then one line per newline left in it.
private func failureLines(_ failure: String) -> [String] {
  var bytes = Array(failure.utf8)
  if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
  return bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map {
    String(decoding: $0, as: UTF8.self)
  }
}

/// Rejects an argument after a config command that takes none (`config --overrides`): the failure names the command.
@WM func noConfigArgument(_ command: String, _ message: inout Message) throws(CommandError) {
  let extra = message.next()
  if extra.isValid {
    throw CommandError(
      "unknown argument '\(extra)' given to command '\(command)' for domain 'config'\n")
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
/// daemon loads, and checks it (configFileCheck). Nothing is applied.
@WM func checkConfigFile(_ command: String, _ message: inout Message) throws(CommandError)
  -> ConfigFileCheck
{
  let explicit =
    try configFileArgument(command, &message) ?? WindowManager.shared.explicitConfigFile
  return try readConfigFile(explicit: explicit)
}

/// Why the yabai.toml of a search could not be checked (readConfigFile).
enum ConfigFileReadError: Error, Equatable {
  /// No file was given and no candidate of the search exists.
  case notFound
  /// The chosen file does not exist (a file given with -c or as an argument).
  case missing(String)
  /// The chosen file exists and cannot be read.
  case unreadable(String)
}

/// Reads and checks the yabai.toml that `choice` names (Daemon.configFile). It is the one read of the startup
/// (loadStartupConfig), `config --check`, `config --reload` and `yabai --check-config`; each words the error itself.
/// Nothing is applied.
@WM func readConfigFile(_ choice: ConfigFileChoice?) throws(ConfigFileReadError) -> ConfigFileCheck
{
  guard let path = choice?.chosen else { throw .notFound }
  guard let data = FileManager.default.contents(atPath: path) else {
    throw fileExists(path) ? .unreadable(path) : .missing(path)
  }
  return configFileCheck(path: path, source: String(decoding: data, as: UTF8.self))
}

/// Reads and checks the yabai.toml of `config --check` and `config --reload`: `explicit` (the -c path or a file argument)
/// when given, else the file the daemon loads (Daemon.configFile). A file that cannot be found or read is a failure.
@WM func readConfigFile(explicit: String?) throws(CommandError) -> ConfigFileCheck {
  do throws(ConfigFileReadError) {
    return try readConfigFile(Daemon.configFile(explicit: explicit))
  } catch {
    switch error {
    case .notFound:
      throw CommandError("could not locate config file\n")
    case .missing(let path), .unreadable(let path):
      throw CommandError("cannot read config file '\(path)'\n")
    }
  }
}

/// Writes `config --check [<file>]`: the report, and a failure response when the report has a failure.
@WM func handleConfigCheck(_ rsp: inout Response, _ message: inout Message) throws(CommandError) {
  let check = try checkConfigFile("--check", &message)
  let text = ResponseText(stringLiteral: check.report.text)
  if check.report.failures > 0 {
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
    let check = try readConfigFile(explicit: file)
    let fd = check.report.failures > 0 ? STDERR_FILENO : STDOUT_FILENO
    Client.writeAll(fd, Array(check.report.text.utf8))
    return check.report.failures > 0 ? EXIT_FAILURE : EXIT_SUCCESS
  } catch {
    Client.writeAll(STDERR_FILENO, error.text.bytes)
    return EXIT_FAILURE
  }
}
