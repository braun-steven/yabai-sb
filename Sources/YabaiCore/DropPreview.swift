import CoreGraphics

//
// NOTE: The geometry of the drop preview (config mouse_drop_preview ghost, P13.3). A window dropped toward a side of
// another window covers the half of it on that side; a stack or a swap covers all of it. The halves are cut the way
// the outline of a drop is clipped (TreeView drawFeedback), in the same coordinates: north is the upper half, south the
// lower, east the right and west the left.
//

public enum DropPreview {
  /// The part of area that a drop toward direction covers: the half on that side for a warp, all of area for a stack or
  /// a swap (nil). The origin of area is kept.
  public static func covered(_ area: CGRect, by direction: InsertDirection?) -> CGRect {
    switch direction {
    case .north?:
      CGRect(x: area.minX, y: area.midY, width: area.width, height: area.maxY - area.midY)
    case .south?:
      CGRect(x: area.minX, y: area.minY, width: area.width, height: area.midY - area.minY)
    case .east?:
      CGRect(x: area.midX, y: area.minY, width: area.maxX - area.midX, height: area.height)
    case .west?:
      CGRect(x: area.minX, y: area.minY, width: area.midX - area.minX, height: area.height)
    case .stack?, nil:
      area
    }
  }

  /// The rect that an image of size takes when it is scaled to fit inside rect, keeping its aspect ratio, and centered in
  /// it. Nil when a size or the rect has no positive, finite width and height: there is nothing to draw.
  public static func fit(_ size: CGSize, in rect: CGRect) -> CGRect? {
    guard isPositive(size), isPositive(rect.size) else { return nil }
    let scale = min(rect.width / size.width, rect.height / size.height)
    let width = size.width * scale
    let height = size.height * scale
    return CGRect(
      x: rect.midX - 0.5 * width, y: rect.midY - 0.5 * height, width: width, height: height)
  }

  private static func isPositive(_ size: CGSize) -> Bool {
    size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite
  }
}
