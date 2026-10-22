import Darwin
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: Reading a client message from a socket pair, the reply to a message that cannot be read, and the response
// timeout of `yabai -m`. The socket pairs hold only bytes the test wrote before the read, and the writer is closed
// after them, so each read ends at the end of the data instead of at a deadline (short deadlines are flaky under ASan).
//

private func header(_ length: Int32) -> [UInt8] {
  withUnsafeBytes(of: length) { Array($0) }
}

/// Reads one message from a socket pair that holds exactly `bytes`. Both ends ignore SIGPIPE, which the test process
/// does not ignore as the daemon does.
private func readFrom(_ bytes: [UInt8]) throws -> Result<[UInt8], MessageLoop.MessageReadError> {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  let writer = pair[0]
  let reader = pair[1]
  defer { close(reader) }

  var one: Int32 = 1
  try #require(
    setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)
  try #require(
    setsockopt(reader, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)

  let written = bytes.withUnsafeBytes { write(writer, $0.baseAddress!, $0.count) }
  try #require(written == bytes.count)
  close(writer)

  do {
    return .success(try MessageLoop.readMessage(reader))
  } catch {
    return .failure(error)
  }
}

@Test(arguments: [-1, Int32.min, Int32(MessageLoop.maxMessageLength) + 1, Int32.max])
func messageLengthOutsideTheCapIsRefusedBeforeTheBody(_ length: Int32) throws {
  // NOTE: No body follows the header: a refused length is not read any further.
  #expect(try readFrom(header(length)) == .failure(.invalidLength))
}

@Test func messageLengthAtTheCapIsAcceptedAndThenReadsItsBody() throws {
  // The header is accepted; the body is missing, so the read fails at the end of the data.
  #expect(try readFrom(header(Int32(MessageLoop.maxMessageLength))) == .failure(.incomplete))
}

@Test func messageWithoutACompleteLengthIsIncomplete() throws {
  #expect(try readFrom([1, 0]) == .failure(.incomplete))
}

@Test func messageEndingBeforeItsLengthIsIncomplete() throws {
  #expect(try readFrom(header(10) + [1, 2, 3]) == .failure(.incomplete))
}

@Test func completeMessageIsReadWithItsTerminatingNulls() throws {
  let encoded = ClientMessage.encode([Array("space".utf8), Array("--focus".utf8), Array("1".utf8)])
  // The reader returns the payload and the two null bytes the daemon adds after it.
  #expect(
    try readFrom(encoded) == .success(Array(encoded.dropFirst(MemoryLayout<Int32>.size)) + [0, 0]))
}

@Test func rejectedMessageGetsTheFailureReply() {
  #expect(MessageLoop.rejection().bytes == [Response.failureByte] + Array("invalid message\n".utf8))
}

@Test(arguments: ["1", "5", "86400"])
func clientTimeoutTakesAPositiveNumberOfSeconds(_ value: String) {
  #expect(Client.responseTimeout(value) == Int(value))
}

@Test(arguments: ["", "0", "-3", "abc", "1.5", " 7"])
func clientTimeoutIgnoresInvalidValues(_ value: String) {
  #expect(Client.responseTimeout(value) == Client.defaultResponseTimeout)
}

@Test func clientTimeoutDefaultsWhenUnset() {
  #expect(Client.responseTimeout(nil) == 30)
}
