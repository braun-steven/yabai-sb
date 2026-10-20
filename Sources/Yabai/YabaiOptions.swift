import ArgumentParser

//
// NOTE: The options of the yabai process. main.swift sends `-m` / `--message` as the first argument to the daemon
// before these are parsed, so the client never pays for swift-argument-parser; the option is declared here for the help,
// the shell completions and a message given in another position, e.g. `--message=query`.
//

/// The command line of the yabai process.
struct YabaiOptions: ParsableCommand
{
    static let configuration = CommandConfiguration(
        commandName: "yabai",
        abstract: "Tiling window manager for macOS.",
        usage: "yabai [<action> | --message <msg> ... | --version | [--config <config>] [--verbose]]",
        discussion: """
            Without options, yabai runs the window manager. An action (--load-sa through --stop-service), --message \
            and --version must be given alone.
            Type `man yabai` for more information, or visit: \
            https://github.com/braun-steven/yabai/blob/main/doc/yabai.asciidoc
            """
    )

    /// An option that does its work and exits instead of running the window manager.
    enum Action: String, EnumerableFlag
    {
        case loadSA           = "load-sa"
        case uninstallSA      = "uninstall-sa"
        case installService   = "install-service"
        case uninstallService = "uninstall-service"
        case startService     = "start-service"
        case restartService   = "restart-service"
        case stopService      = "stop-service"

        static func name(for value: Action) -> NameSpecification
        {
            .customLong(value.rawValue)
        }

        static func help(for value: Action) -> ArgumentHelp?
        {
            switch value {
            case .loadSA:           "Install and load the scripting-addition."
            case .uninstallSA:      "Uninstall the scripting-addition."
            case .installService:   "Write launchd service file to disk."
            case .uninstallService: "Remove launchd service file from disk."
            case .startService:     "Enable, load, and start the launchd service."
            case .restartService:   "Attempts to restart the service instance."
            case .stopService:      "Stops a running instance of the service."
            }
        }

        /// Does the work of the action; returns the exit status.
        func run() async -> Int32
        {
            switch self {
            case .loadSA:           await ScriptingAddition.shared.load()
            case .uninstallSA:      ScriptingAddition.shared.uninstall()
            case .installService:   Service.install()
            case .uninstallService: Service.uninstall()
            case .startService:     await Service.start()
            case .restartService:   await Service.restart()
            case .stopService:      await Service.stop()
            }
        }
    }

    @Flag(exclusivity: .exclusive)
    var action: Action?

    @Option(name: [.customShort("m"), .long], parsing: .remaining, help: ArgumentHelp("Send message to a running instance of yabai.", valueName: "msg"))
    var message: [String] = []

    @Option(name: [.customShort("c"), .long], help: ArgumentHelp("Use the specified configuration file.", valueName: "config"), completion: .file())
    var config: String?

    @Flag(name: [.customShort("V"), .long], help: "Output debug information to stdout.")
    var verbose = false

    @Flag(name: [.customShort("v"), .long], help: "Print version to stdout and exit.")
    var version = false

    func validate() throws
    {
        let exclusive = [action.map { "--\($0.rawValue)" }, message.isEmpty ? nil : "--message", version ? "--version" : nil].compactMap { $0 }
        guard let option = exclusive.first else { return }

        if exclusive.count > 1 || config != nil || verbose {
            throw ValidationError("'\(option)' must be given alone")
        }
    }
}
