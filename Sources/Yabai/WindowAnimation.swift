import AppKit
import ApplicationServices
import QuartzCore
import Synchronization
import CPrivate
import YabaiCore

//
// NOTE: Moving and resizing windows: frame requests that are grouped per application and skipped when
// the window is already there, and animated transitions through proxy windows of the scripting addition.
//

/// A window and the frame it gets.
struct WindowPlacement
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
    var level: Int32 = 0, subLevel: Int32 = 0
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

    @WM init(_ placement: WindowPlacement, connection: Int32)
    {
        cid = connection
        wid = placement.window.id
        x = placement.x; y = placement.y; w = placement.w; h = placement.h
    }
}

private let windowAnimations = Mutex<[WindowID: WindowAnimation]>([:])

extension WindowAnimation
{
    fileprivate func createProxy(alpha: Float)
    {
        guard let image = proxy.image, let frameRegion = SLS.region(proxy.frame),
              let id = SLS.newWindow(cid, shape: frameRegion, options: 13 | (1 << 18), tags: 1 << 46) else { return }
        proxy.id = id.rawValue
        SLS.disableShadow(id)
        SLS.setOpaque(cid, id, false)
        SLS.setResolution(cid, id, 2)
        SLS.setAlpha(cid, id, alpha)
        SLS.setLevel(cid, id, proxy.level)
        SLS.setSubLevel(cid, id, proxy.subLevel)
        proxy.context = SLS.context(cid, id)
        let frame = CGRect(origin: .zero, size: proxy.frame.size)
        proxy.context?.clear(frame)
        proxy.context?.draw(image, in: frame)
        proxy.context?.flush()
    }

    fileprivate func destroyProxy()
    {
        proxy.image = nil
        proxy.context = nil
        if proxy.id != 0 {
            SLS.releaseWindow(cid, WindowID(proxy.id))
            proxy.id = 0
        }
    }
}

extension WindowAnimation
{
    /// Process the tail as well when the image has fewer than four pixels left.
    static func restoreAlpha(_ image: CGImage) -> CGImage?
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

    fileprivate func buildProxy()
    {
        let alpha = SLS.windowAlpha(cid, wid) ?? 1
        proxy.level = wid.level
        proxy.subLevel = wid.subLevel
        proxy.frame = SLS.windowBounds(cid, wid) ?? proxy.frame
        proxy.tx = Float(proxy.frame.origin.x)
        proxy.ty = Float(proxy.frame.origin.y)
        proxy.tw = Float(proxy.frame.width)
        proxy.th = Float(proxy.frame.height)
        if let image = SLS.captureImage(cid, of: wid) {
            proxy.image = alpha == 1 ? image : WindowAnimation.restoreAlpha(image)
        }
        createProxy(alpha: alpha)
    }
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
        // NOTE: The link retains its target until invalidation.
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
            if let transaction = SLS.Transaction(connection) {
                for animation in animations where !animation.skip {
                    animation.proxy.tx = Float((1 - Double(mt)) * animation.proxy.frame.origin.x + Double(mt * animation.x))
                    animation.proxy.ty = Float((1 - Double(mt)) * animation.proxy.frame.origin.y + Double(mt * animation.y))
                    animation.proxy.tw = Float((1 - Double(mt)) * animation.proxy.frame.width + Double(mt * animation.w))
                    animation.proxy.th = Float((1 - Double(mt)) * animation.proxy.frame.height + Double(mt * animation.h))
                    let transform = CGAffineTransform(translationX: -CGFloat(animation.proxy.tx), y: -CGFloat(animation.proxy.ty))
                    let scale = CGAffineTransform(scaleX: animation.proxy.frame.width / CGFloat(animation.proxy.tw),
                                                  y: animation.proxy.frame.height / CGFloat(animation.proxy.th))
                    transaction.setTransform(WindowID(animation.proxy.id), transform.concatenating(scale))
                    let alpha = SLS.windowAlpha(connection, animation.wid) ?? 0
                    if alpha != 0 { transaction.setAlpha(WindowID(animation.proxy.id), alpha) }
                }
                transaction.commit()
            }
        }
        if t == 1 {
            finish()
            link.invalidate()
        }
    }

    private func finish()
    {
        //
        // NOTE: The border comes back while the animation lock is held, so that a new animation of the window, which
        // marks this one as skipped under the lock, cannot have its suspension undone here. Lock order: windowAnimations,
        // then the border lock (Border never takes windowAnimations).
        //
        windowAnimations.withLock { table in
            SLS.disableUpdate(connection)
            ScriptingAddition.shared.swapProxiesOut(animations)
            for animation in animations where !animation.skip {
                table.removeValue(forKey: animation.wid)
                animation.destroyProxy()
                Border.setSuspended(false, for: animation.wid)
            }
            SLS.reenableUpdate(connection)
        }
        SLS.releaseConnection(connection)
    }
}

