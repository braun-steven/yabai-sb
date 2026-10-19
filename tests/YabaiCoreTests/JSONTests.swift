import CoreGraphics
import Testing
@testable import YabaiCore

// NOTE: Ported from json_string_escaping in tests/src/message.c.

@Test("json_string_escaping") func jsonStringEscaping()
{
    #expect(JSON.string(nil) == "")
    #expect(JSON.string("plain") == "plain")
    #expect(JSON.string("say \"hi\"\n") == "say \\\"hi\\\"\\n")
}

@Test func jsonEscapesEveryControlCharacter()
{
    #expect(JSON.string("a\\b\u{8}\u{c}\r\t") == "a\\\\b\\b\\f\\r\\t")
    #expect(JSON.string("\u{1}\u{1f}\u{7f}") == "\\u0001\\u001f\u{7f}")
    #expect(JSON.string("caf\u{e9}") == "caf\u{e9}")
    #expect(JSON.escape(Array("plain".utf8)) == nil)
}

@Test func jsonNumbersMatchPrintf()
{
    #expect(JSON.number(0) == "0.0000")
    #expect(JSON.number(-0.0) == "-0.0000")
    #expect(JSON.number(1.23456) == "1.2346")
    #expect(JSON.number(-1728) == "-1728.0000")
    #expect(JSON.number(1e30) == "1000000000000000019884624838656.0000")
}

@Test func jsonEncodeEscapesStringsAndNonFiniteNumbers()
{
    #expect(String(decoding: JSON.encode(["a/b\"\\\n\u{1}"]), as: UTF8.self) == "[\"a/b\\\"\\\\\\n\\u0001\"]")
    #expect(String(decoding: JSON.encode([Double.nan, .infinity, -.infinity, 0, -1728, 1.5]), as: UTF8.self) == "[\"nan\",\"inf\",\"-inf\",0,-1728,1.5]")
}

@Test func responseWritesJSONWithNewline()
{
    var response = Response()
    response.write(json: [1, 2])
    #expect(response.text == "[1,2]\n")
}

private func unselected() -> String
{
    Issue.record("the value of an unselected property is evaluated")
    return ""
}

@Test func jsonWriterMatchesJSONProperty()
{
    var json = JSONWriter(flags: 0b101)
    json.property(0b001, "\"id\":1")
    json.property(0b010, unselected())
    json.property(0b100, "\"frame\":" + JSON.frame(CGRect(x: 0, y: 25, width: 1512.5, height: 957)))

    #expect(json.finish() == "{\n\t\"id\":1,\n\t\"frame\":{\n\t\t\"x\":0.0000,\n\t\t\"y\":25.0000,\n\t\t\"w\":1512.5000,\n\t\t\"h\":957.0000\n\t}\n}")
    #expect(JSONWriter(flags: 0).finish() == "{\n\n}")
}
