import AppKit
import CPrivate
import Logging
import Synchronization
import YabaiCore

//
// NOTE: The daemon and its startup, run with the options of YabaiOptions.swift. `--message` / `-m` never gets here:
// main.swift runs the client (Sources/Yabai/IPC/Client.swift).
//

/// False for a directory.
func fileExists(_ filename: String) -> Bool {
  var buffer = stat()

  if stat(filename, &buffer) != 0 {
    return false
  }

  if buffer.st_mode & S_IFDIR != 0 {
    return false
  }

  return true
}

/// The path with symlinks resolved (realpath), or the path itself when it cannot be resolved.
func resolvedPath(_ filename: String) -> String {
  guard let resolved = realpath(filename, nil) else { return filename }
  defer { free(resolved) }
  return String(cString: resolved)
}

func directoryExists(_ filename: String) -> Bool {
  var buffer = stat()

  if stat(filename, &buffer) != 0 {
    return false
  }

  return buffer.st_mode & S_IFMT == S_IFDIR
}

/// The daemon and its startup, and the options that run instead of it.
enum Daemon {
  private static let major = 7
  private static let minor = 1
  private static let patch = 25

  /// Whether the process runs as root, real or effective.
  static var isRoot: Bool {
    return getuid() == 0 || geteuid() == 0
  }

  private static func fileCanExecute(_ filename: String) -> Bool {
    var buffer = stat()

    if stat(filename, &buffer) != 0 {
      return false
    }

    return buffer.st_mode & S_IXUSR != 0
  }

  //
  // NOTE: Swift cannot fork (see EventSignals.spawn), so posix_spawn
  // starts the shell directly; nobody waits for it, because SIGCHLD is ignored. A shell that cannot be started is now
  // reported like a failed fork.
  //

  /// The search paths of `filename` from $XDG_CONFIG_HOME and $HOME (see ConfigFileSearch.candidates).
  private static func configCandidates(_ filename: String, homeDotfile: Bool) -> [String] {
    return ConfigFileSearch.candidates(
      filename: filename,
      xdgConfigHome: getenv("XDG_CONFIG_HOME").map { String(cString: $0) },
      home: getenv("HOME").map { String(cString: $0) },
      homeDotfile: homeDotfile)
  }

  /// The yabairc the daemon runs: `explicit` (from -c) when given, else the first existing candidate. Nil when no
  /// candidate exists. The daemon and `config --check` without a file both use it.
  static func configFileChoice(explicit: String?) -> ConfigFileChoice? {
    let candidates = configCandidates("yabairc", homeDotfile: true)
    return ConfigFileSearch.choose(
      explicit: explicit, candidates: candidates, exists: fileExists, resolve: resolvedPath)
  }

  /// The static config file (yabai.toml): `explicit` (from -c) when given, else the first existing candidate. Nil when no
  /// candidate exists. The startup reads it (loadStartupConfig, ConfigLoader.swift) and the leftover check below uses it.
  static func configFile(explicit: String?) -> ConfigFileChoice? {
    let candidates = configCandidates("yabai.toml", homeDotfile: false)
    return ConfigFileSearch.choose(
      explicit: explicit, candidates: candidates, exists: fileExists, resolve: resolvedPath)
  }

  /// Warns, and notifies, at startup when a yabairc exists and no yabai.toml does. See
  /// ConfigFileSearch.leftoverYabaircNotice for the decision.
  static func warnLeftoverYabairc(explicit: String?) {
    let notice = ConfigFileSearch.leftoverYabaircNotice(
      toml: configFile(explicit: explicit),
      yabairc: configFileChoice(explicit: explicit),
      tomlCandidates: configCandidates("yabai.toml", homeDotfile: false))
    guard let notice else { return }

    Logger.daemon.warning("\(notice)")
    notify("configuration", "\(notice)..")
  }

