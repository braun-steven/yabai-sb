import ApplicationServices
import Foundation
import Testing
import CPrivate
@testable import Yabai
import YabaiTestSupport

@Test("frame closeness")
@WM func windowFrameClose()
{
    let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
    #expect(frame.isClose(x: 100, y: 200, w: 300, h: 400))
    #expect(frame.isClose(x: 100.5, y: 199.5, w: 300.9, h: 399.1))
    #expect(!frame.isClose(x: 101, y: 200, w: 300, h: 400))
    #expect(!frame.isClose(x: 100, y: 199, w: 300, h: 400))
    #expect(!frame.isClose(x: 100, y: 200, w: 301, h: 400))
    #expect(!frame.isClose(x: 100, y: 200, w: 300, h: 398.5))
    #expect(!CGRect.zero.isClose(x: 100, y: 200, w: 300, h: 400))
}

@Test("frames grouped by application")
@WM func windowFrameGroupByApplication()
{
    let owners = [Application(), Application()]
    let windows = (0..<5).map { _ in Window(id: 0) }
    let ownerRefs = [AXUIElementCreateApplication(1), AXUIElementCreateApplication(2)]
    let windowRefs = (3...7).map { AXUIElementCreateApplication(pid_t($0)) }
    for i in 0..<2 { owners[i].ref = ownerRefs[i] }
    let placements = (0..<5).map { i in
        windows[i].application = owners[i % 2]
        windows[i].ref = windowRefs[i]
        return WindowPlacement(window: windows[i], x: Float(i), y: Float(10 * i), w: 100, h: 200)
    }
    let groups = WindowFrameGroup.groups(for: placements)
    #expect(groups.count == 2)
    #expect(groups[0].application == owners[0])
    #expect(groups[0].list.count == 3)
    #expect(groups[1].application == owners[1])
    #expect(groups[1].list.count == 2)
    //
    // NOTE: Windows keep their order within a group, and each request carries the frame of its window.
    //
    for (i, expected) in [0, 2, 4].enumerated() { #expect(CFEqual(groups[0].list[i].ref, windowRefs[expected])) }
    for (i, expected) in [1, 3].enumerated() { #expect(CFEqual(groups[1].list[i].ref, windowRefs[expected])) }
    #expect(groups[0].list[1].position.y == 20)
    #expect(groups[1].list[1].position.x == 3)
    #expect(groups[1].list[1].size.height == 200)
}

@Test("frame update decision")
@WM func windowFrameNeedsUpdateDecision()
{
    let target = CGRect(x: 10, y: 20, width: 300, height: 400)
    let other = CGRect(x: 10, y: 20, width: 500, height: 400)
    //
    // NOTE: A window is only skipped when both the last request and the window server bounds match.
    //
    #expect(!WindowManager.frameNeedsUpdate(request: target, bounds: target, x: 10, y: 20, w: 300, h: 400))
    #expect(WindowManager.frameNeedsUpdate(request: target, bounds: other, x: 10, y: 20, w: 300, h: 400))
    #expect(WindowManager.frameNeedsUpdate(request: other, bounds: target, x: 10, y: 20, w: 300, h: 400))
    #expect(WindowManager.frameNeedsUpdate(request: target, bounds: nil, x: 10, y: 20, w: 300, h: 400))
    #expect(WindowManager.frameNeedsUpdate(request: .zero, bounds: target, x: 10, y: 20, w: 300, h: 400))
    //
    // NOTE: An application that has not applied the previous request yet still reports the frame it had
    // before. Going back to that frame must not be skipped, because the pending request would win.
    //
    #expect(WindowManager.frameNeedsUpdate(request: other, bounds: target, x: 10, y: 20, w: 300, h: 400))
}

@Test("animation alpha restoration handles a partial pixel block")
@WM func animationAlphaTail() throws
{
    // NOTE: The C helper processed four pixels at a time even when the bitmap ended mid-block.
    let sourcePixel: [UInt8] = [64, 32, 16, 128]
    let pixel = Array(repeating: sourcePixel, count: 5).flatMap { $0 }
    let provider = try #require(CGDataProvider(data: Data(pixel) as CFData))
    let image = try #require(CGImage(width: 5, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 20,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let restored = try #require(WindowAnimation.restoreAlpha(image))
    let bytes = try #require(restored.dataProvider?.data)
    let data = try #require(CFDataGetBytePtr(bytes))
    let expectedPixel: [UInt8] = [128, 64, 32, 255]
    #expect(Array(UnsafeBufferPointer(start: data, count: 20)) == Array(repeating: expectedPixel, count: 5).flatMap { $0 })
}
