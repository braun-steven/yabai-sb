/// The geometry of a view: the area of its windows inside a display and its gap.
public enum ViewArea
{
    /// Whether auto_padding removes the padding of a tree layout with at most one tiled container.
    public static func autoPaddingApplies(isTree: Bool, autoPadding: Bool, tiledCount: Int) -> Bool
    {
        autoPadding && isTree && tiledCount <= 1
    }

    //
    // NOTE: auto_padding leaves the gap alone: a space with one tiled container has no gap to remove,
    // except between the windows of a split inside a tabbed container, which keep it.
    //

    /// The gap between the windows of a view: zero when the gap is disabled.
    public static func windowGap(gapEnabled: Bool, windowGap: Int) -> Int
    {
        gapEnabled ? windowGap : 0
    }

    /// The area that the windows of a view fill inside frame. The padding is left out when it is disabled or when
    /// auto_padding removed it (unpadded).
    public static func rootArea(_ frame: Area, paddingEnabled: Bool, unpadded: Bool, top: Int, bottom: Int, left: Int, right: Int) -> Area
    {
        var area = frame

        if paddingEnabled && !unpadded {
            area.x += Float(left)
            area.w -= Float(left + right)
            area.y += Float(top)
            area.h -= Float(top + bottom)
        }

        return area
    }
}
