extern struct event_loop g_event_loop;
extern volatile bool __pending_gesture;
extern volatile uint64_t __last_gesture_time;
extern volatile uint32_t __pending_mouse_moved;
extern volatile uint32_t __pending_mouse_dragged;

static inline uint8_t mouse_mod_from_cgflags(uint32_t cgflags)
{
    uint8_t flags = 0;

    if ((cgflags & kCGEventFlagMaskAlternate)   == kCGEventFlagMaskAlternate)   flags |= MOUSE_MOD_ALT;
    if ((cgflags & kCGEventFlagMaskShift)       == kCGEventFlagMaskShift)       flags |= MOUSE_MOD_SHIFT;
    if ((cgflags & kCGEventFlagMaskCommand)     == kCGEventFlagMaskCommand)     flags |= MOUSE_MOD_CMD;
    if ((cgflags & kCGEventFlagMaskControl)     == kCGEventFlagMaskControl)     flags |= MOUSE_MOD_CTRL;
    if ((cgflags & kCGEventFlagMaskSecondaryFn) == kCGEventFlagMaskSecondaryFn) flags |= MOUSE_MOD_FN;

    return flags;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wswitch"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static MOUSE_HANDLER(mouse_handler)
{
    struct mouse_state *mouse_state = context;

    switch (type) {
    case kCGEventTapDisabledByTimeout:
    case kCGEventTapDisabledByUserInput: {
        CFMachPortRef handle = __atomic_load_n(&mouse_state->handle, __ATOMIC_RELAXED);
        if (handle) CGEventTapEnable(handle, true);
    } break;
    case kCGEventLeftMouseDown:
    case kCGEventRightMouseDown: {
        uint8_t mod = mouse_mod_from_cgflags(CGEventGetFlags(event));

        uint32_t tab_wid;
        if (type == kCGEventLeftMouseDown && mod != mouse_state->modifier && tab_bar_hit_test(CGEventGetLocation(event), &tab_wid)) {
            mouse_state->consume_tab_click = true;
            event_loop_post(&g_event_loop, TAB_BAR_CLICKED, (void *)(intptr_t) tab_wid, 0);
            return NULL;
        }

        event_loop_post(&g_event_loop, MOUSE_DOWN, (void *) CFRetain(event), mod);

        if (mod == mouse_state->modifier) {
            mouse_state->consume_mouse_click = true;
            mouse_state->consumed_event = (CGEventRef) CFRetain(event);
            return NULL;
        }
    } break;
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseUp: {
        if (type == kCGEventLeftMouseUp && mouse_state->consume_tab_click) {
            mouse_state->consume_tab_click = false;
            return NULL;
        }

        event_loop_post(&g_event_loop, MOUSE_UP, (void *) CFRetain(event), 0);

        if (mouse_state->consume_mouse_click) {
            if (!mouse_state->drag_detected) {
                CGEventTapPostEvent(proxy, mouse_state->consumed_event);
                CGEventTapPostEvent(proxy, event);
            }

            mouse_state->drag_detected = false;
            mouse_state->consume_mouse_click = false;
            CFRelease(mouse_state->consumed_event);
            return NULL;
        }
    } break;
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged: {
        if (type == kCGEventLeftMouseDragged && mouse_state->consume_tab_click) return NULL;

        mouse_state->drag_detected = true;
        __atomic_add_fetch(&__pending_mouse_dragged, 1, __ATOMIC_ACQ_REL);
        event_loop_post(&g_event_loop, MOUSE_DRAGGED, (void *) CFRetain(event), 0);
    } break;
    case kCGEventMouseMoved: {
        uint8_t mod = mouse_mod_from_cgflags(CGEventGetFlags(event));
        if (mod == mouse_state->modifier) return event;

        __atomic_add_fetch(&__pending_mouse_moved, 1, __ATOMIC_ACQ_REL);
        event_loop_post(&g_event_loop, MOUSE_MOVED, (void *) CFRetain(event), mod);
    } break;
    case /* kCGSEventDockControl */ 30: {
        int type = CGEventGetIntegerValueField(event, /* kCGEventGestureHIDType */ 110);
        if (type == /* kIOHIDEventTypeDockSwipe */ 23) {
            int motion = CGEventGetIntegerValueField(event, /* kCGEventGestureSwipeMotion */ 123);
            if (motion == /* kCGGestureMotionHorizontal */ 1) {
                int phase = CGEventGetIntegerValueField(event, /* kCGEventGesturePhase */ 132);
                if (phase == /* kCGSGesturePhaseBegan */ 1) {
                    __atomic_store_n(&__pending_gesture, true, __ATOMIC_RELEASE);
                } else if (phase == /* kCGSGesturePhaseEnded */ 4 || phase == /* kCGSGesturePhaseCancelled */ 8) {
                    __atomic_store_n(&__pending_gesture, false, __ATOMIC_RELEASE);
                    __atomic_store_n(&__last_gesture_time, read_os_timer(), __ATOMIC_RELEASE);
                }
            }
        }
    } break;
    }

    return event;
}
#pragma clang diagnostic pop

void mouse_window_info_populate(struct mouse_state *ms, struct mouse_window_info *info)
{
    CGRect frame = ms->window->frame;

    info->dx = frame.origin.x    - ms->window_frame.origin.x;
    info->dy = frame.origin.y    - ms->window_frame.origin.y;
    info->dw = frame.size.width  - ms->window_frame.size.width;
    info->dh = frame.size.height - ms->window_frame.size.height;

    info->changed_x = info->dx != 0.0f;
    info->changed_y = info->dy != 0.0f;
    info->changed_w = info->dw != 0.0f;
    info->changed_h = info->dh != 0.0f;

    info->changed_position = info->changed_x || info->changed_y;
    info->changed_size     = info->changed_w || info->changed_h;
}

enum mouse_drop_action mouse_determine_drop_action(struct mouse_state *ms, bool allow_center, struct window *dst_window, CGPoint point)
{
    CGRect  f    = dst_window->frame;
    CGPoint wp   = { point.x - f.origin.x, point.y - f.origin.y };
    CGRect  c    = {{ 0.25f * f.size.width, 0.25f * f.size.height }, { 0.50f * f.size.width, 0.50f * f.size.height }};
    CGPoint t[3] = {{ 0.0f, 0.0f}, { 0.5f * f.size.width, 0.5f * f.size.height }, { f.size.width, 0.0f }};
    CGPoint r[3] = {{ f.size.width, 0.0f }, { 0.5f * f.size.width, 0.5f * f.size.height }, { f.size.width, f.size.height }};
    CGPoint b[3] = {{ f.size.width, f.size.height }, { 0.5f * f.size.width, 0.5f * f.size.height }, { 0.0f, f.size.height }};
    CGPoint l[3] = {{ 0.0f, f.size.height }, { 0.5f * f.size.width, 0.5f * f.size.height }, { 0.0f, 0.0f }};

    if ((CGRectContainsPoint(c, wp)) && allow_center) {
        return ms->drop_action == MOUSE_MODE_STACK ? MOUSE_DROP_ACTION_STACK : MOUSE_DROP_ACTION_SWAP;
    } else if (triangle_contains_point(t, wp)) {
        return MOUSE_DROP_ACTION_WARP_TOP;
    } else if (triangle_contains_point(r, wp)) {
        return MOUSE_DROP_ACTION_WARP_RIGHT;
    } else if (triangle_contains_point(b, wp)) {
        return MOUSE_DROP_ACTION_WARP_BOTTOM;
    } else if (triangle_contains_point(l, wp)) {
        return MOUSE_DROP_ACTION_WARP_LEFT;
    }

    return MOUSE_DROP_ACTION_NONE;
}

void mouse_drop_try_adjust_tree(struct window_manager *wm, struct view *view, struct window *window, struct mouse_window_info *info)
{
    bool success = true;

    if (info->changed_position) {
        uint8_t direction = 0;
        if (info->changed_x) direction |= HANDLE_LEFT;
        if (info->changed_y) direction |= HANDLE_TOP;
        if (window_manager_resize_window_relative(wm, window, direction, info->dx, info->dy, true) == WINDOW_OP_ERROR_INVALID_DST_NODE) {
            success = false;
        }
    }

    if (info->changed_size) {
        uint8_t direction = 0;
        if (info->changed_w && !info->changed_x) direction |= HANDLE_RIGHT;
        if (info->changed_h && !info->changed_y) direction |= HANDLE_BOTTOM;
        if (window_manager_resize_window_relative(wm, window, direction, info->dw, info->dh, true) == WINDOW_OP_ERROR_INVALID_DST_NODE) {
            success = false;
        }
    }

    if (!success) view_flush(view);
}

static int mouse_drop_action_direction(enum mouse_drop_action drop_action)
{
    switch (drop_action) {
    case MOUSE_DROP_ACTION_STACK:       return STACK;
    case MOUSE_DROP_ACTION_SWAP:        return STACK;
    case MOUSE_DROP_ACTION_WARP_TOP:    return DIR_NORTH;
    case MOUSE_DROP_ACTION_WARP_RIGHT:  return DIR_EAST;
    case MOUSE_DROP_ACTION_WARP_BOTTOM: return DIR_SOUTH;
    case MOUSE_DROP_ACTION_WARP_LEFT:   return DIR_WEST;
    case MOUSE_DROP_ACTION_NONE:        return 0;
    }

    return 0;
}

static struct con *mouse_find_con(struct view *view, struct window *window)
{
    return view && window ? tree_view_find_window(view, window->id) : NULL;
}

void mouse_feedback_clear(struct mouse_state *ms)
{
    if (!ms->feedback_wid) return;

    struct window *window = window_manager_find_window(&g_window_manager, ms->feedback_wid);
    struct view *view = window ? window_manager_find_managed_window(&g_window_manager, window) : NULL;
    struct con *con = mouse_find_con(view, window);
    if (con && con->insert_dir == 0) tree_feedback_hide(con);

    ms->feedback_wid = 0;
    ms->feedback_dir = 0;
}

//
// NOTE: While a window is dragged over a managed window, the half where it would be placed
// is outlined, or the whole window when dropping would swap or stack them.
//

void mouse_drag(struct mouse_state *ms, struct view *dst_view, struct window *dst_window, CGPoint point)
{
    struct con *con = mouse_find_con(dst_view, dst_window);
    if (!con) {
        mouse_feedback_clear(ms);
        return;
    }

    int direction = mouse_drop_action_direction(mouse_determine_drop_action(ms, true, dst_window, point));
    if (ms->feedback_wid == dst_window->id && ms->feedback_dir == direction) return;

    mouse_feedback_clear(ms);
    if (!direction) return;

    tree_feedback_show(con, direction);
    ms->feedback_wid = dst_window->id;
    ms->feedback_dir = direction;
}

static void mouse_drop_no_target(struct space_manager *sm, struct window_manager *wm, struct view *src_view, struct view *dst_view, struct window *window)
{
    if (src_view->sid == dst_view->sid || dst_view->layout == VIEW_FLOAT) {
        view_flush(src_view);
        return;
    }

    space_manager_untile_window(src_view, window);
    window_manager_remove_managed_window(wm, window->id);
    window_manager_purify_window(wm, window);

    struct view *view = space_manager_tile_window_on_space(sm, window, dst_view->sid);
    window_manager_add_managed_window(wm, window, view);
}

//
// NOTE: Dropping a window on a managed window: the center swaps the two windows, or makes
// the dropped window a tab of the other one with mouse_drop_action stack. The edges place the dropped
// window on that side of the other window.
//

void mouse_drop(struct space_manager *sm, struct window_manager *wm, struct mouse_state *ms, struct view *src_view, struct view *dst_view, struct window *src_window, struct window *dst_window, CGPoint point)
{
    mouse_feedback_clear(ms);

    struct con *dst_con = mouse_find_con(dst_view, dst_window);
    if (!dst_con) {
        mouse_drop_no_target(sm, wm, src_view, dst_view, src_window);
        return;
    }

    enum mouse_drop_action drop_action = mouse_determine_drop_action(ms, true, dst_window, point);
    int direction = mouse_drop_action_direction(drop_action);

    if (drop_action == MOUSE_DROP_ACTION_NONE) {
        view_flush(src_view);
    } else if (drop_action == MOUSE_DROP_ACTION_SWAP) {
        window_manager_swap_window(wm, src_window, dst_window);
    } else if (direction == STACK) {
        window_manager_stack_window(sm, wm, dst_window, src_window);
        if (src_view != dst_view) view_flush(src_view);
    } else if (src_view == dst_view) {
        struct con *con = tree_find_window(src_view->tree, src_window->id);
        if (!con) return;

        tree_detach(con);
        tree_insert_relative(dst_con, con, direction);
        tree_focus(con);
        tree_flatten(src_view->tree);

        if (!view_update_auto_padding(src_view)) tree_view_update(src_view);
        view_flush(src_view);
    } else {
        dst_con->insert_dir = direction;
        dst_view->insertion_point = dst_window->id;

        space_manager_untile_window(src_view, src_window);
        window_manager_remove_managed_window(wm, src_window->id);
        window_manager_purify_window(wm, src_window);

        struct view *view = space_manager_tile_window_on_space(sm, src_window, dst_view->sid);
        window_manager_add_managed_window(wm, src_window, view);
    }
}

void mouse_state_init(struct mouse_state *state)
{
    state->modifier    = MOUSE_MOD_FN;
    state->action1     = MOUSE_MODE_MOVE;
    state->action2     = MOUSE_MODE_RESIZE;
    state->drop_action = MOUSE_MODE_SWAP;
}

bool mouse_handler_begin(struct mouse_state *mouse_state, uint32_t mask)
{
    if (mouse_state->handle) return true;

    mouse_state->handle = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, mouse_handler, mouse_state);
    if (!mouse_state->handle) return false;

    if (!CGEventTapIsEnabled(mouse_state->handle)) {
        CFMachPortInvalidate(mouse_state->handle);
        CFRelease(mouse_state->handle);
        return false;
    }

    mouse_state->runloop_source = CFMachPortCreateRunLoopSource(NULL, mouse_state->handle, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), mouse_state->runloop_source, kCFRunLoopCommonModes);

    return true;
}

void mouse_handler_end(struct mouse_state *mouse_state)
{
    if (!mouse_state->handle) return;

    CGEventTapEnable(mouse_state->handle, false);
    CFMachPortInvalidate(mouse_state->handle);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), mouse_state->runloop_source, kCFRunLoopCommonModes);
    CFRelease(mouse_state->runloop_source);
    CFRelease(mouse_state->handle);
    __atomic_store_n(&mouse_state->handle, NULL, __ATOMIC_RELEASE);
}
