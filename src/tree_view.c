extern int g_connection;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

//
// NOTE: Applies the container trees of tree.c to the screen: the tree of a view, window frames,
// tab bars, the stacking order of tabs, the outline of selected containers and the JSON of a tree.
// A view that uses the 'tree' layout owns its root container in view->tree.
//

static void tree_append_title(CFMutableStringRef string, struct con *con)
{
    if (con_is_leaf(con)) {
        struct window *window = window_manager_find_window(&g_window_manager, con->window_id);
        if (window && window->application && window->application->name) {
            CFStringAppendCString(string, window->application->name, kCFStringEncodingUTF8);
        }
        return;
    }

    CFStringAppendCString(string, con->layout == CON_SPLITH ? "H[" : con->layout == CON_SPLITV ? "V[" : "T[", kCFStringEncodingUTF8);

    for (int i = 0; i < con->child_count; ++i) {
        if (i > 0) CFStringAppendCString(string, " ", kCFStringEncodingUTF8);
        tree_append_title(string, con->children[i]);
    }

    CFStringAppendCString(string, "]", kCFStringEncodingUTF8);
}

//
// NOTE: The tab title of a container: the window title for a window, or the layout and the
// applications inside for a container, like i3 shows it (H[iTerm2 Safari]).
//

CFStringRef tree_copy_title(struct con *con)
{
    if (con_is_leaf(con)) return tab_bar_copy_title(con->window_id);

    CFMutableStringRef string = CFStringCreateMutable(NULL, 0);
    tree_append_title(string, con);
    return string;
}

static void tree_feedback_destroy(struct con *con)
{
    if (!con->render.feedback_window.id) return;

    SLSOrderWindow(g_connection, con->render.feedback_window.id, 0, 0);
    CGContextRelease(con->render.feedback_window.context);
    SLSReleaseWindow(g_connection, con->render.feedback_window.id);
    memset(&con->render.feedback_window, 0, sizeof(struct feedback_window));
}

static inline int tree_bar_height(void)
{
    return tab_bar_is_enabled() ? g_window_manager.tab_bar_height : 0;
}

static inline int tree_bar_inset(void)
{
    return tab_bar_is_enabled() ? tab_bar_card_padding() : 0;
}

static inline enum con_layout tree_default_layout(struct view *view)
{
    switch (g_space_manager.tree_default_orientation) {
    case TREE_ORIENTATION_HORIZONTAL: return CON_SPLITH;
    case TREE_ORIENTATION_VERTICAL:   return CON_SPLITV;
    case TREE_ORIENTATION_AUTO:       break;
    }

    return view->area.w >= view->area.h ? CON_SPLITH : CON_SPLITV;
}

struct con *tree_view_root(struct view *view)
{
    if (!view->tree) {
        view->tree = con_create(tree_default_layout(view));
        view->tree->area = view->area;
    }

    return view->tree;
}

void tree_view_update(struct view *view)
{
    if (!view->tree) return;
    tree_update(view->tree, view->area, view_window_gap(view), tree_bar_height(), g_window_manager.tab_bar_offset, tree_bar_inset());
}

static void tree_unmanage_windows(struct con *con)
{
    if (con_is_leaf(con)) {
        window_manager_remove_managed_window(&g_window_manager, con->window_id);
        return;
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_unmanage_windows(con->children[i]);
    }
}

void tree_view_clear(struct view *view)
{
    if (!view->tree) return;

    tree_unmanage_windows(view->tree);
    con_free(view->tree);
    view->tree = NULL;
}

struct con *tree_view_find_window(struct view *view, uint32_t window_id)
{
    return view->tree ? tree_find_window(view->tree, window_id) : NULL;
}

//
// NOTE: A new window becomes the focused child of its containers, as i3 focuses new windows, unless
// the focused window is on this space: a window that is moved here or stops floating then stays
// behind it, so that the focused window is not hidden in another tab.
//

