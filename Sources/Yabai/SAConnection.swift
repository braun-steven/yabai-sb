import Darwin
import Logging
import OSAX

//
// NOTE: A request has one absolute deadline, including connect and all partial reads/writes. Never retry
// a command after a timeout: the payload may already have applied it. Requests stay synchronous on yabai.wm: the
// payload replies at once and the deadline bounds a stall, and their callers (mouse drag, tree layout, focus,
// scratchpads) order SA operations between the SkyLight and AX calls of one change, which an await would let other
// @WM code interleave with.
//

struct SAConnection {
  let fd: Int32
  let deadline: UInt64

  static func now() -> UInt64 {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC, &value)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
  }

  init?(fd: Int32, timeoutMS: Int = Int(SA_REQUEST_TIMEOUT_MS)) {
    let flags = fcntl(fd, F_GETFL)
    var one: Int32 = 1
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return nil }
    self.fd = fd
    deadline = Self.now() + UInt64(max(0, timeoutMS)) * 1_000_000
  }

  // NOTE: The payload binds its socket in Dock as the console user and refuses a path it does not own (start_daemon
  // in osax/payload.m). The daemon applies the same rule before it connects, so a socket another user left in /tmp
  // never receives a command. As root (--load-sa under sudo) the owner is the user named by SUDO_UID.
  static func isTrustedSocketPath(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    let trusted = isTrustedSocket(
      mode: info.st_mode, owner: info.st_uid, uid: getuid(), sudoUID: sudoUID())
    if !trusted {
      Logger.daemon.warning(
        "scripting-addition socket '\(path)' is not owned by the user; not connecting")
    }
    return trusted
  }

  static func isTrustedSocket(mode: mode_t, owner: uid_t, uid: uid_t, sudoUID: uid_t?) -> Bool {
    guard mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return false }
    if uid != 0 { return owner == uid }
    if let sudoUID { return owner == sudoUID }
    return owner != 0
  }

  // nil for an unset, empty, non-decimal, out-of-range or zero SUDO_UID.
  static func parseSUDOUID(_ text: String?) -> uid_t? {
    guard let text, !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
      let uid = uid_t(text), uid != 0
    else { return nil }
    return uid
  }

  static func sudoUID() -> uid_t? {
    parseSUDOUID(getenv("SUDO_UID").map { String(cString: $0) })
  }

  func connect(_ path: String) -> Bool {
    guard Self.isTrustedSocketPath(path) else { return false }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
    var result: Int32
    repeat {
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    } while result < 0 && errno == EINTR && Self.now() < deadline
    if result == 0 { return true }
    guard errno == EINPROGRESS || errno == EAGAIN, wait(Int16(POLLOUT)) else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
  }

  private func wait(_ events: Int16) -> Bool {
    while true {
      let now = Self.now()
      guard now < deadline else { return false }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let timeout = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
      let result = poll(&descriptor, 1, timeout)
      if result < 0 && errno == EINTR { continue }
      return result > 0 && descriptor.revents & (events | Int16(POLLHUP)) != 0
    }
  }

  func write(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      guard wait(Int16(POLLOUT)) else { return false }
      let count = bytes.withUnsafeBytes {
        send(fd, $0.baseAddress! + offset, bytes.count - offset, 0)
      }
      if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      guard count > 0 else { return false }
      offset += count
    }
    return true
  }

  // nil is a transport failure; [] is an orderly EOF.
  func read(maximum: Int) -> [UInt8]? {
    guard maximum > 0 else { return [] }
    var bytes = [UInt8](repeating: 0, count: maximum)
    while wait(Int16(POLLIN)) {
      let count = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
      if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      guard count >= 0 else { return nil }
      return Array(bytes.prefix(count))
    }
    return nil
  }

  func handshake() -> (version: [UInt8], attributes: UInt32)? {
    guard write([1, 0, UInt8(SA_OPCODE_HANDSHAKE.rawValue)]) else { return nil }
    var response: [UInt8] = []
    while response.count < 256 {
      guard let part = read(maximum: 256 - response.count), !part.isEmpty else { return nil }
      response.append(contentsOf: part)
      if let zero = response.firstIndex(of: 0), response.count >= zero + 6 {
        guard response.count == zero + 6, response.last == 10 else { return nil }
        let attributes = response.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: zero + 1, as: UInt32.self)
        }
        return (Array(response[..<zero]), attributes)
      }
    }
    return nil
  }

  /// The Dock build the payload runs in: its LC_UUID (empty when unreadable) and whether the payload validated it. nil
  /// for a payload without SA_OPCODE_DOCK_INFO, which rejects the message with one status byte.
  func dockInfo() -> (uuid: String, known: Bool)? {
    guard write([1, 0, UInt8(SA_OPCODE_DOCK_INFO.rawValue)]) else { return nil }
    var response: [UInt8] = []
    while response.count < 256 {
      guard let part = read(maximum: 256 - response.count), !part.isEmpty else { return nil }
      response.append(contentsOf: part)
      if let zero = response.firstIndex(of: 0), response.count >= zero + 3 {
        guard response.count == zero + 3, response[zero + 1] <= 1, response.last == 10 else {
          return nil
        }
        return (String(decoding: response[..<zero], as: UTF8.self), response[zero + 1] == 1)
      }
    }
    return nil
  }

  enum Outcome: Equatable {
    case accepted
    case rejected(UInt8)
    case transportFailure

    var isSuccess: Bool { self == .accepted }
  }

  func command(_ bytes: [UInt8]) -> Outcome {
    guard write(bytes), let reply = read(maximum: 1), let value = reply.first else {
      return .transportFailure
    }
    return value == SA_REPLY_ACCEPTED ? .accepted : .rejected(value)
  }
}
