import Darwin
import Testing
import YabaiCore

@testable import Yabai

// NOTE: A socket pair exercises the encoded request, server framing, command dispatch, queued response write and EOF
// without starting the daemon listener or connecting to the user's yabai process.

private func ipcSocketPair() throws -> (server: Int32, client: Int32) {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)

  var one: Int32 = 1
  for fd in pair {
    try #require(
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)
  }

  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  try #require(
    setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      == 0)
  return (pair[0], pair[1])
}

private func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
  var written = 0
  while written < bytes.count {
    let count = bytes.withUnsafeBytes {
      Darwin.write(fd, $0.baseAddress!.advanced(by: written), $0.count - written)
    }
    try #require(count > 0)
    written += count
  }
  try #require(shutdown(fd, SHUT_WR) == 0)
}

private func readToEnd(_ fd: Int32) throws -> [UInt8] {
  var result: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 256)
  while true {
    let count = buffer.withUnsafeMutableBytes {
      Darwin.read(fd, $0.baseAddress!, $0.count)
    }
    if count == 0 { return result }
    try #require(count > 0)
    result.append(contentsOf: buffer.prefix(count))
  }
}

extension DaemonState {
  @Suite @WM struct IPCTransportIntegrationTests {
    @Test func requestPassesThroughFramingDispatchAndResponseWrite() throws {
      let (server, client) = try ipcSocketPair()
      defer { Darwin.close(client) }
      var responseOwnsServerSocket = false
      defer {
        if !responseOwnsServerSocket { Darwin.close(server) }
      }

      let request = ClientMessage.encode([Array("unknown_test_domain".utf8)])
      try writeAll(request, to: client)

      let bytes = try MessageLoop.readMessage(server)
      #expect(
        bytes == Array(request.dropFirst(MemoryLayout<Int32>.size)) + [0, 0])
      MessageLoop.handle(DaemonMessage(sockfd: server, bytes: bytes))
      responseOwnsServerSocket = true

      #expect(
        try readToEnd(client)
          == [Response.failureByte] + Array("unknown domain 'unknown_test_domain'\n".utf8))
    }
  }
}
