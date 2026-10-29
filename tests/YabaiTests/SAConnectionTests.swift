import Darwin
import Dispatch
import Foundation
import OSAX
import Synchronization
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The test bodies run on the Swift concurrency pool, which has one thread per CPU (three on the CI runner). A
// body that waits in poll, recv, usleep or a DispatchGroup holds one of those threads, so every wait runs on a Thread
// of its own and the body awaits its result (onThread, startReader). The #expect and #require calls stay in the body:
// Test.current is a task-local, which a raw Thread does not have.
//

/// Runs a call that waits (a socket read or write, a poll loop, a DispatchGroup wait) on a thread of its own and
/// returns its result to the awaiting test, without blocking a thread of the concurrency pool.
func onThread<T: Sendable, E: Error>(
  _ body: @escaping @Sendable () throws(E) -> T
) async throws(E) -> T {
  let result = await withCheckedContinuation {
    (continuation: CheckedContinuation<Result<T, E>, Never>) in
    Thread { continuation.resume(returning: Result(catching: body)) }.start()
  }
  return try result.get()
}

/// A socket peer that runs on a thread of its own and returns its result to the test (see onThread). A block on the
/// global dispatch queue waits for the kernel to admit a worker: on the 3-CPU CI runner one waited about 30 s.
final class SocketReader<T: Sendable>: Sendable {
  private let group = DispatchGroup()
  private let result = Mutex<T?>(nil)

  init(_ body: @escaping @Sendable () -> T) {
    group.enter()
    Thread { [self] in
      let value = body()
      result.withLock { $0 = value }
      group.leave()
    }.start()
  }

  /// Waits up to ten seconds for the peer and returns its result, or nil while it still runs.
  func finish() async -> T? {
    let group = group
    guard await onThread({ group.wait(timeout: .now() + .seconds(10)) }) == .success else {
      return nil
    }
    return result.withLock { $0 }
  }
}

/// Starts a socket peer on a thread of its own.
func startReader<T: Sendable>(_ body: @escaping @Sendable () -> T) -> SocketReader<T> {
  SocketReader(body)
}

/// A peer that reads one request and replies with response, or never replies when it is nil (it waits for the client
/// to close then).
private func withSAPeer(
  _ response: [UInt8]?, fragment: Bool = false, timeoutMS: Int = 2000,
  body: (SAConnection) async throws -> Void
) async throws {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  let client = pair[0]
  let server = pair[1]
  // NOTE: setsockopt fails with EINVAL once the peer has closed, and the client may time out before the server
  // replies (slow under ASan): a later send would then raise SIGPIPE in the test process
  var one: Int32 = 1
  try #require(
    setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0)
  let connection = try #require(SAConnection(fd: client, timeoutMS: timeoutMS))
  let peer = startReader {
    defer { close(server) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    func receive() -> Int {
      buffer.withUnsafeMutableBytes { recv(server, $0.baseAddress, $0.count, 0) }
    }
    _ = receive()
    guard let response else {
      while receive() > 0 {}
      return
    }
    if fragment {
      for var byte in response {
        if send(server, &byte, 1, 0) <= 0 { break }
        usleep(100)
      }
    } else {
      _ = response.withUnsafeBytes { send(server, $0.baseAddress, $0.count, 0) }
    }
  }
  // NOTE: The client closes on every path before the wait for the peer, which reads until the client closes.
  let outcome: Result<Void, any Error>
  do {
    try await body(connection)
    outcome = .success(())
  } catch {
    outcome = .failure(error)
  }
  close(client)
  #expect(await peer.finish() != nil, "the peer thread is still running")
  try outcome.get()
}

@Suite struct SAConnectionSocketTests {
  @Test(.timeLimit(.minutes(1))) func saConnectionDistinguishesAcknowledgementEOFAndFailure()
    async throws
  {
    try await withSAPeer([0]) { connection in
      #expect(await onThread { connection.command([1, 0, 1]) } == .accepted)
    }
    try await withSAPeer([2]) { connection in
      #expect(await onThread { connection.command([1, 0, 1]) } == .rejected(2))
    }
    // A payload that closes without a status byte did not confirm the command.
    try await withSAPeer([]) { connection in
      #expect(await onThread { connection.command([1, 0, 1]) } == .transportFailure)
    }
    try await withSAPeer(nil, timeoutMS: 150) { connection in
      #expect(await onThread { connection.command([1, 0, 1]) } == .transportFailure)
    }
  }

