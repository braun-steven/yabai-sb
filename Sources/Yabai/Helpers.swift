import ApplicationServices
import CPrivate
import Darwin
import YabaiCore

//
// NOTE: The helpers of src/misc/helpers.h that the daemon uses: the easing curves of the animations, the timer, colors,
// sockets, C strings, AX elements and geometry.
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
    // NOTE: The curves compute in Float like the C functions; the sine curves multiply by M_PI in Double first, as the
    // C expressions promoted t to double before cosf and sinf took a float again.
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

/// `read_os_timer`: nanoseconds since boot.
func read_os_timer() -> UInt64
{
    return ReadOSTimerC()
}

/// `read_os_freq`
func read_os_freq() -> UInt64
{
    return 1000000000
}

//
// NOTE: Subtracts before converting to float: a timestamp in nanoseconds since boot does not fit into the
// 24 bits of precision of a float, which would round intervals to tens of milliseconds after a few days.
//

/// `os_timer_ms_between`
func os_timer_ms_between(_ from: UInt64, _ to: UInt64) -> Float
{
    return Float(Int64(bitPattern: to &- from)) * (1000.0 / Float(read_os_freq()))
}

/// `struct rgba_color`: p is the color as 0xAARRGGBB.
struct rgba_color: Sendable
{
    var p: UInt32 = 0
    var r: Float = 0
    var g: Float = 0
    var b: Float = 0
    var a: Float = 0
}

/// `rgba_color_from_hex`
func rgba_color_from_hex(_ color: UInt32) -> rgba_color
{
    var result = rgba_color()
    result.p = color
    result.r = Float((color >> 0x10) & 0xff) / 255.0
    result.g = Float((color >> 0x08) & 0xff) / 255.0
    result.b = Float((color >> 0x00) & 0xff) / 255.0
    result.a = Float((color >> 0x18) & 0xff) / 255.0
    return result
}

/// `socket_open`
func socket_open(_ sockfd: inout Int32) -> Bool
{
    sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
    return sockfd != -1
}

/// `socket_connect`
func socket_connect(_ sockfd: Int32, _ socketPath: String) -> Bool
{
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
        let bytes = Array(socketPath.utf8.prefix(sunPath.count - 1))
        sunPath.copyBytes(from: bytes)
        sunPath[bytes.count] = 0
    }

    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    } != -1
}

/// `socket_close`
func socket_close(_ sockfd: Int32)
{
    shutdown(sockfd, SHUT_RDWR)
    close(sockfd)
}

/// `string_equals`: the strings compared byte by byte like strcmp, not by canonical equivalence.
func string_equals(_ a: String, _ b: String) -> Bool
{
    return a.utf8.elementsEqual(b.utf8)
}

/// `sls_window_disable_shadow`
func sls_window_disable_shadow(_ id: UInt32)
{
    let options = ["com.apple.WindowShadowDensity" as CFString: NSNumber(value: Int32(0))] as CFDictionary
    SLSWindowSetShadowProperties(id, options)
}

/// `ax_window_id`: nil when the element is not a window.
func ax_window_id(_ ref: AXUIElement) -> WindowID?
{
    var wid: UInt32 = 0
    _AXUIElementGetWindow(ref, &wid)
    return WindowID(nonzero: wid)
}

/// `ax_window_pid`: the pid that the AX element stores at offset 0x10.
func ax_window_pid(_ ref: AXUIElement) -> pid_t
{
    return Unmanaged.passUnretained(ref).toOpaque().load(fromByteOffset: 0x10, as: pid_t.self)
}

/// `psn_equals`
func psn_equals(_ a: UnsafeMutablePointer<ProcessSerialNumber>, _ b: UnsafeMutablePointer<ProcessSerialNumber>) -> Bool
{
    return ProcessSameC(a, b)
}

/// `cgrect_clamp_x_radius`
func cgrect_clamp_x_radius(_ frame: CGRect, _ radius: Float) -> Float
{
    if radius * 2 > Float(frame.width) { return Float(frame.width) / 2 }
    return radius
}

/// `cgrect_clamp_y_radius`
func cgrect_clamp_y_radius(_ frame: CGRect, _ radius: Float) -> Float
{
    if radius * 2 > Float(frame.height) { return Float(frame.height) / 2 }
    return radius
}

/// `cgrect_contains_point`: the edges count as inside.
func cgrect_contains_point(_ r: CGRect, _ p: CGPoint) -> Bool
{
    return p.x >= r.origin.x && p.x <= r.origin.x + r.size.width &&
           p.y >= r.origin.y && p.y <= r.origin.y + r.size.height
}

/// `triangle_contains_point`
func triangle_contains_point(_ t: UnsafeMutablePointer<CGPoint>, _ p: CGPoint) -> Bool
{
    let l1 = Float((p.x - t[0].x) * (t[2].y - t[0].y) - (t[2].x - t[0].x) * (p.y - t[0].y))
    let l2 = Float((p.x - t[1].x) * (t[0].y - t[1].y) - (t[0].x - t[1].x) * (p.y - t[1].y))
    let l3 = Float((p.x - t[2].x) * (t[1].y - t[2].y) - (t[1].x - t[2].x) * (p.y - t[2].y))

    return (l1 > 0.0 && l2 > 0.0 && l3 > 0.0) || (l1 < 0.0 && l2 < 0.0 && l3 < 0.0)
}

/// `clampf_range`
func clampf_range(_ value: Float, _ min: Float, _ max: Float) -> Float
{
    if value < min { return min }
    if value > max { return max }
    return value
}
