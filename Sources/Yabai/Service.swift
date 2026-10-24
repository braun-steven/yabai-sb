import Foundation
import Logging
import Subprocess
import System

//
// NOTE: The launchd service of --install-service, --uninstall-service, --start-service, --restart-service and
// --stop-service.
//

/// A failure of a service command. The entry points print it with `Logger.daemon.fatal`, which exits with EXIT_FAILURE,
/// except for the two cases that have always failed silently (see install and uninstall).
enum ServiceError: Error, Equatable {
  case missingEnvironment(String)
  case homeDirectoryUnavailable
  case executablePathUnavailable
  case alreadyInstalled(path: String)
  case notInstalled(path: String)
  case plistNotWritten(path: String)

  /// The text of the message, as the service commands have always printed it.
  var message: String {
    switch self {
    case .missingEnvironment(let name): "'env \(name)' not set"
    case .homeDirectoryUnavailable: "unable to retrieve home directory"
    case .executablePathUnavailable: "unable to retrieve path of executable"
    case .alreadyInstalled(let path): "service file '\(path)' is already installed"
    case .notInstalled(let path): "service file '\(path)' is not installed"
    case .plistNotWritten(let path): "service file '\(path)' could not be installed"
    }
  }
}

/// A service command that talks to launchd. `isBootstrapped` tells whether launchd has the service loaded.
enum ServiceAction: Equatable {
  case start(isBootstrapped: Bool)
  case restart
  case stop(isBootstrapped: Bool)
}

/// The launchd service of the daemon: its property list and the launchctl commands that install, start and stop it.
enum Service {
  private static let launchctlExecutable: Executable = .path("/bin/launchctl")
  private static let yabaiPlistName = "com.braun-steven.yabai-sb"

  //
  // NOTE: The label of the service before the fork had its own. --start-service removes a service of this label when
  // it runs this executable, so that both labels do not start a daemon at login; a service that runs another binary,
  // such as an upstream install, is left alone.
  //

  private static let legacyPlistName = "com.asmvik.yabai"

  /// Whether a property list of the legacy label runs the executable at the path.
  static func isLegacyService(plistContents: Data, executable: String) -> Bool {
    guard
      let value = try? PropertyListSerialization.propertyList(from: plistContents, format: nil),
      let dictionary = value as? [String: Any],
      let arguments = dictionary["ProgramArguments"] as? [String]
    else { return false }
    return arguments.first == executable
  }

  /// The launchd property list for the executable, the PATH and the user (the user is in the log paths too).
  static func plist(executable: String, path: String, user: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
      + "<plist version=\"1.0\">\n" + "<dict>\n" + "    <key>Label</key>\n" + "    <string>"
      + yabaiPlistName + "</string>\n" + "    <key>ProgramArguments</key>\n" + "    <array>\n"
      + "        <string>" + executable + "</string>\n" + "    </array>\n"
      + "    <key>EnvironmentVariables</key>\n" + "    <dict>\n" + "        <key>PATH</key>\n"
      + "        <string>" + path + "</string>\n" + "    </dict>\n" + "    <key>RunAtLoad</key>\n"
      + "    <true/>\n" + "    <key>KeepAlive</key>\n" + "    <dict>\n"
      + "        <key>SuccessfulExit</key>\n" + " \t     <false/>\n"
      + " \t     <key>Crashed</key>\n" + " \t     <true/>\n" + "    </dict>\n"
      + "    <key>StandardOutPath</key>\n" + "    <string>/tmp/yabai_" + user
      + ".out.log</string>\n" + "    <key>StandardErrorPath</key>\n" + "    <string>/tmp/yabai_"
      + user + ".err.log</string>\n" + "    <key>ProcessType</key>\n"
      + "    <string>Interactive</string>\n" + "    <key>Nice</key>\n"
      + "    <integer>-20</integer>\n" + "</dict>\n" + "</plist>"
  }

  /// The launchd target of the service in the GUI domain of the user.
  static func serviceTarget(uid: uid_t) -> String {
    "gui/\(uid)/\(yabaiPlistName)"
  }

  /// The launchd GUI domain of the user, into which the service is bootstrapped.
  static func domainTarget(uid: uid_t) -> String {
    "gui/\(uid)"
  }

