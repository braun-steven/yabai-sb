extern struct process_manager g_process_manager;
extern struct mouse_state g_mouse_state;

static TABLE_HASH_FUNC(hash_wm)
{
    return *(uint32_t *) key;
}

static TABLE_COMPARE_FUNC(compare_wm)
{
    return *(uint32_t *) key_a == *(uint32_t *) key_b;
}

bool window_manager_is_window_eligible(struct window *window)
{
    bool result = window->is_root && (window_is_real(window) || window_check_rule_flag(window, WINDOW_RULE_MANAGED));
    return result;
}

void window_manager_set_focus_follows_mouse(struct window_manager *wm, enum ffm_mode mode)
{
    mouse_handler_end(&g_mouse_state);

    if (mode == FFM_DISABLED) {
        mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK);
    } else {
        mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK_FFM);
    }

    wm->ffm_mode = mode;
}

void window_manager_set_window_opacity_enabled(struct window_manager *wm, bool enabled)
{
    wm->enable_window_opacity = enabled;
    table_for (struct window *window, wm->window, {
        if (window_manager_is_window_eligible(window)) {
            window_manager_set_opacity(wm, window, enabled ? window->opacity : 1.0f);
        }
    })
}

void window_manager_center_mouse(struct window_manager *wm, struct window *window)
{
    if (window_check_rule_flag(window, WINDOW_RULE_MFF)) {
        if (!window_check_rule_flag(window, WINDOW_RULE_MFF_VALUE)) {
            return;
        }
    } else {
        if (!wm->enable_mff) {
            return;
        }
    }

    CGPoint cursor;
    SLSGetCurrentCursorLocation(g_connection, &cursor);
    if (CGRectContainsPoint(window->frame, cursor)) return;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    CGPoint center = {
        window->frame.origin.x + window->frame.size.width / 2,
        window->frame.origin.y + window->frame.size.height / 2
    };

    CGRect bounds = CGDisplayBounds(did);
    if (!CGRectContainsPoint(bounds, center)) return;

    CGWarpMouseCursorPosition(center);
}

bool window_manager_should_manage_window(struct window *window)
{
    if (!window->is_root)                           return false;
    if (window_check_flag(window, WINDOW_FLOAT))    return false;
    if (window_is_sticky(window->id))               return false;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return false;
    if (window->application->is_hidden)             return false;

    return (window_is_standard(window) && window_level_is_standard(window) && window_can_move(window)) || window_check_rule_flag(window, WINDOW_RULE_MANAGED);
}

struct view *window_manager_find_managed_window(struct window_manager *wm, struct window *window)
{
    return table_find(&wm->managed_window, &window->id);
}

void window_manager_remove_managed_window(struct window_manager *wm, uint32_t wid)
{
    table_remove(&wm->managed_window, &wid);
}

void window_manager_add_managed_window(struct window_manager *wm, struct window *window, struct view *view)
{
    if (view->layout == VIEW_FLOAT) return;
    table_add(&wm->managed_window, &window->id, view);
    window_manager_purify_window(wm, window);
}

//
// NOTE: Operations on spaces with the 'tree' layout. They act on the container selected with
// 'window --focus parent' when there is one, and on the window otherwise.
//

//
// NOTE: Takes a window out of the tree of its view and gives it the shadow and layer of an unmanaged window.
//

void window_manager_unmanage_window(struct window_manager *wm, struct view *view, struct window *window)
{
    space_manager_untile_window(view, window);
    window_manager_remove_managed_window(wm, window->id);
    window_manager_purify_window(wm, window);
}

void window_manager_manage_window(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t sid, uint32_t insertion_point)
{
    struct view *view = space_manager_tile_window_on_space_with_insertion_point(sm, window, sid, insertion_point);
    window_manager_add_managed_window(wm, window, view);
}

struct view *window_manager_find_tree_view(struct window_manager *wm, struct window *window)
{
    struct view *view = window ? window_manager_find_managed_window(wm, window) : NULL;
    return view && view->tree ? view : NULL;
}

static struct con *window_manager_tree_acting_con(struct view *view, struct window *window)
{
    struct con *selected = tree_find_selected(view->tree);
    if (selected && window->id == g_window_manager.focused_window_id) return selected;
    return tree_find_window(view->tree, window->id);
}

static void window_manager_tree_apply(struct view *view)
{
    //
    // NOTE: Operations on other windows must not hide the focused window in a tab that is not active.
    //

    struct con *focused = tree_find_window(view->tree, g_window_manager.focused_window_id);
    if (focused) tree_focus(focused);

    if (!view_update_auto_padding(view)) tree_view_update(view);
    view_flush(view);
}

static void window_manager_focus_window_id(struct window_manager *wm, uint32_t window_id)
{
    struct window *window = window_manager_find_window(wm, window_id);
    if (window) {
        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
        window_manager_set_pending_focus(wm, window->id);
    }
}

static void tree_collect_window_ids(struct con *con, uint32_t **list)
{
    if (con_is_leaf(con)) {
        if (con->window_id) ts_buf_push(*list, con->window_id);
        return;
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_collect_window_ids(con->children[i], list);
    }
}

//
// NOTE: The windows of the container that are on another space are moved with one operation, which
// is asynchronous. The returned list of moved windows is passed to window_manager_tree_wait_for_view
// before the layout of the view is applied, so that the frames are not set before the windows arrive.
//

