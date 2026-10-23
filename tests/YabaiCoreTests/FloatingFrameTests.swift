import CoreGraphics
import Testing

@testable import YabaiCore

@Suite("FloatingFrame")
struct FloatingFrameTests {
  private static let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
  private static let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

  private static func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
  }

  @Test(
    arguments: [
      // inside the display
      (frame(100, 100, 500, 400), [primary], true),
      // exactly half of the area inside the display (200 of 400 by 100)
      (frame(-200, 0, 400, 100), [primary], true),
      // less than half inside (100 of 400 by 100)
      (frame(-300, 0, 400, 100), [primary], false),
      // a third on each of two displays and a third in the gap between them: no display holds half
      (frame(800, 0, 600, 100), [frame(0, 0, 1000, 1000), frame(1200, 0, 1000, 1000)], false),
      // 600 of 600 by 100 is 460 on the second display (46000 of 60000)
      (frame(1300, 0, 600, 100), [primary, right], true),
      // 100 of 600 by 100 on the display (10000 of 60000)
      (frame(-500, 0, 600, 100), [primary], false),
      // only the edges touch
      (frame(1440, 0, 100, 100), [primary], false),
      // no displays
      (frame(100, 100, 500, 400), [], false),
      // no area
      (frame(100, 100, 0, 400), [primary], false),
    ] as [(CGRect, [CGRect], Bool)])
  func fitsWhenHalfTheAreaIsOnADisplay(_ frame: CGRect, _ displays: [CGRect], _ fits: Bool) {
    #expect(FloatingFrame.fits(frame, in: displays) == fits)
  }

  @Test(
    arguments: [
      // the display with the largest overlap (160 against 140)
      (frame(1300, 100, 300, 100), [primary, right], 1),
      // the frame overlaps none: the first display
      (frame(3000, 3000, 100, 100), [primary, right], 0),
      // equal overlaps (240 against 240): the first display
      (frame(1200, 100, 480, 100), [primary, right], 0),
    ] as [(CGRect, [CGRect], Int)])
  func displayIsTheOneWithTheLargestOverlap(_ frame: CGRect, _ displays: [CGRect], _ index: Int) {
    #expect(FloatingFrame.display(for: frame, in: displays) == displays[index])
  }

  @Test func displayIsNilWithoutDisplays() {
    #expect(FloatingFrame.display(for: Self.frame(0, 0, 10, 10), in: []) == nil)
  }

  @Test(
    arguments: [
      // 500x400 in a 1440x900 display: (1440 - 500) / 2, (900 - 400) / 2
      (CGSize(width: 500, height: 400), primary, frame(470, 250, 500, 400)),
      // an odd difference rounds the origin to a whole point: 569.5 and 399.5
      (CGSize(width: 301, height: 101), primary, frame(570, 400, 301, 101)),
      // a display that does not start at the origin: 2400 - 250 and 540 - 200
      (CGSize(width: 500, height: 400), right, frame(2150, 340, 500, 400)),
    ] as [(CGSize, CGRect, CGRect)])
  func centeredKeepsTheSizeInTheDisplay(_ size: CGSize, _ display: CGRect, _ expected: CGRect) {
    #expect(FloatingFrame.centered(size: size, in: display) == expected)
  }

  @Test func nothingIsRestoredWithoutARememberedFrame() {
    #expect(
      FloatingFrame.restoredFrame(
        remembered: nil, current: Self.frame(0, 0, 400, 800), displays: [Self.primary]) == nil)
  }

  @Test func aRememberedFrameThatFitsIsRestoredAsItWas() {
    let remembered = Self.frame(100, 120, 500, 400)
    #expect(
      FloatingFrame.restoredFrame(
        remembered: remembered, current: Self.frame(0, 0, 400, 800), displays: [Self.primary])
        == remembered)
  }

  @Test(
    arguments: [
      // off every display: the current size is centered on the display of the current frame
      (
        frame(5000, 5000, 500, 400), frame(400, 0, 400, 800), [primary],
        frame(520, 50, 400, 800)
      ),
      // a quarter on the first display and none on the second: centered on the second, where the current frame is
      (
        frame(1200, 850, 200, 200), frame(1500, 100, 300, 200), [primary, right],
        frame(2250, 440, 300, 200)
      ),
    ] as [(CGRect, CGRect, [CGRect], CGRect)])
  func aRememberedFrameThatNoLongerFitsIsCentered(
    _ remembered: CGRect, _ current: CGRect, _ displays: [CGRect], _ expected: CGRect
  ) {
    #expect(
      FloatingFrame.restoredFrame(remembered: remembered, current: current, displays: displays)
        == expected)
  }

  @Test func aRememberedFrameWithoutDisplaysIsNotRestored() {
    #expect(
      FloatingFrame.restoredFrame(
        remembered: Self.frame(100, 100, 500, 400), current: Self.frame(0, 0, 400, 800),
        displays: []) == nil)
  }
}
