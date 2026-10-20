import ApplicationServices
import CPrivate
import Darwin
import YabaiCore

//
// NOTE: The helpers that the daemon uses: the easing curves of the animations, the timer, colors, sockets, strings,
// windows and geometry.
//

/// The easing curve of the window animations (`config window_animation_easing`), named by its config value.
enum AnimationEasing: String, CaseIterable, Sendable
{
    case easeInSine     = "ease_in_sine"
    case easeOutSine    = "ease_out_sine"
    case easeInOutSine  = "ease_in_out_sine"
    case easeInQuad     = "ease_in_quad"
    case easeOutQuad    = "ease_out_quad"
    case easeInOutQuad  = "ease_in_out_quad"
    case easeInCubic    = "ease_in_cubic"
    case easeOutCubic   = "ease_out_cubic"
    case easeInOutCubic = "ease_in_out_cubic"
    case easeInQuart    = "ease_in_quart"
    case easeOutQuart   = "ease_out_quart"
    case easeInOutQuart = "ease_in_out_quart"
    case easeInQuint    = "ease_in_quint"
    case easeOutQuint   = "ease_out_quint"
    case easeInOutQuint = "ease_in_out_quint"
    case easeInExpo     = "ease_in_expo"
    case easeOutExpo    = "ease_out_expo"
    case easeInOutExpo  = "ease_in_out_expo"
    case easeInCirc     = "ease_in_circ"
    case easeOutCirc    = "ease_out_circ"
    case easeInOutCirc  = "ease_in_out_circ"

    //
    // NOTE: The curves compute in Float; the sine curves multiply by M_PI in Double first and then call cosf/sinf on a
    // Float, which keeps their rounding stable.
    //

    /// The eased progress at the linear progress t (0...1).
    func value(at t: Float) -> Float
    {
        switch self {
        case .easeInSine:     1.0 - cosf(Float((Double(t) * Double.pi) / 2.0))
        case .easeOutSine:    sinf(Float((Double(t) * Double.pi) / 2.0))
        case .easeInOutSine:  -(cosf(Float(Double.pi * Double(t))) - 1.0) / 2.0
        case .easeInQuad:     t * t
        case .easeOutQuad:    1.0 - (1.0 - t) * (1.0 - t)
        case .easeInOutQuad:  t < 0.5 ? 2.0 * t * t : 1.0 - powf(-2.0 * t + 2.0, 2.0) / 2.0
        case .easeInCubic:    t * t * t
        case .easeOutCubic:   1.0 - powf(1.0 - t, 3)
        case .easeInOutCubic: t < 0.5 ? 4.0 * t * t * t : 1.0 - powf(-2.0 * t + 2.0, 3.0) / 2.0
        case .easeInQuart:    t * t * t * t
        case .easeOutQuart:   1.0 - powf(1.0 - t, 4)
        case .easeInOutQuart: t < 0.5 ? 8.0 * t * t * t * t : 1.0 - powf(-2.0 * t + 2.0, 4.0) / 2.0
        case .easeInQuint:    t * t * t * t * t
        case .easeOutQuint:   1.0 - powf(1.0 - t, 5)
        case .easeInOutQuint: t < 0.5 ? 16.0 * t * t * t * t * t : 1.0 - powf(-2.0 * t + 2.0, 5.0) / 2.0
        case .easeInExpo:     t == 0.0 ? 0.0 : powf(2.0, 10.0 * t - 10.0)
        case .easeOutExpo:    t == 1.0 ? 1.0 : 1.0 - powf(2.0, -10.0 * t)
        case .easeInOutExpo:  t == 0.0 ? 0.0 : t == 1.0 ? 1.0 : t < 0.5 ? powf(2.0, 20.0 * t - 10.0) / 2.0 : (2.0 - powf(2.0, -20.0 * t + 10.0)) / 2.0
        case .easeInCirc:     1.0 - sqrtf(1.0 - powf(t, 2.0))
        case .easeOutCirc:    sqrtf(1.0 - powf(t - 1.0, 2.0))
        case .easeInOutCirc:  t < 0.5 ? (1.0 - sqrtf(1.0 - powf(2.0 * t, 2.0))) / 2.0 : (sqrtf(1.0 - powf(-2.0 * t + 2.0, 2.0)) + 1.0) / 2.0
        }
    }
}