static void tree_focus_new_window(struct con *root, struct con *con, uint32_t window_id)
{
    tree_focus(con);

    if (window_id != g_window_manager.focused_window_id) {
        struct con *focused = tree_find_window(root, g_window_manager.focused_window_id);
        if (focused) tree_focus(focused);
    }
}

static inline void tree_view_reset_empty_root(struct view *view, struct con *root)
{
    if (root->child_count) return;

    root->layout = tree_default_layout(view);
    root->last_split = root->layout;
}

//
// NOTE: A new window opens where tree_open_con puts it: next to the focused window, or next to
// the selected container (focus parent). An insertion point set with 'window --insert' or by a
// mouse drop places it on that side of its window instead, and the insertion point passed in is
// used for windows that are restored or moved here, so they open next to that window.
//

void tree_add_window(struct view *view, struct window *window, uint32_t insertion_point)
{
    struct con *root = tree_view_root(view);
    if (tree_find_window(root, window->id)) return;

    struct con *con = con_create(CON_SPLITH);
    con->window_id = window->id;

    tree_view_reset_empty_root(view, root);

    struct con *target = view->insertion_point ? tree_find_window(root, view->insertion_point) : NULL;
    if (target && target->insert_dir) {
        int direction = target->insert_dir;
        target->insert_dir = 0;
        tree_feedback_destroy(target);
        view->insertion_point = 0;

        tree_insert_relative(target, con, direction);
        tree_focus_new_window(root, con, window->id);
        return;
    }

    target = insertion_point ? tree_find_window(root, insertion_point) : NULL;

    if (!target) {
        struct con *selected = tree_find_selected(root);
        if (selected && !con_is_leaf(selected)) target = selected;
    }

    if (!target) target = tree_find_window(root, g_window_manager.focused_window_id);
    if (!target) target = tree_descend_focused(root);

    tree_open_con(root, con, target, g_space_manager.tree_autotiling);
    tree_focus_new_window(root, con, window->id);
}

//
// NOTE: A container that moves here from another display, with its windows already moved to the
// space of this view. It keeps its structure and arrives on the side it comes from.
//

void tree_view_attach_from_direction(struct view *view, struct con *con, int direction)
{
    struct con *root = tree_view_root(view);
    tree_view_reset_empty_root(view, root);
    tree_attach_from_direction(root, con, direction);
}

bool tree_remove_window(struct view *view, struct window *window)
{
    struct con *con = tree_find_window(view->tree, window->id);
    if (!con) return false;

    if (view->insertion_point == window->id) view->insertion_point = 0;

    tree_detach(con);
    con_free(con);
    tree_flatten(view->tree);

    return true;
}

static void tree_append_window_list(struct con *con, uint32_t **window_list, int *window_count, int *capacity)
{
    if (con_is_leaf(con)) {
        if (*window_count >= *capacity) {
            ts_expand(*window_list, sizeof(uint32_t) * (*capacity), sizeof(uint32_t) * (*capacity));
            *capacity *= 2;
        }

        (*window_list)[(*window_count)++] = con->window_id;
        return;
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_append_window_list(con->children[i], window_list, window_count, capacity);
    }
}

uint32_t *tree_view_window_list(struct view *view, int *window_count)
{
    *window_count = 0;

    int capacity = 13;
    uint32_t *window_list = ts_alloc_list(uint32_t, capacity);
    if (view->tree) tree_append_window_list(view->tree, &window_list, window_count, &capacity);

    return window_list;
}

//
// NOTE: Counts the areas auto_padding cares about. A tabbed container shows one tab at a time,
// so it is a single area no matter how many tabs it holds.
//

static int tree_tiled_count(struct con *con)
{
    if (con_is_leaf(con)) return con->zoom == CON_ZOOM_FULLSCREEN ? 0 : 1;

    int count = 0;
    for (int i = 0; i < con->child_count; ++i) {
        count += tree_tiled_count(con->children[i]);
    }

    return con->layout == CON_TABBED && count > 1 ? 1 : count;
}

