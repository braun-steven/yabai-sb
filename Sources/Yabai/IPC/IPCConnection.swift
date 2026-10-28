import Darwin
import YabaiCore

/// Owns a nonblocking socket. Readers hand ownership to the response or subscriber queue;
/// queued work retains the connection, so its descriptor cannot be reused under a pending write.
final class IPCConnection: Sendable {
  let fd: Int32

  init(taking fd: Int32) throws(IPCError) {
    let flags = fcntl(fd, F_GETFL)
    let descriptorFlags = fcntl(fd, F_GETFD)
    var one: Int32 = 1
    guard flags >= 0, descriptorFlags >= 0,
      fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
      fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    else {
      Darwin.close(fd)
      throw .io
    }
    self.fd = fd
  }

  deinit { Darwin.close(fd) }

  static func address(_ path: String) throws(IPCError) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw .invalidMessage
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    return address
  }

  static func connect(path: String, timeout: Int) throws(IPCError) -> IPCConnection {
    var address = try address(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .io }
    let connection = try IPCConnection(taking: fd)
    let deadline = Self.deadline(seconds: timeout)
    var result: Int32
    repeat {
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    } while result < 0 && errno == EINTR && Self.now < deadline
    if result == 0 || errno == EISCONN { return connection }
    guard errno == EINPROGRESS || errno == EAGAIN else { throw .io }
    try connection.wait(Int16(POLLOUT), deadline: deadline)
    var error: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw .io }
    return connection
  }

  private static var now: UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

  private static func deadline(seconds: Int) -> UInt64 {
    let duration = UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000)
    let sum = now.addingReportingOverflow(duration.partialValue)
    return duration.overflow || sum.overflow ? UInt64.max : sum.partialValue
  }

  private func wait(_ events: Int16, deadline: UInt64?) throws(IPCError) {
    while true {
      let timeout: Int32
      if let deadline {
        let now = Self.now
        guard now < deadline else { throw .timedOut }
        let remaining = (deadline - now) / 1_000_000
        timeout = Int32(min(UInt64(Int32.max), remaining + 1))
      } else {
        timeout = -1
      }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&descriptor, 1, timeout)
      if result < 0 && errno == EINTR { continue }
      if result == 0 { continue }
      guard result > 0, descriptor.revents & (events | Int16(POLLHUP)) != 0 else { throw .io }
      return
    }
  }

  private func readExactly(_ count: Int, deadline: UInt64?, allowEOF: Bool = false)
    throws(IPCError) -> [UInt8]?
  {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      try wait(Int16(POLLIN), deadline: deadline)
      let received = bytes.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress! + offset, count - offset)
      }
      if received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      if received == 0 {
        if allowEOF && offset == 0 { return nil }
        throw .incomplete
      }
      guard received > 0 else { throw .io }
      offset += received
    }
    return bytes
  }

  /// One deadline spans the complete header and payload, including retries and partial reads.
  func readFrame(limit: Int, timeout: Int?) throws(IPCError) -> [UInt8]? {
    let deadline = timeout.map { Self.deadline(seconds: $0) }
    guard let magic = try readExactly(4, deadline: deadline, allowEOF: true) else { return nil }
    guard magic == IPCProtocol.magic else { throw .incompatibleVersion }
    guard let rest = try readExactly(8, deadline: deadline) else { throw .incomplete }
    let count = try IPCProtocol.payloadLength(magic + rest, limit: limit)
    return try readExactly(count, deadline: deadline)
  }

  func write(_ bytes: [UInt8], timeout: Int) throws(IPCError) {
    let deadline = Self.deadline(seconds: timeout)
    var offset = 0
    while offset < bytes.count {
      try wait(Int16(POLLOUT), deadline: deadline)
      let sent = bytes.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset)
      }
      if sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      guard sent > 0 else { throw .io }
      offset += sent
    }
  }

  /// Wakes a pending write; the descriptor closes after queued work releases its last reference.
  func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
  func finishRequest() { Darwin.shutdown(fd, SHUT_WR) }
}
