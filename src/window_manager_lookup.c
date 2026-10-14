//
// NOTE: Finding windows for the window selectors: by stacking rank on a space, at a point, in a direction,
// in the order of the tree, among the tabs of a tabbed container, and by area.
//

extern int g_connection;

struct window *window_manager_find_window_on_space_by_rank_filtering_window(struct window_manager *wm, uint64_t sid, int rank, uint32_t filter_wid)
{
    int count;
    uint32_t *window_list = space_window_list(sid, &count, false);
    if (!window_list) return NULL;

    struct window *result = NULL;
    for (int i = 0, j = 0; i < count; ++i) {
        if (window_list[i] == filter_wid) continue;

        struct window *window = window_manager_find_window(wm, window_list[i]);
        if (!window) continue;

        if (++j == rank) {
            result = window;
            break;
        }
    }

    return result;
}

//
// NOTE: The window at point, starting below start_wid (order -1) or from the top (start_wid 0, order 1).
// Windows of our own connection (borders, tab bars) are skipped.
//

static struct window *window_manager_find_window_at_point_from(struct window_manager *wm, CGPoint point, uint32_t start_wid, int order)
{
    CGPoint window_point;
    uint32_t window_id;
    int window_cid;

    SLSFindWindowAndOwner(g_connection, start_wid, order, 0, &point, &window_point, &window_id, &window_cid);
    while (window_id && g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);

    return window_manager_find_window(wm, window_id);
}

struct window *window_manager_find_window_at_point_filtering_window(struct window_manager *wm, CGPoint point, uint32_t filter_wid)
{
    return window_manager_find_window_at_point_from(wm, point, filter_wid, -1);
}

struct window *window_manager_find_window_at_point(struct window_manager *wm, CGPoint point)
{
    return window_manager_find_window_at_point_from(wm, point, 0, 1);
}

struct window *window_manager_find_window_below_cursor(struct window_manager *wm)
{
    CGPoint cursor;
    SLSGetCurrentCursorLocation(g_connection, &cursor);
    return window_manager_find_window_at_point(wm, cursor);
}

struct window *window_manager_find_closest_managed_window_in_direction(struct window_manager *wm, struct window *window, int direction)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return NULL;

    struct con *con = tree_find_window(view->tree, window->id);
    if (!con) return NULL;

    struct con *result = NULL;
    if (tree_next(con, direction, FOCUS_WRAPPING_OFF, false, &result) != TREE_RESULT_DONE) return NULL;
    if (!result || !con_is_leaf(result) || result == con) return NULL;

    return window_manager_find_window(wm, result->window_id);
}

static struct view *window_manager_active_tree_view(struct space_manager *sm)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    return view && view->tree ? view : NULL;
}

static struct window *window_manager_find_window_for_con(struct window_manager *wm, struct con *con)
{
    return con && con_is_leaf(con) ? window_manager_find_window(wm, con->window_id) : NULL;
}

struct window *window_manager_find_prev_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_active_tree_view(sm);
    struct con *con = view ? tree_find_window(view->tree, window->id) : NULL;
    return con ? window_manager_find_window_for_con(wm, tree_prev_leaf(con)) : NULL;
}

struct window *window_manager_find_next_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_active_tree_view(sm);
    struct con *con = view ? tree_find_window(view->tree, window->id) : NULL;
    return con ? window_manager_find_window_for_con(wm, tree_next_leaf(con)) : NULL;
}

struct window *window_manager_find_first_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    struct view *view = window_manager_active_tree_view(sm);
    return view ? window_manager_find_window_for_con(wm, tree_first_leaf(view->tree)) : NULL;
}

struct window *window_manager_find_last_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    struct view *view = window_manager_active_tree_view(sm);
    return view ? window_manager_find_window_for_con(wm, tree_last_leaf(view->tree)) : NULL;
}

struct window *window_manager_find_recent_managed_window(struct window_manager *wm)
{
    struct window *window = window_manager_find_window(wm, wm->last_window_id);
    if (!window) return NULL;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    return window;
}

//
// NOTE: The stack.* selectors pick tabs of the closest tabbed container. A tab that holds a
// container resolves to the window focused in it last.
//

static struct con *window_manager_find_tab(struct space_manager *sm, struct window *window, struct con **tabbed)
{
    struct view *view = window_manager_active_tree_view(sm);
    struct con *con = view ? tree_find_window(view->tree, window->id) : NULL;
    if (!con) return NULL;

    struct con *parent = tree_tabbed_ancestor(con);
    if (!parent) return NULL;

    while (con->parent != parent) con = con->parent;
    *tabbed = parent;
    return con;
}

static struct window *window_manager_find_tab_window(struct space_manager *sm, struct window_manager *wm, struct window *window, int index, bool relative)
{
    struct con *tabbed = NULL;
    struct con *tab = window_manager_find_tab(sm, window, &tabbed);
    if (!tab) return NULL;

    int target = relative ? con_index(tab) + index : index == INT_MAX ? tabbed->child_count - 1 : index;
    if (target < 0 || target >= tabbed->child_count) return NULL;

    return window_manager_find_window_for_con(wm, tree_descend_focused(tabbed->children[target]));
}

struct window *window_manager_find_prev_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    return window_manager_find_tab_window(sm, wm, window, -1, true);
}

struct window *window_manager_find_next_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    return window_manager_find_tab_window(sm, wm, window, 1, true);
}

struct window *window_manager_find_first_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    return window_manager_find_tab_window(sm, wm, window, 0, false);
}

struct window *window_manager_find_last_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    return window_manager_find_tab_window(sm, wm, window, INT_MAX, false);
}

struct window *window_manager_find_recent_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct con *tabbed = NULL;
    struct con *tab = window_manager_find_tab(sm, window, &tabbed);
    if (!tab || tabbed->child_count < 2) return NULL;

    struct con *recent = tabbed->focus[0] == tab ? tabbed->focus[1] : tabbed->focus[0];
    return window_manager_find_window_for_con(wm, tree_descend_focused(recent));
}

struct window *window_manager_find_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window, int index)
{
    return window_manager_find_tab_window(sm, wm, window, index - 1, false);
}

static struct window *window_manager_find_managed_window_by_area(struct space_manager *sm, struct window_manager *wm, bool largest)
{
    struct view *view = window_manager_active_tree_view(sm);
    if (!view) return NULL;

    uint32_t best_id   = 0;
    float best_area = largest ? 0 : FLT_MAX;

    for (struct con *con = tree_first_leaf(view->tree); con && con_is_leaf(con); con = tree_next_leaf(con)) {
        if (!tree_con_is_visible(con)) continue;

        float area = con->area.w * con->area.h;
        if (largest ? area > best_area : area <= best_area) {
            best_id   = con->window_id;
            best_area = area;
        }
    }

    return best_id ? window_manager_find_window(wm, best_id) : NULL;
}

struct window *window_manager_find_largest_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    return window_manager_find_managed_window_by_area(sm, wm, true);
}

struct window *window_manager_find_smallest_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    return window_manager_find_managed_window_by_area(sm, wm, false);
}
