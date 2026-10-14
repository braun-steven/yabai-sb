extern int g_connection;
extern struct window_manager g_window_manager;

//
// NOTE: A border is made of four raw SkyLight windows, one per edge, around the window it belongs to. A single
// window around the whole frame would need a backing store as large as the window (about 30 MB at 2x for a big
// window, and the window server keeps one even when the window is only shaped like a ring); the edges only need
// one for the ring itself. The top and bottom edges span the full width and are tall enough to hold the rounded
// corners, the left and right edges fill the straight part in between.
//
// The borders are ordered right below their window, so the window covers the inner edge of the ring, and live on
// the space of their window, so space switches show and hide them without any work from us.
//
// The event loop decides whether a window has a border and which color it has (border_refresh). Moves and resizes
// are applied directly from the SkyLight notifications on the main thread (border_window_moved/changed), without a
// round trip through the event queue, so the border keeps up with a window that is dragged. Both sides only touch
// the border table and its settings below, which are guarded by border_lock, and never the window structs.
//

static pthread_mutex_t border_lock = PTHREAD_MUTEX_INITIALIZER;
static struct table border_table;
static bool border_table_ready;

static struct {
    bool enabled;
    float width;
    struct rgba_color active_color;
    struct rgba_color normal_color;
} border_settings;

//
// NOTE: Within a batch, borders that are turned on or off are shown and hidden only at its end. The windows of a
// tabbed container share the ring around the container, so a tab switch turns off the border of one tab and turns on
// the same ring for the other. Edges that are ordered in again stay blank for a few frames, so instead of hiding one
// ring and showing the other, the edges of the shown ring are handed over to the new tab (border_hand_over_locked).
//

static int border_batch_depth;
static uint32_t border_show_list[64];
static int border_show_count;
static uint32_t border_hide_list[64];
static int border_hide_count;

static CFArrayRef (*border_corner_radii_func)(CFTypeRef iterator);
static bool border_corner_radii_resolved;

static TABLE_HASH_FUNC(border_hash)
{
    return *(uint32_t *) key;
}

static TABLE_COMPARE_FUNC(border_compare)
{
    return *(uint32_t *) key_a == *(uint32_t *) key_b;
}

static inline void border_table_init(void)
{
    if (border_table_ready) return;
    table_init(&border_table, 150, border_hash, border_compare);
    border_table_ready = true;
}

//
// NOTE: The frame the ring goes around: the bounds of the window, grown by the insets of the container it wraps
// (the tab bars of a tabbed container), and the corner radius of that frame.
//

static inline CGRect border_target_frame(struct border *border, CGRect bounds)
{
    return (CGRect) {{ bounds.origin.x - border->inset_left, bounds.origin.y - border->inset_top },
                     { bounds.size.width + border->inset_left + border->inset_right, bounds.size.height + border->inset_top + border->inset_bottom }};
}

static inline float border_target_radius(struct border *border)
{
    return border->container_radius > 0 ? border->container_radius : border->radius;
}

//
// NOTE: Splits the ring around the frame into the frames of the four edge windows. The ring is width wide and its
// outer corners have a radius of radius + width, so the top and bottom edges must be that tall to hold a corner.
// The left and right edges reach one point under the window, like the inner edge of the ring, so that no gap shows
// next to the antialiased edge of the window. For a window too short for two corners, the top and bottom edges
// split the height and the side edges are empty.
//

void border_edge_frames(CGRect frame, float width, float radius, CGRect *edge)
{
    CGRect outer = CGRectInset(frame, -width, -width);
    float extent = ceilf(radius + width);
    float top_height = min(extent, floorf(outer.size.height * 0.5f));
    float bottom_height = min(extent, outer.size.height - top_height);
    float side_height = max(outer.size.height - top_height - bottom_height, 0.0f);
    float side_width = min(width + 1.0f, floorf(outer.size.width * 0.5f));

    edge[BORDER_EDGE_TOP]    = (CGRect) {{ outer.origin.x, outer.origin.y }, { outer.size.width, top_height }};
    edge[BORDER_EDGE_BOTTOM] = (CGRect) {{ outer.origin.x, outer.origin.y + outer.size.height - bottom_height }, { outer.size.width, bottom_height }};
    edge[BORDER_EDGE_LEFT]   = (CGRect) {{ outer.origin.x, outer.origin.y + top_height }, { side_width, side_height }};
    edge[BORDER_EDGE_RIGHT]  = (CGRect) {{ outer.origin.x + outer.size.width - side_width, outer.origin.y + top_height }, { side_width, side_height }};
}

