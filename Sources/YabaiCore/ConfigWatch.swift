//
// NOTE: The pure decisions of the watch of the daemon's yabai.toml (Sources/Yabai/ConfigWatcher.swift): whether a change of
// the file is applied, and the directory the watch is placed on. The watch itself, and the reload, are in Sources/Yabai.
//

/// What a change of the watched file does (ConfigWatch.action).
public enum ConfigWatchAction: Equatable, Sendable {
  /// `[daemon] auto_reload` is off: nothing is applied, and the watch should not be running.
  case stopped
  /// The file does not exist (removed, or not created yet): the running config is kept, and nothing is logged as a failure.
  case missing
  /// The contents are the contents of the last load or attempted load: there is nothing new to apply.
  case unchanged
  /// The contents differ from the last load or attempted load: reload the file.
  case reload
}

/// Pure functions of the config watch (no file system access; the caller reads the file).
public enum ConfigWatch {
  /// The action for a change of the watched file. `loaded` is the text the daemon last loaded or attempted (nil when there
  /// was none), and `current` the text now on disk (nil when the file does not exist). Auto-reload off comes first, so a
  /// change that arrives after the watch stopped does nothing.
  public static func action(autoReload: Bool, loaded: [UInt8]?, current: [UInt8]?)
    -> ConfigWatchAction
  {
    guard autoReload else { return .stopped }
    guard let current else { return .missing }
    return loaded == current ? .unchanged : .reload
  }

  /// The directory that holds `path`: the part before its last slash, `/` for a file in the root and `.` for a bare name.
  public static func directory(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "." }
    if slash == path.startIndex { return "/" }
    return String(path[..<slash])
  }
}