//
// NOTE: A window that is still animating continues from where its running animation is: the new
// proxy starts at the target of the old one and replaces it on screen, and the old animation is
// told to skip the window.
//

extension WindowAnimation
{
    fileprivate func takeOver(from existing: WindowAnimation)
    {
        existing.skip = true
        proxy.frame = CGRect(x: Int(existing.proxy.tx), y: Int(existing.proxy.ty),
                             width: Int(existing.proxy.tw), height: Int(existing.proxy.th))
        proxy.tx = Float(Int(existing.proxy.tx)); proxy.ty = Float(Int(existing.proxy.ty))
        proxy.tw = Float(Int(existing.proxy.tw)); proxy.th = Float(Int(existing.proxy.th))
        proxy.level = existing.proxy.level
        proxy.subLevel = existing.proxy.subLevel
        proxy.image = existing.proxy.image
        let alpha = SLS.windowAlpha(cid, wid) ?? 1
        createProxy(alpha: alpha)
        if let transaction = SLS.Transaction(cid) {
            transaction.orderGroup(WindowID(proxy.id), .above, relativeTo: wid)
            transaction.setSystemAlpha(WindowID(existing.proxy.id), 0)
            transaction.commit()
        }
        existing.destroyProxy()
    }
}

extension WindowManager
{
    private func animateWindowsAsync(_ list: [WindowPlacement])
    {
        let connection = SLS.newConnection()
        let duration = animationDuration
        let easing = Config.current.animation.easing
        let animations = list.map { WindowAnimation($0, connection: connection) }
        let workers = DispatchGroup()
        SLS.disableUpdate(connection)
        windowAnimations.withLock { table in
            for animation in animations {
                if let existing = table[animation.wid] {
                    animation.takeOver(from: existing)
                } else {
                    DispatchQueue.global().async(group: workers) { animation.buildProxy() }
                }
                table[animation.wid] = animation
            }
        }
        workers.wait()
        ScriptingAddition.shared.swapProxiesIn(animations)
        for animation in animations { Border.setSuspended(true, for: animation.wid) }
        setWindowFrames(list)
        SLS.reenableUpdate(connection)
        DispatchQueue.main.async {
            WindowAnimationDisplayLink(connection: connection, animations: animations, duration: duration, easing: easing).start()
        }
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

extension CGRect
{
    func isClose(x: Float, y: Float, w: Float, h: Float) -> Bool
    {
        return abs(Float(origin.x) - x) < 1 && abs(Float(origin.y) - y) < 1 &&
               abs(Float(width) - w) < 1 && abs(Float(height) - h) < 1
    }
}

extension WindowManager
{
    static func frameNeedsUpdate(request: CGRect, bounds: CGRect?, x: Float, y: Float, w: Float, h: Float) -> Bool
    {
        if !request.isClose(x: x, y: y, w: w, h: h) { return true }
        guard let bounds else { return true }
        return !bounds.isClose(x: x, y: y, w: w, h: h)
    }
}

private extension Window
{
    func frameNeedsUpdate(x: Float, y: Float, w: Float, h: Float) -> Bool
    {
        if !frameRequest.isClose(x: x, y: y, w: w, h: h) { return true }
        return WindowManager.frameNeedsUpdate(request: frameRequest, bounds: SLS.windowBounds(SLS.connection, id), x: x, y: y, w: w, h: h)
    }
}

extension WindowManager
{
    //
    // NOTE: Some operations set frames without animating them (a scratchpad that is still ordered out, spaces swapped
    // across displays, Mission Control corrections). They suppress animations as runtime state instead of changing
    // the configured duration, so Config only changes through the config domain.
    //

    /// The duration in effect: zero while animations are suppressed.
    var animationDuration: Float
    {
        animationsSuppressed ? 0 : Config.current.animation.duration
    }

    /// Runs body with animations suppressed.
    func withoutAnimations(_ body: () -> Void)
    {
        let suppressed = animationsSuppressed
        animationsSuppressed = true
        defer { animationsSuppressed = suppressed }
        body()
    }

    func animateWindows(_ list: [WindowPlacement])
    {
        let list = list.filter { $0.window.frameNeedsUpdate(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
        if list.isEmpty { return }
        if animationDuration != 0 {
            animateWindowsAsync(list)
        } else {
            setWindowFrames(list)
        }
    }

    func animateWindow(_ placement: WindowPlacement)
    {
        if !placement.window.frameNeedsUpdate(x: placement.x, y: placement.y, w: placement.w, h: placement.h) { return }
        if animationDuration != 0 {
            animateWindowsAsync([placement])
        } else {
            placement.window.setFrame(x: placement.x, y: placement.y, width: placement.w, height: placement.h)
        }
    }
}

private extension AXUIElement
{
    @discardableResult
    func setFrame(position: CGPoint, size: CGSize) -> AXError
    {
        //
        // NOTE: An application that does not respond makes every call wait for the messaging timeout,
        // so the remaining calls are skipped once one of them could not complete.
        //
        // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.
        var result = setAttribute(kAXSizeAttribute, to: size)
        if result != .cannotComplete { result = setAttribute(kAXPositionAttribute, to: position) }
        // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
        if result != .cannotComplete { result = setAttribute(kAXSizeAttribute, to: size) }
        return result
    }
}

extension Window
{
    func setFrame(x: Float, y: Float, width: Float, height: Float)
    {
        frameRequest = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
        application.ref.withEnhancedUserInterfaceDisabled {
            ref.setFrame(position: CGPoint(x: CGFloat(x), y: CGFloat(y)), size: CGSize(width: CGFloat(width), height: CGFloat(height)))
        }
    }
}

//
// NOTE: The frames of a batch are set per application. AXEnhancedUserInterface is turned off once for
// each application instead of once for each window, and the applications are handled concurrently, so
// that an application that is slow to respond does not delay the windows of all other applications.
// The groups are built on the event loop thread; the worker threads only read the AX references of their
// own group and write its result, and must not touch global state.
//

struct WindowFrameRequest
{
    let ref: AXUIElement
    let position: CGPoint
    let size: CGSize
}

// NOTE: @unchecked Sendable: the group holds non-Sendable AX references and a mutable error. One worker owns each
// group's error, and the event loop reads it after concurrentPerform joins. AX references are retained for the batch;
// workers never touch a model object.
final class WindowFrameGroup: @unchecked Sendable
{
    let application: Application
    let ref: AXUIElement
    let name: String
    var list: [WindowFrameRequest] = []
    var error = AXError.success

    @WM init(_ target: Application)
    {
        application = target
        ref = target.ref
        name = target.name
    }

    @WM static func groups(for list: [WindowPlacement]) -> [WindowFrameGroup]
    {
        var result: [WindowFrameGroup] = []
        for placement in list {
            let owner = placement.window.application!
            let group: WindowFrameGroup
            if let existing = result.first(where: { $0.application == owner }) {
                group = existing
            } else {
                group = WindowFrameGroup(owner)
                result.append(group)
            }
            group.list.append(WindowFrameRequest(ref: placement.window.ref,
                                                 position: CGPoint(x: CGFloat(placement.x), y: CGFloat(placement.y)),
                                                 size: CGSize(width: CGFloat(placement.w), height: CGFloat(placement.h))))
        }
        return result
    }

    func apply()
    {
        let attribute = AXUIElement.enhancedUserInterfaceAttribute
        let (value, result) = ref.attributeValue(attribute)
        if result == .cannotComplete {
            error = result
            return
        }
        let eui = value.map { CFBooleanGetValue(unsafeDowncast($0, to: CFBoolean.self)) } ?? false
        if eui { ref.setAttribute(attribute, to: false) }
        for request in list {
            let frameResult = request.ref.setFrame(position: request.position, size: request.size)
            if frameResult == .cannotComplete {
                error = frameResult
                break
            }
        }
        if eui { ref.setAttribute(attribute, to: true) }
    }
}

extension WindowManager
{
    func setWindowFrames(_ list: [WindowPlacement])
    {
        if list.isEmpty { return }
        for placement in list {
            placement.window.frameRequest = CGRect(x: CGFloat(placement.x), y: CGFloat(placement.y),
                                                   width: CGFloat(placement.w), height: CGFloat(placement.h))
        }
        let groups = WindowFrameGroup.groups(for: list)
        if groups.count == 1 {
            groups[0].apply()
        } else {
            DispatchQueue.concurrentPerform(iterations: groups.count) { groups[$0].apply() }
        }
        for group in groups where group.error == .cannotComplete {
            debug("WindowManager.setWindowFrames: \(group.name) did not respond, \(group.list.count) window(s) may not have been moved\n")
        }
    }
}
