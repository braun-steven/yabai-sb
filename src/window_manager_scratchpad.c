//
// NOTE: Scratchpads: windows with a label that are floated and toggled between hidden (ordered out)
// and shown on the active space, configured by the scratchpad_* options.
//

extern struct space_manager g_space_manager;
extern struct process_manager g_process_manager;
extern int g_connection;

static inline struct window *window_manager_find_scratchpad_window(struct window_manager *wm, char *label)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        if (string_equals(wm->scratchpad_window[i].label, label)) {
            return wm->scratchpad_window[i].window;
        }
    }

    return NULL;
}

bool window_manager_toggle_scratchpad_window_by_label(struct window_manager *wm, char *label)
{
    struct window *window = window_manager_find_scratchpad_window(wm, label);
    return window ? window_manager_toggle_scratchpad_window(wm, window) : false;
}

void window_manager_set_scratchpad_layers(struct window_manager *wm)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        window_manager_adjust_layer(wm->scratchpad_window[i].window, wm->scratchpad_below ? LAYER_BELOW : LAYER_NORMAL);
    }
}

static void window_manager_hide_other_scratchpad_windows(struct window_manager *wm, struct window *window)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        struct window *other = wm->scratchpad_window[i].window;
        if (other == window) continue;

        uint8_t ordered_in = 0;
        SLSWindowIsOrderedIn(g_connection, other->id, &ordered_in);
        if (ordered_in) scripting_addition_order_window(other->id, 0, 0);
    }
}

static void window_manager_apply_scratchpad_grid(struct window_manager *wm, struct window *window)
{
    unsigned *grid = wm->scratchpad_grid;
    if (grid[0] == 0 || grid[1] == 0) return;

    //
    // NOTE: The window is still ordered out, so an animation
    // would capture a stale image; set the frame directly instead.
    //

    float animation_duration = wm->window_animation_duration;
    wm->window_animation_duration = 0.0f;
    window_manager_apply_grid(&g_space_manager, wm, window, grid[0], grid[1], grid[2], grid[3], grid[4], grid[5]);
    wm->window_animation_duration = animation_duration;
}

static void window_manager_hide_scratchpad_window(struct window_manager *wm, struct window *window, uint64_t sid)
{
    struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(wm, sid, 1, window->id);
    if (next) {
        window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
    } else {
        _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
    }

    scripting_addition_order_window(window->id, 0, 0);
}

static void window_manager_show_scratchpad_window(struct window_manager *wm, struct window *window, uint64_t sid, bool move_to_space, bool apply_grid)
{
    if (move_to_space) {
        space_manager_move_window_to_space(sid, window);
        space_manager_wait_for_window_on_space(window->id, sid, 200);
    }

    if (apply_grid) window_manager_apply_scratchpad_grid(wm, window);
    scripting_addition_order_window(window->id, 1, 0);
    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
}

bool window_manager_toggle_scratchpad_window(struct window_manager *wm, struct window *window)
{
    TIME_FUNCTION;

    uint64_t sid = space_manager_active_space();
    if (!sid) return false;

    // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
    bool visible_space = window_space(window->id) == sid || window_is_sticky(window->id);

    uint8_t ordered_in = 0;
    SLSWindowIsOrderedIn(g_connection, window->id, &ordered_in);

    bool shown = true;

    if (visible_space && ordered_in) {
        if (wm->scratchpad_raise && wm->focused_window_id != window->id && !window_check_flag(window, WINDOW_MINIMIZE) && !window->application->is_hidden) {
            window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
        } else {
            window_manager_hide_scratchpad_window(wm, window, sid);
            shown = false;
        }
    } else {
        window_manager_show_scratchpad_window(wm, window, sid, !visible_space, !ordered_in);
    }

    if (shown && wm->scratchpad_exclusive) {
        window_manager_hide_other_scratchpad_windows(wm, window);
    }

    border_refresh_window_space(window);

    return true;
}

bool window_manager_set_scratchpad_for_window(struct window_manager *wm, struct window *window, char *label)
{
    struct window *existing_window = window_manager_find_scratchpad_window(wm, label);
    if (existing_window) return false;

    window_manager_remove_scratchpad_for_window(wm, window, false);
    buf_push(wm->scratchpad_window, ((struct scratchpad) {
        .label = label,
        .window = window
    }));
    window->scratchpad = label;
    window_manager_make_window_floating(&g_space_manager, wm, window, true, false);

    //
    // NOTE: Floating puts the window on the normal sub-layer, above
    // tiled windows; scratchpad_below moves it to their sub-layer.
    //

    if (wm->scratchpad_below) window_manager_adjust_layer(window, LAYER_BELOW);

    return true;
}

//
// NOTE: A window that stops being a scratchpad is brought to the active space and shown,
// without the scratchpad_* options, which only apply to toggling by label.
//

static void window_manager_release_scratchpad_window(struct window_manager *wm, struct window *window)
{
    uint64_t sid = space_manager_active_space();
    if (sid) {
        window_manager_show_scratchpad_window(wm, window, sid, true, false);
        border_refresh_window_space(window);
    }

    if (wm->scratchpad_below) window_manager_adjust_layer(window, LAYER_NORMAL);
    window_manager_make_window_floating(&g_space_manager, wm, window, false, false);
}

bool window_manager_remove_scratchpad_for_window(struct window_manager *wm, struct window *window, bool unfloat)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        if (wm->scratchpad_window[i].window == window) {
            window->scratchpad = NULL;

            free(wm->scratchpad_window[i].label);
            buf_del(wm->scratchpad_window, i);

            if (unfloat) window_manager_release_scratchpad_window(wm, window);

            return true;
        }
    }

    return false;
}

void window_manager_scratchpad_recover_windows(void)
{
    int window_count;
    uint32_t *window_list = window_manager_existing_application_window_list(NULL, &window_count);
    if (!window_list) return;

    if (scripting_addition_order_window_in(window_list, window_count)) {
        space_manager_refresh_application_windows(&g_space_manager);
    }
}