  /// Runs the yabairc: the one given (`explicit`, from -c) or else the first existing candidate, as `config --reload` does
  /// on each reload (the startup applies yabai.toml instead, see loadStartupConfig). In headless mode the run is recorded
  /// instead (Headless.swift).
  static func execConfigFile(_ configFile: String?) {
    guard let choice = configFileChoice(explicit: configFile) else {
      Logger.daemon.warning("could not locate config file")
      notify("configuration", "could not locate config file..")
      return
    }

    let configFile = choice.chosen
    Logger.daemon.notice("using config file '\(configFile)'")

    if !choice.ignored.isEmpty {
      let ignored = choice.ignored.map { "'\($0)'" }.joined(separator: ", ")
      Logger.daemon.warning("using '\(configFile)'; ignoring \(ignored)")
      notify("configuration", "using '\(configFile)'; ignoring \(ignored)..")
    }

    if !fileExists(configFile) {
      Logger.daemon.warning("configuration file '\(configFile)' does not exist")
      notify("configuration", "file '\(configFile)' does not exist..")
      return
    }

    if Headless.isEnabled {
      Headless.record(configFile: configFile)
      return
    }

    let exec =
      fileCanExecute(configFile)
      ? ["/usr/bin/env", "sh", "-c", configFile]
      : ["/usr/bin/env", "sh", configFile]
    var argv: [UnsafeMutablePointer<CChar>?] = exec.map { strdup($0) } + [nil]
    defer {
      for argument in argv { free(argument) }
    }

    var pid: pid_t = 0
    if posix_spawn(&pid, argv[0], nil, nil, &argv, environ_global()) != 0 {
      Logger.daemon.warning("failed to load config file '\(configFile)'")
      notify("configuration", "failed to load file '\(configFile)'")
    }
  }

  /// Asks for the Accessibility permission when the daemon does not have it.
  private static func axPrivilege() -> Bool {
    // kAXTrustedCheckOptionPrompt, a C global that Swift 6 cannot read
    let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue!] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// A function of SkyLight that it does not export, found in its symbol table.
  private static func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    return MachOSymbol.address(
      of: name, inImage: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight")
  }

  /// Logs the private symbols that did not resolve, each with the feature that needs it, as one notice line.
  /// When all of them resolved, logs one debug line.
  private static func logSymbolAvailability(
    _ symbols: [(name: String, feature: String, address: UnsafeMutableRawPointer?)]
  ) {
    let missing = symbols.filter { $0.address == nil }
    guard !missing.isEmpty else {
      Logger.daemon.debug("all private symbols resolved")
      return
    }

    let list = missing.map { "\($0.name) (\($0.feature))" }.joined(separator: ", ")
    Logger.daemon.notice("unresolved private symbols: \(list)")
  }

  /// Loads AppKit and connects to the window server. Returns the pid of the daemon.
  @MainActor private static func connectToWindowServer() -> pid_t {
    NSApplicationLoadC()
    let pid = getpid()
    _ = SLS.connection
    return pid
  }

  /// Resolves the two SkyLight functions that the daemon takes from its symbol table, and logs the unresolved ones.
  @MainActor private static func resolvePrivateSymbols() {
    let connectionPortName = "_CGSGetConnectionPortById"
    let bridgedOperationName =
      "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
    let connectionPort = skyLightSymbol(connectionPortName)
    let bridgedOperation = skyLightSymbol(bridgedOperationName)
    CPrivateSetResolvedFunctions(connectionPort, bridgedOperation)
    logSymbolAvailability([
      (name: connectionPortName, feature: "window sub-level query", address: connectionPort),
      (name: bridgedOperationName, feature: "bridged window move", address: bridgedOperation),
    ])
  }

