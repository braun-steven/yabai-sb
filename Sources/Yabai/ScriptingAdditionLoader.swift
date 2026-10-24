import Foundation
import Logging
import Subprocess
import System
import YabaiCore

//
// NOTE: The built-in load of the scripting addition (`[daemon] load_scripting_addition`). The daemon runs
// `sudo -n <its own binary> --load-sa` (ScriptingAdditionLoad.arguments), the command a user runs by hand.
// The process runs in a detached task that only posts its result back as `.scriptingAdditionLoaded`, so the event loop
// never waits for it. The state of the runs is @WM: ScriptingAdditionLoadQueue lets one run go at a time, and a request
// during a run becomes one more run after it. In headless mode a request is only recorded, and no process starts.
//

/// The result of a load, posted as `.scriptingAdditionLoaded` when its process has ended.
enum ScriptingAdditionLoadResult: Equatable, Sendable {
  case loaded
  case failed(String)
}

/// Loads the scripting addition in a child process, off the event loop (see the NOTE above).
@WM final class ScriptingAdditionLoader {
  static let shared = ScriptingAdditionLoader()

  //
  // NOTE: The path this binary was started from, made absolute once when the loader is created. Links are kept, as
  // with `sudo yabai --load-sa`, so a sudoers line can name a stable link such as /opt/homebrew/bin/yabai instead of a
  // versioned file behind it; the sha256 pin in sudoers decides which binary may run. Nil when the path is unknown.
  //

  let executablePath: String?

  private var queue = ScriptingAdditionLoadQueue()

  private init() {
    var buffer = [CChar](repeating: 0, count: 4096)
    var size = UInt32(buffer.count)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      executablePath = nil
      return
    }
    let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    executablePath =
      path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
  }

  /// Loads the scripting addition in a new process, or queues one more run behind the run in progress. In headless mode
  /// the request is recorded instead (Headless.scriptingAdditionLoads). Called on the event loop.
  func load(reason: String) {
    if Headless.isEnabled {
      Headless.record(scriptingAdditionLoad: reason)
      return
    }
    switch queue.request() {
    case .start: start(reason: reason)
    case .queued:
      Logger.daemon.debug("scripting addition: \(reason) waits for the load in progress")
    }
  }

  /// Called on the event loop when a run has posted its result: starts the pending run, if a request queued one.
  func finished() {
    if queue.finish() == .start { start(reason: "queued request") }
  }

  private func start(reason: String) {
    Logger.daemon.debug("scripting addition: loading (\(reason))")
    guard let executablePath else {
      EventLoop.post(.scriptingAdditionLoaded(.failed("the path of yabai is unknown")))
      return
    }
    let arguments = ScriptingAdditionLoad.arguments(executable: executablePath)
    Task.detached {
      let result = await ScriptingAdditionLoader.execute(arguments)
      EventLoop.post(.scriptingAdditionLoaded(result))
    }
  }

  //
  // NOTE: Runs the argv and waits for it, for at most `timeout`. Cancelling the run of swift-subprocess runs the
  // teardown sequence: SIGTERM, which sudo relays to `--load-sa`, then SIGKILL after
  // ScriptingAdditionLoad.terminationGraceSeconds. The group cancels the other child once one of them has its result.
  // stderr is streamed and only its tail kept (OutputTail): a capped `.string(limit:)` throws on longer output, which
  // ends the run as if the process had not started. This waits for the process to end, so it runs on the concurrent
  // executor, never on the event loop.
  //

  nonisolated static func execute(
    _ arguments: [String], timeout: Duration = .seconds(ScriptingAdditionLoad.timeoutSeconds)
  ) async -> ScriptingAdditionLoadResult {
    await withTaskGroup(of: ScriptingAdditionLoadResult.self) { group in
      group.addTask {
        var options = PlatformOptions()
        options.teardownSequence = [
          .gracefulShutDown(
            allowedDurationToNextStep: .seconds(ScriptingAdditionLoad.terminationGraceSeconds))
        ]
        let exitStatus: ScriptingAdditionLoadExit
        var stderr = ""
        do {
          let result = try await Subprocess.run(
            .path(FilePath(arguments[0])), arguments: Arguments(Array(arguments.dropFirst())),
            platformOptions: options, input: .none, output: .discarded, error: .sequence
          ) { execution in
            var tail = OutputTail(limit: ScriptingAdditionLoad.stderrLimit)
            for try await chunk in execution.standardError {
              chunk.withUnsafeBytes { tail.append($0) }
            }
            return tail.text
          }
          exitStatus = ScriptingAdditionLoader.loadExit(of: result.terminationStatus)
          stderr = result.closureResult
        } catch {
          exitStatus = .notStarted("\(error)")
        }
        return ScriptingAdditionLoader.loadResult(of: exitStatus, stderr: stderr)
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return ScriptingAdditionLoader.loadResult(of: .timedOut, stderr: "")
      }
      let first = await group.next() ?? .failed("no result")
      group.cancelAll()
      return first
    }
  }

  nonisolated static func loadExit(of status: TerminationStatus) -> ScriptingAdditionLoadExit {
    switch status {
    case .exited(let code): .exited(code)
    case .signaled(let signal): .signaled(signal)
    }
  }

  nonisolated static func loadResult(of outcome: ScriptingAdditionLoadExit, stderr: String)
    -> ScriptingAdditionLoadResult
  {
    guard let reason = ScriptingAdditionLoad.failureReason(outcome, stderr: stderr) else {
      return .loaded
    }
    return .failed(reason)
  }
}
