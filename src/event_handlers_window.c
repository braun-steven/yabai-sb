//
// NOTE: The handlers of window events: windows created, destroyed, focused, moved, resized, minimized
// and retitled, from the accessibility observers and the window server.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static EVENT_HANDLER(WINDOW_CREATED)
{
    uint32_t window_id = ax_window_id(context);
    if (!window_id) { CFRelease(context); return; }

    struct window *existing_window = window_manager_find_window(&g_window_manager, window_id);
    if (existing_window) { CFRelease(context); return; }

    pid_t window_pid = ax_window_pid(context);
    if (!window_pid) { CFRelease(context); return; }

    struct application *application = window_manager_find_application(&g_window_manager, window_pid);
    if (!application) { CFRelease(context); return; }

    struct window *window = window_manager_create_and_add_window(&g_space_manager, &g_window_manager, application, context, window_id, true);
    if (!window) return;

    window_manager_remove_one_shot_rules(&g_window_manager);

    if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
        window_manager_manage_window(&g_space_manager, &g_window_manager, window, window_manager_origin_space(&g_window_manager, window), 0);
    }

    if (window_manager_is_window_eligible(window)) {
        event_signal_push(SIGNAL_WINDOW_CREATED, window);
    }

    border_refresh_window_space(window);

    update_window_notifications();
}

static EVENT_HANDLER(WINDOW_DESTROYED)
{
    struct window *window = context;
    if (!window || window->id == 0) {
        debug("%s: window has already been destroyed, ignoring event..\n", __FUNCTION__);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application ? window->application->name : "<unknown>", window->id);

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (view) {
        uint32_t next_focus = window_manager_tree_focus_candidate(&g_window_manager, view, window);
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(&g_window_manager, window->id);
        window_manager_tree_focus_after_close(&g_window_manager, view, next_focus);
    }

    if (g_mouse_state.window == window) g_mouse_state.window = NULL;
    if (g_mouse_state.ffm_window_id == window->id) g_mouse_state.ffm_window_id = 0;

    if (window->is_eligible) {
        event_signal_push(SIGNAL_WINDOW_DESTROYED, window);
    }

    window_manager_remove_scratchpad_for_window(&g_window_manager, window, false);
    window_manager_remove_window(&g_window_manager, window->id);
    window_unobserve(window);
    window_destroy(window);

    if (g_window_manager.window_border_hide_single) {
        border_refresh_space(g_space_manager.current_space_id);
    }

    update_window_notifications();
}

