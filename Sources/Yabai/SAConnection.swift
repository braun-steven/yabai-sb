import Darwin
import OSAX

//
// NOTE: A request has one absolute deadline, including connect and all partial reads/writes. Never retry
// a command after a timeout: the payload may already have applied it. Requests stay synchronous on yabai.wm: the
// payload replies at once and the deadline bounds a stall, and their callers (mouse drag, tree layout, focus,
// scratchpads) order SA operations between the SkyLight and AX calls of one change, which an await would let other
// @WM code interleave with.
//

struct SAConnection
{
    let fd: Int32
    let deadline: UInt64

    static func now() -> UInt64
    {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    init?(fd: Int32, timeoutMS: Int = Int(SA_REQUEST_TIMEOUT_MS))
    {
        let flags = fcntl(fd, F_GETFL)
        var one: Int32 = 1
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return nil }
        self.fd = fd
        deadline = Self.now() + UInt64(max(0, timeoutMS)) * 1_000_000
    }

    func connect(_ path: String) -> Bool
    {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        var result: Int32
        repeat {
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        } while result < 0 && errno == EINTR && Self.now() < deadline
        if result == 0 { return true }
        guard errno == EINPROGRESS || errno == EAGAIN, wait(Int16(POLLOUT)) else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }

    private func wait(_ events: Int16) -> Bool
    {
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

    func write(_ bytes: [UInt8]) -> Bool
    {
        var offset = 0
        while offset < bytes.count {
            guard wait(Int16(POLLOUT)) else { return false }
            let count = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, bytes.count - offset, 0) }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    // nil is a transport failure; [] is an orderly EOF from a legacy payload.
    func read(maximum: Int) -> [UInt8]?
    {
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

    func handshake() -> (version: [UInt8], attributes: UInt32)?
    {
        guard write([1, 0, UInt8(SA_OPCODE_HANDSHAKE.rawValue)]) else { return nil }
        var response: [UInt8] = []
        while response.count < 256 {
            guard let part = read(maximum: 256 - response.count), !part.isEmpty else { return nil }
            response.append(contentsOf: part)
            if let zero = response.firstIndex(of: 0), response.count >= zero + 6 {
                guard response.count == zero + 6, response.last == 10 else { return nil }
                let attributes = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: zero + 1, as: UInt32.self) }
                return (Array(response[..<zero]), attributes)
            }
        }
        return nil
    }

    enum Outcome: Equatable
    {
        case accepted
        case legacyUnconfirmed
        case rejected(UInt8)
        case transportFailure

        var isSuccess: Bool { self == .accepted || self == .legacyUnconfirmed }
    }

    func command(_ bytes: [UInt8]) -> Outcome
    {
        guard write(bytes), let reply = read(maximum: 1) else { return .transportFailure }
        guard let value = reply.first else { return .legacyUnconfirmed }
        return value == SA_REPLY_ACCEPTED ? .accepted : .rejected(value)
    }
}