static uint32_t *window_manager_tree_set_view(struct window_manager *wm, struct con *con, struct view *view)
{
    uint32_t *window_list = NULL;
    tree_collect_window_ids(con, &window_list);

    uint32_t *move_list = NULL;
    for (int i = 0; i < ts_buf_len(window_list); ++i) {
        struct window *window = window_manager_find_window(wm, window_list[i]);
        if (!window) continue;

        if (window_space(window->id) != view->sid) ts_buf_push(move_list, window->id);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_add_managed_window(wm, window, view);
    }

    if (move_list) space_manager_move_window_list_to_space(view->sid, move_list, ts_buf_len(move_list));
    return move_list;
}

static void window_manager_tree_wait_for_view(uint32_t *move_list, struct view *view)
{
    if (move_list) space_manager_wait_for_windows_on_space(move_list, ts_buf_len(move_list), view->sid, 200);
}

//
// NOTE: The ratio of a window on a tree space is its share of its container. The space is taken from
// or given to the next container, or the previous one for the last container.
//

enum window_op_error window_manager_adjust_window_ratio(struct window_manager *wm, struct window *window, int type, float ratio)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    //
    // NOTE: Tabs share the area of their container, so the ratio of a tab is the one of its tabbed
    // container, like i3 skips tabbed containers when it looks for the containers to resize.
    //

    struct con *con = window_manager_tree_acting_con(view, window);
    while (con && con->parent && con->parent->layout == CON_TABBED) con = con->parent;
    if (!con || !con->parent) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct con *parent = con->parent;
    bool horizontal = parent->layout == CON_SPLITH;
    float size = horizontal ? parent->area.w : parent->area.h;
    float percent = type == TYPE_REL ? con->percent + ratio : ratio;
    float delta = (clampf_range(percent, 0.05f, 0.95f) - con->percent) * size;

    if (!tree_resize(con, horizontal ? DIR_EAST : DIR_SOUTH, delta) &&
        !tree_resize(con, horizontal ? DIR_WEST : DIR_NORTH, -delta)) {
        return WINDOW_OP_ERROR_INVALID_SRC_NODE;
    }

    tree_view_update(view);
    view_flush(view);

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_move_window_relative(struct window_manager *wm, struct window *window, int type, float dx, float dy)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    if (type == TYPE_REL) {
        dx += window->frame.origin.x;
        dy += window->frame.origin.y;
    }

    window_manager_animate_window((struct window_capture) { .window = window, .x = dx, .y = dy, .w = window->frame.size.width, .h = window->frame.size.height });
    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_resize_window_relative_internal(struct window *window, CGRect frame, int direction, float dx, float dy, bool animate)
{
    TIME_FUNCTION;

    int x_mod = (direction & HANDLE_LEFT) ? -1 : (direction & HANDLE_RIGHT)  ? 1 : 0;
    int y_mod = (direction & HANDLE_TOP)  ? -1 : (direction & HANDLE_BOTTOM) ? 1 : 0;

    float fw = max(1, frame.size.width  + dx * x_mod);
    float fh = max(1, frame.size.height + dy * y_mod);
    float fx = (direction & HANDLE_LEFT) ? frame.origin.x + frame.size.width  - fw : frame.origin.x;
    float fy = (direction & HANDLE_TOP)  ? frame.origin.y + frame.size.height - fh : frame.origin.y;

    if (animate) {
        window_manager_animate_window((struct window_capture) { .window = window, .x = fx, .y = fy, .w = fw, .h = fh });
    } else {
        AX_ENHANCED_UI_WORKAROUND(window->application->ref, {
            window_manager_move_window(window, fx, fy);
            window_manager_resize_window(window, fw, fh);
        });
    }
}

