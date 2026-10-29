import Foundation
import Logging
import YabaiCore

//
// NOTE: The built-in load of the scripting addition (`[daemon] load_scripting_addition`). The daemon runs
// `sudo -n <its own binary> --load-sa` (ScriptingAdditionLoad.arguments), the command a user runs by hand.
// The process runs on a thread of its own and only posts its result back as `.scriptingAdditionLoaded`, so the event
// loop never waits for it. The state of the runs is @WM: ScriptingAdditionLoadQueue lets one run go at a time, and a request
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
    let socketPath = ScriptingAddition.shared.socketPath
    Task.detached {
      let result = await ScriptingAdditionLoader.execute(arguments, socketPath: socketPath)
      EventLoop.post(.scriptingAdditionLoaded(result))
    }
  }

  //
  // NOTE: Runs the argv on a thread of its own, for at most `timeout`. A dispatch worker must not be held that long:
  // the other dispatch blocks wait for one (doc/swift-conventions.md, Blocking calls). The daemon ignores SIGCHLD
  // (Yabai.swift), so the kernel reaps the process and its exit status cannot be read. A run therefore ends when its
  // stderr ends, which is when sudo and the `--load-sa` it runs have closed it; then the payload decides whether the
  // load worked (result(of:)). A timeout sends SIGTERM, which sudo relays to `--load-sa`, and SIGKILL after
  // ScriptingAdditionLoad.terminationGraceSeconds if the stderr has not ended. The process starts with posix_spawn,
  // since Swift cannot fork (EventSignal.swift). stderr is read as it comes and only its tail kept (OutputTail).
  //

  nonisolated static func execute(
    _ arguments: [String], socketPath: String? = nil,
    timeout: TimeInterval = TimeInterval(ScriptingAdditionLoad.timeoutSeconds)
  ) async -> ScriptingAdditionLoadResult {
    await withCheckedContinuation { continuation in
      Thread {
        continuation.resume(returning: run(arguments, socketPath: socketPath, timeout: timeout))
      }.start()
    }
  }

  nonisolated private static func run(
    _ arguments: [String], socketPath: String?, timeout: TimeInterval
  ) -> ScriptingAdditionLoadResult {
    var ends: [Int32] = [-1, -1]
    guard pipe(&ends) == 0 else {
      return result(
        of: .notStarted(String(cString: strerror(errno))), stderr: "", socketPath: socketPath)
    }
    let (reader, writer) = (ends[0], ends[1])
    _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
    _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
    var pid: pid_t = 0
    let status = spawn(&pid, arguments, stderr: writer)
    close(writer)
    guard status == 0 else {
      close(reader)
      return result(
        of: .notStarted(String(cString: strerror(status))), stderr: "", socketPath: socketPath)
    }
    var tail = OutputTail(limit: ScriptingAdditionLoad.stderrLimit)
    if drain(reader, until: Date().addingTimeInterval(timeout), into: &tail) {
      close(reader)
      return result(of: .ended, stderr: tail.text, socketPath: socketPath)
    }
    kill(pid, SIGTERM)
    let grace = Date().addingTimeInterval(
      TimeInterval(ScriptingAdditionLoad.terminationGraceSeconds))
    if !drain(reader, until: grace, into: &tail) {
      kill(pid, SIGKILL)
    }
    close(reader)
    return result(of: .timedOut, stderr: tail.text, socketPath: socketPath)
  }

  /// Starts the argv with stdin and stdout on /dev/null and its stderr on `stderr`. Returns 0, or the error number.
  nonisolated private static func spawn(_ pid: inout pid_t, _ arguments: [String], stderr: Int32)
    -> Int32
  {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
    //
    // NOTE: The child starts with the daemon's signal mask and dispositions, which ignore SIGCHLD and SIGPIPE. sudo needs
    // SIGCHLD to wait for `--load-sa`, so the child gets the same as swift-subprocess gives: all signals at their default,
    // and an empty mask.
    //
    // NOTE: POSIX_SPAWN_CLOEXEC_DEFAULT closes every descriptor in the child that the file actions do not set up. A
    // socket is not close-on-exec between socketpair or accept and its fcntl (IPCConnection), and a child spawned in that
    // window kept the peer of a closed test socket open, so a write to it succeeded instead of failing with EPIPE.
    //
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var everySignal = sigset_t()
    var noSignal = sigset_t()
    sigfillset(&everySignal)
    sigemptyset(&noSignal)
    posix_spawnattr_setsigdefault(&attributes, &everySignal)
    posix_spawnattr_setsigmask(&attributes, &noSignal)
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for argument in cArguments { free(argument) } }
    return posix_spawn(&pid, cArguments[0], &actions, &attributes, &cArguments, environ)
  }

  /// Reads `fd` into `tail` until its output ends (true), or until `deadline` passes (false).
  nonisolated private static func drain(
    _ fd: Int32, until deadline: Date, into tail: inout OutputTail
  ) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let left = deadline.timeIntervalSinceNow
      guard left > 0 else { return false }
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, Int32(left * 1000) + 1)
      if ready < 0 && errno == EINTR { continue }
      if ready < 0 { return true }
      guard ready > 0 else { continue }
      let count = read(fd, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return true }
      tail.append(Array(buffer[..<count]))
    }
  }

  //
  // NOTE: A run that reported no reason is a load only if the payload that answers is this build's. sudo -n fails with
  // its own line when it cannot run, and `--load-sa` writes its own line when it cannot inject or validate the payload,
  // so a reason here is the failure; without one the payload's version is the check that `--load-sa` itself makes.
  //

  /// The result of a run that ended as `exit` with `stderr`.
  nonisolated static func result(
    of exit: ScriptingAdditionLoadExit, stderr: String, socketPath: String?
  ) -> ScriptingAdditionLoadResult {
    if let reason = ScriptingAdditionLoad.failureReason(exit, stderr: stderr) {
      return .failed(reason)
    }
    guard let socketPath, ScriptingAddition.shared.payloadMatches(socketPath: socketPath) else {
      return .failed("the payload is not current after the load")
    }
    return .loaded
  }
}
