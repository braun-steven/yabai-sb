import Testing

@testable import YabaiCore

@Suite("config file search")
struct ConfigFileSearchTests {
  @Test("candidates follow the XDG and home order, with no dot file in $HOME")
  func candidatesOrder() {
    #expect(
      ConfigFileSearch.candidates(filename: "yabai.toml", xdgConfigHome: "/xdg", home: "/home/u")
        == ["/xdg/yabai/yabai.toml", "/home/u/.config/yabai/yabai.toml"])
    #expect(
      ConfigFileSearch.candidates(filename: "yabai.toml", xdgConfigHome: nil, home: "/home/u")
        == ["/home/u/.config/yabai/yabai.toml"])
  }

  @Test("candidates skip an unset or empty XDG_CONFIG_HOME and a missing HOME")
  func candidatesOptionalInputs() {
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: nil, home: "/home/u")
        == ["/home/u/.config/yabai/yabai.toml"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: "", home: "/home/u")
        == ["/home/u/.config/yabai/yabai.toml"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: "/xdg", home: nil)
        == ["/xdg/yabai/yabai.toml"])
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: nil, home: nil
      ).isEmpty)
  }

  @Test("candidates list a path that appears twice once")
  func candidatesDeduplicate() {
    #expect(
      ConfigFileSearch.candidates(
        filename: "yabai.toml", xdgConfigHome: "/home/u/.config", home: "/home/u")
        == ["/home/u/.config/yabai/yabai.toml"])
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

  @Test("an explicit yabai.toml (-c) wins over the yabai.toml search and any yabai.toml")
  func chooseExplicitToml() {
    let candidates = ConfigFileSearch.candidates(
      filename: "yabai.toml", xdgConfigHome: nil, home: "/home/u")
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

  @Test("config --check and --reload resolve a relative file against the client's directory")
  func resolvingConfigFile() {
    func bytes(_ words: [String]) -> [[UInt8]] { words.map { Array($0.utf8) } }

    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "yabai.toml"]), workingDirectory: "/Users/u/cfg")
        == bytes(["config", "--check", "/Users/u/cfg/yabai.toml"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "yabai.toml"]), workingDirectory: "/")
        == bytes(["config", "--check", "/yabai.toml"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "sub/yabai.toml"]), workingDirectory: "/a/")
        == bytes(["config", "--check", "/a/sub/yabai.toml"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--check", "/tmp/yabai.toml"]), workingDirectory: "/a")
        == bytes(["config", "--check", "/tmp/yabai.toml"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(bytes(["config", "--check"]), workingDirectory: "/a")
        == bytes(["config", "--check"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--reload", "yabai.toml"]), workingDirectory: "/Users/u/cfg")
        == bytes(["config", "--reload", "/Users/u/cfg/yabai.toml"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--reload", "/tmp/yabai.toml"]), workingDirectory: "/a")
        == bytes(["config", "--reload", "/tmp/yabai.toml"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(bytes(["config", "--reload"]), workingDirectory: "/a")
        == bytes(["config", "--reload"]))
    #expect(
      ConfigFileSearch.resolvingConfigFile(
        bytes(["config", "--reloads", "yabai.toml"]), workingDirectory: "/a")
        == bytes(["config", "--reloads", "yabai.toml"]))
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