  @Test(.timeLimit(.minutes(1))) func saConnectionReadsFragmentedHandshakeAndRejectsTruncation()
    async throws
  {
    let response = Array("2.1.35".utf8) + [0, 0x5f, 0, 0, 0, 10]
    try await withSAPeer(response, fragment: true) { connection in
      let result = try #require(await onThread { connection.handshake() })
      #expect(result.version == Array("2.1.35".utf8))
      #expect(result.attributes == 0x5f)
    }
    for count in 0..<response.count {
      try await withSAPeer(Array(response.prefix(count))) { connection in
        #expect(await onThread { connection.handshake() } == nil)
      }
    }
  }

  @Test(.timeLimit(.minutes(1))) func saConnectionReadsDockInfoAndRejectsOtherReplies()
    async throws
  {
    let uuid = "3BDF6A3B-866B-3C07-920C-E9E7FB57B56B"
    let response = Array(uuid.utf8) + [0, 1, 10]
    try await withSAPeer(response, fragment: true) { connection in
      let result = try #require(await onThread { connection.dockInfo() })
      #expect(result.uuid == uuid)
      #expect(result.known)
    }
    try await withSAPeer([0, 0, 10]) { connection in
      let result = try #require(await onThread { connection.dockInfo() })
      #expect(result.uuid.isEmpty)
      #expect(!result.known)
    }
    for count in 0..<response.count {
      try await withSAPeer(Array(response.prefix(count))) { connection in
        #expect(await onThread { connection.dockInfo() } == nil)
      }
    }
    // A payload without the message replies with the invalid status byte.
    try await withSAPeer([UInt8(SA_REPLY_INVALID)]) { connection in
      #expect(await onThread { connection.dockInfo() } == nil)
    }
    try await withSAPeer(Array(uuid.utf8) + [0, 2, 10]) { connection in
      #expect(await onThread { connection.dockInfo() } == nil)
    }
  }

