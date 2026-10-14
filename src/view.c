extern int g_connection;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

static inline struct area area_from_cgrect(CGRect rect)
{
    return (struct area) { rect.origin.x, rect.origin.y, rect.size.width, rect.size.height };
}

static inline CGPoint area_max_point(struct area area)
{
    return (CGPoint) { area.x + area.w - 1, area.y + area.h - 1 };
}

static inline bool area_is_in_direction(struct area *r1, CGPoint r1_max, struct area *r2, CGPoint r2_max, int direction)
{
    if (direction == DIR_NORTH && r1_max.y <= r2->y) return false;
    if (direction == DIR_EAST  && r2_max.x <= r1->x) return false;
    if (direction == DIR_SOUTH && r2_max.y <= r1->y) return false;
    if (direction == DIR_WEST  && r1_max.x <= r2->x) return false;

    if (direction == DIR_NORTH || direction == DIR_SOUTH) {
        return ((r2_max.x >  r1->x && r2_max.x <= r1_max.x) ||
                (r2->x    <  r1->x && r2_max.x >  r1_max.x) ||
                (r2->x    >= r1->x && r2->x    <  r1_max.x));
    }

    if (direction == DIR_EAST || direction == DIR_WEST) {
        return ((r2_max.y >  r1->y && r2_max.y <= r1_max.y) ||
                (r2->y    <  r1->y && r2_max.y >  r1_max.y) ||
                (r2->y    >= r1->y && r2->y    <  r1_max.y));
    }

    return false;
}

static inline int area_distance_in_direction(struct area *r1, CGPoint r1_max, struct area *r2, CGPoint r2_max, int direction)
{
    switch (direction) {
    case DIR_NORTH: {
        return r2_max.y > r1->y ? r2_max.y - r1->y : r1->y - r2_max.y;
    } break;
    case DIR_EAST: {
        return r2->x < r1_max.x ? r1_max.x - r2->x : r2->x - r1_max.x;
    } break;
    case DIR_SOUTH: {
        return r2->y < r1_max.y ? r1_max.y - r2->y : r2->y - r1_max.y;
    } break;
    case DIR_WEST: {
        return r2_max.x > r1->x ? r2_max.x - r1->x : r1->x - r2_max.x;
    } break;
    }

    return INT_MAX;
}

//
// NOTE: auto_padding leaves the gap alone: a space with one tiled container has no gap to remove,
// except between the windows of a split inside a tabbed container, which keep it.
//

int view_window_gap(struct view *view)
{
    return view_check_flag(view, VIEW_ENABLE_GAP) ? view->window_gap : 0;
}

void view_add_window(struct view *view, struct window *window, uint32_t insertion_point)
{
    tree_add_window(view, window, insertion_point);
    if (!view_update_auto_padding(view)) tree_view_update(view);
    view_set_flag(view, VIEW_IS_DIRTY);
}

bool view_remove_window(struct view *view, struct window *window)
{
    if (!tree_remove_window(view, window)) return false;
    if (!view_update_auto_padding(view)) tree_view_update(view);
    view_set_flag(view, VIEW_IS_DIRTY);
    return true;
}

uint32_t *view_find_window_list(struct view *view, int *window_count)
{
    return tree_view_window_list(view, window_count);
}

bool view_is_invalid(struct view *view)
{
    return !view_check_flag(view, VIEW_IS_VALID);
}

bool view_is_dirty(struct view *view)
{
    return view_check_flag(view, VIEW_IS_DIRTY);
}

void view_flush(struct view *view)
{
    if (space_is_visible(view->sid)) {
        tree_flush(view);
        view_clear_flag(view, VIEW_IS_DIRTY);
    } else {
        view_set_flag(view, VIEW_IS_DIRTY);
    }
}

//
// NOTE: The windows of a space as a json array, in temporary storage.
//

static char *view_window_list_json(uint64_t sid)
{
    int window_count = 0;
    uint32_t *window_list = space_window_list(sid, &window_count, true);

    int size = 3 + window_count * 12;
    char *result = ts_alloc_unaligned(size);
    int length = snprintf(result, size, "[");

    for (int i = 0; i < window_count; ++i) {
        length += snprintf(result + length, size - length, "%s%d", i ? ", " : "", window_list[i]);
    }

    snprintf(result + length, size - length, "]");
    return result;
}

static uint32_t view_first_window(struct view *view)
{
    struct con *first = view->tree ? tree_descend_focused(tree_first_leaf(view->tree)) : NULL;
    return first ? first->window_id : 0;
}

static uint32_t view_last_window(struct view *view)
{
    struct con *last = view->tree ? tree_last_leaf(view->tree) : NULL;
    return last ? last->window_id : 0;
}

static char *view_uuid_string(struct view *view)
{
    char *uuid = ts_cfstring_copy(view->uuid);
    return uuid ? uuid : "<unknown>";
}

static char *view_label_string(struct view *view)
{
    struct space_label *space_label = space_manager_get_label_for_space(&g_space_manager, view->sid);
    return space_label ? json_string(space_label->label) : "";
}

