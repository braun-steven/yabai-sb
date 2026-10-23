import CoreGraphics
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The ghost images of the drop preview (P13.3) are set directly, since capturing a window needs the window server.
// The tests check which paths free them: a drag keeps its images while the target changes (clearFeedback), and ends them
// (releaseDropGhosts, clearWindow). The feedback windows are not created: no container has a window id in these tests.
//

extension DaemonState {
  @Suite
  @WM struct DropGhostTests {
    private static func image() -> CGImage? {
      CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )?.makeImage()
    }

    @Test func clearFeedbackKeepsTheImagesOfTheDrag() throws {
      let space = Workspace()
      let dragged = space.open(1, focus: true)
      let target = space.open(2)
      let image = try #require(Self.image())
      let ms = MouseState.shared
      ms.window = dragged
      ms.dragGhost = (dragged.id, image)
      ms.targetGhost = (target.id, image)
      defer { ms.clearWindow() }

      ms.clearFeedback()

      #expect(ms.dragGhost?.window == dragged.id)
      #expect(ms.targetGhost?.window == target.id)
      #expect(ms.sourceGhost == nil)
    }

    @Test func releaseDropGhostsFreesTheImages() throws {
      let space = Workspace()
      let dragged = space.open(1, focus: true)
      let target = space.open(2)
      let image = try #require(Self.image())
      let ms = MouseState.shared
      ms.window = dragged
      ms.dragGhost = (dragged.id, image)
      ms.targetGhost = (target.id, image)
      ms.feedbackSwap = true
      defer { ms.clearWindow() }

      ms.releaseDropGhosts()

      #expect(ms.dragGhost == nil)
      #expect(ms.targetGhost == nil)
      #expect(ms.feedbackWindowID == nil)
      #expect(ms.feedbackSwap == false)
      #expect(ms.window == dragged)
    }

    @Test func clearWindowEndsTheDropPreview() throws {
      let space = Workspace()
      let dragged = space.open(1, focus: true)
      let target = space.open(2)
      let image = try #require(Self.image())
      let ms = MouseState.shared
      ms.window = dragged
      ms.dragGhost = (dragged.id, image)
      ms.targetGhost = (target.id, image)

      ms.clearWindow()

      #expect(ms.window == nil)
      #expect(ms.dragGhost == nil)
      #expect(ms.targetGhost == nil)
    }
  }
}
