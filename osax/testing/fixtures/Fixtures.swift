import Darwin
import OSAXCoreAPI

public func packed<T>(_ value: T) -> [UInt8] {
  withUnsafeBytes(of: value) { Array($0) }
}

public func fixtures() -> [[UInt8]] {
  let wid = packed(UInt32(7))
  let sid = packed(UInt64(1))
  let list = packed(Int32(3)) + packed(UInt32(0)) + wid + packed(UInt32(8))
  let order = wid + packed(Int32(-1)) + packed(UInt32(0))
  return [
    [1], [2] + sid, [3] + sid, [4] + sid,
    [5] + sid + packed(UInt64(2)) + packed(UInt64(0)) + [0],
    [6] + wid + packed(Int32(-1)) + packed(Int32(32)),
    [9] + wid + packed(Int32(-1)), [10] + wid + [0], [11] + wid + [1], [12] + wid,
    [13] + wid + packed(Float(0)) + packed(Float(0)) + packed(Float(1920)) + packed(Float(1080)),
    [16] + order, [17] + list,
    [18] + sid + list, [19] + sid + wid, [20] + packed(Int32(3)) + order + order + order,
  ]
}

public typealias Validator = @convention(c) (UnsafePointer<UInt8>?, Int) -> Bool
public typealias Server = @convention(c) (Int32) -> Bool

public struct Core: Sendable {
  public let validate: Validator
  public let serve: Server

  public init() {
    validate = sa_swift_validate
    serve = sa_swift_serve
  }

  public func valid(_ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBufferPointer { validate($0.baseAddress, $0.count) }
  }
}

public func framed(_ bytes: [UInt8]) -> [UInt8] {
  packed(UInt16(bytes.count)) + bytes
}

public func socketPair() -> (Int32, Int32)? {
  var descriptors: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
  var one: Int32 = 1
  for fd in descriptors {
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  }
  return (descriptors[0], descriptors[1])
}
