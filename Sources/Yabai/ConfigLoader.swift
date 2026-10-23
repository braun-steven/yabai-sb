import Foundation
import Logging
import YabaiCore

//
// NOTE: The static config file (yabai.toml) at startup. Daemon.run reads and checks the file before the managers start
// (loadStartupConfig, the check of `config --check`). A file with a failure applies nothing and the daemon keeps the
// built-in defaults. Otherwise the file is reconciled with the running state in four steps (ConfigStep), which the
// startup sequence interleaves with the manager starts (doc/architecture.md "Startup sequence"). The reconcile is
// ConfigLoader.reconcile (ConfigReconcile.swift): it runs only the messages whose setting differs, through handleMessage
// in-process, the handler that the daemon runs for `yabai -m`: no IPC, no Task and no delay.
//

/// The static config of the daemon: the document that was reconciled last, which a later reconcile compares with, and
/// the default of each option, printed before any file value was applied. The startup and a reload share the one
/// instance (`shared`).
@WM final class ConfigLoader {
  static let shared = ConfigLoader()

  /// The document of the last reconcile that ran every step. Nil before that: a removed setting is then not known.
  var applied: ConfigDocument?
  /// The printed value of each option of a new daemon, captured by the first reconcile (`defaultWords`).
  var defaults: [ConfigName: String]?

  /// Forgets the applied document and the defaults, as a new daemon has them (the test fixture).
  func reset() {
    applied = nil
    defaults = nil
  }
}

/// The steps that apply a loaded file, in the order of the startup sequence.
enum ConfigStep: CaseIterable, Sendable {
  /// After the space defaults and before WindowManager.initialize: the settings that the managers and the views read
  /// when they start (space_layout and the global space options included).
  case settings
  /// After WindowManager.initialize and SpaceManager.begin. tab_bar_font comes after initialize, which sets the default
  /// font; external_bar marks the views of the spaces invalid, so it needs them.
  case managerSettings
  /// After SpaceManager.begin: the [[space]] labels, pins and per-space options.
  case spaces
  /// Before WindowManager.begin, so that the windows it adopts get the rules.
  case rulesAndSignals
}

/// The options that act on a manager's state, so they run in the managerSettings step.
private let managerSettingNames: Set<String> = [
  ConfigName.tabBarFont.rawValue,
  ConfigName.externalBar.rawValue,
]

/// The step that applies `entry`.
func configStep(of entry: ConfigEntry) -> ConfigStep {
  switch entry.kind {
  case .option, .spaceLayout:
    let name = entry.arguments.count > 1 ? entry.arguments[1] : ""
    return managerSettingNames.contains(name) ? .managerSettings : .settings
  case .space:
    return .spaces
  case .rule, .signal:
    return .rulesAndSignals
  }
}

/// The startup file: its path, its document when it can be applied, and what to log and notify.
struct LoadedConfig: Sendable {
  /// The file that was found, or nil when none was.
  let path: String?
  /// The decoded file. Nil when there is no file or it has a failure: nothing is applied then.
  let document: ConfigDocument?
  /// Lines for the log: the failures of the file, or why there is no file.
  let log: [String]
  /// The texts for the notifications, each shown under "configuration".
  let notices: [String]
}

/// Finds and checks the startup file: `explicit` (from -c) when given, else the first yabai.toml of the search
/// (Daemon.configFile). The check is the one of `config --check` (configFileCheck). Nothing is applied here.
@WM func loadStartupConfig(explicit: String?) -> LoadedConfig {
  guard let choice = Daemon.configFile(explicit: explicit) else {
    return LoadedConfig(
      path: nil, document: nil, log: ["could not locate config file"],
      notices: ["could not locate config file.."])
  }

  let path = choice.chosen
  var log = ["using config file '\(path)'"]
  var notices: [String] = []
  if !choice.ignored.isEmpty {
    let ignored = choice.ignored.map { "'\($0)'" }.joined(separator: ", ")
    log.append("using '\(path)'; ignoring \(ignored)")
    notices.append("using '\(path)'; ignoring \(ignored)..")
  }

  guard fileExists(path) else {
    return LoadedConfig(
      path: path, document: nil,
      log: log + ["configuration file '\(path)' does not exist"],
      notices: notices + ["file '\(path)' does not exist.."])
  }

  guard let data = FileManager.default.contents(atPath: path) else {
    return LoadedConfig(
      path: path, document: nil, log: log + ["cannot read config file '\(path)'"],
      notices: notices + ["cannot read file '\(path)'.."])
  }

  let check = configFileCheck(path: path, source: String(decoding: data, as: UTF8.self))
  let failures = check.report.failures
  guard failures == 0 else {
    let report = check.report.text.split(separator: "\n").map(String.init)
    notices.append("\(path) has \(failures) errors; using defaults..")
    return LoadedConfig(path: path, document: nil, log: log + report, notices: notices)
  }

  return LoadedConfig(path: path, document: check.document, log: log, notices: notices)
}

extension LoadedConfig {
  /// The messages of the file in apply order, for the log and the tests. Nil when the file is not applied.
  var entries: [ConfigEntry]? { document?.lowered() }

  /// Reconciles the file with the running state for `step` (ConfigLoader.reconcile). Nothing runs when the file was not
  /// loaded. Returns the number of messages that failed.
  @discardableResult @WM func apply(_ step: ConfigStep) -> Int {
    guard let document else { return 0 }
    return ConfigLoader.shared.reconcile(to: document, step: step)
  }
}
