import Darwin
import Testing
import YabaiCore

@testable import Yabai

func ipcPair() throws -> (server: IPCConnection, client: IPCConnection) {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  return (try IPCConnection(taking: pair[0]), try IPCConnection(taking: pair[1]))
}

/// Reads one reply. It waits on the calling thread: @WM test bodies call it on the yabai.wm queue, the others await
/// awaitReply instead.
func readReply(_ connection: IPCConnection) throws -> IPCReply {
  let payload = try #require(
    try connection.readFrame(limit: IPCProtocol.responseLimit, timeout: 30))
  return try IPCProtocol.decode(IPCReply.self, payload: payload)
}

/// Reads one reply on a thread of its own (see onThread), for test bodies on the concurrency pool.
func awaitReply(_ connection: IPCConnection) async throws -> IPCReply {
  let payload = try #require(
    try await onThread { try connection.readFrame(limit: IPCProtocol.responseLimit, timeout: 30) })
  return try IPCProtocol.decode(IPCReply.self, payload: payload)
}

@Suite struct IPCConnectionTests {
  @Test func fragmentedHeaderAndBodyAreReadCompletely() async throws {
    let (server, client) = try ipcPair()
    let request = IPCRequest.command(arguments: ["query", "--windows", "id"])
    let frame = try IPCProtocol.encode(request, limit: IPCProtocol.requestLimit)
    let reader = startReader {
      Result { () throws(IPCError) in
        try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 30)
      }
    }

    // Wait until the reader has consumed each fragment before sending the next.
    // MSG_PEEK observes the socket without stealing bytes from the reader.
    let boundaries = [0, 1, 4, 9, 12, 13, frame.count]
    for index in 0..<(boundaries.count - 1) {
      let fragment = Array(frame[boundaries[index]..<boundaries[index + 1]])
      try await onThread { try client.write(fragment, timeout: 30) }
      let drained = await onThread {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
          var byte: UInt8 = 0
          let count = recv(server.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
          if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
          usleep(1_000)
        }
        return false
      }
      try #require(drained)
    }
    let result = try #require(await reader.finish(), "the reader thread is still running")
    #expect(result == .success(Array(frame.dropFirst(IPCProtocol.headerLength))))
  }

  @Test func deadlinesApplyBeforeWaitingForMoreBytes() async throws {
    let (server, _) = try ipcPair()
    await #expect(throws: IPCError.timedOut) {
      try await onThread { try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 0) }
    }
  }

  @Test func coalescedFramesAreReadIndependently() async throws {
    let (server, client) = try ipcPair()
    let first = try IPCProtocol.encode(
      IPCReply.complete(ok: true), limit: IPCProtocol.responseLimit)
    let second = try IPCProtocol.encode(
      IPCReply.error(command: nil, message: "bad"), limit: IPCProtocol.responseLimit)
    try await onThread { try server.write(first + second, timeout: 30) }
    #expect(try await awaitReply(client) == .complete(ok: true))
    #expect(try await awaitReply(client) == .error(command: nil, message: "bad"))
  }

  @Test func incompleteHeadersAndPayloadsAreFailures() async throws {
    for bytes in [
      [UInt8](repeating: 89, count: 2),
      IPCProtocol.header(length: 10) + Array("abc".utf8),
    ] {
      let (server, client) = try ipcPair()
      try await onThread { try client.write(bytes, timeout: 30) }
      client.finishRequest()
      await #expect(throws: IPCError.incomplete) {
        try await onThread { try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 30) }
      }
    }
  }

  @Test func badMagicVersionAndLengthAreRejectedWithoutReadingABody() async throws {
    var wrongVersion = IPCProtocol.header(length: 10)
    wrongVersion[7] = 3
    for bytes in [
      [0x07, 0x62, 0x61, 0x64], wrongVersion,
      IPCProtocol.header(length: IPCProtocol.requestLimit + 1),
    ] {
      let (server, client) = try ipcPair()
      try await onThread { try client.write(bytes, timeout: 30) }
      await #expect(throws: (any Error).self) {
        try await onThread { try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 30) }
      }
    }
  }

  @Test func descriptorsAreProtectedAndOverlongPathsAreRefused() throws {
    let (server, _) = try ipcPair()
    #expect(fcntl(server.fd, F_GETFD) & FD_CLOEXEC != 0)
    #expect(fcntl(server.fd, F_GETFL) & O_NONBLOCK != 0)
    #expect(throws: IPCError.invalidMessage) {
      try IPCConnection.address(String(repeating: "x", count: 200))
    }
    #expect(throws: IPCError.invalidMessage) { try IPCConnection.address("a\0b") }
  }

  @Test func disconnectedPeerCannotRaiseSIGPIPE() async throws {
    var pair: (server: IPCConnection, client: IPCConnection)? = try ipcPair()
    let server = try #require(pair?.server)
    pair = nil
    // NOTE: A parallel test's posix_spawn holds a copy of every descriptor until its exec closes them, even close-on-exec
    // ones, so a first write can still reach the closed peer. Writes until one fails, for at most a second.
    await #expect(throws: IPCError.io) {
      try await onThread {
        for _ in 0..<100 {
          try server.write([1], timeout: 30)
          usleep(10_000)
        }
      }
    }
  }

  @Test(arguments: ["1", "5", "86400"])
  func positiveClientTimeout(_ value: String) {
    #expect(Client.responseTimeout(value) == Int(value))
  }

  @Test(arguments: ["", "0", "-3", "abc", "1.5", " 7"])
  func invalidClientTimeout(_ value: String) {
    #expect(Client.responseTimeout(value) == Client.defaultResponseTimeout)
  }

  @Test func unsetClientTimeout() {
    #expect(Client.responseTimeout(nil) == 30)
  }
}
