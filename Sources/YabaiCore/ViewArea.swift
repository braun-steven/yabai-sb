/// The geometry of a view: the area of its windows inside a display and its gap. Ported from src/view.c; the
/// struct view and its tree stay C.
public enum ViewArea
{
    /// `view_auto_padding_applies`: auto_padding removes the padding of a tree layout with at most one tiled container.
    public static func autoPaddingApplies(isTree: Bool, autoPadding: Bool, tiledCount: Int) -> Bool
    {
        autoPadding && isTree && tiledCount <= 1
    }

    //
    // NOTE: auto_padding leaves the gap alone: a space with one tiled container has no gap to remove,
    // except between the windows of a split inside a tabbed container, which keep it.
    //

    /// `view_window_gap`
    public static func windowGap(gapEnabled: Bool, windowGap: Int) -> Int
    {
        gapEnabled ? windowGap : 0
    }

    /// `view_root_area`: the area that the windows of a view fill inside frame. The padding is left out when it is
    /// disabled or when auto_padding removed it (unpadded).
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