int tree_view_tiled_count(struct view *view)
{
    return view->tree ? tree_tiled_count(view->tree) : 0;
}

struct area tree_con_frame(struct view *view, struct con *con)
{
    if (con->zoom == CON_ZOOM_FULLSCREEN) return view->tree->area;
    if (con->zoom == CON_ZOOM_PARENT && con->parent) return con->parent->area;
    return con->area;
}

bool tree_window_needs_flush(struct view *view, uint32_t window_id, CGRect frame)
{
    struct con *con = tree_view_find_window(view, window_id);
    if (!con) return false;

    struct area area = tree_con_frame(view, con);
    return AX_DIFF(area.x, frame.origin.x) ||
           AX_DIFF(area.y, frame.origin.y) ||
           AX_DIFF(area.w, frame.size.width) ||
           AX_DIFF(area.h, frame.size.height);
}

static void tree_capture_windows(struct view *view, struct con *con, struct window_capture **window_list)
{
    if (con_is_leaf(con)) {
        struct window *window = window_manager_find_window(&g_window_manager, con->window_id);
        if (window) {
            struct area area = tree_con_frame(view, con);
            ts_buf_push(*window_list, ((struct window_capture) { .window = window, .x = area.x, .y = area.y, .w = area.w, .h = area.h }));
        }
        return;
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_capture_windows(view, con->children[i], window_list);
    }
}

static bool tree_has_zoom(struct con *con, enum con_zoom zoom)
{
    if (con_is_leaf(con)) return zoom == CON_ZOOM_NONE ? con->zoom != CON_ZOOM_NONE : con->zoom == zoom;

    for (int i = 0; i < con->child_count; ++i) {
        if (tree_has_zoom(con->children[i], zoom)) return true;
    }

    return false;
}

static inline struct con *tree_root_of(struct con *con)
{
    while (con->parent) con = con->parent;
    return con;
}

static bool tree_contains_window(struct con *con, uint32_t window_id)
{
    return window_id && tree_find_window(con, window_id) != NULL;
}

static void tree_render_bar(void *owner)
{
    struct con *con = owner;

    //
    // NOTE: A zoomed window covers the bars of the containers it belongs to, and a fullscreen
    // window covers every bar on the space.
    //

    bool show = tab_bar_is_enabled() &&
                con->layout == CON_TABBED &&
                con->child_count > 0 &&
                con->area.h > 2 * g_window_manager.tab_bar_height &&
                tree_con_is_visible(con) &&
                !tree_has_zoom(con, CON_ZOOM_NONE) &&
                !tree_has_zoom(tree_root_of(con), CON_ZOOM_FULLSCREEN);

    if (!show) {
        tab_bar_hide(&con->render.tab_bar);
        return;
    }

    int entry_count = min(con->child_count, TAB_BAR_MAX_ENTRY_COUNT);
    struct tab_bar_entry entry_list[TAB_BAR_MAX_ENTRY_COUNT];
    bool has_focus = tree_contains_window(con, g_window_manager.focused_window_id);
    struct con *active = con->focus[0];

    for (int i = 0; i < entry_count; ++i) {
        struct con *child = con->children[i];
        struct con *leaf = tree_descend_focused(child);

        entry_list[i].focus_wid = leaf ? leaf->window_id : 0;
        entry_list[i].title = tree_copy_title(child);
        entry_list[i].icon = con_is_leaf(child) ? tab_bar_icon(child->window_id) : NULL;
        entry_list[i].state = child != active ? TAB_BAR_UNFOCUSED : has_focus ? TAB_BAR_FOCUSED : TAB_BAR_INACTIVE;
    }

    con->render.tab_bar.owner = con;
    con->render.tab_bar.redraw = tree_render_bar;

    struct con *above = tree_descend_focused(con);
    int inset = tree_bar_card_inset(con->area, g_window_manager.tab_bar_height, tree_bar_inset());
    CGRect card = {{con->area.x, con->area.y}, {con->area.w, con->area.h}};
    CGRect frame = {{con->area.x + inset, con->area.y + inset}, {con->area.w - 2 * inset, g_window_manager.tab_bar_height}};
    tab_bar_render(&con->render.tab_bar, frame, card, above ? above->window_id : 0, entry_list, entry_count);

    for (int i = 0; i < entry_count; ++i) {
        if (entry_list[i].title) CFRelease(entry_list[i].title);
    }
}

