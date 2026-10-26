import CoreGraphics

//
// NOTE: The order of display_arrangement_order: the displays sorted by their centers, on the axis of the order first and
// then on the other axis. The centers are compared as Float, as the comparator of the window server's displays did.
// Two displays with the same center on both axes keep the order of the window server (the sort is not left to the
// stability of the sort algorithm).
//

public enum DisplayArrangement {
  /// A display of the window server with its uuid and center.
  public struct Placement: Equatable, Sendable {
    public let uuid: String
    public let center: CGPoint

    public init(uuid: String, center: CGPoint) {
      self.uuid = uuid
      self.center = center
    }
  }

  /// The uuids in arrangement order: by x, then y, or with `vertical`, by y, then x.
  public static func sorted(_ placements: [Placement], vertical: Bool) -> [String] {
    let order = placements.indices.sorted { i, j in
      let a = placements[i].center
      let b = placements[j].center

      let aMain = Float(vertical ? a.y : a.x)
      let bMain = Float(vertical ? b.y : b.x)
      if aMain < bMain { return true }
      if aMain > bMain { return false }

      let aCross = Float(vertical ? a.x : a.y)
      let bCross = Float(vertical ? b.x : b.y)
      if aCross < bCross { return true }
      if aCross > bCross { return false }

      return i < j
    }

    return order.map { placements[$0].uuid }
  }

  //
  // NOTE: A display selector in a direction with no display that way wraps around, like sway's 'focus output <dir>'
  // and 'move container|workspace to output <dir>' (wlr_output_layout_farthest_output in the opposite direction): of
  // the displays lying wholly on the other side of the reference, the one whose nearest point is farthest from the
  // reference's center, measured in both axes. Of displays at the same distance, the first one wins.
  //

  /// The index of the frame in candidates that a selector in a direction wraps around to: the one lying farthest the
  /// other way from reference, nil if none lies wholly that way.
  public static func wrapped(
    in direction: Direction, from reference: CGRect, among candidates: [CGRect]
  ) -> Int? {
    let center = CGPoint(x: reference.midX, y: reference.midY)
    var farthest: Int? = nil
    var farthestDistance: CGFloat = 0

    for (index, frame) in candidates.enumerated() {
      let isBehind =
        switch direction {
        case .north: frame.minY >= reference.maxY
        case .east: frame.maxX <= reference.minX
        case .south: frame.maxY <= reference.minY
        case .west: frame.minX >= reference.maxX
        }
      guard isBehind else { continue }

      let dx = min(max(center.x, frame.minX), frame.maxX) - center.x
      let dy = min(max(center.y, frame.minY), frame.maxY) - center.y
      let distance = dx * dx + dy * dy
      if distance > farthestDistance {
        farthest = index
        farthestDistance = distance
      }
    }

    return farthest
  }
}
