import ApplicationServices
import CPrivate
import Darwin
import YabaiCore

//
// NOTE: The helpers that the daemon uses: the timer, colors, sockets, strings, windows and geometry.
//

/// The clock of the event timers.
enum OSTimer {
  /// Nanoseconds since boot, on the uptime clock that matches `mach_absolute_time` (it does not advance during sleep).
  static var now: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

  static let frequency: UInt64 = 1_000_000_000

  //
  // NOTE: Subtracts before converting to float: a timestamp in nanoseconds since boot does not fit into the
  // 24 bits of precision of a float, which would round intervals to tens of milliseconds after a few days.
  //

  static func milliseconds(from: UInt64, to: UInt64) -> Float {
    return Float(Int64(bitPattern: to &- from)) * (1000.0 / Float(frequency))
  }
}

/// A color: argb is the color as 0xAARRGGBB, and r, g, b and a are its components from 0 to 1.
struct RGBAColor: Sendable, Equatable {
  var argb: UInt32 = 0
  var r: Float = 0
  var g: Float = 0
  var b: Float = 0
  var a: Float = 0

  init() {}

  init(hex color: UInt32) {
    argb = color
    r = Float((color >> 0x10) & 0xff) / 255.0
    g = Float((color >> 0x08) & 0xff) / 255.0
    b = Float((color >> 0x00) & 0xff) / 255.0
    a = Float((color >> 0x18) & 0xff) / 255.0
  }
}

/// The environment variables that the daemon, its clients and the service read.
enum ProcessEnvironment {
  /// The user from $USER, or nil when it is not set. Each caller decides how a missing user fails.
  static func currentUser() -> String? {
    getenv("USER").map { String(cString: $0) }
  }
}

/// The Unix domain sockets of the IPC client, the daemon and the scripting addition.
enum UnixSocket {
  static func open(_ sockfd: inout Int32) -> Bool {
    sockfd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    return sockfd != -1
  }

  static func connect(_ sockfd: Int32, to socketPath: String) -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
      let bytes = Array(socketPath.utf8.prefix(sunPath.count - 1))
      sunPath.copyBytes(from: bytes)
      sunPath[bytes.count] = 0
    }

    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    } != -1
  }

  static func close(_ sockfd: Int32) {
    Darwin.shutdown(sockfd, SHUT_RDWR)
    Darwin.close(sockfd)
  }
}

extension ProcessSerialNumber {
  /// Whether both serial numbers name the same process.
  func isSame(as other: ProcessSerialNumber) -> Bool {
    var a = self
    var b = other
    return ProcessSameC(&a, &b)
  }
}

extension CGRect {
  /// The x radius, limited to half the width of the rect.
  func clampedXRadius(_ radius: Float) -> Float {
    if radius * 2 > Float(width) { return Float(width) / 2 }
    return radius
  }

  /// The y radius, limited to half the height of the rect.
  func clampedYRadius(_ radius: Float) -> Float {
    if radius * 2 > Float(height) { return Float(height) / 2 }
    return radius
  }

  /// The edges count as inside.
  func containsIncludingEdges(_ point: CGPoint) -> Bool {
    return point.x >= origin.x && point.x <= origin.x + size.width && point.y >= origin.y
      && point.y <= origin.y + size.height
  }
}

extension CGPoint {
  /// Whether the point lies strictly inside the triangle with the corners t[0], t[1] and t[2].
  func isInTriangle(_ t: [CGPoint]) -> Bool {
    let l1 = Float((x - t[0].x) * (t[2].y - t[0].y) - (t[2].x - t[0].x) * (y - t[0].y))
    let l2 = Float((x - t[1].x) * (t[0].y - t[1].y) - (t[0].x - t[1].x) * (y - t[1].y))
    let l3 = Float((x - t[2].x) * (t[1].y - t[2].y) - (t[1].x - t[2].x) * (y - t[2].y))

    return (l1 > 0.0 && l2 > 0.0 && l3 > 0.0) || (l1 < 0.0 && l2 < 0.0 && l3 < 0.0)
  }
}

extension Float {
  /// The value limited to the range min...max.
  func clamped(min: Float, max: Float) -> Float {
    if self < min { return min }
    if self > max { return max }
    return self
  }
}