//
// NOTE: macOS 26 gives windows different corner radii, which SkyLight reports per window. Older versions have no
// such function and use the same radius for every window.
//

static float border_window_radius(uint32_t wid)
{
    if (!border_corner_radii_resolved) {
        border_corner_radii_func = dlsym(RTLD_DEFAULT, "SLSWindowIteratorGetCornerRadii");
        border_corner_radii_resolved = true;
    }

    if (!border_corner_radii_func) return BORDER_DEFAULT_RADIUS;

    int radius = 0;
    CFArrayRef window_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    CFTypeRef query = SLSWindowQueryWindows(g_connection, window_ref, 1);
    if (query) {
        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
        if (iterator) {
            if (SLSWindowIteratorAdvance(iterator)) {
                CFArrayRef radii = border_corner_radii_func(iterator);
                if (radii) {
                    if (CFArrayGetCount(radii) > 0) {
                        CFNumberGetValue(CFArrayGetValueAtIndex(radii, 0), kCFNumberIntType, &radius);
                    }
                    CFRelease(radii);
                }
            }
            CFRelease(iterator);
        }
        CFRelease(query);
    }
    CFRelease(window_ref);

    return radius > 0 ? radius : BORDER_DEFAULT_RADIUS;
}

static void border_create_edge(struct border *border, int index)
{
    CGRect frame = border->edge[index];
    CGRect shape = { CGPointZero, { max(frame.size.width, 1.0f), max(frame.size.height, 1.0f) } };

    //
    // NOTE: Created with SLSNewWindow instead of SLSNewWindowWithOpaqueShapeAndContext like the tab bars, because a
    // window of the latter is moved to the active space each time it is ordered in again, so a border that was hidden
    // and shown again would land on whatever space is visible instead of the space of its window.
    //

    CFTypeRef shape_region;
    CGSNewRegionWithRect(&shape, &shape_region);
    SLSNewWindow(g_connection, 2, frame.origin.x, frame.origin.y, shape_region, &border->id[index]);
    CFRelease(shape_region);

    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    SLSSetWindowTags(g_connection, border->id[index], &tags, 64);
    sls_window_disable_shadow(border->id[index]);
    SLSSetWindowResolution(g_connection, border->id[index], 2.0f);
    SLSSetWindowOpacity(g_connection, border->id[index], 0);
    border->context[index] = SLWindowContextCreate(g_connection, border->id[index], 0);
}

static void border_reshape_edge(struct border *border, int index)
{
    CGRect frame = border->edge[index];
    CGRect shape = { CGPointZero, { max(frame.size.width, 1.0f), max(frame.size.height, 1.0f) } };

    CFTypeRef shape_region;
    CGSNewRegionWithRect(&shape, &shape_region);
    SLSSetWindowShape(g_connection, border->id[index], frame.origin.x, frame.origin.y, shape_region);
    CFRelease(shape_region);
}

//
// NOTE: Every edge draws the whole ring, shifted so that its own part of the ring lands in its bounds; the context
// clips the rest. The ring is the area between the outer rounded rect and the window frame inset by one point,
// filled with the even-odd rule.
//

static void border_draw_edge(struct border *border, int index, struct rgba_color color)
{
    CGContextRef context = border->context[index];
    CGRect edge = border->edge[index];
    CGContextClearRect(context, (CGRect) { CGPointZero, edge.size });

    CGRect outer = CGRectInset(border->frame, -border->width, -border->width);
    CGRect ring = { CGPointZero, outer.size };
    CGRect inner = CGRectInset(ring, border->width + 1.0f, border->width + 1.0f);

    float radius = border_target_radius(border);
    float outer_radius = min(radius + border->width, min(ring.size.width, ring.size.height) * 0.5f);
    float inner_radius = min(radius, min(inner.size.width, inner.size.height) * 0.5f);

    CGContextSaveGState(context);
    CGContextTranslateCTM(context, outer.origin.x - edge.origin.x, (edge.origin.y + edge.size.height) - (outer.origin.y + outer.size.height));

    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRoundedRect(path, NULL, ring, outer_radius, outer_radius);
    if (inner.size.width > 0 && inner.size.height > 0) {
        CGPathAddRoundedRect(path, NULL, inner, max(inner_radius, 0.0f), max(inner_radius, 0.0f));
    }

    CGContextSetRGBFillColor(context, color.r, color.g, color.b, color.a);
    CGContextAddPath(context, path);
    CGContextEOFillPath(context);
    CGPathRelease(path);

    CGContextRestoreGState(context);
    CGContextFlush(context);
}

