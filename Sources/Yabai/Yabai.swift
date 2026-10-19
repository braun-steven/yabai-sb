import AppKit
import CPrivate

//
// NOTE: The options of the daemon and its startup. `--message` / `-m` never gets here: main.swift runs the client
// (Sources/Yabai/IPC/Client.swift). Ported from src/yabai.c (and get_config_file, exec_config_file, ax_privilege
// and the file helpers of src/misc/helpers.h).
//

private let scriptingAdditionLoadOption      = "--load-sa"
private let scriptingAdditionUninstallOption = "--uninstall-sa"
private let serviceInstallOption             = "--install-service"
private let serviceUninstallOption           = "--uninstall-service"
private let serviceStartOption               = "--start-service"
private let serviceRestartOption             = "--restart-service"
private let serviceStopOption                = "--stop-service"
private let configOptionLong                 = "--config"
private let configOptionShort                = "-c"
private let debugVerboseOptionLong           = "--verbose"
private let debugVerboseOptionShort          = "-V"
private let versionOptionLong                = "--version"
private let versionOptionShort               = "-v"
private let helpOptionLong                   = "--help"
private let helpOptionShort                  = "-h"

private let major = 7
private let minor = 1
private let patch = 25

/// `file_exists`: false for a directory.
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

/// `directory_exists`
func directoryExists(_ filename: String) -> Bool
{
    var buffer = stat()

    if stat(filename, &buffer) != 0 {
        return false
    }

    return buffer.st_mode & S_IFMT == S_IFDIR
}

/// `file_can_execute`
private func fileCanExecute(_ filename: String) -> Bool
{
    var buffer = stat()

    if stat(filename, &buffer) != 0 {
        return false
    }

    return buffer.st_mode & S_IXUSR != 0
}

/// `get_config_file`: the first of $XDG_CONFIG_HOME/yabai/<filename>, ~/.config/yabai/<filename> and ~/.<filename>
/// that exists, or nil.
private func getConfigFile(_ filename: String) -> String?
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
// NOTE: The C version forked, and the child exec'd the shell. Swift cannot fork (see eventSignalSpawn), so posix_spawn
// starts the shell directly; nobody waits for it, because SIGCHLD is ignored. A shell that cannot be started is now
// reported like a failed fork.
//

/// `exec_config_file`
private func execConfigFile(_ configFile: String?)
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

/// `ax_privilege`: asks for the Accessibility permission when the daemon does not have it.
private func axPrivilege() -> Bool
{
    // kAXTrustedCheckOptionPrompt, a C global that Swift 6 cannot read
    let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue!] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

/// `is_root`
func is_root() -> Bool
{
    return getuid() == 0 || geteuid() == 0
}

/// A function of SkyLight that it does not export, found with macho_find_symbol.
private func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer?
{
    var image = Array("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight".utf8CString)
    var symbol = Array(name.utf8CString)
    return macho_find_symbol(&image, &symbol)
}

/// `configure_settings_and_acquire_lock`
@MainActor private func configureSettingsAndAcquireLock() -> Bool
{
    guard let user = getenv("USER").map({ String(cString: $0) }) else {
        error("yabai: 'env USER' not set! abort..\n")
    }

    g_sa_socket_file = "/tmp/yabai-sa_\(user).socket"
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
    mouse_state_init(mouse_state_global())

    let handle = open(lockFile, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
    if handle == -1 {
        error("yabai: could not create lock-file! abort..\n")
    }

    var lockfd = flock(l_start: 0, l_len: 0, l_pid: pid, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))

    return fcntl(handle, F_SETLK, &lockfd) != -1
}

/// `parse_arguments`: runs the options that do something and exit; returns the config file of --config.
private func parseArguments(_ arguments: [String]) -> String?
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
        exit(scripting_addition_uninstall())
    }

    if arguments[1] == scriptingAdditionLoadOption {
        exit(scripting_addition_load())
    }

    if arguments[1] == serviceInstallOption {
        exit(service_install())
    }

    if arguments[1] == serviceUninstallOption {
        exit(service_uninstall())
    }

    if arguments[1] == serviceStartOption {
        exit(service_start())
    }

    if arguments[1] == serviceRestartOption {
        exit(service_restart())
    }

    if arguments[1] == serviceStopOption {
        exit(service_stop())
    }

    var configFile: String?
    var i = 1
    while i < arguments.count {
        let opt = arguments[i]

        if opt == debugVerboseOptionLong || opt == debugVerboseOptionShort {
            g_verbose = true
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

/// `yabai_main`: the daemon and its other options.
@MainActor func yabai_main(_ arguments: [String]) -> Int32
{
    var configFile: String?

    if arguments.count > 1 {
        configFile = parseArguments(arguments)
    }

    if is_root() {
        require("yabai: running as root is not allowed! abort..\n")
    }

    if !axPrivilege() {
        require("yabai: could not access accessibility features! abort..\n")
    }

    if !(SLSGetSpaceManagementMode(SLSMainConnectionID()) == 1) {
        require("yabai: 'display has separate spaces' is disabled! abort..\n")
    }

    if !configureSettingsAndAcquireLock() {
        error("yabai: could not acquire lock-file! abort..\n")
    }

    if !Workspace.begin() {
        error("yabai: could not start workspace context! abort..\n")
    }

    if !ProcessManager.shared.begin() {
        error("yabai: could not start process manager! abort..\n")
    }

    if !DisplayManager.shared.begin() {
        error("yabai: could not start display manager! abort..\n")
    }

    if !mouse_handler_begin(mouse_state_global(), mouseEventMask) {
        error("yabai: could not start mouse handler! abort..\n")
    }

    MissionControl.shared.observe()

    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,1327, nil)
    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,1328, nil)

    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,808, nil)

    //
    // NOTE: Moves, resizes and hides of windows that have a border.
    //

    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,806, nil)
    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,807, nil)
    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,815, nil)
    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,816, nil)
    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,1202, nil)

    SLSRegisterConnectionNotifyProc(SLS.connection, connectionNotificationHandler,804, nil)

    WindowManager.shared.initialize()
    SpaceManager.shared.begin()
    WindowManager.shared.begin()

    update_window_notifications()

    let socketFile = "/tmp/yabai_\(String(cString: getenv("USER")!)).socket"
    if !message_loop_begin(socketFile) {
        error("yabai: could not start message loop! abort..\n")
    }

    execConfigFile(configFile)

    NSApp.run()

    return 0
}
