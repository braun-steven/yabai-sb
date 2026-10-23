import Testing

@testable import YabaiCore

@Suite("config file search")
struct ConfigFileSearchTests {
  @Test("candidates follow the XDG, home and dot-file order")
  func candidatesOrder() {
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabairc", xdgConfigHome: "/xdg", home: "/home/u", homeDotfile: true)
        == ["/xdg/yabai/yabairc", "/home/u/.config/yabai/yabairc", "/home/u/.yabairc"])
  }

  @Test("candidates of yabai.toml have no dot file in $HOME")
  func candidatesTomlHasNoDotFile() {
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: "/xdg", home: "/home/u", homeDotfile: false)
        == ["/xdg/yabai/yabai.toml", "/home/u/.config/yabai/yabai.toml"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: nil, home: "/home/u", homeDotfile: false)
        == ["/home/u/.config/yabai/yabai.toml"])
  }

  @Test("candidates skip an unset or empty XDG_CONFIG_HOME and a missing HOME")
  func candidatesOptionalInputs() {
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabairc", xdgConfigHome: nil, home: "/home/u", homeDotfile: true)
        == ["/home/u/.config/yabai/yabairc", "/home/u/.yabairc"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabairc", xdgConfigHome: "", home: "/home/u", homeDotfile: true)
        == ["/home/u/.config/yabai/yabairc", "/home/u/.yabairc"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabairc", xdgConfigHome: "/xdg", home: nil, homeDotfile: true)
        == ["/xdg/yabai/yabairc"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabairc", xdgConfigHome: nil, home: nil, homeDotfile: true
      ).isEmpty)
  }

  @Test("candidates list a path that appears twice once")
  func candidatesDeduplicate() {
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabairc", xdgConfigHome: "/home/u/.config", home: "/home/u", homeDotfile: true)
        == ["/home/u/.config/yabai/yabairc", "/home/u/.yabairc"])
  }

  @Test("no existing candidate chooses nothing")
  func chooseNone() {
    let candidates = ["/a", "/b", "/c"]
    #expect(
      ConfigFileSearch.choose(explicit: nil, candidates: candidates, exists: { _ in false }) == nil)
    #expect(ConfigFileSearch.choose(explicit: nil, candidates: [], exists: { _ in true }) == nil)
  }

  @Test("one existing candidate is chosen and nothing is ignored")
  func chooseOne() {
    let candidates = ["/a", "/b", "/c"]
    #expect(
      ConfigFileSearch.choose(explicit: nil, candidates: candidates, exists: { $0 == "/b" })
        == ConfigFileChoice(chosen: "/b", ignored: []))
  }

  @Test("several existing candidates: the first is chosen and the others are ignored in order")
  func chooseSeveral() {
    let candidates = ["/a", "/b", "/c"]
    #expect(
      ConfigFileSearch.choose(explicit: nil, candidates: candidates, exists: { $0 != "/x" })
        == ConfigFileChoice(chosen: "/a", ignored: ["/b", "/c"]))
    #expect(
      ConfigFileSearch.choose(
        explicit: nil, candidates: candidates, exists: { $0 == "/c" || $0 == "/b" })
        == ConfigFileChoice(chosen: "/b", ignored: ["/c"]))
  }

  @Test("an explicit path wins over the search and ignores nothing, even when it does not exist")
  func chooseExplicit() {
    let candidates = ["/a", "/b"]
    #expect(
      ConfigFileSearch.choose(explicit: "/explicit", candidates: candidates, exists: { _ in true })
        == ConfigFileChoice(chosen: "/explicit", ignored: []))
    #expect(
      ConfigFileSearch.choose(explicit: "/explicit", candidates: candidates, exists: { _ in false })
        == ConfigFileChoice(chosen: "/explicit", ignored: []))
  }

  @Test("an explicit yabai.toml (-c) wins over the yabai.toml search and any yabairc")
  func chooseExplicitToml() {
    let candidates = ConfigFileSearch.candidates(
      filename: "yabai.toml", xdgConfigHome: nil, home: "/home/u", homeDotfile: false)
    let existing: Set<String> = ["/home/u/.config/yabai/yabai.toml"]
    #expect(
      ConfigFileSearch.choose(
        explicit: "/tmp/other.toml", candidates: candidates, exists: { existing.contains($0) })
        == ConfigFileChoice(chosen: "/tmp/other.toml", ignored: []))
  }

  @Test("an empty explicit path is no explicit path")
  func chooseEmptyExplicit() {
    let candidates = ["/a", "/b"]
    #expect(
      ConfigFileSearch.choose(explicit: "", candidates: candidates, exists: { $0 == "/b" })
        == ConfigFileChoice(chosen: "/b", ignored: []))
    #expect(
      ConfigFileSearch.choose(explicit: "", candidates: candidates, exists: { _ in false }) == nil)
  }

  @Test("the search of the daemon: XDG file, home config and dot file all present")
  func chooseDaemonOrder() {
    let candidates = ConfigFileSearch.candidates(
      filename: "yabairc", xdgConfigHome: "/xdg", home: "/home/u", homeDotfile: true)
    let existing: Set<String> = ["/xdg/yabai/yabairc", "/home/u/.yabairc"]
    #expect(
      ConfigFileSearch.choose(
        explicit: nil, candidates: candidates, exists: { existing.contains($0) })
        == ConfigFileChoice(chosen: "/xdg/yabai/yabairc", ignored: ["/home/u/.yabairc"]))
  }

  @Test("a symlink to the chosen file is not reported as an ignored file")
  func chooseSymlinkCountsOnce() {
    // /b is a link to /a: both exist, and they are one file.
    let candidates = ["/a", "/b"]
    let resolve: (String) -> String = { $0 == "/b" ? "/a" : $0 }
    #expect(
      ConfigFileSearch.choose(
        explicit: nil, candidates: candidates, exists: { _ in true }, resolve: resolve)
        == ConfigFileChoice(chosen: "/a", ignored: []))
  }

  @Test("a link to the chosen file is dropped, another existing file is still ignored")
  func chooseSymlinkKeepsOtherFiles() {
    // /c links to /a; /d is a separate file.
    let candidates = ["/a", "/c", "/d"]
    let resolve: (String) -> String = { $0 == "/c" ? "/a" : $0 }
    #expect(
      ConfigFileSearch.choose(
        explicit: nil, candidates: candidates, exists: { _ in true }, resolve: resolve)
        == ConfigFileChoice(chosen: "/a", ignored: ["/d"]))
  }

  @Test("a dangling link is not chosen, and a link to the chosen file is dropped")
  func chooseSymlinkDanglingAndLinked() {
    // /a does not exist (a dangling link); /b and /c are one file, /c being a link to /b.
    let candidates = ["/a", "/b", "/c"]
    let existing: Set<String> = ["/b", "/c"]
    let resolve: (String) -> String = { $0 == "/c" ? "/b" : $0 }
    #expect(
      ConfigFileSearch.choose(
        explicit: nil, candidates: candidates, exists: { existing.contains($0) }, resolve: resolve)
        == ConfigFileChoice(chosen: "/b", ignored: []))
  }

  @Test("the leftover yabairc notice: only when no yabai.toml is chosen and a yabairc exists")
  func leftoverYabaircNotice() {
    let tomlCandidates = ["/home/u/.config/yabai/yabai.toml"]
    let yabairc = ConfigFileChoice(chosen: "/home/u/.config/yabai/yabairc", ignored: [])
    let toml = ConfigFileChoice(chosen: "/home/u/.config/yabai/yabai.toml", ignored: [])

    #expect(
      ConfigFileSearch.leftoverYabaircNotice(
        toml: nil, yabairc: yabairc, tomlCandidates: tomlCandidates)
        == "yabairc is no longer read; convert it to /home/u/.config/yabai/yabai.toml")
    #expect(
      ConfigFileSearch.leftoverYabaircNotice(
        toml: toml, yabairc: yabairc, tomlCandidates: tomlCandidates) == nil)
    #expect(
      ConfigFileSearch.leftoverYabaircNotice(
        toml: nil, yabairc: nil, tomlCandidates: tomlCandidates) == nil)
    #expect(
      ConfigFileSearch.leftoverYabaircNotice(toml: nil, yabairc: yabairc, tomlCandidates: []) == nil
    )
  }

  @Test("an explicit -c yabairc is a chosen file, so no leftover notice is given")
  func leftoverYabaircNoticeForExplicit() {
    let explicit = ConfigFileSearch.choose(
      explicit: "/tmp/yabairc", candidates: [], exists: { _ in false })
    let yabairc = ConfigFileChoice(chosen: "/home/u/.config/yabai/yabairc", ignored: [])
    #expect(
      ConfigFileSearch.leftoverYabaircNotice(
        toml: explicit, yabairc: yabairc, tomlCandidates: ["/home/u/.config/yabai/yabai.toml"])
        == nil)
  }

  @Test("config --check and --reload resolve a relative file against the client's directory")
  func resolvingConfigFile() {
    func bytes(_ words: [String]) -> [[UInt8]] { words.map { Array($0.utf8) } }

    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "yabairc"]), workingDirectory: "/Users/u/cfg")
        == bytes(["config", "--check", "/Users/u/cfg/yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "yabairc"]), workingDirectory: "/")
        == bytes(["config", "--check", "/yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "sub/yabairc"]), workingDirectory: "/a/")
        == bytes(["config", "--check", "/a/sub/yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "/tmp/yabairc"]), workingDirectory: "/a")
        == bytes(["config", "--check", "/tmp/yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(bytes(["config", "--check"]), workingDirectory: "/a")
        == bytes(["config", "--check"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--reload", "yabairc"]), workingDirectory: "/Users/u/cfg")
        == bytes(["config", "--reload", "/Users/u/cfg/yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--reload", "/tmp/yabairc"]), workingDirectory: "/a")
        == bytes(["config", "--reload", "/tmp/yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(bytes(["config", "--reload"]), workingDirectory: "/a")
        == bytes(["config", "--reload"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--reloads", "yabairc"]), workingDirectory: "/a")
        == bytes(["config", "--reloads", "yabairc"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "window_gap", "10"]), workingDirectory: "/a")
        == bytes(["config", "window_gap", "10"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["window", "--focus", "west"]), workingDirectory: "/a")
        == bytes(["window", "--focus", "west"]))
  }
}