static void border_hide_locked(struct border *border)
{
    if (!border->shown) return;

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        if (border->id[i]) SLSOrderWindow(g_connection, border->id[i], 0, 0);
    }

    border->shown = false;
}

static void border_release_locked(struct border *border)
{
    border_hide_locked(border);

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        if (border->context[i]) CGContextRelease(border->context[i]);
        if (border->id[i]) SLSReleaseWindow(g_connection, border->id[i]);
        border->context[i] = NULL;
        border->id[i] = 0;
    }
}

static void border_move_to_space(struct border *border, uint64_t sid)
{
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(border->id, sizeof(uint32_t), BORDER_EDGE_COUNT, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
    CFRelease(window_list_ref);
    border->sid = sid;
}

static void border_set_sticky(struct border *border, bool sticky)
{
    if (border->sticky == sticky) return;

    uint64_t tags = 1ULL << 11;
    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        if (sticky) {
            SLSSetWindowTags(g_connection, border->id[i], &tags, 64);
        } else {
            SLSClearWindowTags(g_connection, border->id[i], &tags, 64);
        }
    }

    border->sticky = sticky;
}

//
// NOTE: Brings the border in line with its window. BORDER_UPDATE_FRAME moves the edges to the frame of the window and
// reshapes and redraws them when its size or the color changed. BORDER_UPDATE_ORDER hides the border while the window
// is not ordered in, otherwise orders the edges right below the window at its level and keeps them on its space.
// A border that is shown again gets both. Updates are pushed by the window server notifications of the window, so
// each one does only what its notification can have changed: SkyLight calls are cheap, but yabai makes many of them.
//
// BORDER_UPDATE_COLOR only redraws the edges of a shown border in its current color, without asking the window server
// about the window. A focus change needs nothing else, and it happens while the application of the window is busy
// becoming active: the window server can hold back its replies about the window until then, for up to half a second.
//

#define BORDER_UPDATE_FRAME 0x1
#define BORDER_UPDATE_ORDER 0x2
#define BORDER_UPDATE_COLOR 0x4
#define BORDER_UPDATE_ALL   (BORDER_UPDATE_FRAME | BORDER_UPDATE_ORDER)

static inline struct rgba_color border_current_color(struct border *border)
{
    return border->focused ? border_settings.active_color : border_settings.normal_color;
}

//
// NOTE: Returns false when the window has no bounds anymore, so the border has to be hidden.
//

static bool border_update_frame_locked(struct border *border)
{
    CGRect bounds;
    if (SLSGetWindowBounds(g_connection, border->wid, &bounds) != kCGErrorSuccess) return false;

    CGRect frame = border_target_frame(border, bounds);
    float radius = border_target_radius(border);
    struct rgba_color color = border_current_color(border);
    bool restyled = border->width != border_settings.width || radius != border->drawn_radius || color.p != border->color;

    CGRect previous[BORDER_EDGE_COUNT];
    memcpy(previous, border->edge, sizeof(previous));

    border->frame = frame;
    border->width = border_settings.width;
    border->drawn_radius = radius;
    border->color = color.p;
    border_edge_frames(frame, border->width, radius, border->edge);

    bool created = !border->id[0];
    if (created) {
        for (int i = 0; i < BORDER_EDGE_COUNT; ++i) border_create_edge(border, i);
        border->sid = 0;
        border->sticky = false;
        border->level = INT_MIN;
        border->sub_level = INT_MIN;
    }

    //
    // NOTE: Only edges whose size changed are reshaped and redrawn: a window that gets wider only changes the top
    // and bottom edges, the side edges just move.
    //

    bool reshaped[BORDER_EDGE_COUNT];
    bool any_reshaped = false;

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        reshaped[i] = created || !CGSizeEqualToSize(previous[i].size, border->edge[i].size);
        any_reshaped |= reshaped[i];
    }

    if (any_reshaped) SLSDisableUpdate(g_connection);

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        if (reshaped[i] && !created) border_reshape_edge(border, i);
        if (reshaped[i] || restyled) border_draw_edge(border, i, color);
        SLSMoveWindow(g_connection, border->id[i], &border->edge[i].origin);
    }

    if (any_reshaped) SLSReenableUpdate(g_connection);
    return true;
}