enum window_op_error window_manager_resize_window_relative(struct window_manager *wm, struct window *window, int direction, float dx, float dy, bool animate)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        if (direction == HANDLE_ABS || !view->tree) return WINDOW_OP_ERROR_INVALID_OPERATION;

        struct con *con = window_manager_tree_acting_con(view, window);
        if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

        bool did_resize = false;
        if (direction & HANDLE_TOP)    did_resize |= tree_resize(con, DIR_NORTH, dy);
        if (direction & HANDLE_BOTTOM) did_resize |= tree_resize(con, DIR_SOUTH, dy);
        if (direction & HANDLE_LEFT)   did_resize |= tree_resize(con, DIR_WEST, dx);
        if (direction & HANDLE_RIGHT)  did_resize |= tree_resize(con, DIR_EAST, dx);
        if (!did_resize) return WINDOW_OP_ERROR_INVALID_DST_NODE;

        tree_view_update(view);
        view_flush(view);
    } else {
        if (direction == HANDLE_ABS) {
            if (animate) {
                window_manager_animate_window((struct window_capture) { .window = window, .x = window->frame.origin.x, .y = window->frame.origin.y, .w = dx, .h = dy });
            } else {
                AX_ENHANCED_UI_WORKAROUND(window->application->ref, { window_manager_resize_window(window, dx, dy); });
            }
        } else {
            window_manager_resize_window_relative_internal(window, window_ax_frame(window), direction, dx, dy, animate);
        }
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_move_window(struct window *window, float x, float y)
{
    window->frame_request.origin = CGPointMake(x, y);

    CGPoint position = CGPointMake(x, y);
    CFTypeRef position_ref = AXValueCreate(kAXValueTypeCGPoint, (void *) &position);
    if (!position_ref) return;

    AXUIElementSetAttributeValue(window->ref, kAXPositionAttribute, position_ref);
    CFRelease(position_ref);
}

void window_manager_resize_window(struct window *window, float width, float height)
{
    window->frame_request.size = CGSizeMake(width, height);

    CGSize size = CGSizeMake(width, height);
    CFTypeRef size_ref = AXValueCreate(kAXValueTypeCGSize, (void *) &size);
    if (!size_ref) return;

    AXUIElementSetAttributeValue(window->ref, kAXSizeAttribute, size_ref);
    CFRelease(size_ref);
}

void window_manager_set_purify_mode(struct window_manager *wm, enum purify_mode mode)
{
    wm->purify_mode = mode;
    table_for (struct window *window, wm->window, {
        if (window_manager_is_window_eligible(window)) {
            window_manager_purify_window(wm, window);
        }
    })
}

bool window_manager_set_opacity(struct window_manager *wm, struct window *window, float opacity)
{
    if (opacity == 0.0f) {
        if (wm->enable_window_opacity) {
            opacity = window->id == wm->focused_window_id ? wm->active_window_opacity : wm->normal_window_opacity;
        } else {
            opacity = 1.0f;
        }
    }

    return scripting_addition_set_opacity(window->id, opacity, wm->window_opacity_duration);
}

void window_manager_set_window_opacity(struct window_manager *wm, struct window *window, float opacity)
{
    if (!wm->enable_window_opacity)                 return;
    if (!window_manager_is_window_eligible(window)) return;
    if (window->opacity != 0.0f)                    return;

    window_manager_set_opacity(wm, window, opacity);
}

void window_manager_set_menubar_opacity(struct window_manager *wm, float opacity)
{
    wm->menubar_opacity = opacity;
    SLSSetMenuBarInsetAndAlpha(g_connection, 0, 1, opacity);
}

void window_manager_set_active_window_opacity(struct window_manager *wm, float opacity)
{
    wm->active_window_opacity = opacity;
    struct window *window = window_manager_focused_window(wm);
    if (window) window_manager_set_window_opacity(wm, window, wm->active_window_opacity);
}

void window_manager_set_normal_window_opacity(struct window_manager *wm, float opacity)
{
    wm->normal_window_opacity = opacity;
    table_for (struct window *window, wm->window, {
        if (window->id == wm->focused_window_id) continue;
        if (window_manager_is_window_eligible(window)) {
            window_manager_set_window_opacity(wm, window, wm->normal_window_opacity);
        }
    })
}

void window_manager_adjust_layer(struct window *window, int layer)
{
    if (window->layer != LAYER_AUTO) return;

    scripting_addition_set_layer(window->id, layer);
}

//
// NOTE: The descendants of root in a list of (parent, child) relations, breadth first, into result (at
// least relation_count entries). Every relation is used once, which consumes parent_list, so a cycle
// cannot repeat windows.
//

static int window_manager_collect_child_windows(uint32_t root, uint32_t *parent_list, uint32_t *child_list, int relation_count, uint32_t *result)
{
    int result_count = 0;

    for (int i = -1; i < result_count; ++i) {
        uint32_t parent = i < 0 ? root : result[i];

        for (int j = 0; j < relation_count; ++j) {
            if (parent_list[j] != parent) continue;

            parent_list[j] = 0;
            result[result_count++] = child_list[j];
        }
    }

    return result_count;
}

//
// NOTE: The child windows (e.g. sheets) follow the layer of their window. With LAYER_AUTO, managed windows (and
// scratchpads with scratchpad_below) go to the below sub-layer and their child windows to the normal one.
//

bool window_manager_set_window_layer(struct window *window, int layer)
{
    int parent_layer = layer;
    int child_layer = layer;

    if (layer == LAYER_AUTO) {
        bool below = window_manager_find_managed_window(&g_window_manager, window) || (g_window_manager.scratchpad_below && window->scratchpad);
        parent_layer = below ? LAYER_BELOW : LAYER_NORMAL;
        child_layer = LAYER_NORMAL;
    }

    window->layer = layer;
    bool result = scripting_addition_set_layer(window->id, parent_layer);
    if (!result) return false;

    CFArrayRef window_list = SLSCopyAssociatedWindows(g_connection, window->id);
    if (!window_list) return result;

    int window_count = CFArrayGetCount(window_list);
    if (window_count > 0) {
        CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list, window_count);
        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);

        int relation_count = 0;
        uint32_t *parent_list = ts_alloc_list(uint32_t, window_count);
        uint32_t *child_list = ts_alloc_list(uint32_t, window_count);

        while (relation_count < window_count && SLSWindowIteratorAdvance(iterator)) {
            parent_list[relation_count] = SLSWindowIteratorGetParentID(iterator);
            child_list[relation_count] = SLSWindowIteratorGetWindowID(iterator);
            ++relation_count;
        }

        uint32_t *descendant_list = ts_alloc_list(uint32_t, window_count);
        int descendant_count = window_manager_collect_child_windows(window->id, parent_list, child_list, relation_count, descendant_list);

        for (int i = 0; i < descendant_count; ++i) {
            scripting_addition_set_layer(descendant_list[i], child_layer);
        }

        CFRelease(query);
        CFRelease(iterator);
    }

    CFRelease(window_list);

    return result;
}