/// The clock of the event timers.
enum OSTimer
{
    /// Nanoseconds since boot.
    static var now: UInt64 { ReadOSTimerC() }

    static let frequency: UInt64 = 1_000_000_000

    //
    // NOTE: Subtracts before converting to float: a timestamp in nanoseconds since boot does not fit into the
    // 24 bits of precision of a float, which would round intervals to tens of milliseconds after a few days.
    //

    static func milliseconds(from: UInt64, to: UInt64) -> Float
    {
        return Float(Int64(bitPattern: to &- from)) * (1000.0 / Float(frequency))
    }
}

/// A color: argb is the color as 0xAARRGGBB, and r, g, b and a are its components from 0 to 1.
struct RGBAColor: Sendable, Equatable
{
    var argb: UInt32 = 0
    var r: Float = 0
    var g: Float = 0
    var b: Float = 0
    var a: Float = 0

    init() {}

    init(hex color: UInt32)
    {
        argb = color
        r = Float((color >> 0x10) & 0xff) / 255.0
        g = Float((color >> 0x08) & 0xff) / 255.0
        b = Float((color >> 0x00) & 0xff) / 255.0
        a = Float((color >> 0x18) & 0xff) / 255.0
    }
}

/// The Unix domain sockets of the IPC client, the daemon and the scripting addition.
enum UnixSocket
{
    static func open(_ sockfd: inout Int32) -> Bool
    {
        sockfd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        return sockfd != -1
    }

    static func connect(_ sockfd: Int32, to socketPath: String) -> Bool
    {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            let bytes = Array(socketPath.utf8.prefix(sunPath.count - 1))
            sunPath.copyBytes(from: bytes)
            sunPath[bytes.count] = 0
        }

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } != -1
    }

    static func close(_ sockfd: Int32)
    {
        Darwin.shutdown(sockfd, SHUT_RDWR)
        Darwin.close(sockfd)
    }
}

extension ProcessSerialNumber
{
    /// Whether both serial numbers name the same process.
    func isSame(as other: ProcessSerialNumber) -> Bool
    {
        var a = self, b = other
        return ProcessSameC(&a, &b)
    }
}

extension CGRect
{
    /// The x radius, limited to half the width of the rect.
    func clampedXRadius(_ radius: Float) -> Float
    {
        if radius * 2 > Float(width) { return Float(width) / 2 }
        return radius
    }

    /// The y radius, limited to half the height of the rect.
    func clampedYRadius(_ radius: Float) -> Float
    {
        if radius * 2 > Float(height) { return Float(height) / 2 }
        return radius
    }

    /// The edges count as inside.
    func containsIncludingEdges(_ point: CGPoint) -> Bool
    {
        return point.x >= origin.x && point.x <= origin.x + size.width &&
               point.y >= origin.y && point.y <= origin.y + size.height
    }
}

extension CGPoint
{
    /// Whether the point lies strictly inside the triangle with the corners t[0], t[1] and t[2].
    func isInTriangle(_ t: [CGPoint]) -> Bool
    {
        let l1 = Float((x - t[0].x) * (t[2].y - t[0].y) - (t[2].x - t[0].x) * (y - t[0].y))
        let l2 = Float((x - t[1].x) * (t[0].y - t[1].y) - (t[0].x - t[1].x) * (y - t[1].y))
        let l3 = Float((x - t[2].x) * (t[1].y - t[2].y) - (t[1].x - t[2].x) * (y - t[2].y))

        return (l1 > 0.0 && l2 > 0.0 && l3 > 0.0) || (l1 < 0.0 && l2 < 0.0 && l3 < 0.0)
    }
}

extension Float
{
    /// The value limited to the range min...max.
    func clamped(min: Float, max: Float) -> Float
    {
        if self < min { return min }
        if self > max { return max }
        return self
    }
}
