import Darwin
import Testing
import YabaiCore

@testable import Yabai

// NOTE: A socket pair exercises the encoded request, server framing, command dispatch, queued response write and EOF
// without starting the daemon listener or connecting to the user's yabai process.

private enum InvalidIPCRequest: String, CaseIterable, Sendable, CustomStringConvertible {
  case negativeLength
  case oversizedLength
  case incompleteLength
  case truncatedPayload

  var description: String { rawValue }

  var bytes: [UInt8] {
    switch self {
    case .negativeLength:
      return messageHeader(-1)
    case .oversizedLength:
      return messageHeader(Int32(MessageLoop.maxMessageLength + 1))
    case .incompleteLength:
      return [1, 0]
    case .truncatedPayload:
      return messageHeader(4) + [0x61, 0x62]
    }
  }
}

private func messageHeader(_ length: Int32) -> [UInt8] {
  withUnsafeBytes(of: length) { Array($0) }
}

private func ipcSocketPair() throws -> (server: Int32, client: Int32) {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)

  var one: Int32 = 1
  for fd in pair {
    try #require(
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)
  }

  var timeout = timeval(tv_sec: 30, tv_usec: 0)
  try #require(
    setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      == 0)
  return (pair[0], pair[1])
}

private func writeAndFinish(_ bytes: [UInt8], to fd: Int32) throws {
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
      var serverSocketTransferred = false
      defer {
        if !serverSocketTransferred { Darwin.close(server) }
      }

      let request = ClientMessage.encode([Array("unknown_test_domain".utf8)])
      try writeAndFinish(request, to: client)

      var receivedBytes: [UInt8] = []
      serverSocketTransferred = true
      MessageLoop.receiveClient(server) { message in
        receivedBytes = message.bytes
        MessageLoop.handle(message)
      }

      #expect(receivedBytes == Array(request.dropFirst(MemoryLayout<Int32>.size)) + [0, 0])
      #expect(
        try readToEnd(client)
          == [Response.failureByte] + Array("unknown domain 'unknown_test_domain'\n".utf8))
    }
  }
}

@Test(arguments: InvalidIPCRequest.allCases)
private func invalidRequestReceivesRejectionAndEOF(_ request: InvalidIPCRequest) throws {
  let (server, client) = try ipcSocketPair()
  defer { Darwin.close(client) }
  var serverSocketTransferred = false
  defer {
    if !serverSocketTransferred { Darwin.close(server) }
  }

  try writeAndFinish(request.bytes, to: client)

  var handlerWasCalled = false
  serverSocketTransferred = true
  MessageLoop.receiveClient(server) { _ in
    handlerWasCalled = true
  }

  #expect(!handlerWasCalled)
  #expect(try readToEnd(client) == MessageLoop.rejection().bytes)
}
