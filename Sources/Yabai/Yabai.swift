import AppKit
import CPrivate

//
// NOTE: The options of the daemon and its startup. `--message` / `-m` never gets here: main.swift runs the client
// (Sources/Yabai/IPC/Client.swift).
//

/// False for a directory.
func fileExists(_ filename: String) -> Bool
{
    var buffer = stat()

    if stat(filename, &buffer) != 0 {
        return false
    }

    if buffer.st_mode & S_IFDIR != 0 {
        return false
    }

    return true
}

func directoryExists(_ filename: String) -> Bool
{
    var buffer = stat()

    if stat(filename, &buffer) != 0 {
        return false
    }

    return buffer.st_mode & S_IFMT == S_IFDIR
}

/// The daemon and its startup, and the options that run instead of it.
enum Daemon
{
    private static let scriptingAdditionLoadOption      = "--load-sa"
    private static let scriptingAdditionUninstallOption = "--uninstall-sa"
    private static let serviceInstallOption             = "--install-service"
    private static let serviceUninstallOption           = "--uninstall-service"
    private static let serviceStartOption               = "--start-service"
    private static let serviceRestartOption             = "--restart-service"
    private static let serviceStopOption                = "--stop-service"
    private static let configOptionLong                 = "--config"
    private static let configOptionShort                = "-c"
    private static let debugVerboseOptionLong           = "--verbose"
    private static let debugVerboseOptionShort          = "-V"
    private static let versionOptionLong                = "--version"
    private static let versionOptionShort               = "-v"
    private static let helpOptionLong                   = "--help"
    private static let helpOptionShort                  = "-h"

    private static let major = 7
    private static let minor = 1
    private static let patch = 25

    /// Whether the process runs as root, real or effective.
    static var isRoot: Bool
    {
        return getuid() == 0 || geteuid() == 0
    }

    private static func fileCanExecute(_ filename: String) -> Bool
    {
        var buffer = stat()

        if stat(filename, &buffer) != 0 {
            return false
        }

        return buffer.st_mode & S_IXUSR != 0
    }

    /// The first of $XDG_CONFIG_HOME/yabai/<filename>, ~/.config/yabai/<filename> and ~/.<filename> that exists, or nil.
    private static func getConfigFile(_ filename: String) -> String?
    {
        if let xdgHome = getenv("XDG_CONFIG_HOME"), xdgHome.pointee != 0 {
            let path = "\(String(cString: xdgHome))/yabai/\(filename)"
            if fileExists(path) { return path }
        }

        guard let home = getenv("HOME").map({ String(cString: $0) }) else { return nil }

        let path = "\(home)/.config/yabai/\(filename)"
        if fileExists(path) { return path }

        let dotPath = "\(home)/.\(filename)"
        return fileExists(dotPath) ? dotPath : nil
    }

    //
    // NOTE: Swift cannot fork (see EventSignals.spawn), so posix_spawn
    // starts the shell directly; nobody waits for it, because SIGCHLD is ignored. A shell that cannot be started is now
    // reported like a failed fork.
    //

    private static func execConfigFile(_ configFile: String?)
    {
        guard let configFile = configFile.flatMap({ $0.isEmpty ? nil : $0 }) ?? getConfigFile("yabairc") else {
            warn("yabai: could not locate config file..\n")
            notify("configuration", "could not locate config file..")
            return
        }

        if !fileExists(configFile) {
            warn("yabai: configuration file '\(configFile)' does not exist..\n")
            notify("configuration", "file '\(configFile)' does not exist..")
            return
        }

        let exec = fileCanExecute(configFile)
                 ? ["/usr/bin/env", "sh", "-c", configFile]
                 : ["/usr/bin/env", "sh", configFile]
        var argv: [UnsafeMutablePointer<CChar>?] = exec.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        if posix_spawn(&pid, argv[0], nil, nil, &argv, environ_global()) != 0 {
            warn("yabai: failed to load config file '\(configFile)'\n")
            notify("configuration", "failed to load file '\(configFile)'")
        }
    }

