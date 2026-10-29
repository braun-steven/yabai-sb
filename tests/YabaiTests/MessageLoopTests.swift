import Darwin
import Dispatch
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

func ipcPair() throws -> (server: IPCConnection, client: IPCConnection) {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  return (try IPCConnection(taking: pair[0]), try IPCConnection(taking: pair[1]))
}

func readReply(_ connection: IPCConnection) throws -> IPCReply {
  let payload = try #require(
    try connection.readFrame(limit: IPCProtocol.responseLimit, timeout: 30))
  return try IPCProtocol.decode(IPCReply.self, payload: payload)
}

@Suite struct IPCConnectionTests {
  @Test func fragmentedHeaderAndBodyAreReadCompletely() throws {
    let (server, client) = try ipcPair()
    let request = IPCRequest.command(arguments: ["query", "--windows", "id"])
    let frame = try IPCProtocol.encode(request, limit: IPCProtocol.requestLimit)
    let result = Mutex<Result<[UInt8]?, IPCError>?>(nil)
    let finished = DispatchGroup()
    finished.enter()
    startReader {
      defer { finished.leave() }
      let received: Result<[UInt8]?, IPCError>
      do {
        let payload = try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 30)
        received = .success(payload)
      } catch let error as IPCError {
        received = .failure(error)
      } catch {
        Issue.record("unexpected transport error: \(error)")
        received = .failure(.io)
      }
      result.withLock { $0 = received }
    }

    // Wait until the reader has consumed each fragment before sending the next.
    // MSG_PEEK observes the socket without stealing bytes from the reader.
    let boundaries = [0, 1, 4, 9, 12, 13, frame.count]
    for index in 0..<(boundaries.count - 1) {
      try client.write(Array(frame[boundaries[index]..<boundaries[index + 1]]), timeout: 30)
      let deadline = ContinuousClock.now + .seconds(30)
      var drained = false
      while ContinuousClock.now < deadline {
        var byte: UInt8 = 0
        let count = recv(server.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
          drained = true
          break
        }
        usleep(1_000)
      }
      try #require(drained)
    }
    try #require(finished.wait(timeout: .now() + 30) == .success)
    #expect(result.withLock { $0 } == .success(Array(frame.dropFirst(IPCProtocol.headerLength))))
  }

  @Test func deadlinesApplyBeforeWaitingForMoreBytes() throws {
    let (server, _) = try ipcPair()
    #expect(throws: IPCError.timedOut) {
      try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 0)
    }
  }

  @Test func coalescedFramesAreReadIndependently() throws {
    let (server, client) = try ipcPair()
    let first = try IPCProtocol.encode(
      IPCReply.complete(ok: true), limit: IPCProtocol.responseLimit)
    let second = try IPCProtocol.encode(
      IPCReply.error(command: nil, message: "bad"), limit: IPCProtocol.responseLimit)
    try server.write(first + second, timeout: 30)
    #expect(try readReply(client) == .complete(ok: true))
    #expect(try readReply(client) == .error(command: nil, message: "bad"))
  }

  @Test func incompleteHeadersAndPayloadsAreFailures() throws {
    for bytes in [
      [UInt8](repeating: 89, count: 2),
      IPCProtocol.header(length: 10) + Array("abc".utf8),
    ] {
      let (server, client) = try ipcPair()
      try client.write(bytes, timeout: 30)
      client.finishRequest()
      #expect(throws: IPCError.incomplete) {
        try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 30)
      }
    }
  }

  @Test func badMagicVersionAndLengthAreRejectedWithoutReadingABody() throws {
    var wrongVersion = IPCProtocol.header(length: 10)
    wrongVersion[7] = 3
    for bytes in [
      [0x07, 0x62, 0x61, 0x64], wrongVersion,
      IPCProtocol.header(length: IPCProtocol.requestLimit + 1),
    ] {
      let (server, client) = try ipcPair()
      try client.write(bytes, timeout: 30)
      #expect(throws: (any Error).self) {
        try server.readFrame(limit: IPCProtocol.requestLimit, timeout: 30)
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

  @Test func disconnectedPeerCannotRaiseSIGPIPE() throws {
    var pair: (server: IPCConnection, client: IPCConnection)? = try ipcPair()
    let server = try #require(pair?.server)
    pair = nil
    #expect(throws: IPCError.io) { try server.write([1], timeout: 30) }
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