void view_serialize(FILE *rsp, struct view *view, uint64_t flags)
{
    TIME_FUNCTION;

    if (flags == 0x0) flags |= ~flags;

    char *separator = "";
    fprintf(rsp, "{\n");

    JSON_PROPERTY(SPACE_PROPERTY_ID,            "\"id\":%lld", view->sid);
    JSON_PROPERTY(SPACE_PROPERTY_UUID,          "\"uuid\":\"%s\"", view_uuid_string(view));
    JSON_PROPERTY(SPACE_PROPERTY_INDEX,         "\"index\":%d", space_manager_mission_control_index(view->sid));
    JSON_PROPERTY(SPACE_PROPERTY_LABEL,         "\"label\":\"%s\"", view_label_string(view));
    JSON_PROPERTY(SPACE_PROPERTY_TYPE,          "\"type\":\"%s\"", view_type_str[view->layout]);
    JSON_PROPERTY(SPACE_PROPERTY_DISPLAY,       "\"display\":%d", display_manager_display_id_arrangement(space_display_id(view->sid)));
    JSON_PROPERTY(SPACE_PROPERTY_WINDOWS,       "\"windows\":%s", view_window_list_json(view->sid));
    JSON_PROPERTY(SPACE_PROPERTY_FIRST_WINDOW,  "\"first-window\":%d", view_first_window(view));
    JSON_PROPERTY(SPACE_PROPERTY_LAST_WINDOW,   "\"last-window\":%d", view_last_window(view));
    JSON_PROPERTY(SPACE_PROPERTY_HAS_FOCUS,     "\"has-focus\":%s", json_bool(view->sid == g_space_manager.current_space_id));
    JSON_PROPERTY(SPACE_PROPERTY_IS_VISIBLE,    "\"is-visible\":%s", json_bool(space_is_visible(view->sid)));
    JSON_PROPERTY(SPACE_PROPERTY_IS_FULLSCREEN, "\"is-native-fullscreen\":%s", json_bool(space_is_fullscreen(view->sid)));

    fprintf(rsp, "\n}");
}

bool view_auto_padding_applies(enum view_type layout, bool auto_padding, int tiled_count)
{
    return auto_padding && layout == VIEW_TREE && tiled_count <= 1;
}

int view_tiled_count(struct view *view)
{
    return tree_view_tiled_count(view);
}

static struct area view_root_area(struct view *view, CGRect frame)
{
    struct area area = area_from_cgrect(frame);

    if (view_check_flag(view, VIEW_ENABLE_PADDING) && !view_check_flag(view, VIEW_IS_UNPADDED)) {
        area.x += view->left_padding;
        area.w -= (view->left_padding + view->right_padding);
        area.y += view->top_padding;
        area.h -= (view->top_padding + view->bottom_padding);
    }

    return area;
}

static void view_update_with_auto_padding(struct view *view, bool unpadded)
{
    if (unpadded) {
        view_set_flag(view, VIEW_IS_UNPADDED);
    } else {
        view_clear_flag(view, VIEW_IS_UNPADDED);
    }

    uint32_t did = space_display_id(view->sid);
    CGRect frame = display_bounds_constrained(did, false);
    view->area = view_root_area(view, frame);

    tree_view_update(view);
    view_set_flag(view, VIEW_IS_VALID);
    view_set_flag(view, VIEW_IS_DIRTY);
}

//
// NOTE: Re-layout the view if the tiled window count crossed the auto_padding threshold.
// Returns true if it did, in which case the whole tree must be flushed.
//

bool view_update_auto_padding(struct view *view)
{
    bool unpadded = view_auto_padding_applies(view->layout, view->auto_padding, view_tiled_count(view));
    if (unpadded == (view_check_flag(view, VIEW_IS_UNPADDED) != 0)) return false;

    view_update_with_auto_padding(view, unpadded);
    return true;
}

void view_update(struct view *view)
{
    view_update_with_auto_padding(view, view_auto_padding_applies(view->layout, view->auto_padding, view_tiled_count(view)));
}

void view_update_and_flush(struct view *view)
{
    view_update(view);
    view_flush(view);
}

struct view *view_create(uint64_t sid)
{
    struct view *view = malloc(sizeof(struct view));
    memset(view, 0, sizeof(struct view));

    view->sid = sid;
    view->uuid = SLSSpaceCopyName(g_connection, sid);

    view_set_flag(view, VIEW_ENABLE_PADDING);
    view_set_flag(view, VIEW_ENABLE_GAP);

    if (space_is_user(view->sid)) {
        if (!view_check_flag(view, VIEW_LAYOUT))         view->layout         = g_space_manager.layout;
        if (!view_check_flag(view, VIEW_TOP_PADDING))    view->top_padding    = g_space_manager.top_padding;
        if (!view_check_flag(view, VIEW_BOTTOM_PADDING)) view->bottom_padding = g_space_manager.bottom_padding;
        if (!view_check_flag(view, VIEW_LEFT_PADDING))   view->left_padding   = g_space_manager.left_padding;
        if (!view_check_flag(view, VIEW_RIGHT_PADDING))  view->right_padding  = g_space_manager.right_padding;
        if (!view_check_flag(view, VIEW_WINDOW_GAP))     view->window_gap     = g_space_manager.window_gap;
        if (!view_check_flag(view, VIEW_AUTO_PADDING))   view->auto_padding   = g_space_manager.auto_padding;
        view_update(view);
    } else {
        view->layout = VIEW_FLOAT;
    }

    return view;
}

void view_clear(struct view *view)
{
    view->insertion_point = 0;
    tree_view_clear(view);
    view_update(view);
}

void view_destroy(struct view *view)
{
    tree_view_clear(view);

    if (view->uuid) {
        CFRelease(view->uuid);
    }
}
