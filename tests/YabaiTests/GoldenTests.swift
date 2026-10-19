import Foundation
import Testing
import CPrivate
import YabaiCore
@testable import Yabai

//
// NOTE: The golden IPC snapshot: a regression check of the responses, not a contract. Responses may change on purpose
// (doc/swift-refactor.md, Rules): re-record and explain every changed record. The replay sends every command of
// Golden/commands.txt through handleMessage, in order, on one fixture state of the daemon, and compares each response
// byte for byte with Golden/responses.txt. With GOLDEN_RECORD=1 in the environment it writes responses.txt instead
// (in the source tree), e.g. `GOLDEN_RECORD=1 swift test --filter Golden`; review the diff before committing it.
//
// The fixture is a daemon without displays, spaces or windows: only the defaults of the managers. A command must
// never act on the live displays, spaces or windows of this machine, so the space and display domains are only
// covered by commands that fail before they act.
//
// responses.txt holds one record per command: a line "### <byte count> <command>", the response bytes, and a newline.
// A failure response starts with Response.failureByte (\x07), as it does on the socket.
//

struct GoldenRecord
{
    let command: String
    let response: [UInt8]
}

enum Golden
{
    static func url(_ name: String) throws -> URL
    {
        try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Golden"))
    }

    static func commands() throws -> [String]
    {
        try String(contentsOf: url("commands"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
    }

    // A record is a line "### <byte count> <command>", the response bytes, and a newline.
    static func records() throws -> [GoldenRecord]
    {
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
            records.append(GoldenRecord(command: String(parts[2]), response: Array(bytes[start..<start + length])))
            cursor = start + length + 1
        }

        return records
    }

    //
    // NOTE: A command is split at spaces into the arguments of the client, and single quotes keep spaces in an argument
    // like a shell does (action='echo hi'). The message is then encoded like the client does, without its length.
    //

    static func encode(_ line: String) -> Message
    {
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

        return Message(Array(ClientMessage.encode(arguments).dropFirst(MemoryLayout<Int32>.size)))
    }

    @WM static func run(_ line: String) -> [UInt8]
    {
        var response = Response()
        var message = encode(line)
        handleMessage(&response, &message)
        return response.bytes
    }

    @WM static func fixture()
    {
        WindowManager.shared.initialize()
        SpaceManager.shared.resetToDefaults()
        EventSignals.shared.table = SignalTable()
    }

    static func escaped(_ bytes: [UInt8]) -> String
    {
        bytes.map { byte in
            switch byte {
            case UInt8(ascii: "\n"): "\\n"
            case UInt8(ascii: "\t"): "\\t"
            case 0..<0x20:           String(format: "\\x%02x", byte)
            default:                 String(decoding: [byte], as: UTF8.self)
            }
        }.joined()
    }
}

extension DaemonState
{
    @Suite
    struct GoldenTests
    {
        @Test func goldenCaptureCoversEveryCommand() throws
        {
            let commands = try Golden.commands()
            let records = try Golden.records()

            #expect(commands.count >= 60)
            #expect(records.map(\.command) == commands)
        }

        @Test @WM func goldenReplay() throws
        {
            let commands = try Golden.commands()
            Golden.fixture()

            if ProcessInfo.processInfo.environment["GOLDEN_RECORD"] != nil {
                var output: [UInt8] = []
                for command in commands {
                    let response = Golden.run(command)
                    output += Array("### \(response.count) \(command)\n".utf8) + response + [UInt8(ascii: "\n")]
                }

                let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Golden/responses.txt")
                try Data(output).write(to: url)
                return
            }

            let records = try Golden.records()
            try #require(records.map(\.command) == commands, "responses.txt does not match commands.txt; record it again")

            for record in records {
                let response = Golden.run(record.command)
                #expect(response == record.response, "'\(record.command)'\n expected: \"\(Golden.escaped(record.response))\"\n actual:   \"\(Golden.escaped(response))\"")
            }
        }
    }
}
