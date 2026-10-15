//
// NOTE: How the window server describes the windows of a space query. A user window has no parent, a
// standard level (0, 3 or 8) and one of the tag combinations below; it is ordered in, or ordered out
// because it is minimized. The bits are the ones observed for such windows.
//

/// The predicates that classify the windows of a space query. Ported from src/space.h.
public enum SpaceWindow
{
    /// `space_window_has_user_level`
    public static func hasUserLevel(parentID: UInt32, level: Int32) -> Bool
    {
        parentID == 0 && (level == 0 || level == 3 || level == 8)
    }

    /// `space_window_has_user_tags`
    public static func hasUserTags(_ tags: UInt64) -> Bool
    {
        (tags & 0x1) != 0 || ((tags & 0x2) != 0 && (tags & 0x80000000) != 0)
    }

    /// `space_window_is_user_window`
    public static func isUserWindow(parentID: UInt32, level: Int32, tags: UInt64, attributes: UInt64) -> Bool
    {
        hasUserLevel(parentID: parentID, level: level) &&
        ((attributes & 0x2) != 0 || (tags & 0x400000000000000) != 0) &&
        hasUserTags(tags)
    }

    /// `space_window_is_minimized_user_window`
    public static func isMinimizedUserWindow(parentID: UInt32, level: Int32, tags: UInt64, attributes: UInt64) -> Bool
    {
        hasUserLevel(parentID: parentID, level: level) &&
        (attributes == 0x0 || attributes == 0x1) &&
        ((tags & 0x1000000000000000) != 0 || (tags & 0x300000000000000) != 0) &&
        hasUserTags(tags)
    }
}
