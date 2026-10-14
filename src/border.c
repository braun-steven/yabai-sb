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

    float outer_radius = min(border->radius + border->width, min(ring.size.width, ring.size.height) * 0.5f);
    float inner_radius = min(border->radius, min(inner.size.width, inner.size.height) * 0.5f);

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
// NOTE: Brings the border in line with its window: hides it while the window is not ordered in, otherwise moves it
// to the space of the window, reshapes and redraws the edges when the size or the color changed, moves them to the
// frame and orders them right below the window at its level.
//

static void border_update_locked(struct border *border)
{
    if (!border_settings.enabled || !border->enabled || border->suspended) {
        border_hide_locked(border);
        return;
    }

    uint8_t ordered_in = 0;
    SLSWindowIsOrderedIn(g_connection, border->wid, &ordered_in);
    if (!ordered_in) {
        border_hide_locked(border);
        return;
    }

    CGRect frame;
    if (SLSGetWindowBounds(g_connection, border->wid, &frame) != kCGErrorSuccess) {
        border_hide_locked(border);
        return;
    }

    struct rgba_color color = border->focused ? border_settings.active_color : border_settings.normal_color;
    bool resized = !CGSizeEqualToSize(frame.size, border->frame.size) || border->width != border_settings.width;
    bool recolored = color.p != border->color;

    border->frame = frame;
    border->width = border_settings.width;
    border_edge_frames(frame, border->width, border->radius, border->edge);

    SLSDisableUpdate(g_connection);

    if (!border->id[0]) {
        for (int i = 0; i < BORDER_EDGE_COUNT; ++i) border_create_edge(border, i);
        border->sid = 0;
        border->sticky = false;
        resized = true;
    } else if (resized) {
        for (int i = 0; i < BORDER_EDGE_COUNT; ++i) border_reshape_edge(border, i);
    }

    if (resized || recolored) {
        for (int i = 0; i < BORDER_EDGE_COUNT; ++i) border_draw_edge(border, i, color);
        border->color = color.p;
    }

    int level = window_level(border->wid);
    int sub_level = window_sub_level(border->wid);

    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        SLSMoveWindow(g_connection, border->id[i], &border->edge[i].origin);
        SLSSetWindowLevel(g_connection, border->id[i], level);
        SLSSetWindowSubLevel(g_connection, border->id[i], sub_level);

        //
        // NOTE: A side edge of a window shorter than two corners is empty, so it stays hidden.
        //

        if (border->edge[i].size.width > 0 && border->edge[i].size.height > 0) {
            SLSOrderWindow(g_connection, border->id[i], -1, border->wid);
        } else {
            SLSOrderWindow(g_connection, border->id[i], 0, 0);
        }
    }

    //
    // NOTE: The edges are put on the space of the window after they are ordered, and checked on every update,
    // because ordering them in can move them to the active space.
    //

    bool sticky = window_is_sticky(border->wid);
    uint64_t sid = window_space(border->wid);
    if (!sticky && sid && window_space(border->id[0]) != sid) border_move_to_space(border, sid);
    border_set_sticky(border, sticky);

    SLSReenableUpdate(g_connection);
    border->shown = true;
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
// NOTE: Called on the event loop whenever the state of the window that decides about its border may have changed:
// creation, focus, (de)minimize, hide/unhide of its application, native fullscreen and moves to another space.
//

void border_refresh(struct window *window)
{
    if (!window || !window->id) return;

    bool enabled = g_window_manager.enable_window_border && border_should_show(window);
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
        added = !border->enabled && enabled;
        border->enabled = enabled;
        border->focused = focused;
        border_update_locked(border);
    }

    pthread_mutex_unlock(&border_lock);

    if (added && !workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
        update_window_notifications();
    }
}

void border_refresh_all(void)
{
    table_for (struct window *window, g_window_manager.window, {
        border_refresh(window);
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
        border_update_locked(border);
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

    CGRect frame;
    if (SLSGetWindowBounds(g_connection, wid, &frame) != kCGErrorSuccess) goto out;

    if (!CGSizeEqualToSize(frame.size, border->frame.size)) {
        border_update_locked(border);
        goto out;
    }

    border->frame = frame;
    border_edge_frames(frame, border->width, border->radius, border->edge);

    SLSDisableUpdate(g_connection);
    for (int i = 0; i < BORDER_EDGE_COUNT; ++i) {
        SLSMoveWindow(g_connection, border->id[i], &border->edge[i].origin);
    }
    SLSReenableUpdate(g_connection);

out:
    pthread_mutex_unlock(&border_lock);
}

void border_window_changed(uint32_t wid)
{
    pthread_mutex_lock(&border_lock);
    if (!border_table_ready) goto out;

    struct border *border = table_find(&border_table, &wid);
    if (border && border->enabled) border_update_locked(border);

out:
    pthread_mutex_unlock(&border_lock);
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
