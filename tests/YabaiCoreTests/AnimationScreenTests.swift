import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("AnimationScreen")
struct AnimationScreenTests {
  private static let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
  private static let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
  /// Left of and slightly higher than the primary screen: negative x and y.
  private static let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
  /// Above the primary screen: negative y.
  private static let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

  private static func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
  }

  @Test(
    arguments: [
      // single screen
      ([frame(100, 100, 200, 200)], [primary], 0),
      // the union is on the second of two screens
      ([frame(1500, 100, 200, 200)], [primary, right], 1),
      // a screen left of the primary one (negative x and y)
      ([frame(-1000, 100, 300, 300)], [primary, left], 1),
      // a screen above the primary one (negative y)
      ([frame(500, -500, 200, 200)], [primary, above], 1),
      // the union spans both screens and its center is on the second one
      ([frame(1100, 100, 200, 100), frame(1400, 100, 400, 100)], [primary, right], 1),
      // the union spans both screens and its center is on the first one
      ([frame(1000, 100, 200, 100), frame(1300, 100, 200, 100)], [primary, right], 0),
      // the center on the shared edge belongs to the screen on the right (right and bottom edges excluded)
      ([frame(1400, 100, 80, 100)], [primary, right], 1),
      // the center falls in a gap: the screen with the largest overlap (first one, 200 against 100)
      (
        [frame(800, 100, 200, 100), frame(1100, 100, 200, 100)],
        [frame(0, 0, 1000, 1000), frame(1200, 0, 1000, 1000)], 0
      ),
      // the center falls in a gap: the second screen has the largest overlap (300 against 150)
      (
        [frame(850, 100, 200, 100), frame(1100, 100, 400, 100)],
        [frame(0, 0, 1000, 1000), frame(1200, 0, 1000, 1000)], 1
      ),
      // equal overlaps: the first screen
      (
        [frame(900, 100, 100, 100), frame(1200, 100, 100, 100)],
        [frame(0, 0, 1000, 1000), frame(1200, 0, 1000, 1000)], 0
      ),
      // no intersection with any screen
      ([frame(2000, 2000, 100, 100)], [primary], nil),
      // no frames
      ([CGRect](), [primary], nil),
      // no screens
      ([frame(100, 100, 200, 200)], [CGRect](), nil),
    ] as [([CGRect], [CGRect], Int?)])
  func screenChoice(frames: [CGRect], screens: [CGRect], expected: Int?) {
    #expect(AnimationScreen.index(of: frames, in: screens) == expected)
  }
}