void window_manager_purify_window(struct window_manager *wm, struct window *window)
{
    int value;

    if (wm->purify_mode == PURIFY_DISABLED) {
        value = 1;
    } else if (wm->purify_mode == PURIFY_MANAGED) {
        value = window_manager_find_managed_window(wm, window) ? 0 : 1;
    } else /*if (wm->purify_mode == PURIFY_ALWAYS) */ {
        value = 0;
    }

    if (scripting_addition_set_shadow(window->id, value)) {
        if (value) {
            window_set_flag(window, WINDOW_SHADOW);
        } else {
            window_clear_flag(window, WINDOW_SHADOW);
        }
    }
}

bool window_manager_find_lost_front_switched_event(struct window_manager *wm, pid_t pid)
{
    return table_find(&wm->application_lost_front_switched_event, &pid) != NULL;
}

void window_manager_remove_lost_front_switched_event(struct window_manager *wm, pid_t pid)
{
    table_remove(&wm->application_lost_front_switched_event, &pid);
}

void window_manager_add_lost_front_switched_event(struct window_manager *wm, pid_t pid)
{
    table_add(&wm->application_lost_front_switched_event, &pid, (void *)(intptr_t) 1);
}

bool window_manager_find_lost_focused_event(struct window_manager *wm, uint32_t window_id)
{
    return table_find(&wm->window_lost_focused_event, &window_id) != NULL;
}

void window_manager_remove_lost_focused_event(struct window_manager *wm, uint32_t window_id)
{
    table_remove(&wm->window_lost_focused_event, &window_id);
}

void window_manager_add_lost_focused_event(struct window_manager *wm, uint32_t window_id)
{
    table_add(&wm->window_lost_focused_event, &window_id, (void *)(intptr_t) 1);
}

struct window *window_manager_find_window(struct window_manager *wm, uint32_t window_id)
{
    return table_find(&wm->window, &window_id);
}

void window_manager_remove_window(struct window_manager *wm, uint32_t window_id)
{
    border_remove(window_id);
    table_remove(&wm->window, &window_id);
}

void window_manager_add_window(struct window_manager *wm, struct window *window)
{
    table_add(&wm->window, &window->id, window);
}

struct application *window_manager_find_application(struct window_manager *wm, pid_t pid)
{
    return table_find(&wm->application, &pid);
}

void window_manager_remove_application(struct window_manager *wm, pid_t pid)
{
    table_remove(&wm->application, &pid);
}

void window_manager_add_application(struct window_manager *wm, struct application *application)
{
    table_add(&wm->application, &application->pid, application);
}

struct window **window_manager_find_application_windows(struct window_manager *wm, struct application *application, int *window_count)
{
    *window_count = 0;
    struct window **window_list = ts_alloc_list(struct window *, wm->window.count);

    table_for (struct window *window, wm->window, {
        if (window->application == application) {
            window_list[(*window_count)++] = window;
        }
    })

    return window_list;
}

enum window_op_error window_manager_set_window_insertion(struct space_manager *sm, struct window *window, int direction)
{
    TIME_FUNCTION;

    struct view *view = space_manager_find_view(sm, window_space(window->id));
    if (view->layout != VIEW_TREE || !view->tree) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *con = tree_find_window(view->tree, window->id);
    if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    if (view->insertion_point && view->insertion_point != window->id) {
        struct con *insert = tree_find_window(view->tree, view->insertion_point);
        if (insert) {
            insert->insert_dir = 0;
            tree_feedback_hide(insert);
        }
    }

    if (direction == con->insert_dir) {
        con->insert_dir = 0;
        tree_feedback_hide(con);
        view->insertion_point = 0;
        return WINDOW_OP_ERROR_SUCCESS;
    }

    con->insert_dir = direction;
    view->insertion_point = window->id;
    if (space_is_visible(view->sid)) tree_feedback_show(con, direction);

    return WINDOW_OP_ERROR_SUCCESS;
}

//
// NOTE: Stacking a window onto another puts it into the tabbed container of that window, and turns
// the window into a tabbed container first when it is not a tab yet.
//

