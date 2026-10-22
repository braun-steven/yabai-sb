import Darwin
import Foundation
import Synchronization
import OSAXCoreAPI

private struct Cursor
{
    var bytes: UnsafeRawBufferPointer
    var offset = 0

    mutating func take<T>(_ type: T.Type) -> T?
    {
        guard bytes.count - offset >= MemoryLayout<T>.size else { return nil }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
        return value
    }

    var remaining: Int { bytes.count - offset }
}

@_cdecl("sa_swift_validate")
public func swiftValidate(_ message: UnsafePointer<UInt8>?, _ length: Int) -> Bool
{
    guard let message, length > 0, length <= Int(SA_SOCKET_BUFF_LEN) - 2 else { return false }
    var cursor = Cursor(bytes: UnsafeRawBufferPointer(start: message, count: length))
    let opcode = cursor.take(UInt8.self)!
    let expected: Int
    switch opcode {
    case 1: expected = 0
    case 2, 3, 4: expected = 8
    case 5: expected = 25
    case 6, 7, 8, 16, 19: expected = 12
    case 9: expected = 8
    case 10, 11: expected = 5
    case 12: expected = 4
    case 13: expected = 20
    case 14, 15, 17, 18, 20:
        if opcode == 18 && cursor.take(UInt64.self) == nil { return false }
        guard let count = cursor.take(Int32.self), count >= 0 else { return false }
        if opcode == 14 || opcode == 15 {
            guard Int(count) <= cursor.remaining / 4 else { return false }
            for _ in 0..<count {
                guard let wid = cursor.take(UInt32.self) else { return false }
                if wid != 0 && cursor.take(UInt32.self) == nil { return false }
            }
            return cursor.remaining == 0
        }
        let width = opcode == 20 ? 12 : 4
        return cursor.remaining % width == 0 && Int(count) == cursor.remaining / width
    default: return false
    }
    guard cursor.remaining == expected else { return false }
    if opcode == 5 && message[25] > 1 { return false }
    if (opcode == 10 || opcode == 11) && message[5] > 1 { return false }
    if opcode == 7 || opcode == 8 {
        cursor.offset = 5
        let alpha = cursor.take(Float.self)!
        let duration = cursor.take(Float.self)!
        if !alpha.isFinite || alpha < 0 || alpha > 1 || !duration.isFinite || duration < 0 { return false }
    }
    if opcode == 13 {
        cursor.offset = 5
        for _ in 0..<4 {
            if !cursor.take(Float.self)!.isFinite { return false }
        }
    }
    return true
}

private func nowNS() -> UInt64
{
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func transfer(_ fd: Int32, _ bytes: UnsafeMutableRawBufferPointer, writing: Bool, deadline: UInt64) -> Bool
{
    var offset = 0
    while offset < bytes.count {
        let now = nowNS()
        guard now < deadline else { return false }
        let events = Int16(writing ? POLLOUT : POLLIN)
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let wait = poll(&descriptor, 1, Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000)))
        if wait < 0 && errno == EINTR { continue }
        guard wait > 0, descriptor.revents & (events | Int16(POLLHUP)) != 0 else { return false }
        let count = writing ? send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
                            : recv(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
        if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
        guard count > 0 else { return false }
        offset += count
    }
    return true
}

@_cdecl("sa_swift_serve")
public func swiftServe(_ fd: Int32) -> Bool
{
    let flags = fcntl(fd, F_GETFL)
    var one: Int32 = 1
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
    let deadline = nowNS() + UInt64(SA_READ_TIMEOUT_MS) * 1_000_000
    var length: UInt16 = 0
    guard withUnsafeMutableBytes(of: &length, { transfer(fd, $0, writing: false, deadline: deadline) }) else { return false }
    var reply = UInt8(SA_REPLY_INVALID)
    if length > 0 && length <= Int(SA_SOCKET_BUFF_LEN) - 2 {
        var message = [UInt8](repeating: 0, count: Int(length))
        if message.withUnsafeMutableBytes({ transfer(fd, $0, writing: false, deadline: deadline) }),
           message.withUnsafeBufferPointer({ swiftValidate($0.baseAddress, $0.count) }) {
            if message[0] == SA_OPCODE_HANDSHAKE.rawValue {
                let version = String(cString: sa_native_version())
                var response = Array(version.utf8) + [0]
                withUnsafeBytes(of: sa_native_attributes()) { response.append(contentsOf: $0) }
                response.append(10)
                guard response.count <= 256 else { return false }
                return response.withUnsafeMutableBytes { transfer(fd, $0, writing: true, deadline: nowNS() + 1_000_000_000) }
            }
            reply = message.withUnsafeBufferPointer { sa_native_dispatch($0.baseAddress, $0.count) }
        }
    }
    return withUnsafeMutableBytes(of: &reply) { transfer(fd, $0, writing: true, deadline: nowNS() + 1_000_000_000) }
}

private struct Fade
{
    var startAlpha: Float
    var alpha: Float
    var duration: Float
    var start: UInt64
}

// Native alpha calls stay inside the lock, so a tick cannot race with a newer command.
private let fades = Mutex<[UInt32: Fade]>([:])

@_cdecl("sa_swift_opacity")
public func swiftOpacity(_ wid: UInt32, _ alpha: Float, _ duration: Float, _ now: UInt64) -> Bool
{
    guard wid != 0, alpha.isFinite, alpha >= 0, alpha <= 1, duration.isFinite, duration >= 0 else { return false }
    return fades.withLock { state in
        state.removeValue(forKey: wid)
        if duration == 0 { return sa_native_set_alpha(wid, alpha) }
        var start: Float = 0
        guard sa_native_get_alpha(wid, &start) else { return false }
        state[wid] = Fade(startAlpha: start, alpha: alpha, duration: duration, start: now)
        return true
    }
}

// Returns true while fades remain, so the native side can keep its timer armed only for that time.
@_cdecl("sa_swift_tick")
public func swiftTick(_ now: UInt64) -> Bool
{
    fades.withLock { state in
        // Snapshot keys so removing completed fades does not mutate a live iterator.
        for wid in Array(state.keys) {
            let fade = state[wid]!
            let elapsed = now >= fade.start ? Double(now - fade.start) / 1e9 : 0
            let t = min(1, elapsed / Double(fade.duration))
            let alpha = Float((1 - t) * Double(fade.startAlpha) + t * Double(fade.alpha))
            if !sa_native_set_alpha(wid, alpha) || t >= 1 { state.removeValue(forKey: wid) }
        }
        return !state.isEmpty
    }
}

@_cdecl("sa_swift_has_fades")
public func swiftHasFades() -> Bool
{
    fades.withLock { !$0.isEmpty }
}

@_cdecl("sa_swift_reset")
public func swiftReset()
{
    fades.withLock { $0.removeAll() }
}
