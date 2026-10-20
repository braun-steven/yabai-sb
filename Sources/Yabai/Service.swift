import Foundation
import Logging
import Subprocess

//
// NOTE: The launchd service of --install-service, --uninstall-service, --start-service, --restart-service and
// --stop-service.
//

/// The launchd service of the daemon: its property list and the launchctl commands that install, start and stop it.
enum Service
{
    private static let launchctlExecutable: Executable = .path("/bin/launchctl")
    private static let yabaiPlistName = "com.asmvik.yabai"

    /// The launchd property list: the executable, PATH, and the user twice.
    private static func yabaiPlist(_ exePath: String, _ pathEnv: String, _ user: String) -> String
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

    /// Runs launchctl, without an environment, and waits for it; returns its exit status, 1 if it could not run or was
    /// killed by a signal.
    private static func launchctl(_ arguments: [String], suppressOutput: Bool = false) async -> Int32
    {
        let configuration = Configuration(executable: launchctlExecutable, arguments: Arguments(arguments), environment: .custom([:]))
        let status = suppressOutput
                   ? try? await run(configuration, output: .discarded).terminationStatus
                   : try? await run(configuration, output: .currentStandardOutput, error: .currentStandardError).terminationStatus

        guard case .exited(let code) = status else { return 1 }
        return code
    }

    /// The path of the property list in the LaunchAgents directory of the user.
    private static func populatePlistPath() -> String
    {
        guard let home = NSHomeDirectoryForUser(nil) else {
            Logger.daemon.fatal("unable to retrieve home directory")
        }

        return "\(home)/Library/LaunchAgents/\(yabaiPlistName).plist"
    }

    /// The contents of the property list for this executable, user and PATH.
    private static func populatePlist() -> String
    {
        guard let user = getenv("USER") else {
            Logger.daemon.fatal("'env USER' not set")
        }

        guard let pathEnv = getenv("PATH") else {
            Logger.daemon.fatal("'env PATH' not set")
        }

        var exePath = [CChar](repeating: 0, count: 4096)
        var exePathSize = UInt32(exePath.count)
        if _NSGetExecutablePath(&exePath, &exePathSize) < 0 {
            Logger.daemon.fatal("unable to retrieve path of executable")
        }

        let exe = exePath.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return yabaiPlist(exe, String(cString: pathEnv), String(cString: user))
    }

    /// Creates the directory of the property list.
    private static func ensureDirectoryExists(_ yabaiPlistPath: String)
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

    /// Writes the property list to the path and returns 0 on success.
    private static func installPlist(_ yabaiPlistPath: String) -> Int32
    {
        let plist = populatePlist()
        ensureDirectoryExists(yabaiPlistPath)

        guard let handle = fopen(yabaiPlistPath, "w") else { return 1 }

        let bytes = Array(plist.utf8)
        let written = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, bytes.count, 1, handle) }
        let result: Int32 = written == 1 ? 0 : 1
        fclose(handle)

        return result
    }

    /// Writes the property list to disk.
    static func install() -> Int32
    {
        let yabaiPlistPath = populatePlistPath()

        if fileExists(yabaiPlistPath) {
            Logger.daemon.fatal("service file '\(yabaiPlistPath)' is already installed")
        }

        return installPlist(yabaiPlistPath)
    }

    /// Removes the property list from disk.
    static func uninstall() -> Int32
    {
        let yabaiPlistPath = populatePlistPath()

        if !fileExists(yabaiPlistPath) {
            Logger.daemon.fatal("service file '\(yabaiPlistPath)' is not installed")
        }

        return unlink(yabaiPlistPath) == 0 ? 0 : 1
    }

    /// Enables, bootstraps or kickstarts the service, installing the property list first if needed.
    static func start() async -> Int32
    {
        let yabaiPlistPath = populatePlistPath()
        if !fileExists(yabaiPlistPath) {
            Logger.daemon.warning("service file '\(yabaiPlistPath)' is not installed, attempting installation")

            let result = installPlist(yabaiPlistPath)
            if result != 0 {
                Logger.daemon.fatal("service file '\(yabaiPlistPath)' could not be installed")
            }
        }

        let serviceTarget = "gui/\(getuid())/\(yabaiPlistName)"
        let domainTarget = "gui/\(getuid())"

        //
        // NOTE(asmvik): Check if service is bootstrapped
        //

        let isBootstrapped = await launchctl(["print", serviceTarget], suppressOutput: true)

        if isBootstrapped != 0 {

            //
            // NOTE(asmvik): Service is not bootstrapped and could be disabled.
            // There is no way to query if the service is disabled, and we cannot
            // bootstrap a disabled service. Try to enable the service. This will be
            // a no-op if the service is already enabled.
            //

            _ = await launchctl(["enable", serviceTarget])

            //
            // NOTE(asmvik): Bootstrap service into the target domain.
            // This will also start the program **iff* RunAtLoad is set to true.
            //

            return await launchctl(["bootstrap", domainTarget, yabaiPlistPath])
        } else {

            //
            // NOTE(asmvik): The service has already been bootstrapped.
            // Tell the bootstrapped service to launch immediately; it is an
            // error to bootstrap a service that has already been bootstrapped.
            //

            return await launchctl(["kickstart", serviceTarget])
        }
    }

    /// Restarts the bootstrapped service instance.
    static func restart() async -> Int32
    {
        let yabaiPlistPath = populatePlistPath()
        if !fileExists(yabaiPlistPath) {
            Logger.daemon.fatal("service file '\(yabaiPlistPath)' is not installed")
        }

        let serviceTarget = "gui/\(getuid())/\(yabaiPlistName)"

        return await launchctl(["kickstart", "-k", serviceTarget])
    }

    /// Stops the running instance and unloads the service.
    static func stop() async -> Int32
    {
        let yabaiPlistPath = populatePlistPath()
        if !fileExists(yabaiPlistPath) {
            Logger.daemon.fatal("service file '\(yabaiPlistPath)' is not installed")
        }

        let serviceTarget = "gui/\(getuid())/\(yabaiPlistName)"
        let domainTarget = "gui/\(getuid())"

        //
        // NOTE(asmvik): Check if service is bootstrapped
        //

        let isBootstrapped = await launchctl(["print", serviceTarget], suppressOutput: true)

        if isBootstrapped != 0 {

            //
            // NOTE(asmvik): Service is not bootstrapped, but the program
            // could still be running an instance that was started **while the service
            // was bootstrapped**, so we tell it to stop said service.
            //

            return await launchctl(["kill", "SIGTERM", serviceTarget])
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

            _ = await launchctl(["bootout", domainTarget, yabaiPlistPath])

            return await launchctl(["disable", serviceTarget])
        }
    }
}
