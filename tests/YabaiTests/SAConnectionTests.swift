import Darwin
import Dispatch
import Testing
@testable import Yabai
import YabaiTestSupport

private func withSAPeer(_ response: [UInt8]?, fragment: Bool = false,
                        body: (SAConnection) throws -> Void) throws
{
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let client = pair[0], server = pair[1]
    let connection = try #require(SAConnection(fd: client, timeoutMS: 150))
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        defer { close(server); group.leave() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = buffer.withUnsafeMutableBytes { recv(server, $0.baseAddress, $0.count, 0) }
        guard let response else { usleep(250_000); return }
        var one: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if fragment {
            for var byte in response { if send(server, &byte, 1, 0) <= 0 { break }; usleep(100) }
        } else {
            _ = response.withUnsafeBytes { send(server, $0.baseAddress, $0.count, 0) }
        }
    }
    defer { close(client); group.wait() }
    try body(connection)
}

@Test(.timeLimit(.minutes(1))) func saConnectionDistinguishesAcknowledgementEOFAndFailure() throws
{
    try withSAPeer([0]) { #expect($0.command([1, 0, 1]) == .accepted) }
    try withSAPeer([2]) { #expect($0.command([1, 0, 1]) == .rejected(2)) }
    try withSAPeer([]) { #expect($0.command([1, 0, 1]) == .legacyUnconfirmed) }
    try withSAPeer(nil) { #expect($0.command([1, 0, 1]) == .transportFailure) }
}

@Test(.timeLimit(.minutes(1))) func saConnectionReadsFragmentedHandshakeAndRejectsTruncation() throws
{
    let response = Array("2.1.35".utf8) + [0, 0x5f, 0, 0, 0, 10]
    try withSAPeer(response, fragment: true) { connection in
        let result = try #require(connection.handshake())
        #expect(result.version == Array("2.1.35".utf8))
        #expect(result.attributes == 0x5f)
    }
    for count in 0..<response.count {
        try withSAPeer(Array(response.prefix(count))) { #expect($0.handshake() == nil) }
    }
}

@Test(.timeLimit(.minutes(1))) func saConnectionCompletesPartialWritesAndBoundsBackpressure() throws
{
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let client = pair[0], server = pair[1]
    var size: Int32 = 1024
    setsockopt(client, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let connection = try #require(SAConnection(fd: client, timeoutMS: 2000))
    let expected = [UInt8](repeating: 0x5a, count: 512 * 1024)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        defer { close(server); group.leave() }
        var buffer = [UInt8](repeating: 0, count: 123)
        var count = 0
        while count < expected.count {
            let received = buffer.withUnsafeMutableBytes { recv(server, $0.baseAddress, $0.count, 0) }
            if received <= 0 { break }
            #expect(buffer.prefix(received).allSatisfy { $0 == 0x5a })
            count += received
        }
        #expect(count == expected.count)
    }
    #expect(connection.write(expected))
    shutdown(client, SHUT_WR)
    close(client)
    group.wait()

    var stalled: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &stalled) == 0)
    defer { close(stalled[0]); close(stalled[1]) }
    setsockopt(stalled[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let bounded = try #require(SAConnection(fd: stalled[0], timeoutMS: 50))
    #expect(!bounded.write(expected))
}
