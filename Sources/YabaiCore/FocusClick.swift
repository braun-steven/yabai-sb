import CoreGraphics

//
// NOTE: Focusing a display or space with no window to focus. sway focuses the empty workspace itself; macOS moves key
// focus and the active menu bar to a display only through a click on its desktop, so yabai clicks there and the
// desktop (Finder) takes focus. The click is skipped when the space is already the active one. It goes to the first
// point of the display that has the desktop under it: the centre, then the other points of a 3 x 3 grid at a sixth, a
// half and five sixths of the display's width and height. A floating or sticky window, the Dock or a panel can cover
// the centre; with every point covered there is no click, so it never reaches another application's window.
//
// The cursor is warped to the click point, since the click is posted at it. Afterwards it goes back where it was with
// mouse_follows_focus off, and to the centre of the display with it on. Without a click the cursor stays with
// mouse_follows_focus off and goes to the centre with it on.
//
// Focus follows mouse focuses an empty display whose desktop the cursor is on (`FFMDisplayFocus`), so its click goes
// to the cursor (`planAtCursor`) and the cursor never moves: a warp would fight the user's own movement, and the
// restore would put the cursor back where it was 0.1 s earlier. With something else than the desktop under the cursor
// (the Dock, a window yabai does not know) there is no click and only the menu bar moves.
//
// NOTE: The click is posted at the HID event tap, so it passes yabai's own mouse tap (on the main run loop) before the
// window server handles it, and a posted mouse event can move the cursor to its point when it is handled. A warp back
// right after posting could run first and be undone, so the restore waits `restoreDelay` on the event loop
// (`EventLoop.post(_:after:key:)`). The warps themselves do not stall the cursor: the local event suppression interval
// is 0 (`configureEventSystem`), which removed the 0.25 s lag after a warp (P5.6).
//

/// What focusing an empty display does with the cursor and the focus click.
public struct FocusClickPlan: Sendable, Equatable {
  /// Where to warp the cursor now; nil leaves it.
  public var warp: CGPoint?
  /// Where to click, after the warp; nil posts no click.
  public var click: CGPoint?
  /// Where to warp the cursor once the click is delivered; nil leaves it at the click.
  public var restore: CGPoint?

  public init(warp: CGPoint?, click: CGPoint?, restore: CGPoint?) {
    self.warp = warp
    self.click = click
    self.restore = restore
  }
}

public enum FocusClick {
  /// How long the cursor waits at the click point before it goes back, so that the click is handled first.
  public static let restoreDelay: Duration = .milliseconds(100)

  /// The centre of a rectangle.
  public static func center(of bounds: CGRect) -> CGPoint {
    CGPoint(x: bounds.midX, y: bounds.midY)
  }

  /// The points to try for the click on a display with these bounds, in order: the centre first, then the rest of a
  /// 3 x 3 grid at a sixth, a half and five sixths of the width and height, row by row.
  public static func candidates(in bounds: CGRect) -> [CGPoint] {
    let fractions: [CGFloat] = [1.0 / 6.0, 0.5, 5.0 / 6.0]
    var points = [center(of: bounds)]
    for fy in fractions {
      for fx in fractions where fx != 0.5 || fy != 0.5 {
        points.append(
          CGPoint(x: bounds.minX + fx * bounds.width, y: bounds.minY + fy * bounds.height))
      }
    }
    return points
  }

  /// What to do for a display with these bounds. `needsClick` is false when the space is already the active one;
  /// `isDesktop` tells whether the desktop is under a point and is only asked when a click is needed.
  public static func plan(
    bounds: CGRect, cursor: CGPoint, needsClick: Bool, mouseFollowsFocus: Bool,
    isDesktop: (CGPoint) -> Bool
  ) -> FocusClickPlan {
    let center = center(of: bounds)
    let click = needsClick ? candidates(in: bounds).first(where: isDesktop) : nil

    guard let click else {
      let warp = mouseFollowsFocus && cursor != center ? center : nil
      return FocusClickPlan(warp: warp, click: nil, restore: nil)
    }

    let final = mouseFollowsFocus ? center : cursor
    return FocusClickPlan(warp: click, click: click, restore: final == click ? nil : final)
  }

  /// What focusing an empty display does for focus follows mouse, with the cursor on its desktop: the click goes to
  /// the cursor when `needsClick` and the desktop is under it, and the cursor stays.
  public static func planAtCursor(
    cursor: CGPoint, needsClick: Bool, isDesktop: (CGPoint) -> Bool
  ) -> FocusClickPlan {
    let click = needsClick && isDesktop(cursor) ? cursor : nil
    return FocusClickPlan(warp: nil, click: click, restore: nil)
  }
}
