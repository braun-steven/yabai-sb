#ifndef VIEW_H
#define VIEW_H

struct area
{
    float x;
    float y;
    float w;
    float h;
};

//
// NOTE: Geometry of areas in a direction, used to find the closest display. area_max_point is the last
// pixel inside an area.
//

static inline struct area area_from_cgrect(CGRect rect)
{
    return (struct area) { rect.origin.x, rect.origin.y, rect.size.width, rect.size.height };
}

// implemented in Sources/Yabai/Shims/AreaShims.swift (Area in Sources/YabaiCore/Area.swift)
CGPoint area_max_point(struct area area);
bool area_is_in_direction(struct area *r1, CGPoint r1_max, struct area *r2, CGPoint r2_max, int direction);
int area_distance_in_direction(struct area *r1, CGPoint r1_max, struct area *r2, CGPoint r2_max, int direction);

enum window_split
{
    SPLIT_NONE,
    SPLIT_Y,
    SPLIT_X
};

#define TAB_BAR_MAX_ENTRY_COUNT 64

enum view_type
{
    VIEW_DEFAULT,
    VIEW_FLOAT,
    VIEW_TREE
};

enum view_flag
{
    VIEW_LAYOUT         = 0x001,
    VIEW_TOP_PADDING    = 0x002,
    VIEW_BOTTOM_PADDING = 0x004,
    VIEW_LEFT_PADDING   = 0x008,
    VIEW_RIGHT_PADDING  = 0x010,
    VIEW_WINDOW_GAP     = 0x020,
    VIEW_ENABLE_PADDING = 0x080,
    VIEW_ENABLE_GAP     = 0x100,
    VIEW_IS_VALID       = 0x200,
    VIEW_IS_DIRTY       = 0x400,
    VIEW_AUTO_PADDING   = 0x1000,
    VIEW_IS_UNPADDED    = 0x2000,
};

//
// NOTE: The views are Swift (Sources/Yabai/View.swift; the geometry is ViewArea in Sources/YabaiCore/ViewArea.swift).
//

#endif
