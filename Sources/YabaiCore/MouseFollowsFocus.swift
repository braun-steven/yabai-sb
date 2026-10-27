import CoreGraphics

//
// NOTE: mouse_follows_focus works like sway's 'mouse_warping output' (`seat_consider_warp_to_focus`): focus that stays
// on the display under the cursor never moves the cursor, and focus that goes to another display puts it at the
// center of the focused window, or of the display when nothing there takes focus. A display's bounds hold their
// origin but not their far edges, as `CGRect.contains` reads them, so a cursor on the edge between two displays is
// on the one it is drawn on. A window whose center lies off its display (a frame across two displays) does not move
// the cursor, and neither does focus of the window under the cursor.
//
// Commands that move a window do not move the cursor, as in sway, which does not warp after 'move', 'swap' or
// 'move container to output|workspace': the window manager marks the focus such a command asks for (`warpsMouse` of
// the pending focus).
//

public enum MouseFollowsFocus {
  /// Whether focusing a display with these bounds moves the cursor there: only when it is on another display.
  public static func warps(cursor: CGPoint, to displayBounds: CGRect) -> Bool {
    !displayBounds.contains(cursor)
  }

  /// The frame of a window on a display with these bounds to center the cursor on: its cached frame while that lies on
  /// the display (its center inside the bounds), else its tile there, else the window server's frame (`live`, read only
  /// then), else the cached frame. A cached frame off the display is from before its space moved there.
  public static func focusFrame(
    cached: CGRect, tile: CGRect?, displayBounds: CGRect, live: () -> CGRect?
  ) -> CGRect {
    if displayBounds.contains(CGPoint(x: cached.midX, y: cached.midY)) { return cached }
    if let tile, displayBounds.contains(CGPoint(x: tile.midX, y: tile.midY)) { return tile }
    return live() ?? cached
  }

  /// Where the cursor goes when a window with this frame, on a display with these bounds, takes focus; nil leaves it.
  public static func warpPoint(cursor: CGPoint, frame: CGRect, displayBounds: CGRect) -> CGPoint? {
    if frame.contains(cursor) || !warps(cursor: cursor, to: displayBounds) { return nil }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    return displayBounds.contains(center) ? center : nil
  }

  /// How long the cursor follows a floating window it was centered on after its space moved to another display, in
  /// milliseconds (`followPoint`).
  public static let followTimeoutMs: Float = 2000.0

  /// Where the cursor goes when a floating window it was centered on at `warped`, `elapsedMs` ago, now has this frame on
  /// a display with these bounds: the new center while the cursor is still at the warp point (within a point) and
  /// `followTimeoutMs` has not passed; nil leaves it.
  public static func followPoint(
    cursor: CGPoint, warped: CGPoint, frame: CGRect, displayBounds: CGRect, elapsedMs: Float
  ) -> CGPoint? {
    if elapsedMs >= followTimeoutMs { return nil }
    if abs(cursor.x - warped.x) > 1 || abs(cursor.y - warped.y) > 1 { return nil }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    if abs(center.x - warped.x) <= 1 && abs(center.y - warped.y) <= 1 { return nil }
    return displayBounds.contains(center) ? center : nil
  }
}