static void border_update_order_locked(struct border *border)
{
    int level = window_level(border->wid);
    int sub_level = window_sub_level(border->wid);

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        if (level != border->level) SLSSetWindowLevel(g_connection, border->id[i], level);
        if (sub_level != border->sub_level) SLSSetWindowSubLevel(g_connection, border->id[i], sub_level);

        //
        // NOTE: A side edge of a window shorter than two corners is empty, so it stays hidden.
        //

        if (border->edge[i].size.width > 0 && border->edge[i].size.height > 0) {
            SLSOrderWindow(g_connection, border->id[i], -1, border->wid);
        } else {
            SLSOrderWindow(g_connection, border->id[i], 0, 0);
        }
    }

    border->level = level;
    border->sub_level = sub_level;

    //
    // NOTE: The edges are put on the space of the window after they are ordered, because ordering them in can
    // move them to the active space.
    //

    bool sticky = window_is_sticky(border->wid);
    uint64_t sid = window_space(border->wid);
    if (!sticky && sid && window_space(border->id[0]) != sid) border_move_to_space(border, sid);
    if (sid) border->sid = sid;
    border_set_sticky(border, sticky);
}

static void border_update_locked(struct border *border, int what)
{
    if (!border_settings.enabled || !border->enabled || border->suspended) {
        border_hide_locked(border);
        return;
    }

    if (!border->shown) what = BORDER_UPDATE_ALL;

    if (what == BORDER_UPDATE_COLOR) {
        struct rgba_color color = border_current_color(border);
        for (int i = 0; i < BORDER_EDGE_COUNT; ++i) border_draw_edge(border, i, color);
        border->color = color.p;
        return;
    }

    if (what & BORDER_UPDATE_ORDER) {
        uint8_t ordered_in = 0;
        SLSWindowIsOrderedIn(g_connection, border->wid, &ordered_in);
        if (!ordered_in) {
            border_hide_locked(border);
            return;
        }
    }

    if ((what & BORDER_UPDATE_FRAME) && !border_update_frame_locked(border)) {
        border_hide_locked(border);
        return;
    }

    if (what & BORDER_UPDATE_ORDER) border_update_order_locked(border);

    border->shown = true;
}

//
// NOTE: Gives the shown edges of from to the border to, which goes around the same frame, and the hidden edges of to
// to from. The edges stay ordered in and are only moved below the window of to, which shares the level and the space
// of the window of from, and redrawn when the color differs, all within one update of the screen.
//

static void border_hand_over_locked(struct border *from, struct border *to)
{
    struct border edges = *to;

    memcpy(to->id, from->id, sizeof(to->id));
    memcpy(to->context, from->context, sizeof(to->context));
    memcpy(to->edge, from->edge, sizeof(to->edge));
    to->frame = from->frame;
    to->sid = from->sid;
    to->drawn_radius = from->drawn_radius;
    to->width = from->width;
    to->color = from->color;
    to->sticky = from->sticky;
    to->level = from->level;
    to->sub_level = from->sub_level;
    to->shown = true;

    memcpy(from->id, edges.id, sizeof(from->id));
    memcpy(from->context, edges.context, sizeof(from->context));
    memcpy(from->edge, edges.edge, sizeof(from->edge));
    from->frame = edges.frame;
    from->sid = edges.sid;
    from->drawn_radius = edges.drawn_radius;
    from->width = edges.width;
    from->color = edges.color;
    from->sticky = edges.sticky;
    from->level = edges.level;
    from->sub_level = edges.sub_level;
    from->shown = false;

    SLSDisableUpdate(g_connection);
    border_update_locked(to, BORDER_UPDATE_FRAME);
    if (to->shown) {
        for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
            if (to->edge[i].size.width > 0 && to->edge[i].size.height > 0) {
                SLSOrderWindow(g_connection, to->id[i], -1, to->wid);
            }
        }
    }
    SLSReenableUpdate(g_connection);
}

