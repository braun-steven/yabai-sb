import CoreGraphics

//
// NOTE: The screen whose display link drives an animation. The frames and the screens are in the window server's
// global space (top-left origin, as CGDisplayBounds reports displays), so no Cocoa flip is needed. The rule: the first
// screen that contains the center of the union (bounding box) of the frames, with the right and bottom edges excluded;
// else the screen with the largest overlap with the union (the first one on a tie; no overlap counts when it has no
// area); else nil. The caller then falls back to the main screen. No frames give nil.
//

public enum AnimationScreen {
  /// The index in screens of the screen that drives an animation of the frames, or nil when none applies.
  public static func index(of frames: [CGRect], in screens: [CGRect]) -> Int? {
    guard let first = frames.first else { return nil }
    var minX = first.minX
    var maxX = first.maxX
    var minY = first.minY
    var maxY = first.maxY
    for frame in frames.dropFirst() {
      minX = min(minX, frame.minX)
      maxX = max(maxX, frame.maxX)
      minY = min(minY, frame.minY)
      maxY = max(maxY, frame.maxY)
    }

    let centerX = (minX + maxX) / 2
    let centerY = (minY + maxY) / 2
    for (index, screen) in screens.enumerated()
    where screen.minX <= centerX && centerX < screen.maxX && screen.minY <= centerY
      && centerY < screen.maxY
    {
      return index
    }

    var best: Int?
    var bestArea: CGFloat = 0
    for (index, screen) in screens.enumerated() {
      let width = min(screen.maxX, maxX) - max(screen.minX, minX)
      let height = min(screen.maxY, maxY) - max(screen.minY, minY)
      guard width > 0, height > 0 else { continue }
      if width * height > bestArea {
        best = index
        bestArea = width * height
      }
    }
    return best
  }
}
