import CoreGraphics

//
// NOTE: Where a window goes when it floats again. A floating window remembers the frame it had while floating, and
// it returns there when that frame still fits: at least half of its area inside the visible frame of one display.
// Otherwise it is centered at its current size on the display it is most on (the first display when none overlaps).
// Without a remembered frame the window keeps its current frame, so the caller does nothing.
//

public enum FloatingFrame {
  /// Whether at least half of the area of the frame lies inside one of the displays. A frame without area fits nothing.
  public static func fits(_ frame: CGRect, in displays: [CGRect]) -> Bool {
    let area = frame.width * frame.height
    guard area > 0 else { return false }
    return displays.contains { display in
      let overlap = frame.intersection(display)
      return !overlap.isNull && overlap.width * overlap.height * 2 >= area
    }
  }

  /// The display that the frame is most on: the first one with the largest overlap, and the first one when the frame
  /// overlaps none. Nil only when there are no displays.
  public static func display(for frame: CGRect, in displays: [CGRect]) -> CGRect? {
    var best: CGRect?
    var bestArea: CGFloat = -1
    for display in displays {
      let overlap = frame.intersection(display)
      let area = overlap.isNull ? 0 : overlap.width * overlap.height
      if area > bestArea {
        best = display
        bestArea = area
      }
    }
    return best
  }

  /// The frame of the given size centered in the display.
  public static func centered(size: CGSize, in display: CGRect) -> CGRect {
    CGRect(
      x: (display.midX - size.width / 2).rounded(),
      y: (display.midY - size.height / 2).rounded(),
      width: size.width, height: size.height)
  }

  /// The frame a window gets when it floats again, or nil when it keeps its current frame: nothing is remembered, or
  /// there is no display. The remembered frame when it fits; otherwise the current size, centered on the display that
  /// the current frame is most on.
  public static func restoredFrame(
    remembered: CGRect?, current: CGRect, displays: [CGRect]
  ) -> CGRect? {
    guard let remembered else { return nil }
    if fits(remembered, in: displays) { return remembered }
    guard let display = display(for: current, in: displays) else { return nil }
    return centered(size: current.size, in: display)
  }
}
