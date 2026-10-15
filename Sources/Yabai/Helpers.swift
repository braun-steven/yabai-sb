import ApplicationServices
import CPrivate
import Darwin

//
// NOTE: The helpers of src/misc/helpers.h that the daemon uses: the easing curves of the animations, the timer, colors,
// sockets, C strings, AX elements and geometry.
//

/// `enum animation_easing_type`
struct animation_easing_type: RawRepresentable, Equatable, Sendable
{
    var rawValue: UInt32
}

let ease_in_sine_type      = animation_easing_type(rawValue: 0)
let ease_out_sine_type     = animation_easing_type(rawValue: 1)
let ease_in_out_sine_type  = animation_easing_type(rawValue: 2)
let ease_in_quad_type      = animation_easing_type(rawValue: 3)
let ease_out_quad_type     = animation_easing_type(rawValue: 4)
let ease_in_out_quad_type  = animation_easing_type(rawValue: 5)
let ease_in_cubic_type     = animation_easing_type(rawValue: 6)
let ease_out_cubic_type    = animation_easing_type(rawValue: 7)
let ease_in_out_cubic_type = animation_easing_type(rawValue: 8)
let ease_in_quart_type     = animation_easing_type(rawValue: 9)
let ease_out_quart_type    = animation_easing_type(rawValue: 10)
let ease_in_out_quart_type = animation_easing_type(rawValue: 11)
let ease_in_quint_type     = animation_easing_type(rawValue: 12)
let ease_out_quint_type    = animation_easing_type(rawValue: 13)
let ease_in_out_quint_type = animation_easing_type(rawValue: 14)
let ease_in_expo_type      = animation_easing_type(rawValue: 15)
let ease_out_expo_type     = animation_easing_type(rawValue: 16)
let ease_in_out_expo_type  = animation_easing_type(rawValue: 17)
let ease_in_circ_type      = animation_easing_type(rawValue: 18)
let ease_out_circ_type     = animation_easing_type(rawValue: 19)
let ease_in_out_circ_type  = animation_easing_type(rawValue: 20)
let EASING_TYPE_COUNT      = animation_easing_type(rawValue: 21)

//
// NOTE: The curves compute in Float like the C functions; the sine curves multiply by M_PI in Double first, as the
// C expressions promoted t to double before cosf and sinf took a float again.
//

func ease_in_sine(_ t: Float) -> Float { 1.0 - cosf(Float((Double(t) * Double.pi) / 2.0)) }
func ease_out_sine(_ t: Float) -> Float { sinf(Float((Double(t) * Double.pi) / 2.0)) }
func ease_in_out_sine(_ t: Float) -> Float { -(cosf(Float(Double.pi * Double(t))) - 1.0) / 2.0 }
func ease_in_quad(_ t: Float) -> Float { t * t }
func ease_out_quad(_ t: Float) -> Float { 1.0 - (1.0 - t) * (1.0 - t) }
func ease_in_out_quad(_ t: Float) -> Float { t < 0.5 ? 2.0 * t * t : 1.0 - powf(-2.0 * t + 2.0, 2.0) / 2.0 }
func ease_in_cubic(_ t: Float) -> Float { t * t * t }
func ease_out_cubic(_ t: Float) -> Float { 1.0 - powf(1.0 - t, 3) }
func ease_in_out_cubic(_ t: Float) -> Float { t < 0.5 ? 4.0 * t * t * t : 1.0 - powf(-2.0 * t + 2.0, 3.0) / 2.0 }
func ease_in_quart(_ t: Float) -> Float { t * t * t * t }
func ease_out_quart(_ t: Float) -> Float { 1.0 - powf(1.0 - t, 4) }
func ease_in_out_quart(_ t: Float) -> Float { t < 0.5 ? 8.0 * t * t * t * t : 1.0 - powf(-2.0 * t + 2.0, 4.0) / 2.0 }
func ease_in_quint(_ t: Float) -> Float { t * t * t * t * t }
func ease_out_quint(_ t: Float) -> Float { 1.0 - powf(1.0 - t, 5) }
func ease_in_out_quint(_ t: Float) -> Float { t < 0.5 ? 16.0 * t * t * t * t * t : 1.0 - powf(-2.0 * t + 2.0, 5.0) / 2.0 }
func ease_in_expo(_ t: Float) -> Float { t == 0.0 ? 0.0 : powf(2.0, 10.0 * t - 10.0) }
func ease_out_expo(_ t: Float) -> Float { t == 1.0 ? 1.0 : 1.0 - powf(2.0, -10.0 * t) }
func ease_in_out_expo(_ t: Float) -> Float { t == 0.0 ? 0.0 : t == 1.0 ? 1.0 : t < 0.5 ? powf(2.0, 20.0 * t - 10.0) / 2.0 : (2.0 - powf(2.0, -20.0 * t + 10.0)) / 2.0 }
func ease_in_circ(_ t: Float) -> Float { 1.0 - sqrtf(1.0 - powf(t, 2.0)) }
func ease_out_circ(_ t: Float) -> Float { sqrtf(1.0 - powf(t - 1.0, 2.0)) }
func ease_in_out_circ(_ t: Float) -> Float { t < 0.5 ? (1.0 - sqrtf(1.0 - powf(2.0 * t, 2.0))) / 2.0 : (sqrtf(1.0 - powf(-2.0 * t + 2.0, 2.0)) + 1.0) / 2.0 }

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

/// `string_equals`: false when either string is NULL.
func string_equals(_ a: UnsafePointer<CChar>?, _ b: UnsafePointer<CChar>?) -> Bool
{
    guard let a, let b else { return false }
    return strcmp(a, b) == 0
}

/// `string_equals` of a C string and a Swift string, compared byte by byte like strcmp.
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

/// `cfstring_copy`: a malloc'ed UTF-8 copy, or nil.
func cfstring_copy(_ string: CFString) -> UnsafeMutablePointer<CChar>?
{
    let numBytes = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), CFStringBuiltInEncodings.UTF8.rawValue)
    guard let result = malloc(numBytes + 1)?.assumingMemoryBound(to: CChar.self) else { return nil }

    if !CFStringGetCString(string, result, numBytes + 1, CFStringBuiltInEncodings.UTF8.rawValue) {
        free(result)
        return nil
    }

    return result
}

/// `ax_window_id`
func ax_window_id(_ ref: AXUIElement) -> UInt32
{
    var wid: UInt32 = 0
    _AXUIElementGetWindow(ref, &wid)
    return wid
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

/// `regex_match`
func regex_match(_ valid: Bool, _ regex: UnsafeMutablePointer<regex_t>, _ match: UnsafePointer<CChar>) -> Int32
{
    if !valid { return REGEX_MATCH_UD }

    let result = regexec(regex, match, 0, nil, 0)
    return result == 0 ? REGEX_MATCH_YES : REGEX_MATCH_NO
}

/// `clampf_range`
func clampf_range(_ value: Float, _ min: Float, _ max: Float) -> Float
{
    if value < min { return min }
    if value > max { return max }
    return value
}
