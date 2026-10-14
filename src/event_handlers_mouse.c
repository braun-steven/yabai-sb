//
// NOTE: The handlers of mouse events: moving and resizing windows with the mouse modifier, dropping them on
// other windows, tab bar clicks, and focus follows mouse.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
//
// NOTE: A resize drags the corner (or edge) of the window that is closest to where the mouse went down.
//

static inline int mouse_resize_direction(CGRect frame, CGPoint point)
{
    int direction = 0;
    CGPoint frame_mid = { CGRectGetMidX(frame), CGRectGetMidY(frame) };

    if (point.x < frame_mid.x) direction |= HANDLE_LEFT;
    if (point.y < frame_mid.y) direction |= HANDLE_TOP;
    if (point.x > frame_mid.x) direction |= HANDLE_RIGHT;
    if (point.y > frame_mid.y) direction |= HANDLE_BOTTOM;

    return direction;
}

static EVENT_HANDLER(MOUSE_DOWN)
{
    if (mission_control_is_active())                     goto out;
    if (g_mouse_state.current_action != MOUSE_MODE_NONE) goto out;

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f\n", __FUNCTION__, point.x, point.y);

    struct window *window = window_manager_find_window_at_point(&g_window_manager, point);
    if (!window || window_check_flag(window, WINDOW_FULLSCREEN)) goto out;

    g_mouse_state.window = window;
    g_mouse_state.window_frame = g_mouse_state.window->frame;
    g_mouse_state.down_location = point;
    g_mouse_state.direction = 0;

    int64_t button = CGEventGetIntegerValueField(context, kCGMouseEventButtonNumber);
    uint8_t mod = (uint8_t) param1;

    if (button == kCGMouseButtonLeft && g_mouse_state.modifier == mod) {
        g_mouse_state.current_action = g_mouse_state.action1;
    } else if (button == kCGMouseButtonRight && g_mouse_state.modifier == mod) {
        g_mouse_state.current_action = g_mouse_state.action2;
    }

    if (g_mouse_state.current_action == MOUSE_MODE_RESIZE) {
        g_mouse_state.direction = mouse_resize_direction(g_mouse_state.window_frame, point);
    }

out:
    CFRelease(context);
}

static EVENT_HANDLER(TAB_BAR_CLICKED)
{
    uint32_t wid = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);

    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window) return;

    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
}

//
// NOTE: The view of the space under the cursor, and the window under the cursor other than the dragged
// window (or NULL), that a dragged window is dropped on.
//

static struct window *mouse_drop_target(CGPoint point, struct view **dst_view)
{
    uint64_t cursor_sid = display_space_id(display_manager_point_display_id(point));
    *dst_view = space_manager_find_view(&g_space_manager, cursor_sid);

    struct window *window = window_manager_find_window_at_point_filtering_window(&g_window_manager, point, g_mouse_state.window->id);
    if (!window) window = window_manager_find_window_at_point(&g_window_manager, point);
    return window == g_mouse_state.window ? NULL : window;
}

static EVENT_HANDLER(MOUSE_UP)
{
    if (mission_control_is_active()) goto out;
    if (!g_mouse_state.window)       goto res;

    if (!window_is_valid(g_mouse_state.window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, g_mouse_state.window->id);
        goto err;
    }

    if (window_check_flag(g_mouse_state.window, WINDOW_FULLSCREEN)) {
        debug("%s: %d is transitioning into native-fullscreen mode, ignoring event..\n", __FUNCTION__, g_mouse_state.window->id);
        goto err;
    }

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f\n", __FUNCTION__, point.x, point.y);

    struct view *src_view = window_manager_find_managed_window(&g_window_manager, g_mouse_state.window);
    if (!src_view) goto err;

    struct mouse_window_info info;
    mouse_window_info_populate(&g_mouse_state, &info);

    if (info.changed_position && !info.changed_size) {
        struct view *dst_view;
        struct window *window = mouse_drop_target(point, &dst_view);

        mouse_drop(&g_space_manager, &g_window_manager, &g_mouse_state, src_view, dst_view, g_mouse_state.window, window, point);
    } else if (info.changed_position || info.changed_size) {
        mouse_drop_try_adjust_tree(&g_window_manager, src_view, g_mouse_state.window, &info);
    }

err:
    g_mouse_state.window = NULL;
res:
    g_mouse_state.current_action = MOUSE_MODE_NONE;
out:
    CFRelease(context);
}

