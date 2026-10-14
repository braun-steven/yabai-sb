//
// NOTE: i3 navigation in the container tree of a space: focus and move in a direction, into the parent
// or child container, and across displays when a direction leaves the tree.
//

extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

static uint32_t window_manager_tree_display_in_direction(struct view *view, int direction)
{
    uint32_t did = display_manager_find_closest_display_in_direction(space_display_id(view->sid), direction);
    if (!did || space_is_fullscreen(display_space_id(did))) return 0;
    return did;
}

//
// NOTE: Focuses the display in the direction like i3 focuses an output: on a tree space the window
// that was focused there last, otherwise whatever macOS focuses on that display.
//

static void window_manager_tree_focus_display(struct window_manager *wm, uint32_t did)
{
    uint64_t sid = display_space_id(did);
    struct view *view = space_manager_find_view(&g_space_manager, sid);
    struct con *leaf = view && view->layout == VIEW_TREE && view->tree ? tree_descend_focused(view->tree) : NULL;

    if (leaf && con_is_leaf(leaf)) {
        window_manager_focus_window_id(wm, leaf->window_id);
    } else {
        display_manager_focus_display(did, sid);
    }
}

enum window_op_error window_manager_tree_focus_direction(struct window_manager *wm, struct window *window, int direction)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *con = window_manager_tree_acting_con(view, window);
    if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    uint32_t did = window_manager_tree_display_in_direction(view, direction);
    struct con *result = NULL;

    switch (tree_next(con, direction, wm->focus_wrapping, did != 0, &result)) {
    case TREE_RESULT_DONE: {
        if (!result || !con_is_leaf(result)) return WINDOW_OP_ERROR_INVALID_DST_NODE;
        if (result->window_id == window->id && con_is_leaf(con)) return WINDOW_OP_ERROR_INVALID_DST_NODE;
        tree_select(view->tree, NULL);
        window_manager_focus_window_id(wm, result->window_id);
    } break;
    case TREE_RESULT_OUTPUT: {
        tree_select(view->tree, NULL);
        window_manager_tree_focus_display(wm, did);
    } break;
    case TREE_RESULT_NONE: {
        return WINDOW_OP_ERROR_INVALID_DST_NODE;
    } break;
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_tree_focus_parent(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *con = window_manager_tree_acting_con(view, window);
    if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;
    if (!con->parent) return WINDOW_OP_ERROR_INVALID_DST_NODE;

    tree_select(view->tree, con->parent);
    if (space_is_visible(view->sid)) tree_selection_show(con->parent);

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_tree_focus_child(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *selected = tree_find_selected(view->tree);
    if (!selected || !selected->child_count) return WINDOW_OP_ERROR_INVALID_DST_NODE;

    struct con *child = selected->focus[0];
    if (con_is_leaf(child)) {
        tree_select(view->tree, NULL);
        window_manager_focus_window_id(wm, child->window_id);
    } else {
        tree_select(view->tree, child);
        if (space_is_visible(view->sid)) tree_selection_show(child);
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

//
// NOTE: Moves the container to the space on the display in the direction, like i3 and sway move a
// container to the next output. On a tree space it keeps its structure and arrives on the side it
// comes from (tree_attach_from_direction). On other spaces every window is sent there on its own.
//

static void window_manager_tree_move_to_display(struct space_manager *sm, struct window_manager *wm, struct view *view, struct con *con, uint32_t did, int direction)
{
    tree_select(view->tree, NULL);

    uint64_t sid = display_space_id(did);
    struct view *dst_view = space_manager_find_view(sm, sid);

    if (dst_view->layout == VIEW_TREE) {
        struct con *focus = tree_descend_focused(con);

        tree_detach(con);
        tree_flatten(view->tree);

        if (view_is_invalid(dst_view)) view_update(dst_view);
        tree_view_attach_from_direction(dst_view, con, direction);
        uint32_t *moved = window_manager_tree_set_view(wm, con, dst_view);
        window_manager_tree_wait_for_view(moved, dst_view);
        tree_flatten(dst_view->tree);

        if (focus) tree_focus(focus);
        window_manager_tree_apply(view);
        window_manager_tree_apply(dst_view);

        if (focus && con_is_leaf(focus)) window_manager_focus_window_id(wm, focus->window_id);
        return;
    }

    int window_count = 0;
    uint32_t window_list[256];

    for (struct con *leaf = tree_first_leaf(con); leaf && window_count < (int) array_count(window_list); leaf = tree_next_leaf(leaf)) {
        window_list[window_count++] = leaf->window_id;
        if (leaf == tree_last_leaf(con)) break;
    }

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_manager_find_window(wm, window_list[i]);
        if (window) window_manager_send_window_to_space(sm, wm, window, sid, false);
    }

    struct window *focus = window_count ? window_manager_find_window(wm, window_list[0]) : NULL;
    if (focus) window_manager_focus_window_with_raise(&focus->application->psn, focus->id, focus->ref);
}

enum window_op_error window_manager_tree_move_direction(struct space_manager *sm, struct window_manager *wm, struct window *window, int direction)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *con = window_manager_tree_acting_con(view, window);
    if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    uint32_t did = window_manager_tree_display_in_direction(view, direction);

    switch (tree_move(view->tree, con, direction, did != 0)) {
    case TREE_RESULT_DONE: {
        window_manager_tree_apply(view);
    } break;
    case TREE_RESULT_OUTPUT: {
        window_manager_tree_move_to_display(sm, wm, view, con, did, direction);
    } break;
    case TREE_RESULT_NONE: {
        return WINDOW_OP_ERROR_INVALID_DST_NODE;
    } break;
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

//
// NOTE: When the focused window of a tree space closes, i3 focuses the window that was focused
// before it in the same container. Computed before the window is taken out of the tree.
//

uint32_t window_manager_tree_focus_candidate(struct window_manager *wm, struct view *view, struct window *window)
{
    if (!view || view->layout != VIEW_TREE) return 0;

    //
    // NOTE: macOS often focuses another window of the application before the window is reported as
    // destroyed. The window then is the previously focused one, and the choice of macOS is replaced.
    // That window can be on another space or display, so a window of the same application counts too.
    //

    bool was_focused = window->id == wm->focused_window_id;
    if (!was_focused && window->id == wm->last_window_id) {
        struct window *focused = window_manager_find_window(wm, wm->focused_window_id);
        was_focused = focused && (focused->application == window->application || window_manager_find_tree_view(wm, focused) == view);
    }

    if (!was_focused) return 0;

    struct con *con = tree_find_window(view->tree, window->id);
    struct con *candidate = con ? tree_focus_candidate(con) : NULL;
    return candidate && con_is_leaf(candidate) ? candidate->window_id : 0;
}

void window_manager_tree_focus_after_close(struct window_manager *wm, struct view *view, uint32_t window_id)
{
    if (!window_id || !space_is_visible(view->sid)) return;
    window_manager_focus_window_id(wm, window_id);
}

enum window_op_error window_manager_tree_split(struct window_manager *wm, struct window *window, int orientation)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *con = window_manager_tree_acting_con(view, window);
    if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    if (orientation < 0) {
        struct con *parent = con->parent ? con->parent : con;
        orientation = parent->layout == CON_SPLITH ? CON_VERTICAL : CON_HORIZONTAL;
    }

    tree_split(con, orientation);
    window_manager_tree_apply(view);

    return WINDOW_OP_ERROR_SUCCESS;
}