void tree_render_bars(struct con *con)
{
    if (con_is_leaf(con)) return;

    if (con->layout == CON_TABBED) {
        tree_render_bar(con);
    } else {
        tab_bar_release(&con->render.tab_bar);
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_render_bars(con->children[i]);
    }
}

void tree_release_bars(struct con *con)
{
    tab_bar_release(&con->render.tab_bar);

    for (int i = 0; i < con->child_count; ++i) {
        tree_release_bars(con->children[i]);
    }
}

static void tree_collect_window_order(struct con *con, int order, uint32_t relative, struct sa_window_order **list)
{
    if (con_is_leaf(con)) {
        if (con->window_id != relative) ts_buf_push(*list, ((struct sa_window_order) { con->window_id, order, relative }));
        return;
    }

    if (order == 1 && con->layout == CON_TABBED) {
        if (con->child_count) tree_collect_window_order(con->focus[0], order, relative, list);
        return;
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_collect_window_order(con->children[i], order, relative, list);
    }
}

//
// NOTE: Windows of hidden tabs keep the frame of their tabbed container and are hidden by
// stacking order alone. When a tab becomes active, the windows of the other tabs are ordered
// below the backdrop card of the container (below its focused window without a card), and
// the other visible windows of the tab (when it holds a split) are ordered above it. The card
// itself sits right below the focused window, so this is redone when either of them changes.
// The focused window is also ordered right above the card: the card does not reliably follow
// its own ordering, and a new window was ordered below the card as a hidden tab before it got
// focus, which the application then does not raise again. The orderings of the whole tree are
// collected first and sent to the scripting addition in one message.
//

static void tree_collect_tab_order(struct con *con, bool force, struct sa_window_order **list)
{
    if (con_is_leaf(con)) return;

    if (con->layout == CON_TABBED && con->child_count && tree_con_is_visible(con)) {
        struct con *active = con->focus[0];

        struct con *anchor = tree_descend_focused(active);
        uint32_t anchor_wid = anchor ? anchor->window_id : 0;
        uint32_t card_wid = tab_bar_card_id(&con->render.tab_bar);

        if (force || con->render.raised != active || con->render.raised_anchor != anchor_wid || con->render.raised_card != card_wid) {
            con->render.raised = active;
            con->render.raised_anchor = anchor_wid;
            con->render.raised_card = card_wid;

            if (anchor && card_wid) {
                ts_buf_push(*list, ((struct sa_window_order) { anchor_wid, 1, card_wid }));
            }

            if (anchor && con->child_count > 1) {
                for (int i = 0; i < con->child_count; ++i) {
                    if (con->children[i] != active) tree_collect_window_order(con->children[i], -1, card_wid ? card_wid : anchor_wid, list);
                }
            }

            if (anchor && !con_is_leaf(active)) {
                tree_collect_window_order(active, 1, anchor->window_id, list);
            }
        }
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_collect_tab_order(con->children[i], force, list);
    }
}

void tree_raise_tabs(struct con *con, bool force)
{
    struct sa_window_order *list = NULL;
    tree_collect_tab_order(con, force, &list);

    if (list) scripting_addition_order_window_list(list, ts_buf_len(list));
}

void tree_flush(struct view *view)
{
    if (!view->tree) return;

    struct window_capture *window_list = NULL;
    tree_capture_windows(view, view->tree, &window_list);
    if (window_list) window_manager_animate_window_list(window_list, ts_buf_len(window_list));

    tree_render_bars(view->tree);
    tree_raise_tabs(view->tree, false);

    struct con *selected = tree_find_selected(view->tree);
    if (selected) tree_selection_show(selected);

    struct con *insert = view->insertion_point ? tree_find_window(view->tree, view->insertion_point) : NULL;
    if (insert && insert->insert_dir) tree_feedback_show(insert, insert->insert_dir);
}