enum window_op_error window_manager_stack_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    struct view *a_view = window_manager_find_tree_view(wm, a);
    if (!a_view) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct con *a_con = tree_find_window(a_view->tree, a->id);
    if (!a_con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct view *b_view = window_manager_find_managed_window(wm, b);
    if (b_view) {
        window_manager_unmanage_window(wm, b_view, b);
    } else if (window_check_flag(b, WINDOW_FLOAT)) {
        if (!window_manager_is_window_eligible(b)) return WINDOW_OP_ERROR_INVALID_DST_NODE;
        window_clear_flag(b, WINDOW_FLOAT);
        if (window_check_flag(b, WINDOW_STICKY)) window_manager_make_window_sticky(sm, wm, b, false);
    }

    a_con = tree_find_window(a_view->tree, a->id);
    if (!a_con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    if (window_space(b->id) != a_view->sid) {
        space_manager_move_window_to_space(a_view->sid, b);
        space_manager_wait_for_window_on_space(b->id, a_view->sid, 200);
    }

    struct con *con = con_create(CON_SPLITH);
    con->window_id = b->id;
    tree_insert_relative(a_con, con, STACK);

    window_manager_add_managed_window(wm, b, a_view);
    window_manager_adjust_layer(b, LAYER_BELOW);
    window_manager_tree_apply(a_view);

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_set_window_layout(struct window_manager *wm, struct window *window, enum window_layout layout)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct con *con = window_manager_tree_acting_con(view, window);
    if (!con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct con *parent = con->parent ? con->parent : con;

    switch (layout) {
    case WINDOW_LAYOUT_TABBED:       { tree_set_layout(con, CON_TABBED); } break;
    case WINDOW_LAYOUT_SPLITH:       { tree_set_layout(con, CON_SPLITH); } break;
    case WINDOW_LAYOUT_SPLITV:       { tree_set_layout(con, CON_SPLITV); } break;
    case WINDOW_LAYOUT_SPLIT:        { tree_set_layout(con, parent->layout == CON_TABBED ? parent->last_split : parent->layout); } break;
    case WINDOW_LAYOUT_TOGGLE:       { tree_toggle_layout(con, false); } break;
    case WINDOW_LAYOUT_TOGGLE_SPLIT: { tree_toggle_layout(con, true); } break;
    }

    tree_flatten(view->tree);
    window_manager_tree_apply(view);
    return WINDOW_OP_ERROR_SUCCESS;
}

//
// NOTE: Warping onto a window places the window right after it, in the container of that window.
//

enum window_op_error window_manager_warp_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    struct view *a_view = window_manager_find_tree_view(wm, a);
    struct view *b_view = window_manager_find_tree_view(wm, b);
    if (!a_view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;
    if (!b_view) return WINDOW_OP_ERROR_INVALID_DST_VIEW;

    struct con *a_con = tree_find_window(a_view->tree, a->id);
    struct con *b_con = tree_find_window(b_view->tree, b->id);
    if (!a_con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;
    if (!b_con) return WINDOW_OP_ERROR_INVALID_DST_NODE;

    if (a_view == b_view) {
        tree_insert_con(a_con, b_con, TREE_AFTER);
        tree_flatten(a_view->tree);
        window_manager_tree_apply(a_view);
    } else {
        space_manager_untile_window(a_view, a);
        window_manager_remove_managed_window(wm, a->id);
        window_manager_add_managed_window(wm, a, b_view);
        space_manager_move_window_to_space(b_view->sid, a);
        space_manager_wait_for_window_on_space(a->id, b_view->sid, 200);
        space_manager_tile_window_on_space_with_insertion_point(sm, a, b_view->sid, b->id);
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_swap_window(struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    struct view *a_view = window_manager_find_tree_view(wm, a);
    struct view *b_view = window_manager_find_tree_view(wm, b);
    if (!a_view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;
    if (!b_view) return WINDOW_OP_ERROR_INVALID_DST_VIEW;

    struct con *a_con = tree_find_window(a_view->tree, a->id);
    struct con *b_con = tree_find_window(b_view->tree, b->id);
    if (!a_con) return WINDOW_OP_ERROR_INVALID_SRC_NODE;
    if (!b_con) return WINDOW_OP_ERROR_INVALID_DST_NODE;

    tree_swap(a_con, b_con);

    if (a_view != b_view) {
        uint32_t *a_moved = window_manager_tree_set_view(wm, a_con, b_view);
        uint32_t *b_moved = window_manager_tree_set_view(wm, b_con, a_view);
        window_manager_tree_wait_for_view(a_moved, b_view);
        window_manager_tree_wait_for_view(b_moved, a_view);
        window_manager_tree_apply(b_view);
    }

    window_manager_tree_apply(a_view);
    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_minimize_window(struct window *window)
{
    TIME_FUNCTION;

    if (!window_can_minimize(window)) return WINDOW_OP_ERROR_CANT_MINIMIZE;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return WINDOW_OP_ERROR_ALREADY_MINIMIZED;

    AXError result = AXUIElementSetAttributeValue(window->ref, kAXMinimizedAttribute, kCFBooleanTrue);
    return result == kAXErrorSuccess ? WINDOW_OP_ERROR_SUCCESS : WINDOW_OP_ERROR_MINIMIZE_FAILED;
}

enum window_op_error window_manager_deminimize_window(struct window *window)
{
    TIME_FUNCTION;

    if (!window_check_flag(window, WINDOW_MINIMIZE)) return WINDOW_OP_ERROR_NOT_MINIMIZED;

    AXError result = AXUIElementSetAttributeValue(window->ref, kAXMinimizedAttribute, kCFBooleanFalse);
    return result == kAXErrorSuccess ? WINDOW_OP_ERROR_SUCCESS : WINDOW_OP_ERROR_DEMINIMIZE_FAILED;
}

bool window_manager_close_window(struct window *window)
{
    TIME_FUNCTION;

    CFTypeRef button = NULL;
    AXUIElementCopyAttributeValue(window->ref, kAXCloseButtonAttribute, &button);
    if (!button) return false;

    AXUIElementPerformAction(button, kAXPressAction);
    CFRelease(button);

    return true;
}

void window_manager_send_window_to_space(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t dst_sid, bool moved_by_rule)
{
    TIME_FUNCTION;

    uint64_t src_sid = window_space(window->id);
    if (src_sid == dst_sid) return;

    if ((space_is_visible(src_sid) && (moved_by_rule || wm->focused_window_id == window->id))) {
        struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(wm, src_sid, 1, window->id);
        if (next) {
            window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
        } else {
            _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
        }
    }

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        window_manager_unmanage_window(wm, view, window);
    }

    space_manager_move_window_to_space(dst_sid, window);
    space_manager_wait_for_window_on_space(window->id, dst_sid, 200);
    SLSSpaceSetFrontPSN(g_connection, dst_sid, window->application->psn);

    if (window_manager_should_manage_window(window)) {
        window_manager_manage_window(sm, wm, window, dst_sid, 0);
    }

    border_refresh_space(src_sid);
    border_refresh_window_space(window);
}

enum window_op_error window_manager_apply_grid(struct space_manager *sm, struct window_manager *wm, struct window *window, unsigned r, unsigned c, unsigned x, unsigned y, unsigned w, unsigned h)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    uint32_t did = window_display_id(window->id);
    if (!did) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    if (x >=   c) x = c - 1;
    if (y >=   r) y = r - 1;
    if (w <=   0) w = 1;
    if (h <=   0) h = 1;
    if (w >  c-x) w = c - x;
    if (h >  r-y) h = r - y;

    CGRect bounds = display_bounds_constrained(did, false);
    struct view *dview = space_manager_find_view(sm, display_space_id(did));

    if (dview) {
        if (view_check_flag(dview, VIEW_ENABLE_PADDING)) {
            bounds.origin.x    += dview->left_padding;
            bounds.size.width  -= (dview->left_padding + dview->right_padding);
            bounds.origin.y    += dview->top_padding;
            bounds.size.height -= (dview->top_padding + dview->bottom_padding);
        }

        if (view_check_flag(dview, VIEW_ENABLE_GAP)) {
            int gap = dview->window_gap;

            if (x > 0) {
                bounds.origin.x   += gap;
                bounds.size.width -= gap;
            }

            if (y > 0) {
                bounds.origin.y    += gap;
                bounds.size.height -= gap;
            }

            if (c > x+w) bounds.size.width  -= gap;
            if (r > y+h) bounds.size.height -= gap;
        }
    }

    float cw = bounds.size.width / c;
    float ch = bounds.size.height / r;
    float fx = bounds.origin.x + bounds.size.width  - cw * (c - x);
    float fy = bounds.origin.y + bounds.size.height - ch * (r - y);
    float fw = cw * w;
    float fh = ch * h;

    window_manager_animate_window((struct window_capture) { .window = window, .x = fx, .y = fy, .w = fw, .h = fh });
    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_make_window_floating(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_float, bool force)
{
    TIME_FUNCTION;

    if (!window_manager_is_window_eligible(window)) return;

    if (!force) {
        if (!window_is_standard(window) || !window_level_is_standard(window) || !window_can_move(window)) {
            if (!window_check_rule_flag(window, WINDOW_RULE_MANAGED)) {
                return;
            }
        }
    }

    if (should_float) {
        struct view *view = window_manager_find_managed_window(wm, window);
        if (view) {
            window_manager_unmanage_window(wm, view, window);
        }
        window_set_flag(window, WINDOW_FLOAT);
    } else {
        window_clear_flag(window, WINDOW_FLOAT);

        if (!window_check_flag(window, WINDOW_STICKY)) {
            if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                window_manager_manage_window(sm, wm, window, space_manager_active_space(), 0);
            }
        }
    }
}

void window_manager_make_window_sticky(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_sticky)
{
    TIME_FUNCTION;

    if (!window_manager_is_window_eligible(window)) return;

    if (should_sticky) {
        if (scripting_addition_set_sticky(window->id, true)) {
            struct view *view = window_manager_find_managed_window(wm, window);
            if (view) {
                window_manager_unmanage_window(wm, view, window);
            }
            window_set_flag(window, WINDOW_STICKY);
        }
    } else {
        if (scripting_addition_set_sticky(window->id, false)) {
            window_clear_flag(window, WINDOW_STICKY);

            if (!window_check_flag(window, WINDOW_FLOAT)) {
                if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                    window_manager_manage_window(sm, wm, window, space_manager_active_space(), 0);
                }
            }
        }
    }
}

void window_manager_toggle_window_shadow(struct window *window)
{
    TIME_FUNCTION;

    bool shadow = !window_check_flag(window, WINDOW_SHADOW);
    if (scripting_addition_set_shadow(window->id, shadow)) {
        if (shadow) {
            window_set_flag(window, WINDOW_SHADOW);
        } else {
            window_clear_flag(window, WINDOW_SHADOW);
        }
    }
}

#define NATIVE_FULLSCREEN_WAIT_ITERATIONS 30

void window_manager_wait_for_native_fullscreen_transition(void)
{
    TIME_FUNCTION;

    for (int i = 0; i < NATIVE_FULLSCREEN_WAIT_ITERATIONS && !space_is_user(space_manager_active_space()); ++i) {

        //
        // NOTE(asmvik): Window has exited native-fullscreen mode.
        // We need to spin lock until the display is finished animating
        // because we are not actually able to interact with the window.
        //
        // The display_manager API does not work on macOS Monterey.
        //
        // NOTE: The wait is bounded, because the space we wait for may never become active
        // (e.g. the transition was cancelled), and this blocks the event loop.
        //

        usleep(100000);
    }
}

void window_manager_toggle_window_native_fullscreen(struct window *window)
{
    TIME_FUNCTION;

    uint64_t sid = window_space(window->id);

    //
    // NOTE(asmvik): The window must become the focused window
    // before we can change its fullscreen attribute. We focus the
    // window and spin lock until a potential space animation has finished.
    //

    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    for (int i = 0; i < NATIVE_FULLSCREEN_WAIT_ITERATIONS && sid != space_manager_active_space(); ++i) { usleep(100000); }


    if (!window_is_fullscreen(window)) {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanTrue);
    } else {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanFalse);
    }

    //
    // NOTE(asmvik): We toggled the fullscreen attribute and must
    // now spin lock until the post-exit space animation has finished.
    //

    window_manager_wait_for_native_fullscreen_transition();
}

static void window_manager_toggle_window_zoom(struct window_manager *wm, struct window *window, enum con_zoom zoom)
{
    struct view *view = window_manager_find_tree_view(wm, window);
    if (!view) return;

    struct con *con = tree_find_window(view->tree, window->id);
    if (!con || con == view->tree) return;
    if (zoom == CON_ZOOM_PARENT && con->parent == view->tree) zoom = CON_ZOOM_FULLSCREEN;

    con->zoom = con->zoom == zoom ? CON_ZOOM_NONE : zoom;
    window_manager_tree_apply(view);
}


void window_manager_toggle_window_zoom_parent(struct window_manager *wm, struct window *window)
{
    TIME_FUNCTION;
    window_manager_toggle_window_zoom(wm, window, CON_ZOOM_PARENT);
}

void window_manager_toggle_window_zoom_fullscreen(struct window_manager *wm, struct window *window)
{
    TIME_FUNCTION;
    window_manager_toggle_window_zoom(wm, window, CON_ZOOM_FULLSCREEN);
}

void window_manager_toggle_window_windowed_fullscreen(struct window *window)
{
    TIME_FUNCTION;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    if (window_check_flag(window, WINDOW_WINDOWED)) {
        window_clear_flag(window, WINDOW_WINDOWED);
        window_manager_animate_window((struct window_capture) { .window = window, .x = window->windowed_frame.origin.x , .y = window->windowed_frame.origin.y, .w = window->windowed_frame.size.width, .h = window->windowed_frame.size.height });
    } else {
        window_set_flag(window, WINDOW_WINDOWED);
        window->windowed_frame = window->frame;
        CGRect bounds = display_bounds_constrained(did, true);
        window_manager_animate_window((struct window_capture) { .window = window, .x = bounds.origin.x, .y = bounds.origin.y, .w = bounds.size.width, .h = bounds.size.height });
    }
}

void window_manager_toggle_window_expose(struct window *window)
{
    TIME_FUNCTION;

    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    CoreDockSendNotification(CFSTR("com.apple.expose.front.awake"), 0);
}

void window_manager_toggle_window_pip(struct space_manager *sm, struct window *window)
{
    TIME_FUNCTION;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    uint64_t sid = display_space_id(did);
    struct view *dview = space_manager_find_view(sm, sid);

    CGRect bounds = display_bounds_constrained(did, false);
    if (dview && view_check_flag(dview, VIEW_ENABLE_PADDING)) {
        bounds.origin.x    += dview->left_padding;
        bounds.size.width  -= (dview->left_padding + dview->right_padding);
        bounds.origin.y    += dview->top_padding;
        bounds.size.height -= (dview->top_padding + dview->bottom_padding);
    }

    scripting_addition_scale_window(window->id, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
}

static void window_manager_validate_windows_on_space(struct window_manager *wm, struct view *view, uint32_t *window_list, int window_count)
{
    int view_window_count;
    uint32_t *view_window_list = view_find_window_list(view, &view_window_count);

    for (int i = 0; i < view_window_count; ++i) {
        bool found = false;

        for (int j = 0; j < window_count; ++j) {
            if (view_window_list[i] == window_list[j]) {
                found = true;
                break;
            }
        }

        if (!found) {
            struct window *window = window_manager_find_window(wm, view_window_list[i]);
            if (!window) continue;

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_remove_window(view, window);
            window_manager_adjust_layer(window, LAYER_NORMAL);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);

            view_set_flag(view, VIEW_IS_DIRTY);
        }
    }
}

static void window_manager_check_for_windows_on_space(struct window_manager *wm, struct view *view, uint32_t *window_list, int window_count)
{
    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_manager_find_window(wm, window_list[i]);
        if (!window || !window_manager_should_manage_window(window)) continue;

        struct view *existing_view = window_manager_find_managed_window(wm, window);
        if (existing_view && existing_view->layout != VIEW_FLOAT && existing_view != view) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_remove_window(existing_view, window);
            window_manager_adjust_layer(window, LAYER_NORMAL);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);
            view_set_flag(existing_view, VIEW_IS_DIRTY);
        }

        if (!existing_view || (existing_view->layout != VIEW_FLOAT && existing_view != view)) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_add_window(view, window, 0);
            window_manager_adjust_layer(window, LAYER_BELOW);
            window_manager_add_managed_window(wm, window, view);
            view_set_flag(view, VIEW_IS_DIRTY);
        }
    }
}

