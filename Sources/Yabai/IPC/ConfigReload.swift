import Foundation
import Synchronization
import YabaiCore

//
// NOTE: `config --reload [<file>]` reads the yabai.toml that `config --check` reads (the daemon's file, or the file given)
// and checks it. A failure is the failure response, and nothing changes. Otherwise the handler reconciles the document with
// the running state for each ConfigStep, in order, with nothing between the steps (ConfigLoader.reconcile): only the
// settings whose value differs are run, so the layouts, the windows and the spaces stay as they are. Overrides made by
// `config`, `rule --add` or `signal --add` since the last load are put back by the same reconcile. Rules apply to windows
// created later, as before. The reply is `reloaded <file>: <n> changes`. When a setting failed while it ran (a check
// cannot catch everything: a selector names a space that does not exist), the other settings still apply, and the reply
// is a failure: `reloaded <file>: <n> changes, <m> failures` and a `<key path>: <failure>` line for each.
//
// `config --overrides` lists what differs from the last applied document (configOverrideLines).
//
// The reload core is reloadConfig, which the watch of the daemon's file (ConfigWatcher, `.configFileChanged`) calls too:
// there is one reload path, and the watch only adds the decision whether the file changed. A reload that turns
// `[daemon] load_scripting_addition` on requests the scripting addition load (requestScriptingAdditionLoad).
//

/// The outcome of a reload (reloadConfig).
enum ConfigReloadOutcome {
  /// The check failed: nothing changed, and the report lists the failures.
  case failed(ConfigCheckReport)
  /// The file was applied: `result` counts the changes of the reconcile.
  case reloaded(path: String, result: ConfigReconcileResult)
}

/// The one reload path, of `config --reload` and of the watch. It records `check.source` as the last loaded contents when
/// the check is of the daemon's file (ConfigLoader.recordContents), whatever the outcome. A failed check changes nothing. Otherwise it
/// reconciles each ConfigStep in order, with nothing between the steps, and then syncs the watch with the applied
/// `auto_reload` (ConfigWatcher.sync).
@WM func reloadConfig(_ check: ConfigFileCheck) -> ConfigReloadOutcome {
  ConfigLoader.shared.recordContents(of: check)
  let path = check.path

  guard let document = check.document, check.report.failures == 0 else {
    return .failed(check.report)
  }

  let loadedScriptingAddition = ConfigLoader.shared.loadScriptingAddition
  var result = ConfigReconcileResult()
  for step in ConfigStep.allCases {
    result += ConfigLoader.shared.reconcile(to: document, step: step)
  }
  // NOTE: A reload that turns `load_scripting_addition` on loads the scripting addition; turning it off does nothing.
  if !loadedScriptingAddition {
    requestScriptingAdditionLoad(reason: "reload")
  }
  ConfigWatcher.shared.sync()
  // NOTE: The config_loaded signal of the file is pushed here, once per applied file (a failed check pushes nothing). The
  // pushed signals run when the event loop flushes after the current event: the watch's .configFileChanged, or the
  // .daemonMessage of `config --reload` (MessageLoop.swift).
  EventSignals.shared.push(.configLoaded(file: path, changes: result.changes))
  return .reloaded(path: path, result: result)
}

/// Writes `config --reload [<file>]`: `reloaded <file>: <n> changes`, the failures of the check, which change nothing, or
/// as a failure the settings that failed while they ran (configReloadFailureText).
@WM func handleConfigReload(_ rsp: inout Response, _ message: inout Message) throws(CommandError) {
  switch reloadConfig(try checkConfigFile("--reload", &message)) {
  case .failed(let report):
    rsp.fail(CommandError(report.text))
  case .reloaded(let path, let result) where result.failures > 0:
    rsp.fail(
      CommandError(configReloadFailureText(path: path, result: result))
    )
  case .reloaded(let path, let result):
    rsp.write("reloaded \(path): \(result.changes) changes\n")
  }
}

/// The reply of a reload in which settings failed while they ran: the counts, then a line for each failure.
func configReloadFailureText(path: String, result: ConfigReconcileResult) -> String {
  (["reloaded \(path): \(result.changes) changes, \(result.failures) failures"]
    + result.failureLines)
    .joined(separator: "\n") + "\n"
}

/// Writes `config --overrides`: the lines of configOverrideLines, or nothing when no value is overridden.
@WM func handleConfigOverrides(_ rsp: inout Response, _ message: inout Message) throws(CommandError)
{
  try noConfigArgument("--overrides", &message)
  for line in configOverrideLines() {
    rsp.write(line + "\n")
  }
}
