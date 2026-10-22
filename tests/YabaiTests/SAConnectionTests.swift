import Darwin
import Dispatch
import Testing
@testable import Yabai
import YabaiTestSupport

/// A peer that reads one request and replies with response, or never replies when it is nil (it waits for the client
/// to close then).
private func withSAPeer(_ response: [UInt8]?, fragment: Bool = false, timeoutMS: Int = 2000,
                        body: (SAConnection) throws -> Void) throws
{
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let client = pair[0], server = pair[1]
    // NOTE: setsockopt fails with EINVAL once the peer has closed, and the client may time out before the server
    // replies (slow under ASan): a later send would then raise SIGPIPE in the test process
    var one: Int32 = 1
    try #require(setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)
    let connection = try #require(SAConnection(fd: client, timeoutMS: timeoutMS))
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        defer { close(server); group.leave() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        func receive() -> Int { buffer.withUnsafeMutableBytes { recv(server, $0.baseAddress, $0.count, 0) } }
        _ = receive()
        guard let response else { while receive() > 0 {}; return }
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
    try withSAPeer(nil, timeoutMS: 150) { #expect($0.command([1, 0, 1]) == .transportFailure) }
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

// NOTE: Only OSAX_ATTRIB_ANIM_TIME is optional: a Dock build without the validated animation patch still works.
@Test(arguments: [UInt32(0x5F), 0x7F]) func scriptingAdditionAttributeVerdictAcceptsEveryBitSet(attributes: UInt32)
{
    #expect(ScriptingAddition.attributeVerdict(attributes) == .supported)
}

@Test func scriptingAdditionAttributeVerdictWarnsWhenOnlyAnimationIsMissing()
{
    #expect(ScriptingAddition.attributeVerdict(0x1F) == .missingAnimation)
    #expect(ScriptingAddition.attributeVerdict(0x1F | 0x20) == .missingAnimation)
}

@Test(arguments: [UInt32(0x00), 0x1E, 0x1B, 0x5B, 0x5E]) func scriptingAdditionAttributeVerdictFailsWhenARequiredBitIsMissing(attributes: UInt32)
{
    #expect(ScriptingAddition.attributeVerdict(attributes) == .unsupported)
}
