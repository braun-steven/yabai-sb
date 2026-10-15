import ApplicationServices
import Foundation
import Testing
import CPrivate
@testable import Yabai

@Test("window_frame_close")
func windowFrameClose()
{
    let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
    #expect(window_frame_is_close(frame, 100, 200, 300, 400))
    #expect(window_frame_is_close(frame, 100.5, 199.5, 300.9, 399.1))
    #expect(!window_frame_is_close(frame, 101, 200, 300, 400))
    #expect(!window_frame_is_close(frame, 100, 199, 300, 400))
    #expect(!window_frame_is_close(frame, 100, 200, 301, 400))
    #expect(!window_frame_is_close(frame, 100, 200, 300, 398.5))
    #expect(!window_frame_is_close(.zero, 100, 200, 300, 400))
}

@Test("window_frame_group_by_application")
func windowFrameGroupByApplication()
{
    let owners = [Application(), Application()]
    let windows = (0..<5).map { _ in Window() }
    let ownerRefs = [AXUIElementCreateApplication(1), AXUIElementCreateApplication(2)]
    let windowRefs = (3...7).map { AXUIElementCreateApplication(pid_t($0)) }
    for i in 0..<2 { owners[i].ref = ownerRefs[i] }
    let captures = (0..<5).map { i in
        windows[i].application = owners[i % 2]
        windows[i].ref = windowRefs[i]
        return window_capture(window: windows[i], x: Float(i), y: Float(10 * i), w: 100, h: 200)
    }
    let groups = captures.withUnsafeBufferPointer { window_manager_group_window_frames($0.baseAddress!, 5) }
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

@Test("window_frame_needs_update_decision")
func windowFrameNeedsUpdateDecision()
{
    let target = CGRect(x: 10, y: 20, width: 300, height: 400)
    let other = CGRect(x: 10, y: 20, width: 500, height: 400)
    //
    // NOTE: A window is only skipped when both the last request and the window server bounds match.
    //
    #expect(!window_frame_needs_update(target, true, target, 10, 20, 300, 400))
    #expect(window_frame_needs_update(target, true, other, 10, 20, 300, 400))
    #expect(window_frame_needs_update(other, true, target, 10, 20, 300, 400))
    #expect(window_frame_needs_update(target, false, target, 10, 20, 300, 400))
    #expect(window_frame_needs_update(.zero, true, target, 10, 20, 300, 400))
    //
    // NOTE: An application that has not applied the previous request yet still reports the frame it had
    // before. Going back to that frame must not be skipped, because the pending request would win.
    //
    #expect(window_frame_needs_update(other, true, target, 10, 20, 300, 400))
}

@Test("animation alpha restoration handles a partial pixel block")
func animationAlphaTail() throws
{
    // NOTE: The C helper processed four pixels at a time even when the bitmap ended mid-block.
    let sourcePixel: [UInt8] = [64, 32, 16, 128]
    let pixel = Array(repeating: sourcePixel, count: 5).flatMap { $0 }
    let provider = try #require(CGDataProvider(data: Data(pixel) as CFData))
    let image = try #require(CGImage(width: 5, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 20,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let restored = try #require(animationRestoreAlpha(image))
    let bytes = try #require(restored.dataProvider?.data)
    let data = try #require(CFDataGetBytePtr(bytes))
    let expectedPixel: [UInt8] = [128, 64, 32, 255]
    #expect(Array(UnsafeBufferPointer(start: data, count: 20)) == Array(repeating: expectedPixel, count: 5).flatMap { $0 })
}
