import AppKit
import ApplicationServices
import QuartzCore
import Synchronization
import CPrivate
import YabaiCore

//
// NOTE: Moving and resizing windows: frame requests that are grouped per application and skipped when
// the window is already there, and animated transitions through proxy windows of the scripting addition.
// Ported from src/window_animation.c.
//

/// `struct window_capture` (view.h): a window and the frame it gets.
struct window_capture
{
    var window: Window!
    var x: Float, y: Float, w: Float, h: Float
}

struct WindowProxy
{
    var id: UInt32 = 0
    var context: CGContext?
    var tx: Float = 0, ty: Float = 0, tw: Float = 0, th: Float = 0
    var frame: CGRect = .zero
    var level: Int32 = 0, sub_level: Int32 = 0
    var image: CGImage?
}

//
// NOTE: @unchecked Sendable: proxy construction belongs to one worker per new animation, and the
// event loop waits for those workers before publishing the display link. Afterwards every access to
// mutable state (including skip and the proxy resources) holds windowAnimations. No window pointer is
// kept by an animation: its window can be destroyed before the display link finishes.
//

final class WindowAnimation: @unchecked Sendable
{
    let cid: Int32
    var wid: WindowID
    let x: Float, y: Float, w: Float, h: Float
    var proxy = WindowProxy()
    var skip = false

    init(_ capture: window_capture, connection: Int32)
    {
        cid = connection
        wid = capture.window.id
        x = capture.x; y = capture.y; w = capture.w; h = capture.h
    }
}

private let windowAnimations = Mutex<[WindowID: WindowAnimation]>([:])

private func windowManagerCreateWindowProxy(_ animation: WindowAnimation, alpha: Float)
{
    guard let image = animation.proxy.image else { return }
    var region: CFTypeRef?
    CGSNewRegionWithRect(&animation.proxy.frame, &region)
    guard let frameRegion = region, let emptyRegion = CGRegionCreateEmptyRegion() else { return }
    var tags: UInt64 = 1 << 46
    SLSNewWindowWithOpaqueShapeAndContext(animation.cid, 2, frameRegion, emptyRegion,
                                        13 | (1 << 18), &tags, 0, 0, 64, &animation.proxy.id, nil)
    sls_window_disable_shadow(animation.proxy.id)
    SLSSetWindowOpacity(animation.cid, animation.proxy.id, false)
    SLSSetWindowResolution(animation.cid, animation.proxy.id, 2)
    SLSSetWindowAlpha(animation.cid, animation.proxy.id, alpha)
    SLSSetWindowLevel(animation.cid, animation.proxy.id, animation.proxy.level)
    SLSSetWindowSubLevel(animation.cid, animation.proxy.id, animation.proxy.sub_level)
    animation.proxy.context = SLWindowContextCreate(animation.cid, animation.proxy.id, nil)
    let frame = CGRect(origin: .zero, size: animation.proxy.frame.size)
    animation.proxy.context?.clear(frame)
    animation.proxy.context?.draw(image, in: frame)
    animation.proxy.context?.flush()
}

private func windowManagerDestroyWindowProxy(_ animation: WindowAnimation)
{
    animation.proxy.image = nil
    animation.proxy.context = nil
    if animation.proxy.id != 0 {
        SLSReleaseWindow(animation.cid, animation.proxy.id)
        animation.proxy.id = 0
    }
}