void window_manager_validate_and_check_for_windows_on_space(struct space_manager *sm, struct window_manager *wm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return;

    int window_count = 0;
    uint32_t *window_list = space_window_list(sid, &window_count, false);
    window_manager_validate_windows_on_space(wm, view, window_list, window_count);
    window_manager_check_for_windows_on_space(wm, view, window_list, window_count);

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    if (space_is_visible(view->sid) && view_is_dirty(view)) {
        view_flush(view);
    }
}

void window_manager_correct_for_mission_control_changes(struct space_manager *sm, struct window_manager *wm)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    float animation_duration = wm->window_animation_duration;
    wm->window_animation_duration = 0.0f;

    for (int i = 0; i < display_count; ++i) {
        uint32_t did = display_list[i];

        int space_count;
        uint64_t *space_list = display_space_list(did, &space_count);
        if (!space_list) continue;

        uint64_t sid = display_space_id(did);
        for (int j = 0; j < space_count; ++j) {
            if (space_list[j] == sid) {
                window_manager_validate_and_check_for_windows_on_space(sm, wm, sid);
            } else {
                space_manager_mark_view_invalid(sm, space_list[j]);
            }
        }
    }

    wm->window_animation_duration = animation_duration;
}

void window_manager_handle_display_add_and_remove(struct space_manager *sm, struct window_manager *wm, uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return;

    for (int i = 0; i < space_count; ++i) {
        if (space_is_user(space_list[i])) {
            int window_count;
            uint32_t *window_list = space_window_list(space_list[i], &window_count, false);
            if (window_list) {
                struct view *view = space_manager_find_view(sm, space_list[i]);
                if (view->layout != VIEW_FLOAT) {
                    window_manager_check_for_windows_on_space(wm, view, window_list, window_count);
                }
            }
            break;
        }
    }

    uint64_t sid = display_space_id(did);
    for (int i = 0; i < space_count; ++i) {
        if (space_list[i] == sid) {
            space_manager_refresh_view(sm, sid);
        } else {
            space_manager_mark_view_invalid(sm, space_list[i]);
        }
    }
}

