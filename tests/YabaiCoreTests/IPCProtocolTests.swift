import Testing
import YabaiCore
import YabaiTestSupport

@Suite struct IPCProtocolTests {
  @Test(arguments: [
    IPCRequest.command(arguments: ["window", "--label", ""]),
    .batch(commands: [["query", "--windows", "id,title"], ["rule", "--remove", ""]]),
    .command(arguments: ["rule", "--add", "title=文書 💻", "app=TextEdit"]),
  ])
  func requestRoundTrips(_ request: IPCRequest) throws {
    let frame = try IPCProtocol.encode(request, limit: IPCProtocol.requestLimit)
    #expect(Array(frame.prefix(8)) == Array("YBIP".utf8) + [0, 0, 0, 2])
    #expect(
      try IPCProtocol.payloadLength(Array(frame.prefix(12)), limit: 1 << 20) == frame.count - 12)
    #expect(try IPCProtocol.decode(IPCRequest.self, payload: Array(frame.dropFirst(12))) == request)
  }

  @Test(arguments: [
    #"{"type":"batch","commands":[]}"#,
    #"{"type":"batch","commands":[["config","window_gap","1"],[]]}"#,
    #"{"type":"command","arguments":[]}"#,
    #"{"type":"unknown","arguments":["query"]}"#,
    #"{"type":"command","arguments":1}"#,
    "{",
  ])
  func malformedRequestsAreRefused(_ json: String) {
    #expect(throws: IPCError.invalidMessage) {
      try IPCProtocol.decode(IPCRequest.self, payload: Array(json.utf8))
    }
  }

  @Test func frameLengthAndVersionAreCheckedBeforePayloadAllocation() throws {
    for length in [0, IPCProtocol.requestLimit + 1] {
      #expect(throws: IPCError.invalidLength) {
        try IPCProtocol.payloadLength(
          IPCProtocol.header(length: length), limit: IPCProtocol.requestLimit)
      }
    }
    #expect(
      try IPCProtocol.payloadLength(
        IPCProtocol.header(length: IPCProtocol.requestLimit), limit: IPCProtocol.requestLimit)
        == IPCProtocol.requestLimit)
    var header = IPCProtocol.header(length: 1)
    header[7] = 3
    #expect(throws: IPCError.incompatibleVersion) {
      try IPCProtocol.payloadLength(header, limit: 1 << 20)
    }
    header[0] = 0
    #expect(throws: IPCError.incompatibleVersion) {
      try IPCProtocol.payloadLength(header, limit: 1 << 20)
    }
    #expect(throws: IPCError.incomplete) {
      try IPCProtocol.payloadLength([1, 2], limit: 1 << 20)
    }
    #expect(throws: IPCError.invalidLength) {
      try IPCProtocol.encode("too long", limit: 2)
    }
  }

  @Test func jsonResultsPreserveIntegerBoundariesAndNulls() throws {
    let value = JSONValue.object([
      "signed": .integer(.min), "unsigned": .unsignedInteger(.max),
      "null": .null, "fraction": .number(0.125), "bool": .bool(true),
      "array": .array([.string("a\u{0}b\u{7}文"), .integer(.max)]),
    ])
    let reply = IPCReply.output(command: 1, data: value, format: .json)
    #expect(try IPCProtocol.decode(IPCReply.self, payload: JSON.encode(reply)) == reply)
    var renderer = IPCRenderer(request: .command(arguments: ["query"]))
    let output = try renderer.consume(reply)
    #expect(output.stdout.contains("18446744073709551615"))
    #expect(output.stdout.contains("-9223372036854775808"))
    #expect(output.stderr.isEmpty)
  }

  @Test func typedResultsEncodeAsNestedJSON() throws {
    let output = IPCOutput(
      command: 1, entry: .json(.window(WindowInfo(id: WindowID(42), properties: [.id]))))
    let reply = try IPCProtocol.decode(IPCReply.self, payload: JSON.encode(output))
    #expect(reply == .output(command: 1, data: .object(["id": .integer(42)]), format: .json))
  }

  @Test func mixedBatchKeepsSuccessfulOutputOnStdout() throws {
    var renderer = IPCRenderer(request: .batch(commands: [["config"], ["config"]]))
    #expect(
      try renderer.consume(.error(command: 1, message: "bad\nworse\n"))
        == CLIOutput(stderr: "1: bad\n1: worse\n"))
    #expect(
      try renderer.consume(.output(command: 2, data: .string("off\n"), format: .text))
        == CLIOutput(stdout: "off\n"))
    _ = try renderer.consume(.complete(ok: false))
    #expect(try renderer.finish() == false)
    #expect(throws: IPCError.invalidMessage) {
      try renderer.consume(.complete(ok: false))
    }
  }

  @Test func oneCommandCanContinueAfterAnError() throws {
    var renderer = IPCRenderer(request: .command(arguments: ["config"]))
    _ = try renderer.consume(.error(command: 1, message: "bad\n"))
    #expect(
      try renderer.consume(.output(command: 1, data: .string("ok\u{7}\u{0}\n"), format: .text))
        == CLIOutput(stdout: "ok\u{7}\u{0}\n"))
    _ = try renderer.consume(.complete(ok: false))
    #expect(try renderer.finish() == false)
  }

  @Test func completionAndSubscriptionSequencesAreValidated() throws {
    var renderer = IPCRenderer(request: .command(arguments: ["query"]))
    #expect(throws: IPCError.incomplete) { try renderer.finish() }
    #expect(throws: IPCError.invalidMessage) { try renderer.consume(.event(data: [:])) }
    #expect(throws: IPCError.invalidMessage) { try renderer.consume(.subscribed(events: [])) }
    #expect(throws: IPCError.invalidMessage) {
      try renderer.consume(.output(command: 2, data: .string(""), format: .text))
    }
    #expect(throws: IPCError.invalidMessage) {
      try renderer.consume(.complete(ok: false))
    }
    _ = try renderer.consume(.complete(ok: true))
    #expect(try renderer.finish())

    var subscription = IPCRenderer(request: .command(arguments: ["subscribe"]))
    #expect(
      try subscription.consume(.subscribed(events: ["window_focused"])).stdout
        == "{\"subscribed\":[\"window_focused\"]}\n")
    #expect(
      try subscription.consume(.event(data: ["event": "window_focused"])).stdout
        == "{\"event\":\"window_focused\"}\n")
    #expect(throws: IPCError.invalidMessage) { try subscription.consume(.complete(ok: true)) }
    #expect(try subscription.finish())
  }

  @Test func batchCommandIndicesCannotMoveBackwards() throws {
    var renderer = IPCRenderer(request: .batch(commands: [["config"], ["config"]]))
    _ = try renderer.consume(.output(command: 2, data: .string("off\n"), format: .text))
    #expect(throws: IPCError.invalidMessage) {
      try renderer.consume(.error(command: 1, message: "late\n"))
    }
  }
}