/// `cgimage_restore_alpha` (helpers.h). Process the tail as well when the image has fewer than four pixels left.
func animationRestoreAlpha(_ image: CGImage) -> CGImage?
{
    let width = image.width, height = image.height
    let data = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
    data.initialize(repeating: 0, count: width * height)
    defer { data.deallocate() }
    guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let count = width * height
    let vectorCount = count - count % 4
    for i in stride(from: 0, to: vectorCount, by: 4) {
        let source = UnsafeRawPointer(data + i).loadUnaligned(as: SIMD4<UInt32>.self)
        let alpha = SIMD4<Float>(source &>> 24)
        let divisor = alpha.replacing(with: SIMD4(repeating: 1), where: alpha .== .zero)
        var red = 255 * (SIMD4<Float>(source & 0xff) / divisor)
        var green = 255 * (SIMD4<Float>((source &>> 8) & 0xff) / divisor)
        var blue = 255 * (SIMD4<Float>((source &>> 16) & 0xff) / divisor)
        red = (1 / Float(255)) * (red * 255)
        green = (1 / Float(255)) * (green * 255)
        blue = (1 / Float(255)) * (blue * 255)
        let color = SIMD4<UInt32>(red.rounded(.toNearestOrEven)) |
                    (SIMD4<UInt32>(green.rounded(.toNearestOrEven)) &<< 8) |
                    (SIMD4<UInt32>(blue.rounded(.toNearestOrEven)) &<< 16) | 0xff000000
        var restored = source.replacing(with: color, where: alpha .> .zero)
        withUnsafeBytes(of: &restored) { UnsafeMutableRawPointer(data + i).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
    for i in vectorCount..<count {
        let source = data[i]
        let alpha = Float(source >> 24)
        if alpha == 0 { continue }
        var color: UInt32 = 0xff000000
        for shift: UInt32 in stride(from: 0, through: 16, by: 8) {
            var value = Float((source >> shift) & 0xff)
            value = 255 * (value / alpha)
            value = (1 / Float(255)) * (value * 255)
            color |= UInt32(value.rounded(.toNearestOrEven)) << shift
        }
        data[i] = color
    }
    return context.makeImage()
}

private func windowManagerBuildWindowProxy(_ animation: WindowAnimation)
{
    var alpha: Float = 1
    SLSGetWindowAlpha(animation.cid, animation.wid.rawValue, &alpha)
    animation.proxy.level = window_level(animation.wid)
    animation.proxy.sub_level = window_sub_level(animation.wid)
    SLSGetWindowBounds(animation.cid, animation.wid.rawValue, &animation.proxy.frame)
    animation.proxy.tx = Float(animation.proxy.frame.origin.x)
    animation.proxy.ty = Float(animation.proxy.frame.origin.y)
    animation.proxy.tw = Float(animation.proxy.frame.width)
    animation.proxy.th = Float(animation.proxy.frame.height)
    var capturedID = animation.wid.rawValue
    if let images = SLSHWCaptureWindowList(animation.cid, &capturedID, 1, (1 << 11) | (1 << 8)), CFArrayGetCount(images) > 0 {
        let image = unsafeBitCast(CFArrayGetValueAtIndex(images, 0), to: CGImage.self)
        animation.proxy.image = alpha == 1 ? image : animationRestoreAlpha(image)
    }
    windowManagerCreateWindowProxy(animation, alpha: alpha)
}

@MainActor
private final class WindowAnimationDisplayLink: NSObject
{
    let connection: Int32
    let animations: [WindowAnimation]
    let duration: Float
    let easing: AnimationEasing
    private var clock: CFTimeInterval?

    init(connection: Int32, animations: [WindowAnimation], duration: Float, easing: AnimationEasing)
    {
        self.connection = connection
        self.animations = animations
        self.duration = duration
        self.easing = easing
    }

    func start()
    {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            finish()
            return
        }
        // NOTE: The link retains its target until invalidation, like the C display link's context.
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink)
    {
        if clock == nil { clock = link.timestamp }
        let t = min(1, max(0, (link.targetTimestamp - clock!) / Double(duration)))
        let mt = easing.value(at: Float(t))

        //
        // NOTE: A new animation of the same window marks this entry as skipped and destroys its proxy
        // while holding the lock, so the proxy must not be used here without holding it as well.
        //

        windowAnimations.withLock { _ in
            if let transaction = SLSTransactionCreate(connection) {
                for animation in animations where !animation.skip {
                    animation.proxy.tx = Float((1 - Double(mt)) * animation.proxy.frame.origin.x + Double(mt * animation.x))
                    animation.proxy.ty = Float((1 - Double(mt)) * animation.proxy.frame.origin.y + Double(mt * animation.y))
                    animation.proxy.tw = Float((1 - Double(mt)) * animation.proxy.frame.width + Double(mt * animation.w))
                    animation.proxy.th = Float((1 - Double(mt)) * animation.proxy.frame.height + Double(mt * animation.h))
                    let transform = CGAffineTransform(translationX: -CGFloat(animation.proxy.tx), y: -CGFloat(animation.proxy.ty))
                    let scale = CGAffineTransform(scaleX: animation.proxy.frame.width / CGFloat(animation.proxy.tw),
                                                  y: animation.proxy.frame.height / CGFloat(animation.proxy.th))
                    SLSTransactionSetWindowTransform(transaction, animation.proxy.id, 0, 0, transform.concatenating(scale))
                    var alpha: Float = 0
                    SLSGetWindowAlpha(connection, animation.wid.rawValue, &alpha)
                    if alpha != 0 { SLSTransactionSetWindowAlpha(transaction, animation.proxy.id, alpha) }
                }
                SLSTransactionCommit(transaction, 0)
            }
        }
        if t == 1 {
            finish()
            link.invalidate()
        }
    }

    private func finish()
    {
        windowAnimations.withLock { table in
            SLSDisableUpdate(connection)
            scripting_addition_swap_window_proxy_out(animations)
            for animation in animations where !animation.skip {
                table.removeValue(forKey: animation.wid)
                windowManagerDestroyWindowProxy(animation)
            }
            SLSReenableUpdate(connection)
        }
        SLSReleaseConnection(connection)
    }
}

//
// NOTE: A window that is still animating continues from where its running animation is: the new
// proxy starts at the target of the old one and replaces it on screen, and the old animation is
// told to skip the window.
//

private func windowAnimationTakeOver(_ animation: WindowAnimation, _ existing: WindowAnimation)
{
    existing.skip = true
    animation.proxy.frame = CGRect(x: Int(existing.proxy.tx), y: Int(existing.proxy.ty),
                                   width: Int(existing.proxy.tw), height: Int(existing.proxy.th))
    animation.proxy.tx = Float(Int(existing.proxy.tx)); animation.proxy.ty = Float(Int(existing.proxy.ty))
    animation.proxy.tw = Float(Int(existing.proxy.tw)); animation.proxy.th = Float(Int(existing.proxy.th))
    animation.proxy.level = existing.proxy.level
    animation.proxy.sub_level = existing.proxy.sub_level
    animation.proxy.image = existing.proxy.image
    var alpha: Float = 1
    SLSGetWindowAlpha(animation.cid, animation.wid.rawValue, &alpha)
    windowManagerCreateWindowProxy(animation, alpha: alpha)
    if let transaction = SLSTransactionCreate(animation.cid) {
        SLSTransactionOrderWindowGroup(transaction, animation.proxy.id, 1, animation.wid.rawValue)
        SLSTransactionSetWindowSystemAlpha(transaction, existing.proxy.id, 0)
        SLSTransactionCommit(transaction, 0)
    }
    windowManagerDestroyWindowProxy(existing)
}

private func windowManagerAnimateWindowListAsync(_ list: [window_capture])
{
    let wm = window_manager_global()
    var connection: Int32 = 0
    SLSNewConnection(0, &connection)
    let duration = wm.window_animation_duration
    let easing = wm.window_animation_easing
    let animations = list.map { WindowAnimation($0, connection: connection) }
    let workers = DispatchGroup()
    SLSDisableUpdate(connection)
    windowAnimations.withLock { table in
        for animation in animations {
            if let existing = table[animation.wid] {
                windowAnimationTakeOver(animation, existing)
            } else {
                DispatchQueue.global().async(group: workers) { windowManagerBuildWindowProxy(animation) }
            }
            table[animation.wid] = animation
        }
    }
    workers.wait()
    scripting_addition_swap_window_proxy_in(animations)
    for animation in animations { border_suspend(animation.wid, true) }
    window_manager_set_window_frames(list)
    SLSReenableUpdate(connection)
    let animationConnection = connection
    DispatchQueue.main.async {
        WindowAnimationDisplayLink(connection: animationConnection, animations: animations, duration: duration, easing: easing).start()
    }
}

//
// NOTE(asmvik): Attempting to check the window frame cache to prevent unnecessary movement and resize calls to the AX API
// is not reliable because it is possible to perform operations that should be applied, at a higher rate than the AX API events
// are received, causing our cache to become out of date and incorrectly guard against some changes that **should** be applied.
// This causes the window layout to **not** be modified the way we expect.
//
// A possible solution is to use the faster CG window notifications, as they are **a lot** more responsive, and can be used to
// track changes to the window frame in real-time without delay.
//
// NOTE: We therefore compare against the bounds of the window server instead, which change as soon as the window is moved,
// and against the frame we requested last. The window is only skipped when both match the target. If an application has not
// yet applied a previous request, the request differs from the target and the frame is set again.
//

func window_frame_is_close(_ frame: CGRect, _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Bool
{
    return abs(Float(frame.origin.x) - x) < 1 && abs(Float(frame.origin.y) - y) < 1 &&
           abs(Float(frame.width) - w) < 1 && abs(Float(frame.height) - h) < 1
}

func window_frame_needs_update(_ request: CGRect, _ hasBounds: Bool, _ bounds: CGRect,
                               _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Bool
{
    if !window_frame_is_close(request, x, y, w, h) || !hasBounds { return true }
    return !window_frame_is_close(bounds, x, y, w, h)
}

private func windowManagerWindowFrameNeedsUpdate(_ target: Window, _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Bool
{
    if !window_frame_is_close(target.frame_request, x, y, w, h) { return true }
    var bounds = CGRect.zero
    let hasBounds = SLSGetWindowBounds(connection_global(), target.id.rawValue, &bounds) == .success
    return window_frame_needs_update(target.frame_request, hasBounds, bounds, x, y, w, h)
}

func window_manager_animate_window_list(_ list: [window_capture])
{
    let list = list.filter { windowManagerWindowFrameNeedsUpdate($0.window, $0.x, $0.y, $0.w, $0.h) }
    if list.isEmpty { return }
    if window_manager_global().window_animation_duration != 0 {
        windowManagerAnimateWindowListAsync(list)
    } else {
        window_manager_set_window_frames(list)
    }
}

func window_manager_animate_window(_ capture: window_capture)
{
    if !windowManagerWindowFrameNeedsUpdate(capture.window, capture.x, capture.y, capture.w, capture.h) { return }
    if window_manager_global().window_animation_duration != 0 {
        windowManagerAnimateWindowListAsync([capture])
    } else {
        window_manager_set_window_frame(capture.window, capture.x, capture.y, capture.w, capture.h)
    }
}

@discardableResult
private func windowManagerSetWindowFrameAX(_ ref: AXUIElement, _ position: CGPoint, _ size: CGSize) -> AXError
{
    var position = position, size = size
    let positionRef = AXValueCreate(.cgPoint, &position)
    let sizeRef = AXValueCreate(.cgSize, &size)
    var result = AXError.success
    //
    // NOTE: An application that does not respond makes every call wait for the messaging timeout,
    // so the remaining calls are skipped once one of them could not complete.
    //
    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.
    if let sizeRef { result = AXUIElementSetAttributeValue(ref, kAXSizeAttribute as CFString, sizeRef) }
    if let positionRef, result != .cannotComplete {
        result = AXUIElementSetAttributeValue(ref, kAXPositionAttribute as CFString, positionRef)
    }
    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
    if let sizeRef, result != .cannotComplete {
        result = AXUIElementSetAttributeValue(ref, kAXSizeAttribute as CFString, sizeRef)
    }
    return result
}

func window_manager_set_window_frame(_ target: Window, _ x: Float, _ y: Float, _ width: Float, _ height: Float)
{
    target.frame_request = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    axEnhancedUIWorkaround(target.application.ref) {
        windowManagerSetWindowFrameAX(target.ref,
                                     CGPoint(x: CGFloat(x), y: CGFloat(y)), CGSize(width: CGFloat(width), height: CGFloat(height)))
    }
}

//
// NOTE: The frames of a batch are set per application. AXEnhancedUserInterface is turned off once for
// each application instead of once for each window, and the applications are handled concurrently, so
// that an application that is slow to respond does not delay the windows of all other applications.
// The groups are built on the event loop thread; the worker threads only read the AX references of their
// own group and write its result, and must not touch the ts arena, tables or other global state.
//

struct WindowFrameRequest
{
    let ref: AXUIElement
    let position: CGPoint
    let size: CGSize
}

// NOTE: @unchecked Sendable: one worker owns each group's error. The event loop reads it after
// concurrentPerform joins. AX references are retained for the batch; workers never dereference a C model.
final class WindowFrameGroup: @unchecked Sendable
{
    let application: Application
    let ref: AXUIElement
    let name: String
    var list: [WindowFrameRequest] = []
    var error = AXError.success

    init(_ target: Application)
    {
        application = target
        ref = target.ref
        name = target.name
    }
}

func window_manager_group_window_frames(_ list: [window_capture]) -> [WindowFrameGroup]
{
    var groups: [WindowFrameGroup] = []
    for capture in list {
        let owner = capture.window.application!
        let group: WindowFrameGroup
        if let existing = groups.first(where: { $0.application == owner }) {
            group = existing
        } else {
            group = WindowFrameGroup(owner)
            groups.append(group)
        }
        group.list.append(WindowFrameRequest(ref: capture.window.ref,
                                             position: CGPoint(x: CGFloat(capture.x), y: CGFloat(capture.y)),
                                             size: CGSize(width: CGFloat(capture.w), height: CGFloat(capture.h))))
    }
    return groups
}

private func windowManagerApplyWindowFrameGroup(_ group: WindowFrameGroup)
{
    let attribute = "AXEnhancedUserInterface" as CFString
    var value: CFTypeRef?
    var result = AXUIElementCopyAttributeValue(group.ref, attribute, &value)
    if result == .cannotComplete {
        group.error = result
        return
    }
    let eui = value.map { CFBooleanGetValue(unsafeDowncast($0, to: CFBoolean.self)) } ?? false
    if eui { AXUIElementSetAttributeValue(group.ref, attribute, kCFBooleanFalse) }
    for request in group.list {
        result = windowManagerSetWindowFrameAX(request.ref, request.position, request.size)
        if result == .cannotComplete {
            group.error = result
            break
        }
    }
    if eui { AXUIElementSetAttributeValue(group.ref, attribute, kCFBooleanTrue) }
}

func window_manager_set_window_frames(_ list: [window_capture])
{
    if list.isEmpty { return }
    for capture in list {
        capture.window.frame_request = CGRect(x: CGFloat(capture.x), y: CGFloat(capture.y),
                                                     width: CGFloat(capture.w), height: CGFloat(capture.h))
    }
    let groups = window_manager_group_window_frames(list)
    if groups.count == 1 {
        windowManagerApplyWindowFrameGroup(groups[0])
    } else {
        DispatchQueue.concurrentPerform(iterations: groups.count) { windowManagerApplyWindowFrameGroup(groups[$0]) }
    }
    for group in groups where group.error == .cannotComplete {
        debug("window_manager_set_window_frames: \(group.name) did not respond, \(group.list.count) window(s) may not have been moved\n")
    }
}
