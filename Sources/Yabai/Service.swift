import Foundation

//
// NOTE: The launchd service of --install-service, --uninstall-service, --start-service, --restart-service and
// --stop-service. Ported from src/misc/service.h.
//

private let launchctlPath = "/bin/launchctl"
private let yabaiPlistName = "com.asmvik.yabai"

/// `_YABAI_PLIST` with its four values: the executable, PATH, and the user twice.
private func yabaiPlist(_ exePath: String, _ pathEnv: String, _ user: String) -> String
{
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
    "<plist version=\"1.0\">\n" +
    "<dict>\n" +
    "    <key>Label</key>\n" +
    "    <string>" + yabaiPlistName + "</string>\n" +
    "    <key>ProgramArguments</key>\n" +
    "    <array>\n" +
    "        <string>" + exePath + "</string>\n" +
    "    </array>\n" +
    "    <key>EnvironmentVariables</key>\n" +
    "    <dict>\n" +
    "        <key>PATH</key>\n" +
    "        <string>" + pathEnv + "</string>\n" +
    "    </dict>\n" +
    "    <key>RunAtLoad</key>\n" +
    "    <true/>\n" +
    "    <key>KeepAlive</key>\n" +
    "    <dict>\n" +
    "        <key>SuccessfulExit</key>\n" +
    " \t     <false/>\n" +
    " \t     <key>Crashed</key>\n" +
    " \t     <true/>\n" +
    "    </dict>\n" +
    "    <key>StandardOutPath</key>\n" +
    "    <string>/tmp/yabai_" + user + ".out.log</string>\n" +
    "    <key>StandardErrorPath</key>\n" +
    "    <string>/tmp/yabai_" + user + ".err.log</string>\n" +
    "    <key>ProcessType</key>\n" +
    "    <string>Interactive</string>\n" +
    "    <key>Nice</key>\n" +
    "    <integer>-20</integer>\n" +
    "</dict>\n" +
    "</plist>"
}

//
// NOTE(asmvik): A launchd service has the following states:
//
//          1. Installed / Uninstalled
//          2. Active (Enable / Disable)
//          3. Bootstrapped (Load / Unload)
//          4. Running (Start / Stop)
//

// WIFSIGNALED, WIFSTOPPED and WEXITSTATUS of <sys/wait.h>, which Swift does not import
private func waitStatus(_ status: Int32) -> Int32 { status & 0o177 }
private func waitIfStopped(_ status: Int32) -> Bool { waitStatus(status) == 0o177 && (status >> 8) != 0x13 }
private func waitIfSignaled(_ status: Int32) -> Bool { waitStatus(status) != 0o177 && waitStatus(status) != 0 }
private func waitExitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0xff }

/// `safe_exec`: runs the command, without an environment, and waits for it.
private func safeExec(_ arguments: [String], _ suppressOutput: Bool) -> Int32
{
    var pid: pid_t = 0
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    if suppressOutput {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY|O_APPEND, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY|O_APPEND, 0)
    }

    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }

    var status = posix_spawn(&pid, argv[0], &actions, nil, &argv, nil)
    if status != 0 { return 1 }

    while waitpid(pid, &status, 0) == -1 && errno == EINTR {
        usleep(1000)
    }

    if waitIfSignaled(status) {
        return 1
    } else if waitIfStopped(status) {
        return 1
    } else {
        return waitExitStatus(status)
    }
}

/// `populate_plist_path`
private func populatePlistPath() -> String
{
    guard let home = NSHomeDirectoryForUser(nil) else {
        error("yabai: unable to retrieve home directory! abort..\n")
    }

    return "\(home)/Library/LaunchAgents/\(yabaiPlistName).plist"
}

/// `populate_plist`
private func populatePlist() -> String
{
    guard let user = getenv("USER") else {
        error("yabai: 'env USER' not set! abort..\n")
    }

    guard let pathEnv = getenv("PATH") else {
        error("yabai: 'env PATH' not set! abort..\n")
    }

    var exePath = [CChar](repeating: 0, count: 4096)
    var exePathSize = UInt32(exePath.count)
    if _NSGetExecutablePath(&exePath, &exePathSize) < 0 {
        error("yabai: unable to retrieve path of executable! abort..\n")
    }

    let exe = exePath.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return yabaiPlist(exe, String(cString: pathEnv), String(cString: user))
}