static EVENT_HANDLER(WINDOW_FOCUS_DEFERRED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;

    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window || !window->application) {
        debug("%s: %d no longer exists, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    window_manager_focus_window_without_raise_deferred(window);
}

static EVENT_HANDLER(WINDOW_FOCUSED)
{
    __atomic_store_n(&__pending_window_focus, false, __ATOMIC_RELEASE);
    uint32_t window_id = (uint32_t)(intptr_t) context;

    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) {
        window_manager_add_lost_focused_event(&g_window_manager, window_id);
        return;
    }

    if (!window_is_valid(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    if (window_check_flag(window, WINDOW_MINIMIZE)) {
        window_manager_add_lost_focused_event(&g_window_manager, window->id);
        return;
    }

    if (!application_is_frontmost(window->application)) {
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);

    if (g_space_manager.skip_window_focus_animation) {
        uint64_t sid = window_space(window->id);
        if (sid && !space_is_visible(sid)) {
            SLSSpaceSetFrontPSN(g_connection, sid, window->application->psn);
            space_manager_focus_space_using_gesture(space_display_id(sid), sid);
        }
    }

    window_did_receive_focus(&g_window_manager, &g_mouse_state, window);
    event_signal_push(SIGNAL_WINDOW_FOCUSED, window);
}

static EVENT_HANDLER(WINDOW_MOVED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) return;

    if (!window_is_valid(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    if (window->application->is_hidden) {
        debug("%s: %d was moved while the application is hidden, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    CGPoint new_origin = window_ax_origin(window);
    if (CGPointEqualToPoint(new_origin, window->frame.origin)) {
        debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);
    event_signal_push(SIGNAL_WINDOW_MOVED, window);
    bool windowed_fullscreen = CGRectEqualToRect(window->windowed_frame, window->frame);
    window->frame.origin = new_origin;

    if (!windowed_fullscreen) {
        window_clear_flag(window, WINDOW_WINDOWED);

        if (!g_mouse_state.window || g_mouse_state.window != window) {
            struct view *view = window_manager_find_managed_window(&g_window_manager, window);
            if (view && tree_window_needs_flush(view, window->id, window->frame)) view_flush(view);
        }
    }
}

static EVENT_HANDLER(WINDOW_RESIZED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) return;

    if (!window_is_valid(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    if (window->application->is_hidden) {
        debug("%s: %d was resized while the application is hidden, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    CGRect new_frame = window_ax_frame(window);
    if (CGRectEqualToRect(new_frame, window->frame)) {
        debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);
    event_signal_push(SIGNAL_WINDOW_RESIZED, window);

    bool was_fullscreen = window_check_flag(window, WINDOW_FULLSCREEN);

    bool is_fullscreen = window_is_fullscreen(window);
    if (is_fullscreen) {
        window_set_flag(window, WINDOW_FULLSCREEN);
    } else {
        window_clear_flag(window, WINDOW_FULLSCREEN);
    }

    if (was_fullscreen != is_fullscreen) {
        window_refresh_ax_properties(window);
    }

    bool windowed_fullscreen = CGRectEqualToRect(window->windowed_frame, window->frame);
    window->frame = new_frame;

    if (was_fullscreen != is_fullscreen) border_refresh_window_space(window);

    if (!was_fullscreen && is_fullscreen) {
        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        if (view) {
            window_manager_unmanage_window(&g_window_manager, view, window);
        }
    } else if (was_fullscreen && !is_fullscreen) {
        window_manager_wait_for_native_fullscreen_transition();

        if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
            window_manager_manage_window(&g_space_manager, &g_window_manager, window, window_space(window->id), 0);
        }
    } else if (!was_fullscreen == !is_fullscreen) {
        if (g_mouse_state.current_action == MOUSE_MODE_MOVE && g_mouse_state.window == window) {
            g_mouse_state.window_frame.size = g_mouse_state.window->frame.size;
        }

        if (!windowed_fullscreen) {
            window_clear_flag(window, WINDOW_WINDOWED);

            if (!g_mouse_state.window || g_mouse_state.window != window) {
                struct view *view = window_manager_find_managed_window(&g_window_manager, window);
                if (view && tree_window_needs_flush(view, window->id, new_frame)) view_flush(view);
            }
        }
    }
}

static EVENT_HANDLER(WINDOW_MINIMIZED)
{
    struct window *window = context;

    if (!window_is_valid(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window->id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);
    window_set_flag(window, WINDOW_MINIMIZE);

    window_refresh_ax_properties(window);

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    uint32_t next_focus = view ? window_manager_tree_focus_candidate(&g_window_manager, view, window) : 0;

    if (window->id == g_window_manager.last_window_id) {
        g_window_manager.last_window_id = g_window_manager.focused_window_id;
    }

    if (view) {
        window_manager_unmanage_window(&g_window_manager, view, window);
        window_manager_tree_focus_after_close(&g_window_manager, view, next_focus);
    }

    border_refresh_window_space(window);
    event_signal_push(SIGNAL_WINDOW_MINIMIZED, window);
}

static EVENT_HANDLER(WINDOW_DEMINIMIZED)
{
    struct window *window = context;

    if (!window_is_valid(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window->id);
        window_manager_remove_lost_focused_event(&g_window_manager, window->id);
        return;
    }

    window_clear_flag(window, WINDOW_MINIMIZE);

    window_refresh_ax_properties(window);

    uint64_t sid = space_manager_active_space();
    if (space_manager_is_window_on_space(sid, window)) {
        debug("%s: window %s %d is deminimized on active space\n", __FUNCTION__, window->application->name, window->id);
        if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
            struct window *last_window = window_manager_find_window(&g_window_manager, g_window_manager.last_window_id);
            uint32_t insertion_point = last_window && last_window->application->pid != window->application->pid ? last_window->id : 0;
            window_manager_manage_window(&g_space_manager, &g_window_manager, window, sid, insertion_point);
        }
    } else {
        debug("%s: window %s %d is deminimized on inactive space\n", __FUNCTION__, window->application->name, window->id);
    }

    if (window_manager_find_lost_focused_event(&g_window_manager, window->id)) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
        window_manager_remove_lost_focused_event(&g_window_manager, window->id);
    }

    border_refresh_window_space(window);
    event_signal_push(SIGNAL_WINDOW_DEMINIMIZED, window);
}

static EVENT_HANDLER(WINDOW_TITLE_CHANGED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) return;

    if (!window_is_valid(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);

    if (window->title) CFRelease(window->title);

    window->title = window_title(window);
    tab_bar_refresh_for_window(window->id);

    event_signal_push(SIGNAL_WINDOW_TITLE_CHANGED, window);
}

static EVENT_HANDLER(SLS_WINDOW_ORDERED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    tab_bar_order(wid);
}

static EVENT_HANDLER(SLS_WINDOW_DESTROYED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);

    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window) return;

    //
    // NOTE: The AX destroyed notification for the same window can arrive on the main thread at any
    // time. Claim the window like that callback does, so that it bails out instead of posting a second
    // WINDOW_DESTROYED event for memory that we are about to free.
    //

    if (!window_invalidate(window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, wid);
        return;
    }

    EVENT_HANDLER_WINDOW_DESTROYED(window, 0);
}
#pragma clang diagnostic pop