  /// Ignores SIGCHLD, so the kernel reaps the children the daemon spawns, and SIGPIPE.
  @MainActor private static func installSignalHandlers() {
    signal(SIGCHLD, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
  }

  //
  // NOTE: The suppression interval stays a global setting (CGSetLocalEventsSuppressionInterval, deprecated). Its
  // per-source replacement (CGEventSourceSetLocalEventsSuppressionInterval) only covers events posted with that
  // source. The SDK headers do not say that it also covers CGWarpMouseCursorPosition, which mouse_follows_focus and
  // display focus use, so the zero interval could not be moved to a source without a lag after a warp.
  //
  /// Turns off the local event suppression interval and enables event state combining.
  @MainActor private static func configureEventSystem() {
    CGSetLocalEventsSuppressionIntervalC(0.0)
    CGEnableEventStateCombiningC(false)
    ReduceMotion.observe()
  }

  /// Takes the write lock of the user's lock-file. False when another daemon holds it.
  @MainActor private static func acquireLock(user: String, pid: pid_t) -> Bool {
    let lockFile = "/tmp/yabai_\(user).lock"

    let handle = open(lockFile, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
    if handle == -1 {
      Logger.daemon.fatal("could not create lock-file")
    }

    var lockfd = flock(
      l_start: 0, l_len: 0, l_pid: pid, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))

    return fcntl(handle, F_SETLK, &lockfd) != -1
  }

  /// Runs the daemon, or prints the version.
  @MainActor static func run(_ options: YabaiOptions) -> Int32 {
    if options.version {
      fputs("yabai-v\(major).\(minor).\(patch)\n", stdout_global())
      return EXIT_SUCCESS
    }

    if options.verbose {
      Log.verbose.store(true, ordering: .relaxed)
    }
    Log.verboseAtStartup.store(options.verbose, ordering: .relaxed)

    if isRoot {
      Logger.daemon.fatal("running as root is not allowed", exitCode: EXIT_SUCCESS)
    }

    if !axPrivilege() {
      Logger.daemon.fatal("could not access accessibility features", exitCode: EXIT_SUCCESS)
    }

    if SLS.spaceManagementMode(SLS.connection) != 1 {
      Logger.daemon.fatal("'display has separate spaces' is disabled", exitCode: EXIT_SUCCESS)
    }

    //
    // NOTE: The startup steps run in this order, each with one debug line; doc/architecture.md "Startup sequence"
    // lists them. Keep the SkyLight notification registration before the manager sync: the windows that the
    // managers tile must already be subscribed (architecture.md, "Subscribe before initial tiling").
    //

    Logger.daemon.debug("startup: reading the user and connecting to the window server")
    guard let user = ProcessEnvironment.currentUser() else {
      Logger.daemon.fatal("'env USER' not set")
    }
    let pid = connectToWindowServer()

    Logger.daemon.debug("startup: resolving private symbols")
    resolvePrivateSymbols()

    Logger.daemon.debug("startup: installing signal handlers")
    installSignalHandlers()

    Logger.daemon.debug("startup: configuring the event system")
    configureEventSystem()

    Logger.daemon.debug("startup: acquiring the lock-file")
    if !acquireLock(user: user, pid: pid) {
      Logger.daemon.fatal("could not acquire lock-file")
    }

    Logger.daemon.debug("startup: starting the event loop")
    EventLoop.start()

    Logger.daemon.debug("startup: starting the workspace context")
    if !Workspace.begin() {
      Logger.daemon.fatal("could not start workspace context")
    }

    Logger.daemon.debug("startup: starting the process manager")
    if !ProcessManager.shared.begin() {
      Logger.daemon.fatal("could not start process manager")
    }

    Logger.daemon.debug("startup: starting the display manager")
    if !DisplayManager.shared.begin() {
      Logger.daemon.fatal("could not start display manager")
    }

    Logger.daemon.debug("startup: starting the mouse handler")
    if !WM.sync({ MouseState.shared.beginEventTap(mask: mouseEventMask) }) {
      Logger.daemon.fatal("could not start mouse handler")
    }

    Logger.daemon.debug("startup: observing Mission Control")
    MissionControl.shared.observe()

    //
    // NOTE: Registration order is the declaration order of SLSNotification (see SLSNotification.swift).
    //
    Logger.daemon.debug("startup: registering the SkyLight notifications")
    for kind in SLSNotification.allCases {
      SLS.registerNotification(
        SLS.connection, kind.rawValue, handler: connectionNotificationHandler)
    }

    //
    // NOTE: The -c path is kept for `config --check` without a file. It is set on the event loop before the message loop
    // starts, so no message reads it earlier.
    //
    let explicitConfigFile = options.config
    WM.sync { WindowManager.shared.explicitConfigFile = explicitConfigFile }

    //
    // NOTE: Startup reads the process table on @WM; Carbon callbacks only post events to that queue. The space
    // defaults come first in the sync block: SpaceManager.begin creates the views from them. The only other work in
    // the block is the steps of the config file, in ConfigStep order.
    //
    Logger.daemon.debug("startup: checking the config file")
    let config = WM.sync { loadStartupConfig(explicit: options.config) }
    for line in config.log {
      if config.entries == nil {
        Logger.daemon.warning("\(line)")
      } else {
        Logger.daemon.notice("\(line)")
      }
    }
    for notice in config.notices {
      notify("configuration", notice)
    }

    //
    // NOTE: The file is applied on @WM between the manager starts (ConfigStep, doc/architecture.md "Startup sequence"),
    // so the windows that WindowManager.begin adopts see its rules, and no client message runs before it (the message loop
    // starts after the block). The block returns the number of messages that failed, for one notification.
    //
    Logger.daemon.debug("startup: starting the managers on the event loop")
    let applyFailures = WM.sync { () -> Int in
      Logger.daemon.debug("startup: applying the space defaults")
      Config.current.applySpaceDefaults()
      Logger.daemon.debug("startup: applying the config file settings")
      var failures = config.apply(.settings)
      Logger.daemon.debug("startup: initializing the window manager")
      WindowManager.shared.initialize()
      Logger.daemon.debug("startup: beginning the space manager")
      SpaceManager.shared.begin()
      Logger.daemon.debug("startup: applying the config file manager settings")
      failures += config.apply(.managerSettings)
      Logger.daemon.debug("startup: applying the config file spaces")
      failures += config.apply(.spaces)
      Logger.daemon.debug("startup: applying the config file rules and signals")
      failures += config.apply(.rulesAndSignals)
      Logger.daemon.debug("startup: beginning the window manager")
      WindowManager.shared.begin()
      Logger.daemon.debug("startup: requesting window notifications")
      WindowManager.shared.updateWindowNotifications()
      Logger.daemon.debug("startup: starting the config observer")
      ConfigObserver.shared.start()
      //
      // NOTE: The file is applied before ConfigObserver.start, and the observer only reacts to later sets. Window
      // adoption covers the shadow, opacity, border and tab bar groups of the file. The menu bar alpha is not covered
      // by any step, so it is applied here once, with the fullscreen rule of EventHandler+Space.swift.
      //
      if Config.current.menuBar.opacity != 1.0 {
        Logger.daemon.debug("startup: applying the menu bar alpha")
        let isFullscreen = SpaceManager.shared.currentSpaceID.map { $0.isFullscreen } ?? false
        SLS.setMenuBarAlpha(SLS.connection, isFullscreen ? 1.0 : Config.current.menuBar.opacity)
      }
      return failures
    }
    if applyFailures > 0, let path = config.path {
      notify("configuration", "\(applyFailures) settings of \(path) did not apply..")
    }

    //
    // NOTE: The pins of the config file are set by its `space --pin` messages, which schedule their own pass. This pass
    // covers the displays that are connected at startup, once the config file has been applied.
    //
    Logger.daemon.debug("startup: reconciling the space pins")
    EventLoop.post(.spacePinReconcile, after: .seconds(1), key: .spacePinReconcile)

    Logger.daemon.debug("startup: starting the message loop")
    let socketFile = "/tmp/yabai_\(user).socket"
    if !MessageLoop.begin(socketPath: socketFile) {
      Logger.daemon.fatal("could not start message loop")
    }

    Logger.daemon.debug("startup: checking for a yabairc that is no longer read")
    warnLeftoverYabairc(explicit: options.config)

    Logger.daemon.debug("startup: running the main run loop")
    NSApp.run()

    return 0
  }
}
