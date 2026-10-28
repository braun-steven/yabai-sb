import Testing
import YabaiTestSupport

@testable import YabaiCore

@Test func jsonEncodeEscapesStringsAndNonFiniteNumbers() throws {
  #expect(
    String(decoding: try JSON.encode(["a/b\"\\\n\u{1}"]), as: UTF8.self)
      == "[\"a/b\\\"\\\\\\n\\u0001\"]")
  #expect(
    String(
      decoding: try JSON.encode([Double.nan, .infinity, -.infinity, 0, -1728, 1.5]), as: UTF8.self)
      == "[\"nan\",\"inf\",\"-inf\",0,-1728,1.5]")
}

@Test func jsonEncodeEscapesControlCharactersOnly() throws {
  #expect(
    String(decoding: try JSON.encode(["\u{8}\u{c}\r\t\u{1f}\u{7f}caf\u{e9}"]), as: UTF8.self)
      == "[\"\\b\\f\\r\\t\\u001f\u{7f}caf\u{e9}\"]")
}

@Test func responseKeepsJSONSeparateFromTextAndErrors() throws {
  var response = Response()
  response.write(json: .windows([]))
  response.write("text\n")
  response.fail(CommandError("bad\n"))
  #expect(response.text == "text\n")
  #expect(response.failures == ["bad\n"])
  #expect(response.entries.count == 3)
  guard case .json(let result) = response.entries[0] else {
    Issue.record("expected a JSON result")
    return
  }
  #expect(String(decoding: try JSON.encode(result), as: UTF8.self) == "[]")
}