static bool border_should_show(struct window *window)
{
    if (!window->is_eligible)                             return false;
    if (!window->application || window->application->is_hidden) return false;
    if (window_check_flag(window, WINDOW_MINIMIZE))       return false;
    if (window_check_flag(window, WINDOW_FULLSCREEN))     return false;
    if (window_check_rule_flag(window, WINDOW_RULE_MANAGED)) return true;

    return window_is_standard(window) && window_level_is_standard(window);
}

//
// NOTE: The number of windows that count for window_border_hide_single on a space: the tiled windows, where a tabbed
// container counts as one like for auto_padding, and the visible floating windows. Scratchpads do not count.
//

static int border_space_window_count(uint64_t sid)
{
    struct view *view = space_manager_find_view(&g_space_manager, sid);
    int count = view && view->layout == VIEW_TREE ? tree_view_tiled_count(view) : 0;

    table_for (struct window *window, g_window_manager.window, {
        if (window->scratchpad || !border_should_show(window)) continue;
        if (window_manager_find_managed_window(&g_window_manager, window)) continue;
        if (window_space(window->id) != sid) continue;

        uint8_t ordered_in = 0;
        SLSWindowIsOrderedIn(g_connection, window->id, &ordered_in);
        if (ordered_in) ++count;
    })

    return count;
}

static void border_refresh_with_count(struct window *window, uint64_t sid, int window_count)
{
    if (!window || !window->id) return;

    struct area window_area, border_area;
    int container_radius;
    struct view *view = window_manager_find_managed_window(&g_window_manager, window);

    bool enabled = g_window_manager.enable_window_border &&
                   border_should_show(window) &&
                   tree_window_border_area(view, window->id, &window_area, &border_area, &container_radius);

    if (enabled && g_window_manager.window_border_hide_single && !window->scratchpad) {
        if (window_count < 0) window_count = border_space_window_count(sid ? sid : window_space(window->id));
        enabled = window_count > 1;
    }

    bool focused = g_window_manager.focused_window_id == window->id;

    pthread_mutex_lock(&border_lock);
    border_table_init();

    border_settings.enabled = g_window_manager.enable_window_border;
    border_settings.width = g_window_manager.window_border_width;
    border_settings.active_color = g_window_manager.active_window_border_color;
    border_settings.normal_color = g_window_manager.normal_window_border_color;

    struct border *border = table_find(&border_table, &window->id);
    if (!border && enabled) {
        border = calloc(1, sizeof(struct border));
        border->wid = window->id;
        border->radius = border_window_radius(window->id);
        table_add(&border_table, &border->wid, border);
    }

    bool added = false;
    if (border) {
        float inset_top    = enabled ? window_area.y - border_area.y : border->inset_top;
        float inset_left   = enabled ? window_area.x - border_area.x : border->inset_left;
        float inset_bottom = enabled ? (border_area.y + border_area.h) - (window_area.y + window_area.h) : border->inset_bottom;
        float inset_right  = enabled ? (border_area.x + border_area.w) - (window_area.x + window_area.w) : border->inset_right;
        float radius       = enabled ? container_radius : border->container_radius;
        CGRect area        = enabled ? (CGRect) {{ border_area.x, border_area.y }, { border_area.w, border_area.h }} : border->area;

        //
        // NOTE: Nothing to do when the state of the border is unchanged; moves and resizes of the window reach the
        // border through its own notifications. A border that only changes its color is just redrawn.
        //

        struct rgba_color color = focused ? border_settings.active_color : border_settings.normal_color;
        bool recolored = border->color != color.p;
        bool changed = border->enabled != enabled ||
                       border->inset_top != inset_top ||
                       border->inset_left != inset_left ||
                       border->inset_bottom != inset_bottom ||
                       border->inset_right != inset_right ||
                       border->container_radius != radius ||
                       border->width != border_settings.width ||
                       border->shown != enabled;

        added = !border->enabled && enabled;
        border->enabled = enabled;
        border->focused = focused;
        border->inset_top = inset_top;
        border->inset_left = inset_left;
        border->inset_bottom = inset_bottom;
        border->inset_right = inset_right;
        border->container_radius = radius;
        border->area = area;

        if (changed && !enabled && border->shown && border_batch_depth > 0 && border_hide_count < (int) array_count(border_hide_list)) {
            border_hide_list[border_hide_count++] = border->wid;
        } else if (changed && enabled && !border->shown && border_batch_depth > 0 && border_show_count < (int) array_count(border_show_list)) {
            border_show_list[border_show_count++] = border->wid;
        } else if (changed) {
            border_update_locked(border, BORDER_UPDATE_ALL);
        } else if (recolored) {
            border_update_locked(border, BORDER_UPDATE_COLOR);
        }
    }

    pthread_mutex_unlock(&border_lock);

    if (added && !workspace_is_macos_sequoia_or_newer()) {
        update_window_notifications();
    }
}

