import TOMLDecoder
import Testing

@Test func tomlDecoderParsesTypedValuesAndReportsSyntaxErrorLines() throws {
  let config = try TOMLTable(source: "[config]\nwindow_gap = 10\nmouse_follows_focus = false\n")
    .table(forKey: "config")
  #expect(try config.integer(forKey: "window_gap") == 10)
  #expect(try config.bool(forKey: "mouse_follows_focus") == false)

  do {
    _ = try TOMLTable(source: "a = 1\nb = \n")
    Issue.record("a TOML syntax error was not reported")
  } catch {
    #expect(error.description.contains("Line 2"))
  }
}
