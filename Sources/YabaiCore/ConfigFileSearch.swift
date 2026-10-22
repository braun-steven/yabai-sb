//
// NOTE: The daemon loads the first existing file of $XDG_CONFIG_HOME/yabai/<name> (when the variable is set),
// ~/.config/yabai/<name> and ~/.<name>, unless the process was started with -c. Both the daemon startup and
// `config --check` / `--reload` without a file call this search, so they agree on the file.
//

/// The config file that the search chooses, and the other existing candidates that it ignores.
public struct ConfigFileChoice: Equatable, Sendable
{
    public let chosen: String
    public let ignored: [String]

    public init(chosen: String, ignored: [String])
    {
        self.chosen = chosen
        self.ignored = ignored
    }
}

/// Pure functions over the config file search (no file system or environment access; the caller passes both in).
public enum ConfigFileSearch
{
    /// The paths searched for `filename`, in order. $XDG_CONFIG_HOME/yabai/<filename> comes first only when it is set and
    /// not empty. A path that appears twice (e.g. XDG_CONFIG_HOME set to ~/.config) is listed once.
    public static func candidates(filename: String, xdgConfigHome: String?, home: String?) -> [String]
    {
        var paths: [String] = []
        if let xdgConfigHome, !xdgConfigHome.isEmpty {
            paths.append("\(xdgConfigHome)/yabai/\(filename)")
        }
        if let home {
            paths.append("\(home)/.config/yabai/\(filename)")
            paths.append("\(home)/.\(filename)")
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// The file the daemon loads. An explicit path (from -c) wins, and nothing is ignored: it is chosen even when it does
    /// not exist, so the caller reports that. Otherwise the first candidate for which `exists` is true is chosen, and the
    /// later existing candidates are the ignored ones. Nil when no candidate exists.
    public static func choose(explicit: String?, candidates: [String], exists: (String) -> Bool) -> ConfigFileChoice?
    {
        if let explicit, !explicit.isEmpty {
            return ConfigFileChoice(chosen: explicit, ignored: [])
        }

        let found = candidates.filter(exists)
        guard let chosen = found.first else { return nil }
        return ConfigFileChoice(chosen: chosen, ignored: Array(found.dropFirst()))
    }
}