void border_begin_batch(void)
{
    ++border_batch_depth;
}

void border_end_batch(void)
{
    if (--border_batch_depth > 0) return;

    pthread_mutex_lock(&border_lock);

    for (int i = 0; i < border_show_count; ++i) {
        struct border *border = table_find(&border_table, &border_show_list[i]);
        if (!border || !border->enabled || border->shown) continue;

        struct border *shown = NULL;
        if (border_settings.enabled && !border->suspended && border->area.size.width > 0) {
            for (int j = 0; j < border_hide_count; ++j) {
                struct border *other = table_find(&border_table, &border_hide_list[j]);
                if (other && !other->enabled && other->shown && CGRectEqualToRect(other->area, border->area)) {
                    shown = other;
                    break;
                }
            }
        }

        if (shown) {
            border_hand_over_locked(shown, border);
        } else {
            border_update_locked(border, BORDER_UPDATE_ALL);
        }
    }

    for (int i = 0; i < border_hide_count; ++i) {
        struct border *border = table_find(&border_table, &border_hide_list[i]);
        if (border && !border->enabled) border_hide_locked(border);
    }

    border_show_count = 0;
    border_hide_count = 0;
    pthread_mutex_unlock(&border_lock);
}

//
// NOTE: Called on the event loop whenever the state of the window that decides about its border may have changed,
// e.g. its focus. Changes that can also affect the borders of the other windows on the space (a window appears or
// disappears, a container changes) refresh the whole space instead.
//

void border_refresh(struct window *window)
{
    border_refresh_with_count(window, 0, -1);
}

//
// NOTE: Without window_border_hide_single a change on a space only affects the borders of its tiled windows and of
// the windows that had a border there (e.g. a window that just stopped being tiled), so only those are refreshed,
// without asking the window server for the space of every window.
//

void border_refresh_space(uint64_t sid)
{
    if (!sid) return;

    border_begin_batch();

    if (g_window_manager.window_border_hide_single) {
        int window_count = border_space_window_count(sid);

        table_for (struct window *window, g_window_manager.window, {
            if (window_space(window->id) == sid) border_refresh_with_count(window, sid, window_count);
        })

        border_end_batch();
        return;
    }

    int window_count = 0;
    uint32_t *tree_list = NULL;

    struct view *view = space_manager_find_view(&g_space_manager, sid);
    if (view && view->layout == VIEW_TREE) tree_list = tree_view_window_list(view, &window_count);

    int capacity = window_count + g_window_manager.window.count;
    uint32_t *window_list = ts_alloc_list(uint32_t, capacity);
    if (window_count) memcpy(window_list, tree_list, sizeof(uint32_t) * window_count);

    pthread_mutex_lock(&border_lock);
    if (border_table_ready) {
        table_for (struct border *border, border_table, {
            if (border->sid != sid) continue;

            bool listed = false;
            for (int j = 0; j < window_count; ++j) {
                if (window_list[j] == border->wid) { listed = true; break; }
            }

            if (!listed && window_count < capacity) {
                window_list[window_count++] = border->wid;
            }
        })
    }
    pthread_mutex_unlock(&border_lock);

    for (int i = 0; i < window_count; ++i) {
        border_refresh_with_count(window_manager_find_window(&g_window_manager, window_list[i]), sid, 0);
    }

    border_end_batch();
}