  @Test(.timeLimit(.minutes(1))) func saConnectionCompletesPartialWritesAndBoundsBackpressure()
    async throws
  {
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let client = pair[0]
    let server = pair[1]
    var size: Int32 = 1024
    setsockopt(client, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let connection = try #require(SAConnection(fd: client, timeoutMS: 2000))
    let expected = [UInt8](repeating: 0x5a, count: 512 * 1024)
    let reader = startReader { () -> (count: Int, uniform: Bool) in
      defer { close(server) }
      var buffer = [UInt8](repeating: 0, count: 123)
      var count = 0
      var uniform = true
      while count < expected.count {
        let received = buffer.withUnsafeMutableBytes { recv(server, $0.baseAddress, $0.count, 0) }
        if received <= 0 { break }
        uniform = uniform && buffer.prefix(received).allSatisfy { $0 == 0x5a }
        count += received
      }
      return (count, uniform)
    }
    let written = await onThread { connection.write(expected) }
    #expect(written)
    shutdown(client, SHUT_WR)
    close(client)
    let received = try #require(await reader.finish(), "the reader thread is still running")
    #expect(received.count == expected.count)
    #expect(received.uniform)

    var stalled: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &stalled) == 0)
    defer {
      close(stalled[0])
      close(stalled[1])
    }
    setsockopt(stalled[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let bounded = try #require(SAConnection(fd: stalled[0], timeoutMS: 50))
    let boundedWritten = await onThread { bounded.write(expected) }
    #expect(!boundedWritten)
  }
}

// NOTE: Only OSAX_ATTRIB_ANIM_TIME is optional: a Dock build without the validated animation patch still works.
@Test(arguments: [UInt32(0x5F), 0x7F]) func scriptingAdditionAttributeVerdictAcceptsEveryBitSet(
  attributes: UInt32
) {
  #expect(ScriptingAddition.attributeVerdict(attributes) == .supported)
}

@Test func scriptingAdditionAttributeVerdictWarnsWhenOnlyAnimationIsMissing() {
  #expect(ScriptingAddition.attributeVerdict(0x1F) == .missingAnimation)
  #expect(ScriptingAddition.attributeVerdict(0x1F | 0x20) == .missingAnimation)
}

@Test(arguments: [UInt32(0x00), 0x1E, 0x1B, 0x5B, 0x5E])
func scriptingAdditionAttributeVerdictFailsWhenARequiredBitIsMissing(attributes: UInt32) {
  #expect(ScriptingAddition.attributeVerdict(attributes) == .unsupported)
}

// The query's capability bits are the payload's attribute bits, which YabaiCore cannot import.
private let capabilityAttributes: [(ScriptingAdditionInfo.Capability, Int32)] = [
  (.dockSpaces, OSAX_ATTRIB_DOCK_SPACES),
  (.desktopPictureManager, OSAX_ATTRIB_DPPM),
  (.addSpace, OSAX_ATTRIB_ADD_SPACE),
  (.removeSpace, OSAX_ATTRIB_REM_SPACE),
  (.moveSpace, OSAX_ATTRIB_MOV_SPACE),
  (.animationPatch, OSAX_ATTRIB_ANIM_TIME),
]

@Test(arguments: capabilityAttributes)
func scriptingAdditionCapabilityMatchesItsAttributeBit(
  capability: ScriptingAdditionInfo.Capability, attribute: Int32
) {
  #expect(capability.bit == UInt32(attribute))
  let present = ScriptingAdditionInfo.capabilities(from: UInt32(attribute))
  #expect(present.filter(\.1).map(\.0) == [capability])
}

struct TrustedSocketRow: Sendable {
  let name: String
  let mode: mode_t
  let owner: uid_t
  let uid: uid_t
  let sudoUID: uid_t?
  let trusted: Bool
}

private let socketMode = mode_t(S_IFSOCK) | 0o600
private let trustedSocketRows: [TrustedSocketRow] = [
  TrustedSocketRow(
    name: "user owns socket", mode: socketMode, owner: 501, uid: 501, sudoUID: nil, trusted: true),
  TrustedSocketRow(
    name: "other user owns socket", mode: socketMode, owner: 502, uid: 501, sudoUID: nil,
    trusted: false),
  TrustedSocketRow(
    name: "root owns socket as user", mode: socketMode, owner: 0, uid: 501, sudoUID: nil,
    trusted: false),
  TrustedSocketRow(
    name: "SUDO_UID ignored when not root", mode: socketMode, owner: 501, uid: 501, sudoUID: 502,
    trusted: true),
  TrustedSocketRow(
    name: "regular file", mode: mode_t(S_IFREG) | 0o600, owner: 501, uid: 501, sudoUID: nil,
    trusted: false),
  TrustedSocketRow(
    name: "symbolic link", mode: mode_t(S_IFLNK) | 0o777, owner: 501, uid: 501, sudoUID: nil,
    trusted: false),
  TrustedSocketRow(
    name: "directory", mode: mode_t(S_IFDIR) | 0o700, owner: 501, uid: 501, sudoUID: nil,
    trusted: false),
  TrustedSocketRow(
    name: "root with SUDO_UID owns socket", mode: socketMode, owner: 501, uid: 0, sudoUID: 501,
    trusted: true),
  TrustedSocketRow(
    name: "root with SUDO_UID, other owner", mode: socketMode, owner: 502, uid: 0, sudoUID: 501,
    trusted: false),
  TrustedSocketRow(
    name: "root with SUDO_UID, root owns socket", mode: socketMode, owner: 0, uid: 0, sudoUID: 501,
    trusted: false),
  TrustedSocketRow(
    name: "root without SUDO_UID, console user", mode: socketMode, owner: 501, uid: 0, sudoUID: nil,
    trusted: true),
  TrustedSocketRow(
    name: "root without SUDO_UID, root owns socket", mode: socketMode, owner: 0, uid: 0,
    sudoUID: nil, trusted: false),
  TrustedSocketRow(
    name: "root, regular file", mode: mode_t(S_IFREG) | 0o600, owner: 501, uid: 0, sudoUID: 501,
    trusted: false),
]

@Test(arguments: trustedSocketRows) func saSocketIsTrustedOnlyWhenOwnedByTheUser(
  row: TrustedSocketRow
) {
  #expect(
    SAConnection.isTrustedSocket(
      mode: row.mode, owner: row.owner, uid: row.uid, sudoUID: row.sudoUID) == row.trusted,
    "\(row.name)")
}

struct SUDOUIDRow: Sendable {
  let text: String?
  let uid: uid_t?
}

private let sudoUIDRows: [SUDOUIDRow] = [
  SUDOUIDRow(text: "501", uid: 501),
  SUDOUIDRow(text: "4294967294", uid: 4_294_967_294),
  SUDOUIDRow(text: nil, uid: nil),
  SUDOUIDRow(text: "", uid: nil),
  SUDOUIDRow(text: "0", uid: nil),
  SUDOUIDRow(text: "501abc", uid: nil),
  SUDOUIDRow(text: " 501", uid: nil),
  SUDOUIDRow(text: "+501", uid: nil),
  SUDOUIDRow(text: "-1", uid: nil),
  SUDOUIDRow(text: "4294967296", uid: nil),
]

@Test(arguments: sudoUIDRows) func saSudoUIDParsesOnlyDecimalNonZeroIDs(row: SUDOUIDRow) {
  #expect(SAConnection.parseSUDOUID(row.text) == row.uid)
}
