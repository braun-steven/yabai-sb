import AppKit
import CPrivate
import Logging

//
// NOTE: The daemon and its startup, run with the options of YabaiOptions.swift. `--message` / `-m` never gets here:
// main.swift runs the client (Sources/Yabai/IPC/Client.swift).
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
            Logger.daemon.warning("could not locate config file")
            notify("configuration", "could not locate config file..")
            return
        }

        if !fileExists(configFile) {
            Logger.daemon.warning("configuration file '\(configFile)' does not exist")
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
            Logger.daemon.warning("failed to load config file '\(configFile)'")
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

    /// Logs the private symbols that did not resolve, each with the feature that needs it, as one notice line.
    /// When all of them resolved, logs one debug line.
    private static func logSymbolAvailability(_ symbols: [(name: String, feature: String, address: UnsafeMutableRawPointer?)])
    {
        let missing = symbols.filter { $0.address == nil }
        guard !missing.isEmpty else {
            Logger.daemon.debug("all private symbols resolved")
            return
        }

        let list = missing.map { "\($0.name) (\($0.feature))" }.joined(separator: ", ")
        Logger.daemon.notice("unresolved private symbols: \(list)")
    }

    @MainActor private static func configureSettingsAndAcquireLock() -> Bool
    {
        guard let user = getenv("USER").map({ String(cString: $0) }) else {
            Logger.daemon.fatal("'env USER' not set")
        }

        let lockFile = "/tmp/yabai_\(user).lock"

        NSApplicationLoadC()
        let pid = getpid()
        _ = SLS.connection
        let connectionPortName = "_CGSGetConnectionPortById"
        let bridgedOperationName = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
        let connectionPort = skyLightSymbol(connectionPortName)
        let bridgedOperation = skyLightSymbol(bridgedOperationName)
        CPrivateSetResolvedFunctions(connectionPort, bridgedOperation)
        logSymbolAvailability([
            (name: connectionPortName, feature: "window sub-level query", address: connectionPort),
            (name: bridgedOperationName, feature: "bridged window move", address: bridgedOperation),
        ])

        signal(SIGCHLD, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        CGSetLocalEventsSuppressionIntervalC(0.0)
        CGEnableEventStateCombiningC(false)
        let handle = open(lockFile, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        if handle == -1 {
            Logger.daemon.fatal("could not create lock-file")
        }

        var lockfd = flock(l_start: 0, l_len: 0, l_pid: pid, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))

        return fcntl(handle, F_SETLK, &lockfd) != -1
    }

    /// Runs the daemon, or prints the version.
    @MainActor static func run(_ options: YabaiOptions) -> Int32
    {
        if options.version {
            fputs("yabai-v\(major).\(minor).\(patch)\n", stdout_global())
            return EXIT_SUCCESS
        }

        if options.verbose {
            Log.verbose.store(true, ordering: .relaxed)
        }

        if isRoot {
            Logger.daemon.fatal("running as root is not allowed", exitCode: EXIT_SUCCESS)
        }

        if !axPrivilege() {
            Logger.daemon.fatal("could not access accessibility features", exitCode: EXIT_SUCCESS)
        }

        if SLS.spaceManagementMode(SLS.connection) != 1 {
            Logger.daemon.fatal("'display has separate spaces' is disabled", exitCode: EXIT_SUCCESS)
        }

        if !configureSettingsAndAcquireLock() {
            Logger.daemon.fatal("could not acquire lock-file")
        }

        EventLoop.start()

        if !Workspace.begin() {
            Logger.daemon.fatal("could not start workspace context")
        }

        if !ProcessManager.shared.begin() {
            Logger.daemon.fatal("could not start process manager")
        }

        if !DisplayManager.shared.begin() {
            Logger.daemon.fatal("could not start display manager")
        }

        if !WM.sync({ MouseState.shared.beginEventTap(mask: mouseEventMask) }) {
            Logger.daemon.fatal("could not start mouse handler")
        }

        MissionControl.shared.observe()

        //
        // NOTE: Registration order is the declaration order of SLSNotification (see SLSNotification.swift).
        //
        for kind in SLSNotification.allCases {
            SLS.registerNotification(SLS.connection, kind.rawValue, handler: connectionNotificationHandler)
        }

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
            Logger.daemon.fatal("'env USER' not set")
        }
        let socketFile = "/tmp/yabai_\(user).socket"
        if !MessageLoop.begin(socketPath: socketFile) {
            Logger.daemon.fatal("could not start message loop")
        }

        execConfigFile(options.config)

        NSApp.run()

        return 0
    }
}