static void mouse_drag_move_window(CGPoint point)
{
    CGPoint new_point = { g_mouse_state.window_frame.origin.x + (point.x - g_mouse_state.down_location.x),
                          g_mouse_state.window_frame.origin.y + (point.y - g_mouse_state.down_location.y) };

    uint32_t did = display_manager_point_display_id(new_point);
    if (did) {
        CGRect bounds = display_bounds_constrained(did, false);
        if (new_point.y < bounds.origin.y) new_point.y = bounds.origin.y;
    }

    if (!scripting_addition_move_window(g_mouse_state.window->id, new_point.x, new_point.y)) {
        window_manager_move_window(g_mouse_state.window, new_point.x, new_point.y);
    }
}

//
// NOTE: Resizing through the AX API is slow, so a drag resizes the window at most once per throttle
// interval. Returns false when this event was skipped.
//

#define MOUSE_RESIZE_THROTTLE_MS 67.67f

static bool mouse_drag_resize_window(CGPoint point)
{
    uint64_t event_time = read_os_timer();
    if (os_timer_ms_between(g_mouse_state.last_moved_time, event_time) < MOUSE_RESIZE_THROTTLE_MS) return false;

    int dx = point.x - g_mouse_state.down_location.x;
    int dy = point.y - g_mouse_state.down_location.y;

    window_manager_resize_window_relative_internal(g_mouse_state.window, g_mouse_state.window->frame, g_mouse_state.direction, dx, dy, false);

    g_mouse_state.last_moved_time = event_time;
    g_mouse_state.down_location = point;
    return true;
}

static EVENT_HANDLER(MOUSE_DRAGGED)
{
    //
    // NOTE: Only the most recent drag event matters, because the new frame is computed from the
    // location where the drag started. Skip this one if a newer one is already queued.
    //

    if (mouse_event_is_stale(&__pending_mouse_dragged)) goto out;

    if (mission_control_is_active()) goto out;
    if (!g_mouse_state.window)       goto out;

    if (!window_is_valid(g_mouse_state.window)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, g_mouse_state.window->id);
        g_mouse_state.window = NULL;
        g_mouse_state.current_action = MOUSE_MODE_NONE;
        CFRelease(context);
        return;
    }

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f\n", __FUNCTION__, point.x, point.y);

    if (g_mouse_state.current_action == MOUSE_MODE_MOVE) {
        mouse_drag_move_window(point);
    } else if (g_mouse_state.current_action == MOUSE_MODE_RESIZE) {
        if (!mouse_drag_resize_window(point)) goto out;
    }

    struct view *src_view = window_manager_find_managed_window(&g_window_manager, g_mouse_state.window);
    if (!src_view) goto out;

    struct mouse_window_info info;
    mouse_window_info_populate(&g_mouse_state, &info);

    if (info.changed_position && !info.changed_size) {
        struct view *dst_view;
        struct window *window = mouse_drop_target(point, &dst_view);

        mouse_drag(&g_mouse_state, dst_view, window, point);
    }

out:
    CFRelease(context);
}

//
// NOTE(asmvik): Look for a window with role AXSheet or AXDrawer
// and forward focus to it because we are not allowed to focus the main
// window in these cases.
//

static struct window *ffm_window_to_focus(struct window *window)
{
    CFArrayRef window_list = SLSCopyAssociatedWindows(g_connection, window->id);
    if (!window_list) return window;

    struct window *result = window;
    int window_count = CFArrayGetCount(window_list);

