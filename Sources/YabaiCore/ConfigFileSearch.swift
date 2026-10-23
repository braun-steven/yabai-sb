//
// NOTE: The daemon loads the first existing file of $XDG_CONFIG_HOME/yabai/<name> (when the variable is set),
// ~/.config/yabai/<name> and, for the yabairc, ~/.<name>, unless the process was started with -c. The yabairc is what
// the daemon runs until the static config (yabai.toml) is applied at startup; the yabai.toml search has no dot file in
// $HOME. Both the daemon startup and `config --check` / `--reload` without a file call this search, so they agree on the
// file.
//

/// The config file that the search chooses, and the other existing candidates that it ignores.
public struct ConfigFileChoice: Equatable, Sendable {
  public let chosen: String
  public let ignored: [String]

  public init(chosen: String, ignored: [String]) {
    self.chosen = chosen
    self.ignored = ignored
  }
}

/// Pure functions over the config file search (no file system or environment access; the caller passes both in).
public enum ConfigFileSearch {
  /// The paths searched for `filename`, in order. $XDG_CONFIG_HOME/yabai/<filename> comes first only when it is set and
  /// not empty, then ~/.config/yabai/<filename>, then ~/.<filename> when `homeDotfile` is true. A path that appears twice
  /// (e.g. XDG_CONFIG_HOME set to ~/.config) is listed once.
  public static func candidates(
    filename: String, xdgConfigHome: String?, home: String?, homeDotfile: Bool
  ) -> [String] {
    var paths: [String] = []
    if let xdgConfigHome, !xdgConfigHome.isEmpty {
      paths.append("\(xdgConfigHome)/yabai/\(filename)")
    }
    if let home {
      paths.append("\(home)/.config/yabai/\(filename)")
      if homeDotfile {
        paths.append("\(home)/.\(filename)")
      }
    }

    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  /// The file the daemon loads. An explicit path (from -c) wins, and nothing is ignored: it is chosen even when it does
  /// not exist, so the caller reports that. Otherwise the first candidate for which `exists` is true is chosen, and the
  /// later existing candidates are the ignored ones. Nil when no candidate exists.
  ///
  /// `resolve` gives the real path of a file (symlinks followed). Two existing candidates that resolve to one file count
  /// once: a later candidate that is the chosen file, reached through a link, is not reported as ignored.
  public static func choose(
    explicit: String?, candidates: [String], exists: (String) -> Bool,
    resolve: (String) -> String = { $0 }
  ) -> ConfigFileChoice? {
    if let explicit, !explicit.isEmpty {
      return ConfigFileChoice(chosen: explicit, ignored: [])
    }

    var files = Set<String>()
    let found = candidates.filter { exists($0) && files.insert(resolve($0)).inserted }
    guard let chosen = found.first else { return nil }
    return ConfigFileChoice(chosen: chosen, ignored: Array(found.dropFirst()))
  }

  /// The notice for a yabairc that the daemon does not read in favor of a yabai.toml: nil unless no yabai.toml is chosen
  /// (`toml` is nil) and a yabairc exists. `tomlCandidates` are the yabai.toml paths the search lists; the first one is
  /// where the file belongs.
  public static func leftoverYabaircNotice(
    toml: ConfigFileChoice?, yabairc: ConfigFileChoice?, tomlCandidates: [String]
  ) -> String? {
    guard toml == nil, yabairc != nil, let target = tomlCandidates.first else { return nil }
    return "yabairc is no longer read; convert it to \(target)"
  }

  //
  // NOTE: The daemon resolves a relative path against its own directory, not the one of `yabai -m`. The client makes the
  // file of `config --check <file>` and `config --reload <file>` absolute before it sends the message, so both sides
  // read the same file.
  //

  /// The arguments of a message `config --check <file>` or `config --reload <file>` with a relative `<file>` made absolute
  /// against `workingDirectory`, the client's directory. Any other message, an absolute file or no file is returned unchanged.
  public static func resolvingConfigFile(_ arguments: [[UInt8]], workingDirectory: String)
    -> [[UInt8]]
  {
    guard arguments.count >= 3, arguments[0] == Array("config".utf8),
      arguments[1] == Array("--check".utf8) || arguments[1] == Array("--reload".utf8)
    else {
      return arguments
    }

    let file = arguments[2]
    guard let first = file.first, first != UInt8(ascii: "/") else { return arguments }

    var resolved = arguments
    var directory = Array(workingDirectory.utf8)
    if directory.last != UInt8(ascii: "/") { directory.append(UInt8(ascii: "/")) }
    resolved[2] = directory + file
    return resolved
  }
}