void border_refresh_window_space(struct window *window)
{
    if (!window || !window->id) return;

    uint64_t sid = window_space(window->id);
    if (g_window_manager.window_border_hide_single && sid) {
        border_refresh_space(sid);
    } else {
        border_refresh(window);
    }
}

void border_refresh_all(void)
{
    uint64_t sid_list[64];
    int count_list[64];
    int sid_count = 0;

    table_for (struct window *window, g_window_manager.window, {
        uint64_t sid = window_space(window->id);
        int window_count = -1;

        if (g_window_manager.window_border_hide_single && sid) {
            for (int j = 0; j < sid_count; ++j) {
                if (sid_list[j] == sid) { window_count = count_list[j]; break; }
            }

            if (window_count < 0) {
                window_count = border_space_window_count(sid);
                if (sid_count < (int) array_count(sid_list)) {
                    sid_list[sid_count] = sid;
                    count_list[sid_count] = window_count;
                    ++sid_count;
                }
            }
        }

        border_refresh_with_count(window, sid, window_count);
    })
}

void border_remove(uint32_t wid)
{
    pthread_mutex_lock(&border_lock);
    border_table_init();

    struct border *border = table_find(&border_table, &wid);
    if (border) {
        table_remove(&border_table, &wid);
        border_release_locked(border);
        free(border);
    }

    pthread_mutex_unlock(&border_lock);
}

//
// NOTE: A window that is animated is drawn by a proxy window in its place while the real window already sits at its
// final frame, so its border is hidden for the duration of the animation and put back at the end.
//

void border_suspend(uint32_t wid, bool suspended)
{
    pthread_mutex_lock(&border_lock);
    if (!border_table_ready) goto out;

    struct border *border = table_find(&border_table, &wid);
    if (border) {
        border->suspended = suspended;
        border_update_locked(border, BORDER_UPDATE_ALL);
    }

out:
    pthread_mutex_unlock(&border_lock);
}

//
// NOTE: The handlers below run on the main thread, straight from the SkyLight notifications of the window.
//

void border_window_moved(uint32_t wid)
{
    pthread_mutex_lock(&border_lock);
    if (!border_table_ready) goto out;

    struct border *border = table_find(&border_table, &wid);
    if (!border || !border->shown) goto out;

    CGRect bounds;
    if (SLSGetWindowBounds(g_connection, wid, &bounds) != kCGErrorSuccess) goto out;

    CGRect frame = border_target_frame(border, bounds);
    if (!CGSizeEqualToSize(frame.size, border->frame.size)) {
        border_update_locked(border, BORDER_UPDATE_FRAME);
        goto out;
    }

    border->frame = frame;
    border_edge_frames(frame, border->width, border->drawn_radius, border->edge);

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        SLSMoveWindow(g_connection, border->id[i], &border->edge[i].origin);
    }

out:
    pthread_mutex_unlock(&border_lock);
}

static void border_window_update(uint32_t wid, int what)
{
    pthread_mutex_lock(&border_lock);
    if (!border_table_ready) goto out;

    struct border *border = table_find(&border_table, &wid);
    if (border && border->enabled) border_update_locked(border, what);

out:
    pthread_mutex_unlock(&border_lock);
}

void border_window_resized(uint32_t wid)
{
    border_window_update(wid, BORDER_UPDATE_FRAME);
}

void border_window_ordered(uint32_t wid)
{
    border_window_update(wid, BORDER_UPDATE_ORDER);
}

void border_window_changed(uint32_t wid)
{
    border_window_update(wid, BORDER_UPDATE_ALL);
}

void border_window_hidden(uint32_t wid)
{
    pthread_mutex_lock(&border_lock);
    if (!border_table_ready) goto out;

    struct border *border = table_find(&border_table, &wid);
    if (border) border_hide_locked(border);

out:
    pthread_mutex_unlock(&border_lock);
}

int border_window_list(uint32_t *window_list, int capacity)
{
    int count = 0;
    pthread_mutex_lock(&border_lock);

    if (border_table_ready) {
        table_for (struct border *border, border_table, {
            if (border->enabled && count < capacity) window_list[count++] = border->wid;
        })
    }

    pthread_mutex_unlock(&border_lock);
    return count;
}