void tree_window_did_receive_focus(struct view *view, uint32_t window_id)
{
    struct con *con = tree_view_find_window(view, window_id);
    if (!con) return;

    tree_select(view->tree, NULL);
    tree_focus(con);

    if (!space_is_visible(view->sid)) {
        view_set_flag(view, VIEW_IS_DIRTY);
        return;
    }

    tree_raise_tabs(view->tree, false);
    tree_render_bars(view->tree);
}

void tree_refresh_for_window(uint32_t window_id)
{
    if (!window_id) return;

    struct view *view = table_find(&g_window_manager.managed_window, &window_id);
    if (!view || view->layout != VIEW_TREE || !view->tree) return;

    if (space_is_visible(view->sid)) tree_render_bars(view->tree);
}

//
// NOTE: Outline of a container, drawn with the insert feedback color. Without a direction
// it outlines the whole container, which marks the container selected with 'window --focus parent'.
// With a direction it shows the half where a window will be inserted, as set by 'window --insert'
// or while dragging a window with the mouse.
//

#define INSERT_FEEDBACK_WIDTH 2
#define INSERT_FEEDBACK_RADIUS 9
void tree_feedback_show(struct con *con, int insert_dir)
{
    struct con *leaf = tree_descend_focused(con);
    if (!leaf || !con_is_leaf(leaf)) return;

    CFTypeRef frame_region;
    CGRect frame = {{con->area.x, con->area.y},{con->area.w, con->area.h}};
    CGSNewRegionWithRect(&frame, &frame_region);
    frame.origin.x = 0; frame.origin.y = 0;

    if (!con->render.feedback_window.id) {
        uint64_t tags = (1ULL << 1) | (1ULL << 9);
        CFTypeRef empty_region = CGRegionCreateEmptyRegion();
        SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region, 13, &tags, 0, 0, 64, &con->render.feedback_window.id, NULL);
        CFRelease(empty_region);

        sls_window_disable_shadow(con->render.feedback_window.id);
        SLSSetWindowResolution(g_connection, con->render.feedback_window.id, 1.0f);
        SLSSetWindowOpacity(g_connection, con->render.feedback_window.id, 0);
        con->render.feedback_window.context = SLWindowContextCreate(g_connection, con->render.feedback_window.id, 0);
        CGContextSetLineWidth(con->render.feedback_window.context, INSERT_FEEDBACK_WIDTH);
    }

    struct rgba_color color = g_window_manager.insert_feedback_color;
    CGContextSetRGBFillColor(con->render.feedback_window.context, color.r, color.g, color.b, color.a * (insert_dir ? 0.25f : 0.15f));
    CGContextSetRGBStrokeColor(con->render.feedback_window.context, color.r, color.g, color.b, color.a);

    CGFloat clip_x = -0.5f * INSERT_FEEDBACK_WIDTH;
    CGFloat clip_y = -0.5f * INSERT_FEEDBACK_WIDTH;
    CGFloat clip_w = INSERT_FEEDBACK_WIDTH;
    CGFloat clip_h = INSERT_FEEDBACK_WIDTH;
    CGFloat midx = CGRectGetMidX(frame);
    CGFloat midy = CGRectGetMidY(frame);

    switch (insert_dir) {
    case DIR_NORTH: { clip_y = midy - 0.5f * INSERT_FEEDBACK_WIDTH; } break;
    case DIR_EAST:  { clip_x = midx - 0.5f * INSERT_FEEDBACK_WIDTH; } break;
    case DIR_SOUTH: { clip_h = -midy + INSERT_FEEDBACK_WIDTH; } break;
    case DIR_WEST:  { clip_w = -midx + INSERT_FEEDBACK_WIDTH; } break;
    }

    CGRect rect = (CGRect) {{ 0.5f*INSERT_FEEDBACK_WIDTH, 0.5f*INSERT_FEEDBACK_WIDTH }, { frame.size.width - INSERT_FEEDBACK_WIDTH, frame.size.height - INSERT_FEEDBACK_WIDTH }};
    CGRect fill = CGRectInset(rect, 0.5f*INSERT_FEEDBACK_WIDTH, 0.5f*INSERT_FEEDBACK_WIDTH);
    CGRect clip = { { rect.origin.x + clip_x, rect.origin.y + clip_y }, { rect.size.width + clip_w, rect.size.height + clip_h } };
    CGPathRef path = CGPathCreateWithRoundedRect(rect, cgrect_clamp_x_radius(rect, INSERT_FEEDBACK_RADIUS), cgrect_clamp_y_radius(rect, INSERT_FEEDBACK_RADIUS), NULL);

    SLSDisableUpdate(g_connection);
    SLSSetWindowShape(g_connection, con->render.feedback_window.id, 0.0f, 0.0f, frame_region);
    CGContextClearRect(con->render.feedback_window.context, frame);
    CGContextClipToRect(con->render.feedback_window.context, clip);
    CGContextFillRect(con->render.feedback_window.context, fill);
    CGContextAddPath(con->render.feedback_window.context, path);
    CGContextStrokePath(con->render.feedback_window.context);
    CGContextResetClip(con->render.feedback_window.context);
    CGContextFlush(con->render.feedback_window.context);
    SLSReenableUpdate(g_connection);
    CGPathRelease(path);
    CFRelease(frame_region);

    SLSSetWindowLevel(g_connection, con->render.feedback_window.id, window_level(leaf->window_id));
    SLSSetWindowSubLevel(g_connection, con->render.feedback_window.id, window_sub_level(leaf->window_id));
    SLSOrderWindow(g_connection, con->render.feedback_window.id, 1, leaf->window_id);
}

