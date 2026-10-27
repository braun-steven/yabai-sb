import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("MouseFollowsFocus")
struct MouseFollowsFocusTests {
  private static let display = CGRect(x: 1920, y: 0, width: 1800, height: 1200)
  private static let window = CGRect(x: 2000, y: 100, width: 800, height: 600)
  private static let center = CGPoint(x: 2400, y: 400)

  // Columns: cursor, window frame, expected warp point.
  @Test(
    arguments: [
      // the cursor on another display: to the center of the window
      (CGPoint(x: 100, y: 200), window, CGPoint?(center)),
      // the far edge of the display belongs to the next display
      (CGPoint(x: 3720, y: 400), window, CGPoint?(center)),
      // the cursor on the window's display, outside the window: it stays (sway 'mouse_warping output')
      (CGPoint(x: 3500, y: 1100), window, nil),
      (CGPoint(x: 1920, y: 0), window, nil),
      // the cursor inside the window
      (CGPoint(x: 2100, y: 200), window, nil),
      // the window's center off its display: it stays
      (CGPoint(x: 100, y: 200), CGRect(x: 3500, y: 100, width: 800, height: 600), nil),
      // a window across two displays with the cursor in its part on the other display
      (
        CGPoint(x: 1900, y: 400), CGRect(x: 1800, y: 100, width: 800, height: 600),
        nil
      ),
    ] as [(CGPoint, CGRect, CGPoint?)])
  func warpPoint(cursor: CGPoint, frame: CGRect, expected: CGPoint?) {
    #expect(
      MouseFollowsFocus.warpPoint(cursor: cursor, frame: frame, displayBounds: Self.display)
        == expected)
  }

  // NOTE: The window of a space moved to `display`: its cached frame is still on the old display (x < 1920).
  private static let stale = CGRect(x: 0, y: 0, width: 1920, height: 1080)
  private static let tile = CGRect(x: 1930, y: 10, width: 1780, height: 1180)

  // Columns: cached frame, tile, window server frame, expected frame, whether the window server is asked.
  @Test(
    arguments: [
      // the cached frame on the display: kept
      (window, CGRect?(tile), CGRect?(stale), window, false),
      // stale: the tile on the new display
      (stale, CGRect?(tile), CGRect?(window), tile, false),
      // stale, no tile (floating) or a tile still laid out for the old display: the window server's frame
      (stale, nil, CGRect?(window), window, true),
      (stale, CGRect?(stale), CGRect?(window), window, true),
      // nothing better: the cached frame
      (stale, nil, nil, stale, true),
    ] as [(CGRect, CGRect?, CGRect?, CGRect, Bool)])
  func focusFrame(cached: CGRect, tile: CGRect?, live: CGRect?, expected: CGRect, asks: Bool) {
    var asked = false
    let frame = MouseFollowsFocus.focusFrame(
      cached: cached, tile: tile, displayBounds: Self.display,
      live: {
        asked = true
        return live
      })
    #expect(frame == expected)
    #expect(asked == asks)
  }

  @Test func movedWindowWarpsToItsTile() {
    let frame = MouseFollowsFocus.focusFrame(
      cached: Self.stale, tile: Self.tile, displayBounds: Self.display, live: { nil })
    #expect(
      MouseFollowsFocus.warpPoint(
        cursor: CGPoint(x: 900, y: 700), frame: frame, displayBounds: Self.display)
        == CGPoint(x: Self.tile.midX, y: Self.tile.midY))
  }

  @Test func warpsOnlyToAnotherDisplay() {
    #expect(MouseFollowsFocus.warps(cursor: CGPoint(x: 100, y: 200), to: Self.display))
    #expect(MouseFollowsFocus.warps(cursor: CGPoint(x: 2000, y: 1200), to: Self.display))
    #expect(!MouseFollowsFocus.warps(cursor: CGPoint(x: 2000, y: 1199), to: Self.display))
  }
}