    /// Asks for the Accessibility permission when the daemon does not have it.
    private static func axPrivilege() -> Bool
    {
        // kAXTrustedCheckOptionPrompt, a C global that Swift 6 cannot read
        let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue!] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// A function of SkyLight that it does not export, found in its symbol table.
    private static func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer?
    {
        return MachOSymbol.address(of: name, inImage: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight")
    }

    @MainActor private static func configureSettingsAndAcquireLock() -> Bool
    {
        guard let user = getenv("USER").map({ String(cString: $0) }) else {
            error("yabai: 'env USER' not set! abort..\n")
        }

        let lockFile = "/tmp/yabai_\(user).lock"

        NSApplicationLoadC()
        let pid = getpid()
        _ = SLS.connection
        CPrivateSetResolvedFunctions(skyLightSymbol("_CGSGetConnectionPortById"),
                                     skyLightSymbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"))

        signal(SIGCHLD, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        CGSetLocalEventsSuppressionIntervalC(0.0)
        CGEnableEventStateCombiningC(false)
        let handle = open(lockFile, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        if handle == -1 {
            error("yabai: could not create lock-file! abort..\n")
        }

        var lockfd = flock(l_start: 0, l_len: 0, l_pid: pid, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))

        return fcntl(handle, F_SETLK, &lockfd) != -1
    }

    /// Runs the options that do something and exit; returns the config file of --config.
    private static func parseArguments(_ arguments: [String]) -> String?
    {
        if arguments[1] == helpOptionLong || arguments[1] == helpOptionShort {
            fputs("Usage: yabai [option]\n" +
                  "Options:\n" +
                  "    --load-sa              Install and load the scripting-addition.\n" +
                  "    --uninstall-sa         Uninstall the scripting-addition.\n" +
                  "    --install-service      Write launchd service file to disk.\n" +
                  "    --uninstall-service    Remove launchd service file from disk.\n" +
                  "    --start-service        Enable, load, and start the launchd service.\n" +
                  "    --restart-service      Attempts to restart the service instance.\n" +
                  "    --stop-service         Stops a running instance of the service.\n" +
                  "    --message, -m <msg>    Send message to a running instance of yabai.\n" +
                  "    --config, -c <config>  Use the specified configuration file.\n" +
                  "    --verbose, -V          Output debug information to stdout.\n" +
                  "    --version, -v          Print version to stdout and exit.\n" +
                  "    --help, -h             Print options to stdout and exit.\n" +
                  "Type `man yabai` for more information, or visit: " +
                  "https://github.com/braun-steven/yabai/blob/main/doc/yabai.asciidoc\n", stdout_global())
            exit(EXIT_SUCCESS)
        }

        if arguments[1] == versionOptionLong || arguments[1] == versionOptionShort {
            fputs("yabai-v\(major).\(minor).\(patch)\n", stdout_global())
            exit(EXIT_SUCCESS)
        }

        if arguments[1] == scriptingAdditionUninstallOption {
            exit(ScriptingAddition.shared.uninstall())
        }

        if arguments[1] == scriptingAdditionLoadOption {
            exit(ScriptingAddition.shared.load())
        }

        if arguments[1] == serviceInstallOption {
            exit(Service.install())
        }

        if arguments[1] == serviceUninstallOption {
            exit(Service.uninstall())
        }

        if arguments[1] == serviceStartOption {
            exit(Service.start())
        }

        if arguments[1] == serviceRestartOption {
            exit(Service.restart())
        }

        if arguments[1] == serviceStopOption {
            exit(Service.stop())
        }

        var configFile: String?
        var i = 1
        while i < arguments.count {
            let opt = arguments[i]

            if opt == debugVerboseOptionLong || opt == debugVerboseOptionShort {
                Log.verbose.store(true, ordering: .relaxed)
            } else if opt == configOptionLong || opt == configOptionShort {
                guard i < arguments.count - 1 else { error("yabai: option '\(configOptionLong)|\(configOptionShort)' requires an argument!\n") }
                i += 1
                configFile = arguments[i]
            } else {
                error("yabai: '\(opt)' is not a valid option!\n")
            }

            i += 1
        }

        return configFile
    }

    /// Runs the daemon, or the option given on the command line.
    @MainActor static func run(_ arguments: [String]) -> Int32
    {
        var configFile: String?

        if arguments.count > 1 {
            configFile = parseArguments(arguments)
        }

        if isRoot {
            require("yabai: running as root is not allowed! abort..\n")
        }

        if !axPrivilege() {
            require("yabai: could not access accessibility features! abort..\n")
        }

        if SLS.spaceManagementMode(SLS.connection) != 1 {
            require("yabai: 'display has separate spaces' is disabled! abort..\n")
        }

        if !configureSettingsAndAcquireLock() {
            error("yabai: could not acquire lock-file! abort..\n")
        }

        EventLoop.start()

        if !Workspace.begin() {
            error("yabai: could not start workspace context! abort..\n")
        }

        if !ProcessManager.shared.begin() {
            error("yabai: could not start process manager! abort..\n")
        }

        if !DisplayManager.shared.begin() {
            error("yabai: could not start display manager! abort..\n")
        }

        if !WM.sync({ MouseState.shared.beginEventTap(mask: mouseEventMask) }) {
            error("yabai: could not start mouse handler! abort..\n")
        }

        MissionControl.shared.observe()

        SLS.registerNotification(SLS.connection, 1327, handler: connectionNotificationHandler)
        SLS.registerNotification(SLS.connection, 1328, handler: connectionNotificationHandler)

        SLS.registerNotification(SLS.connection, 808, handler: connectionNotificationHandler)

        //
        // NOTE: Moves, resizes and hides of windows that have a border.
        //

        SLS.registerNotification(SLS.connection, 806, handler: connectionNotificationHandler)
        SLS.registerNotification(SLS.connection, 807, handler: connectionNotificationHandler)
        SLS.registerNotification(SLS.connection, 815, handler: connectionNotificationHandler)
        SLS.registerNotification(SLS.connection, 816, handler: connectionNotificationHandler)
        SLS.registerNotification(SLS.connection, 1202, handler: connectionNotificationHandler)

        SLS.registerNotification(SLS.connection, 804, handler: connectionNotificationHandler)

        //
        // NOTE: Startup reads the process table on @WM; Carbon callbacks only post events to that queue.
        //
        WM.sync {
            WindowManager.shared.initialize()
            SpaceManager.shared.begin()
            WindowManager.shared.begin()
            WindowManager.shared.updateWindowNotifications()
            ConfigObserver.shared.start()
        }

        guard let user = getenv("USER").map({ String(cString: $0) }) else {
            error("yabai: 'env USER' not set! abort..\n")
        }
        let socketFile = "/tmp/yabai_\(user).socket"
        if !MessageLoop.begin(socketPath: socketFile) {
            error("yabai: could not start message loop! abort..\n")
        }

        execConfigFile(configFile)

        NSApp.run()

        return 0
    }
}
