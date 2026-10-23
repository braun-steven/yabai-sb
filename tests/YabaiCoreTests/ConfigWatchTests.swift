import Testing

@testable import YabaiCore

@Suite("config watch decisions")
struct ConfigWatchTests {
  private static let text: [UInt8] = Array("[config]\nwindow_gap = 10\n".utf8)
  private static let other: [UInt8] = Array("[config]\nwindow_gap = 12\n".utf8)

  @Test(
    "a change of the file is applied only when auto-reload is on and the text differs",
    arguments: [
      // autoReload, loaded, current, action
      (false, Self.text, Self.other, ConfigWatchAction.stopped),
      (false, nil, nil, ConfigWatchAction.stopped),
      (true, Self.text, Self.text, ConfigWatchAction.unchanged),
      (true, Self.text, Self.other, ConfigWatchAction.reload),
      (true, nil, Self.text, ConfigWatchAction.reload),
      (true, Self.text, nil, ConfigWatchAction.missing),
      (true, nil, nil, ConfigWatchAction.missing),
    ] as [(Bool, [UInt8]?, [UInt8]?, ConfigWatchAction)])
  func action(
    autoReload: Bool, loaded: [UInt8]?, current: [UInt8]?, expected: ConfigWatchAction
  ) {
    #expect(
      ConfigWatch.action(autoReload: autoReload, loaded: loaded, current: current) == expected)
  }

  @Test(
    "the watch is placed on the directory of the file",
    arguments: [
      ("/Users/u/.config/yabai/yabai.toml", "/Users/u/.config/yabai"),
      ("/yabai.toml", "/"),
      ("yabai.toml", "."),
      ("/tmp/a.b/c.toml", "/tmp/a.b"),
    ])
  func directory(path: String, expected: String) {
    #expect(ConfigWatch.directory(of: path) == expected)
  }
}