  /// The launchctl commands of one action, in the order they run. The last command gives the exit status of the
  /// action; the others run for their effect, and their status is ignored.
  static func launchctlArguments(for action: ServiceAction, uid: uid_t, plistPath: String)
    -> [[String]]
  {
    let serviceTarget = serviceTarget(uid: uid)
    let domainTarget = domainTarget(uid: uid)

    switch action {
    case .start(isBootstrapped: false):
      //
      // NOTE(asmvik): Service is not bootstrapped and could be disabled. There is no way to query if the service is
      // disabled, and we cannot bootstrap a disabled service. Enable it first; this is a no-op if it is enabled.
      // Bootstrapping also starts the program iff RunAtLoad is set.
      //
      return [["enable", serviceTarget], ["bootstrap", domainTarget, plistPath]]
    case .start(isBootstrapped: true):
      //
      // NOTE(asmvik): It is an error to bootstrap a service that has already been bootstrapped, so kickstart it.
      //
      return [["kickstart", serviceTarget]]
    case .restart:
      return [["kickstart", "-k", serviceTarget]]
    case .stop(isBootstrapped: false):
      //
      // NOTE(asmvik): The service is not bootstrapped, but the program could still be running an instance that was
      // started while the service was bootstrapped, so tell it to stop.
      //
      return [["kill", "SIGTERM", serviceTarget]]
    case .stop(isBootstrapped: true):
      //
      // NOTE(asmvik): Stop a potentially running instance and unload the service, so it does not trigger
      // automatically. This is NOT disabling the service, which the last command does.
      //
      return [["bootout", domainTarget, plistPath], ["disable", serviceTarget]]
    }
  }

  //
  // NOTE(asmvik): A launchd service has the following states:
  //
  //          1. Installed / Uninstalled
  //          2. Active (Enable / Disable)
  //          3. Bootstrapped (Load / Unload)
  //          4. Running (Start / Stop)
  //

  /// Runs launchctl, without an environment, and waits for it; returns its exit status, 1 if it could not run or was
  /// killed by a signal.
  private static func launchctl(_ arguments: [String], suppressOutput: Bool = false) async -> Int32
  {
    let configuration = Configuration(
      executable: launchctlExecutable, arguments: Arguments(arguments), environment: .custom([:]))
    let status =
      suppressOutput
      ? try? await run(configuration, output: .discarded).terminationStatus
      : try? await run(configuration, output: .currentStandardOutput, error: .currentStandardError)
        .terminationStatus

    guard case .exited(let code) = status else { return 1 }
    return code
  }

  /// Runs the commands of an action in order and returns the exit status of the last one.
  private static func runLaunchctl(_ commands: [[String]]) async -> Int32 {
    var status: Int32 = 1
    for arguments in commands {
      status = await launchctl(arguments)
    }

    return status
  }

  /// The path of the property list in the LaunchAgents directory of the user.
  private static func plistPath(name: String = yabaiPlistName) throws(ServiceError) -> String {
    guard let home = NSHomeDirectoryForUser(nil) else { throw .homeDirectoryUnavailable }

    return "\(home)/Library/LaunchAgents/\(name).plist"
  }

  /// Unloads and removes the service of the legacy label when it runs this executable (see the NOTE above).
  private static func removeLegacyService(uid: uid_t) async throws(ServiceError) {
    let legacyPath = try plistPath(name: legacyPlistName)
    guard let contents = FileManager.default.contents(atPath: legacyPath),
      isLegacyService(plistContents: contents, executable: try executablePath())
    else { return }

    Logger.daemon.warning("removing service file '\(legacyPath)' of the old label")
    _ = await launchctl(["bootout", domainTarget(uid: uid), legacyPath], suppressOutput: true)
    unlink(legacyPath)
  }

  /// The path of this executable.
  private static func executablePath() throws(ServiceError) -> String {
    var exePath = [CChar](repeating: 0, count: 4096)
    var exePathSize = UInt32(exePath.count)
    if _NSGetExecutablePath(&exePath, &exePathSize) < 0 {
      throw .executablePathUnavailable
    }

    return exePath.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }

  /// The contents of the property list for this executable, the user and the PATH.
  private static func populatePlist() throws(ServiceError) -> String {
    guard let user = ProcessEnvironment.currentUser() else { throw .missingEnvironment("USER") }

    guard let pathEnv = getenv("PATH").map({ String(cString: $0) }) else {
      throw .missingEnvironment("PATH")
    }

    return plist(executable: try executablePath(), path: pathEnv, user: user)
  }

