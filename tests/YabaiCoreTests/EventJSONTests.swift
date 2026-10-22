import Testing

@testable import YabaiCore

//
// NOTE: eventJSONLine is the line an event subscriber receives. The keys are sorted, the values stay strings, and a value
// with a newline is escaped, so one event is always one line.
//

@Test func eventJSONLineWritesSortedKeysAndStringValues() {
  let line = eventJSONLine(
    type: "window_focused", arguments: [("YABAI_WINDOW_ID", "42"), ("YABAI_PROCESS_ID", "7")])
  #expect(
    line == Array("{\"event\":\"window_focused\",\"process_id\":\"7\",\"window_id\":\"42\"}\n".utf8)
  )
}

@Test func eventJSONLineWithoutArgumentsHasOnlyTheEvent() {
  let line = eventJSONLine(type: "system_woke", arguments: [])
  #expect(line == Array("{\"event\":\"system_woke\"}\n".utf8))
}

@Test func eventJSONLineMapsSpaceChangeNames() {
  let line = eventJSONLine(
    type: "space_changed",
    arguments: [
      ("YABAI_SPACE_ID", "9"), ("YABAI_RECENT_SPACE_ID", "3"), ("YABAI_SPACE_INDEX", "2"),
      ("YABAI_RECENT_SPACE_INDEX", "1"),
    ])
  #expect(
    line
      == Array(
        "{\"event\":\"space_changed\",\"recent_space_id\":\"3\",\"recent_space_index\":\"1\",\"space_id\":\"9\",\"space_index\":\"2\"}\n"
          .utf8))
}

/// A value with a newline, a quote and a slash stays on one line: the newline and the quote are escaped, the slash is not.
@Test func eventJSONLineEscapesValuesOntoOneLine() {
  let line = eventJSONLine(type: "window_title_changed", arguments: [("YABAI_APP", "a\"b\nc/d")])
  #expect(line == Array("{\"app\":\"a\\\"b\\nc/d\",\"event\":\"window_title_changed\"}\n".utf8))
  #expect(line.filter { $0 == UInt8(ascii: "\n") }.count == 1)
}