void tree_feedback_hide(struct con *con)
{
    tree_feedback_destroy(con);
}

void tree_selection_show(struct con *con)
{
    tree_feedback_show(con, 0);
}

static void tree_serialize_con(FILE *rsp, struct view *view, struct con *con, int depth)
{
    struct area frame = con_is_leaf(con) ? tree_con_frame(view, con) : con->area;
    bool visible = tree_con_is_visible(con);

    fprintf(rsp, "%*s{\"type\":\"%s\",\"layout\":%s%s%s,\"percent\":%.4f,\"window\":%d,\"frame\":{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f},\"focused\":%s,\"selected\":%s,\"visible\":%s,\"nodes\":[",
            depth, "",
            !con->parent ? "workspace" : con_is_leaf(con) ? "window" : "container",
            con_is_leaf(con) ? "" : "\"", con_is_leaf(con) ? "null" : con_layout_str[con->layout], con_is_leaf(con) ? "" : "\"",
            con->parent ? con->percent : 1.0f,
            con->window_id,
            frame.x, frame.y, frame.w, frame.h,
            json_bool(con_is_leaf(con) && con->window_id == g_window_manager.focused_window_id),
            json_bool(con->selected),
            json_bool(visible));

    for (int i = 0; i < con->child_count; ++i) {
        fprintf(rsp, "%s\n", i ? "," : "");
        tree_serialize_con(rsp, view, con->children[i], depth + 1);
    }

    fprintf(rsp, "%s]}", con->child_count ? "\n" : "");
}

//
// NOTE: The container tree of a space, similar to i3's get_tree. Containers list their children
// in tab or split order. Spaces without the tree layout have no tree.
//

bool tree_serialize(FILE *rsp, struct view *view)
{
    if (view->layout != VIEW_TREE) return false;

    struct con *root = tree_view_root(view);
    tree_serialize_con(rsp, view, root, 0);
    fprintf(rsp, "\n");
    return true;
}