  /// Creates the directory of the property list.
  private static func ensureDirectoryExists(_ yabaiPlistPath: String) {
    //
    // NOTE(asmvik): Temporarily remove filename.
    // We know the filepath will contain a slash, as
    // it is controlled by us, so don't bother checking
    // the result..
    //

    let directory = String(yabaiPlistPath[..<yabaiPlistPath.lastIndex(of: "/")!])

    if !directoryExists(directory) {
      mkdir(directory, 0o755)
    }
  }

  /// Writes the property list to the path.
  private static func installPlist(_ yabaiPlistPath: String) throws(ServiceError) {
    let contents = try populatePlist()
    ensureDirectoryExists(yabaiPlistPath)

    guard let handle = fopen(yabaiPlistPath, "w") else {
      throw .plistNotWritten(path: yabaiPlistPath)
    }

    let bytes = Array(contents.utf8)
    let written = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, bytes.count, 1, handle) }
    fclose(handle)

    guard written == 1 else { throw .plistNotWritten(path: yabaiPlistPath) }
  }

  /// Throws if the property list is already on disk.
  private static func ensureNotInstalled(_ yabaiPlistPath: String) throws(ServiceError) {
    if fileExists(yabaiPlistPath) {
      throw .alreadyInstalled(path: yabaiPlistPath)
    }
  }

  /// Throws if the property list is not on disk.
  private static func ensureInstalled(_ yabaiPlistPath: String) throws(ServiceError) {
    if !fileExists(yabaiPlistPath) {
      throw .notInstalled(path: yabaiPlistPath)
    }
  }

  /// Writes the property list to disk. A failed write only sets the exit status, as it always has.
  static func install() -> Int32 {
    do {
      let yabaiPlistPath = try plistPath()
      try ensureNotInstalled(yabaiPlistPath)
      try installPlist(yabaiPlistPath)
      return 0
    } catch {
      if case .plistNotWritten = error { return 1 }
      Logger.daemon.fatal("\(error.message)")
    }
  }

  /// Removes the property list from disk.
  static func uninstall() -> Int32 {
    do {
      let yabaiPlistPath = try plistPath()
      try ensureInstalled(yabaiPlistPath)
      return unlink(yabaiPlistPath) == 0 ? 0 : 1
    } catch {
      Logger.daemon.fatal("\(error.message)")
    }
  }

  /// Enables, bootstraps or kickstarts the service, installing the property list first if needed.
  static func start() async -> Int32 {
    let uid = getuid()

    do {
      try await removeLegacyService(uid: uid)
      let yabaiPlistPath = try plistPath()
      if !fileExists(yabaiPlistPath) {
        Logger.daemon.warning(
          "service file '\(yabaiPlistPath)' is not installed, attempting installation")
        try installPlist(yabaiPlistPath)
      }

      //
      // NOTE(asmvik): Check if service is bootstrapped
      //

      let isBootstrapped =
        await launchctl(["print", serviceTarget(uid: uid)], suppressOutput: true) == 0
      let commands = launchctlArguments(
        for: .start(isBootstrapped: isBootstrapped), uid: uid, plistPath: yabaiPlistPath)
      return await runLaunchctl(commands)
    } catch {
      Logger.daemon.fatal("\(error.message)")
    }
  }

  /// Restarts the bootstrapped service instance.
  static func restart() async -> Int32 {
    let uid = getuid()

    do {
      let yabaiPlistPath = try plistPath()
      try ensureInstalled(yabaiPlistPath)
      return await runLaunchctl(
        launchctlArguments(for: .restart, uid: uid, plistPath: yabaiPlistPath))
    } catch {
      Logger.daemon.fatal("\(error.message)")
    }
  }

  /// Stops the running instance and unloads the service.
  static func stop() async -> Int32 {
    let uid = getuid()

    do {
      let yabaiPlistPath = try plistPath()
      try ensureInstalled(yabaiPlistPath)

      //
      // NOTE(asmvik): Check if service is bootstrapped
      //

      let isBootstrapped =
        await launchctl(["print", serviceTarget(uid: uid)], suppressOutput: true) == 0
      let commands = launchctlArguments(
        for: .stop(isBootstrapped: isBootstrapped), uid: uid, plistPath: yabaiPlistPath)
      return await runLaunchctl(commands)
    } catch {
      Logger.daemon.fatal("\(error.message)")
    }
  }
}