    for (int i = 0; i < window_count; ++i) {
        uint32_t child_wid;
        CFNumberGetValue(CFArrayGetValueAtIndex(window_list, i), kCFNumberSInt32Type, &child_wid);
        struct window *child = window_manager_find_window(&g_window_manager, child_wid);
        if (!child) continue;

        CFTypeRef role = window_role(child);
        if (!role) continue;

        bool valid = CFEqual(role, kAXSheetRole) || CFEqual(role, kAXDrawerRole);
        CFRelease(role);

        if (valid) {
            result = child;
            break;
        }
    }

    CFRelease(window_list);
    return result;
}

//
// NOTE(asmvik): If any **floating** window would be fully occluded by
// autoraising the window below the cursor we do not actually perform the
// focus change, as it is likely that the user is trying to reach for the
// smaller window that sits on top of the window we would otherwise raise.
//

static bool ffm_raise_would_occlude_floating_window(struct window *window)
{
    int window_count;
    uint32_t *window_list = space_window_list(g_space_manager.current_space_id, &window_count, false);
    if (!window_list) return false;

    int level = window_level(window->id);
    int sub_level = window_sub_level(window->id);

    for (int i = 0; i < window_count; ++i) {
        uint32_t wid = window_list[i];
        if (wid == window->id) break;

        struct window *sub_window = window_manager_find_window(&g_window_manager, wid);
        if (!sub_window) continue;

        if (!window_check_flag(sub_window, WINDOW_FLOAT))   continue;
        if (level != window_level(sub_window->id))         continue;
        if (sub_level != window_sub_level(sub_window->id)) continue;

        if (CGRectContainsRect(window->frame, sub_window->frame)) return true;
    }

    return false;
}

static void ffm_focus_window(struct window *window)
{
    if (window->id == g_window_manager.focused_window_id) return;
    if (!window_manager_is_window_eligible(window))       return;

    if (g_window_manager.ffm_mode == FFM_AUTOFOCUS) {
        window = ffm_window_to_focus(window);
        window_manager_focus_window_without_raise(&window->application->psn, window->id);
        g_mouse_state.ffm_window_id = window->id;
    } else if (g_window_manager.ffm_mode == FFM_AUTORAISE) {
        if (ffm_raise_would_occlude_floating_window(window)) return;

        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
        g_mouse_state.ffm_window_id = window->id;
    }
}

static void ffm_focus_display_at_point(CGPoint point)
{
    uint32_t cursor_did = display_manager_point_display_id(point);
    if (g_display_manager.current_display_id == cursor_did) return;

    CGRect bounds = display_bounds_constrained(cursor_did, false);
    if (!cgrect_contains_point(bounds, point)) return;

    uint32_t wid = display_manager_focus_display_with_window_at_point(point);
    if (!wid) display_manager_set_active_display_id(cursor_did);
    g_mouse_state.ffm_window_id = wid;
}

static EVENT_HANDLER(MOUSE_MOVED)
{
    if (mouse_event_is_stale(&__pending_mouse_moved)) goto out;

    if (g_window_manager.ffm_mode == FFM_DISABLED) goto out;
    if (mission_control_is_active())               goto out;
    if (g_mouse_state.ffm_window_id)               goto out;

    if (__atomic_load_n(&__pending_gesture, __ATOMIC_RELAXED)) goto out;
    uint64_t last_gesture_time = __atomic_load_n(&__last_gesture_time, __ATOMIC_RELAXED);
    float dt = os_timer_ms_between(last_gesture_time, read_os_timer());
    if (dt < 1250.0f) goto out;

    CGPoint point = CGEventGetLocation(context);
    struct window *window = window_manager_find_window_at_point(&g_window_manager, point);

    if (window) {
        ffm_focus_window(window);
    } else {
        ffm_focus_display_at_point(point);
    }

out:
    CFRelease(context);
}
#pragma clang diagnostic pop