/// `ensure_directory_exists`: creates the directory of the plist.
private func ensureDirectoryExists(_ yabaiPlistPath: String)
{
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

/// `service_install_internal`
private func serviceInstallInternal(_ yabaiPlistPath: String) -> Int32
{
    let yabaiPlist = populatePlist()
    ensureDirectoryExists(yabaiPlistPath)

    guard let handle = fopen(yabaiPlistPath, "w") else { return 1 }

    let bytes = Array(yabaiPlist.utf8)
    let written = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, bytes.count, 1, handle) }
    let result: Int32 = written == 1 ? 0 : 1
    fclose(handle)

    return result
}

/// `service_install`
func service_install() -> Int32
{
    let yabaiPlistPath = populatePlistPath()

    if fileExists(yabaiPlistPath) {
        error("yabai: service file '\(yabaiPlistPath)' is already installed! abort..\n")
    }

    return serviceInstallInternal(yabaiPlistPath)
}

/// `service_uninstall`
func service_uninstall() -> Int32
{
    let yabaiPlistPath = populatePlistPath()

    if !fileExists(yabaiPlistPath) {
        error("yabai: service file '\(yabaiPlistPath)' is not installed! abort..\n")
    }

    return unlink(yabaiPlistPath) == 0 ? 0 : 1
}

/// `service_start`
func service_start() -> Int32
{
    let yabaiPlistPath = populatePlistPath()
    if !fileExists(yabaiPlistPath) {
        warn("yabai: service file '\(yabaiPlistPath)' is not installed! attempting installation..\n")

        let result = serviceInstallInternal(yabaiPlistPath)
        if result != 0 {
            error("yabai: service file '\(yabaiPlistPath)' could not be installed! abort..\n")
        }
    }

    let serviceTarget = "gui/\(getuid())/\(yabaiPlistName)"
    let domainTarget = "gui/\(getuid())"

    //
    // NOTE(asmvik): Check if service is bootstrapped
    //

    let isBootstrapped = safeExec([launchctlPath, "print", serviceTarget], true)

    if isBootstrapped != 0 {

        //
        // NOTE(asmvik): Service is not bootstrapped and could be disabled.
        // There is no way to query if the service is disabled, and we cannot
        // bootstrap a disabled service. Try to enable the service. This will be
        // a no-op if the service is already enabled.
        //

        _ = safeExec([launchctlPath, "enable", serviceTarget], false)

        //
        // NOTE(asmvik): Bootstrap service into the target domain.
        // This will also start the program **iff* RunAtLoad is set to true.
        //

        return safeExec([launchctlPath, "bootstrap", domainTarget, yabaiPlistPath], false)
    } else {

        //
        // NOTE(asmvik): The service has already been bootstrapped.
        // Tell the bootstrapped service to launch immediately; it is an
        // error to bootstrap a service that has already been bootstrapped.
        //

        return safeExec([launchctlPath, "kickstart", serviceTarget], false)
    }
}

/// `service_restart`
func service_restart() -> Int32
{
    let yabaiPlistPath = populatePlistPath()
    if !fileExists(yabaiPlistPath) {
        error("yabai: service file '\(yabaiPlistPath)' is not installed! abort..\n")
    }

    let serviceTarget = "gui/\(getuid())/\(yabaiPlistName)"

    return safeExec([launchctlPath, "kickstart", "-k", serviceTarget], false)
}

/// `service_stop`
func service_stop() -> Int32
{
    let yabaiPlistPath = populatePlistPath()
    if !fileExists(yabaiPlistPath) {
        error("yabai: service file '\(yabaiPlistPath)' is not installed! abort..\n")
    }

    let serviceTarget = "gui/\(getuid())/\(yabaiPlistName)"
    let domainTarget = "gui/\(getuid())"

    //
    // NOTE(asmvik): Check if service is bootstrapped
    //

    let isBootstrapped = safeExec([launchctlPath, "print", serviceTarget], true)

    if isBootstrapped != 0 {

        //
        // NOTE(asmvik): Service is not bootstrapped, but the program
        // could still be running an instance that was started **while the service
        // was bootstrapped**, so we tell it to stop said service.
        //

        return safeExec([launchctlPath, "kill", "SIGTERM", serviceTarget], false)
    } else {

        //
        // NOTE(asmvik): Service is bootstrapped; we stop a potentially
        // running instance of the program and unload the service, making it
        // not trigger automatically in the future.
        //
        // This is NOT the same as disabling the service, which will prevent
        // it from being boostrapped in the future (without explicitly re-enabling
        // it first).
        //

        _ = safeExec([launchctlPath, "bootout", domainTarget, yabaiPlistPath], false)

        return safeExec([launchctlPath, "disable", serviceTarget], false)
    }
}
