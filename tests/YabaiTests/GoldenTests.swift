import CPrivate
import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The golden IPC snapshot: a regression check of the responses, not a contract. Responses may change on purpose:
// re-record and explain every changed record. The replay sends every command of
// Golden/commands.txt through handleMessage, in order, on one fixture state of the daemon, and compares each response
// byte for byte with Golden/responses.txt. With GOLDEN_RECORD=1 in the environment it writes responses.txt instead
// (in the source tree), e.g. `GOLDEN_RECORD=1 swift test --filter Golden`; review the diff before committing it.
//
// The fixture is a daemon without displays, spaces or windows: only the defaults of the managers. A command must
// never act on the live displays, spaces or windows of this machine, so the space and display domains are only
// covered by commands that fail before they act.
//
// responses.txt holds one record per command: a line "### <byte count> <command>", the response bytes, and a newline.
// Responses are deterministic JSON snapshots of typed entries and overall success, without wire framing.
//

struct GoldenRecord {
  let command: String
  let response: [UInt8]
}

enum Golden {
  static func url(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Golden"))
  }

  static func commands() throws -> [String] {
    try String(contentsOf: url("commands"), encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { !$0.hasPrefix("#") }
  }

  // A record is a line "### <byte count> <command>", the response bytes, and a newline.
  static func records() throws -> [GoldenRecord] {
    let bytes = Array(try Data(contentsOf: url("responses")))
    var records: [GoldenRecord] = []
    var cursor = 0

    while cursor < bytes.count {
      let end = try #require(bytes[cursor...].firstIndex(of: UInt8(ascii: "\n")))
      let header = String(decoding: bytes[cursor..<end], as: UTF8.self)
      let parts = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
      try #require(parts.count == 3 && parts[0] == "###")
      let length = try #require(Int(parts[1]))

      let start = end + 1
      try #require(start + length < bytes.count && bytes[start + length] == UInt8(ascii: "\n"))
      records.append(
        GoldenRecord(command: String(parts[2]), response: Array(bytes[start..<start + length])))
      cursor = start + length + 1
    }

    return records
  }

  //
  // NOTE: A command is split at spaces into the arguments of the client, and single quotes keep spaces in an argument
  // like a shell does (action='echo hi'). The message is then encoded like the client does, without its length.
  //

  static func encode(_ line: String) -> Message {
    var arguments: [[UInt8]] = []
    var current: [UInt8]? = nil
    var quoted = false

    for byte in line.utf8 {
      if byte == UInt8(ascii: " ") && !quoted {
        if let argument = current { arguments.append(argument) }
        current = nil
      } else if byte == UInt8(ascii: "'") {
        quoted.toggle()
        current = current ?? []
      } else {
        current = (current ?? []) + [byte]
      }
    }
    if let argument = current { arguments.append(argument) }

    return Message(commandTokens: arguments.map { Token($0) })
  }

  @WM static func run(_ line: String) -> [UInt8] {
    var response = Response()
    var message = encode(line)
    handleMessage(&response, &message)
    return render(response).flatMap { Array(($0.stdout + $0.stderr).utf8) }
  }

  /// Human output assertions deliberately exclude protocol framing.
  static func render(_ response: Response) -> [CLIOutput] {
    var renderer = IPCRenderer(request: .command(arguments: ["test"]))
    return response.entries.map { entry in
      do {
        let bytes = try JSON.encode(IPCOutput(command: 1, entry: entry))
        return try renderer.consume(IPCProtocol.decode(IPCReply.self, payload: bytes))
      } catch {
        Issue.record("cannot render result: \(error)")
        return CLIOutput()
      }
    }
  }

  private struct Snapshot: Encodable {
    let entries: [IPCOutput]
    let ok: Bool
  }

  @WM static func structured(_ line: String) throws -> [UInt8] {
    var response = Response()
    var message = encode(line)
    handleMessage(&response, &message)
    return try JSON.encode(
      Snapshot(
        entries: response.entries.map { IPCOutput(command: 1, entry: $0) },
        ok: response.failures.isEmpty))
  }

  @WM static func fixture() {
    DaemonFixture.reset()
  }

  static func escaped(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
      switch byte {
      case UInt8(ascii: "\n"): "\\n"
      case UInt8(ascii: "\t"): "\\t"
      case 0..<0x20: String(format: "\\x%02x", byte)
      default: String(decoding: [byte], as: UTF8.self)
      }
    }.joined()
  }
}

extension DaemonState {
  @Suite
  @WM struct GoldenTests {
    @Test func goldenCaptureCoversEveryCommand() throws {
      let commands = try Golden.commands()
      let records = try Golden.records()

      #expect(commands.count >= 60)
      #expect(records.map(\.command) == commands)
    }

    @Test @WM func goldenReplay() throws {
      let commands = try Golden.commands()
      Golden.fixture()

      if ProcessInfo.processInfo.environment["GOLDEN_RECORD"] != nil {
        var output: [UInt8] = []
        for command in commands {
          let response = try Golden.structured(command)
          output +=
            Array("### \(response.count) \(command)\n".utf8) + response + [UInt8(ascii: "\n")]
        }

        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(
          path: "Golden/responses.txt")
        try Data(output).write(to: url)
        return
      }

      let records = try Golden.records()
      try #require(
        records.map(\.command) == commands,
        "responses.txt does not match commands.txt; record it again")

      for record in records {
        let response = try Golden.structured(record.command)
        #expect(
          response == record.response,
          "'\(record.command)'\n expected: \"\(Golden.escaped(record.response))\"\n actual:   \"\(Golden.escaped(response))\""
        )
      }
    }
  }
}
