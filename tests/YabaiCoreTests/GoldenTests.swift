import Foundation
import Testing

//
// NOTE: The golden IPC capture of the C implementation (tests/src/golden.c, doc/swift-port.md). Until P6 ports the
// IPC domains, this only checks that the capture is complete; P6 replays the records against the Swift handlers.
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
}

@Test func goldenCaptureCoversEveryCommand() throws
{
    let commands = try Golden.commands()
    let records = try Golden.records()

    #expect(commands.count >= 60)
    #expect(records.map(\.command) == commands)
}
