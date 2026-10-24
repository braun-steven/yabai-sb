//
// NOTE: The pure parts of the built-in load of the scripting addition (Sources/Yabai/ScriptingAdditionLoader.swift): the
// argv of the sudo call, how its exit is reported, and whether a request starts a run or waits behind the one that runs.
// The process and the event are in Sources/Yabai.
//

/// How the process of a load ended.
public enum ScriptingAdditionLoadExit: Equatable, Sendable {
  /// The process exited with this status.
  case exited(Int32)
  /// The process was killed by this signal.
  case signaled(Int32)
  /// The process was still running when the timeout passed and was killed.
  case timedOut
  /// The process could not be started; the text is the error that starting it threw.
  case notStarted(String)
}

/// Pure functions of the built-in load of the scripting addition.
public enum ScriptingAdditionLoad {
  /// The sudo that runs `--load-sa`. The sudoers entry of the user names this path.
  public static let sudoPath = "/usr/bin/sudo"

  /// How long a load may run before its process is stopped.
  public static let timeoutSeconds = 30

  //
  // NOTE: A load that times out gets SIGTERM, and SIGKILL only if it has not ended after this many seconds. sudo relays
  // SIGTERM to the `--load-sa` it runs as root, which the daemon cannot signal itself; sudo cannot relay SIGKILL.
  //

  /// How long a stopped load has between SIGTERM and SIGKILL.
  public static let terminationGraceSeconds = 2

  /// How many bytes of the stderr of a load are kept: the last ones, which hold the line that failureReason reports.
  public static let stderrLimit = 4096

  /// The argv of a load: `sudo -n <executable> --load-sa`. `-n` makes sudo fail instead of asking for a password.
  public static func arguments(executable: String) -> [String] {
    [sudoPath, "-n", executable, "--load-sa"]
  }

  /// The reason a load failed, or nil when it succeeded. The reason is the last non-blank line that the process wrote to
  /// stderr (sudo's "a password is required", or yabai's own message), or the exit status when there is none.
  public static func failureReason(_ exit: ScriptingAdditionLoadExit, stderr: String) -> String? {
    switch exit {
    case .exited(0):
      return nil
    case .exited(let status):
      return lastLine(of: stderr) ?? "exit status \(status)"
    case .signaled(let signal):
      return "killed by signal \(signal)"
    case .timedOut:
      return "timed out after \(timeoutSeconds) s"
    case .notStarted(let error):
      return "could not start \(sudoPath): \(error)"
    }
  }

  /// The last line that has a character other than blanks, without its leading and trailing blanks.
  private static func lastLine(of text: String) -> String? {
    func isBlank(_ character: Character) -> Bool { character == " " || character == "\t" }
    var last: String?
    for line in text.split(whereSeparator: { $0.isNewline }) {
      let leading = line.drop(while: isBlank)
      var end = leading.endIndex
      while end > leading.startIndex, isBlank(leading[leading.index(before: end)]) {
        end = leading.index(before: end)
      }
      if end > leading.startIndex { last = String(leading[..<end]) }
    }
    return last
  }
}

/// The last `limit` bytes of an output that arrives in chunks, so output of any length keeps its last line.
public struct OutputTail: Equatable, Sendable {
  public let limit: Int
  public private(set) var bytes: [UInt8] = []

  public init(limit: Int) {
    self.limit = limit
  }

  public mutating func append(_ chunk: some Collection<UInt8>) {
    bytes.append(contentsOf: chunk)
    if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
  }

  /// The kept bytes as UTF-8; a character cut at the start becomes U+FFFD.
  public var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// The state of the runs of the load: at most one run at a time, and a request that arrives during a run asks for one
/// more run after it. Any number of such requests make one pending run. The caller starts a process for each `.start`.
public struct ScriptingAdditionLoadQueue: Equatable, Sendable {
  /// What a request does: start a run now, or wait behind the running one.
  public enum Request: Equatable, Sendable {
    case start
    case queued
  }

  /// What a finished run does: start the pending run, or go idle.
  public enum Finish: Equatable, Sendable {
    case start
    case idle
  }

  /// True from the `.start` of a request until the run that it started finishes with no pending run.
  public private(set) var isRunning = false
  /// True when a request arrived during the run and no run has started for it yet.
  public private(set) var isPending = false

  public init() {}

  public mutating func request() -> Request {
    guard isRunning else {
      isRunning = true
      return .start
    }
    isPending = true
    return .queued
  }

  public mutating func finish() -> Finish {
    guard isPending else {
      isRunning = false
      return .idle
    }
    isPending = false
    return .start
  }
}