void window_manager_init(struct window_manager *wm)
{
    wm->system_element = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(wm->system_element, 1.0);

    wm->ffm_mode = FFM_DISABLED;
    wm->purify_mode = PURIFY_DISABLED;
    wm->window_origin_mode = WINDOW_ORIGIN_DEFAULT;
    wm->enable_mff = false;
    wm->enable_window_opacity = false;
    wm->menubar_opacity = 1.0f;
    wm->active_window_opacity = 1.0f;
    wm->normal_window_opacity = 1.0f;
    wm->window_opacity_duration = 0.0f;
    wm->window_animation_duration = 0.0f;
    wm->window_animation_easing = ease_out_circ_type;
    wm->insert_feedback_color = rgba_color_from_hex(0xffd75f5f);
    wm->enable_window_border = false;
    wm->window_border_hide_single = false;
    wm->window_border_width = 4.0f;
    wm->active_window_border_color = rgba_color_from_hex(0xffe1e3e4);
    wm->normal_window_border_color = rgba_color_from_hex(0xff494d64);
    wm->focus_wrapping = FOCUS_WRAPPING_ON;
    wm->enable_tab_bar = true;
    wm->tab_bar_height = 24;
    wm->tab_bar_offset = 0;
    wm->tab_bar_icons = true;
    wm->tab_bar_style = TAB_BAR_STYLE_GLASS;
    wm->tab_bar_backdrop = TAB_BAR_BACKDROP_GLASS;
    wm->tab_bar_card_padding = 6;
    wm->tab_bar_window_radius = 16;
    wm->tab_bar_focused_color = rgba_color_from_hex(0xff285577);
    wm->tab_bar_focused_text_color = rgba_color_from_hex(0xffffffff);
    wm->tab_bar_inactive_color = rgba_color_from_hex(0xff5f676a);
    wm->tab_bar_inactive_text_color = rgba_color_from_hex(0xffffffff);
    wm->tab_bar_unfocused_color = rgba_color_from_hex(0xff222222);
    wm->tab_bar_unfocused_text_color = rgba_color_from_hex(0xff888888);
    wm->tab_bar_backdrop_color = rgba_color_from_hex(0xff48484a);
    tab_bar_set_font(TAB_BAR_DEFAULT_FONT);
    wm->scratchpad_exclusive = false;
    wm->scratchpad_raise = false;
    wm->scratchpad_below = false;
    memset(wm->scratchpad_grid, 0, sizeof(wm->scratchpad_grid));

    table_init(&wm->application, 150, hash_wm, compare_wm);
    table_init(&wm->window, 150, hash_wm, compare_wm);
    table_init(&wm->managed_window, 150, hash_wm, compare_wm);
    table_init(&wm->window_lost_focused_event, 150, hash_wm, compare_wm);
    table_init(&wm->application_lost_front_switched_event, 150, hash_wm, compare_wm);
    table_init(&wm->window_animations_table, 150, hash_wm, compare_wm);
    pthread_mutex_init(&wm->window_animations_lock, NULL);
}

void window_manager_begin(struct space_manager *sm, struct window_manager *wm)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    table_for (struct process *process, g_process_manager.process, {
        if (workspace_application_is_observable(process)) {
            struct application *application = application_create(process);

            if (application_observe(application)) {
                window_manager_add_application(wm, application);
                window_manager_add_existing_application_windows(sm, wm, application, -1);
            } else {
                application_unobserve(application);
                application_destroy(application);
            }
        } else {
            debug("%s: %s (%d) is not observable, subscribing to activationPolicy changes\n", __FUNCTION__, process->name, process->pid);
            workspace_application_observe_activation_policy(process);
        }
    })
    [pool drain];

    struct window *window = window_manager_focused_window(wm);
    if (window) {
        wm->last_window_id = window->id;
        wm->focused_window_id = window->id;
        wm->focused_window_psn = window->application->psn;
        window_manager_set_window_opacity(wm, window, wm->active_window_opacity);
    }
}
