import CoreGraphics

//
// NOTE: The order of display_arrangement_order: the displays sorted by their centers, on the axis of the order first and
// then on the other axis. The centers are compared as Float, as the comparator of the window server's displays did.
// Two displays with the same center on both axes keep the order of the window server (the sort is not left to the
// stability of the sort algorithm).
//

public enum DisplayArrangement
{
    /// A display of the window server with its uuid and center.
    public struct Placement: Equatable, Sendable
    {
        public let uuid: String
        public let center: CGPoint

        public init(uuid: String, center: CGPoint)
        {
            self.uuid = uuid
            self.center = center
        }
    }

    /// The uuids in arrangement order: by x, then y, or with `vertical`, by y, then x.
    public static func sorted(_ placements: [Placement], vertical: Bool) -> [String]
    {
        let order = placements.indices.sorted { i, j in
            let a = placements[i].center
            let b = placements[j].center

            let aMain = Float(vertical ? a.y : a.x), bMain = Float(vertical ? b.y : b.x)
            if aMain < bMain { return true }
            if aMain > bMain { return false }

            let aCross = Float(vertical ? a.x : a.y), bCross = Float(vertical ? b.x : b.y)
            if aCross < bCross { return true }
            if aCross > bCross { return false }

            return i < j
        }

        return order.map { placements[$0].uuid }
    }
}
