extern mach_port_t g_bs_port;
extern uint8_t *g_event_bytes;
extern struct event_loop g_event_loop;
extern void *g_workspace_context;
extern struct process_manager g_process_manager;
extern struct mouse_state g_mouse_state;
extern double g_cv_host_clock_frequency;

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

void window_manager_query_window_rules(FILE *rsp)
{
    TIME_FUNCTION;

    fprintf(rsp, "[");
    for (int i = 0; i < buf_len(g_window_manager.rules); ++i) {
        struct rule *rule = &g_window_manager.rules[i];
        rule_serialize(rsp, rule, i);
        if (i < buf_len(g_window_manager.rules) - 1) fprintf(rsp, ",");
    }
    fprintf(rsp, "]\n");
}

void window_manager_query_windows_for_spaces(FILE *rsp, uint64_t *space_list, int space_count, uint64_t flags)
{
    TIME_FUNCTION;

    int window_count = 0;
    uint32_t *window_list = space_window_list_for_connection(space_list, space_count, 0, &window_count, true);

    fprintf(rsp, "[");
    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_manager_find_window(&g_window_manager, window_list[i]);
        if (window) window_serialize(rsp, window, flags); else window_nonax_serialize(rsp, window_list[i], flags);
        if (i < window_count - 1) fprintf(rsp, ",");
    }
    fprintf(rsp, "]\n");
}

void window_manager_query_windows_for_display(FILE *rsp, uint32_t did, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    window_manager_query_windows_for_spaces(rsp, space_list, space_count, flags);
}

void window_manager_query_windows_for_displays(FILE *rsp, uint64_t flags)
{
    TIME_FUNCTION;

    int display_count = 0;
    uint32_t *display_list = display_manager_active_display_list(&display_count);

    int space_count = 0;
    uint64_t *space_list = NULL;

    for (int i = 0; i < display_count; ++i) {
        int count;
        uint64_t *list = display_space_list(display_list[i], &count);
        if (!list) continue;

        //
        // NOTE(asmvik): display_space_list(..) uses a linear allocator,
        // and so we only need to track the beginning of the first list along
        // with the total number of spaces that have been allocated.
        //

        if (!space_list) space_list = list;
        space_count += count;
    }

    window_manager_query_windows_for_spaces(rsp, space_list, space_count, flags);
}

bool window_manager_rule_matches_window(struct rule *rule, struct window *window, char *window_title, char *window_role, char *window_subrole)
{
    int regex_match_app = rule_check_flag(rule, RULE_APP_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_APP_VALID), &rule->app_regex, window->application->name) == regex_match_app) return false;

    int regex_match_title = rule_check_flag(rule, RULE_TITLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_TITLE_VALID), &rule->title_regex, window_title) == regex_match_title) return false;

    int regex_match_role = rule_check_flag(rule, RULE_ROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_ROLE_VALID), &rule->role_regex, window_role) == regex_match_role) return false;

    int regex_match_subrole = rule_check_flag(rule, RULE_SUBROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_SUBROLE_VALID), &rule->subrole_regex, window_subrole) == regex_match_subrole) return false;

    return true;
}

void window_manager_apply_manage_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects)
{
    if (effects->manage == RULE_PROP_ON) {
        window_set_rule_flag(window, WINDOW_RULE_MANAGED);
        window_manager_make_window_floating(sm, wm, window, false, true);
    } else if (effects->manage == RULE_PROP_OFF) {
        window_clear_rule_flag(window, WINDOW_RULE_MANAGED);
        window_manager_make_window_floating(sm, wm, window, true, true);
    }
}

void window_manager_apply_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects)
{
    if (effects->sid || effects->did) {
        if (!window_is_fullscreen(window) && !space_is_fullscreen(window_space(window->id))) {
            uint64_t sid = effects->sid ? effects->sid : display_space_id(effects->did);
            window_manager_send_window_to_space(sm, wm, window, sid, true);
            if (rule_effects_check_flag(effects, RULE_FOLLOW_SPACE) || effects->fullscreen == RULE_PROP_ON) {
                space_manager_focus_space(sid);
            }
        }
    }

    if (effects->sticky == RULE_PROP_ON) {
        window_manager_make_window_sticky(sm, wm, window, true);
    } else if (effects->sticky == RULE_PROP_OFF) {
        window_manager_make_window_sticky(sm, wm, window, false);
    }

    if (effects->mff == RULE_PROP_ON) {
        window_set_rule_flag(window, WINDOW_RULE_MFF);
        window_set_rule_flag(window, WINDOW_RULE_MFF_VALUE);
    } else if (effects->mff == RULE_PROP_OFF) {
        window_set_rule_flag(window, WINDOW_RULE_MFF);
        window_clear_rule_flag(window, WINDOW_RULE_MFF_VALUE);
    }

    if (rule_effects_check_flag(effects, RULE_LAYER)) {
        window_manager_set_window_layer(window, effects->layer);
    }

    if (rule_effects_check_flag(effects, RULE_OPACITY) && in_range_ii(effects->opacity, 0.0f, 1.0f)) {
        window->opacity = effects->opacity;
        window_manager_set_opacity(wm, window, effects->opacity);
    }

    if (effects->fullscreen == RULE_PROP_ON) {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanTrue);
        window_set_rule_flag(window, WINDOW_RULE_FULLSCREEN);
    }

    if (effects->scratchpad) {
        char *scratchpad = string_copy(effects->scratchpad);
        if (!window_manager_set_scratchpad_for_window(wm, window, scratchpad)) {
            free(scratchpad);
        }
    }

    if (effects->grid[0] != 0 && effects->grid[1] != 0) {
        window_manager_apply_grid(sm, wm, window, effects->grid[0], effects->grid[1], effects->grid[2], effects->grid[3], effects->grid[4], effects->grid[5]);
    }
}

void window_manager_apply_manage_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules)
{
    bool match = false;
    struct rule_effects effects = {0};

    for (int i = 0; i < buf_len(wm->rules); ++i) {
        if (one_shot_rules || !rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) {
            if (window_manager_rule_matches_window(&wm->rules[i], window, window_title, window_role, window_subrole)) {
                if (wm->rules[i].effects.manage == RULE_PROP_ON) {
                    if (!rule_check_flag(&wm->rules[i], RULE_ROLE_VALID)    && !string_equals(window_role   , "AXWindow"))         continue;
                    if (!rule_check_flag(&wm->rules[i], RULE_SUBROLE_VALID) && !string_equals(window_subrole, "AXStandardWindow")) continue;
                }

                match = true;
                rule_combine_effects(&wm->rules[i].effects, &effects);

                if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) rule_set_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE);
            }
        }
    }

    if (match) window_manager_apply_manage_rule_effects_to_window(sm, wm, window, &effects);
}

void window_manager_apply_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules)
{
    bool match = false;
    struct rule_effects effects = {0};

    for (int i = 0; i < buf_len(wm->rules); ++i) {
        if (one_shot_rules || !rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) {
            if (window_manager_rule_matches_window(&wm->rules[i], window, window_title, window_role, window_subrole)) {
                if (!window_check_rule_flag(window, WINDOW_RULE_MANAGED)) {
                    if (!rule_check_flag(&wm->rules[i], RULE_ROLE_VALID)    && !string_equals(window_role   , "AXWindow"))         continue;
                    if (!rule_check_flag(&wm->rules[i], RULE_SUBROLE_VALID) && !string_equals(window_subrole, "AXStandardWindow")) continue;
                }

                match = true;
                rule_combine_effects(&wm->rules[i].effects, &effects);

                if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) rule_set_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE);
            }
        }
    }

    if (match) window_manager_apply_rule_effects_to_window(sm, wm, window, &effects);
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

static void window_manager_tree_set_view(struct window_manager *wm, struct con *con, struct view *view)
{
    if (con_is_leaf(con)) {
        struct window *window = window_manager_find_window(wm, con->window_id);
        if (!window) return;

        if (window_space(window->id) != view->sid) space_manager_move_window_to_space(view->sid, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_add_managed_window(wm, window, view);
        return;
    }

    for (int i = 0; i < con->child_count; ++i) {
        window_manager_tree_set_view(wm, con->children[i], view);
    }
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
static inline void window_manager_notify_jankyborders(struct window_animation *animation_list, int animation_count, uint32_t event, bool skip, bool wait)
{
    mach_port_t port;
    if (g_bs_port && bootstrap_look_up(g_bs_port, "git.felix.jbevent", &port) == KERN_SUCCESS) {
        struct {
            uint32_t event;
            uint32_t count;
            uint32_t proxy_wid[512];
            uint32_t real_wid[512];
        } data = { event, 0 };

        for (int i = 0; i < animation_count && (int) data.count < array_count(data.proxy_wid); ++i) {
            if (skip && __atomic_load_n(&animation_list[i].skip, __ATOMIC_RELAXED)) continue;

            data.proxy_wid[data.count] = animation_list[i].proxy.id;
            data.real_wid[data.count]  = animation_list[i].wid;

            ++data.count;
        }

        mach_send(port, &data, sizeof(data));
        if (wait) usleep(20000);
    }
}
#pragma clang diagnostic pop

static void window_manager_create_window_proxy(int animation_connection, float alpha, struct window_proxy *proxy)
{
    if (!proxy->image) return;

    CFTypeRef frame_region;
    CGSNewRegionWithRect(&proxy->frame, &frame_region);
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();

    uint64_t tags = 1ULL << 46;
    SLSNewWindowWithOpaqueShapeAndContext(animation_connection, 2, frame_region, empty_region, 13|(1 << 18), &tags, 0, 0, 64, &proxy->id, NULL);
    sls_window_disable_shadow(proxy->id);
    SLSSetWindowOpacity(animation_connection, proxy->id, 0);
    SLSSetWindowResolution(animation_connection, proxy->id, 2.0f);
    SLSSetWindowAlpha(animation_connection, proxy->id, alpha);
    SLSSetWindowLevel(animation_connection, proxy->id, proxy->level);
    SLSSetWindowSubLevel(animation_connection, proxy->id, proxy->sub_level);
    proxy->context = SLWindowContextCreate(animation_connection, proxy->id, 0);

    CGRect frame = { {0, 0}, proxy->frame.size };
    CGContextClearRect(proxy->context, frame);
    CGContextDrawImage(proxy->context, frame, proxy->image);
    CGContextFlush(proxy->context);
    CFRelease(frame_region);
    CFRelease(empty_region);
}

static void window_manager_destroy_window_proxy(int animation_connection, struct window_proxy *proxy)
{
    if (proxy->image) {
        CFRelease(proxy->image);
        proxy->image = NULL;
    }

    if (proxy->context) {
        CGContextRelease(proxy->context);
        proxy->context = NULL;
    }

    if (proxy->id) {
        SLSReleaseWindow(animation_connection, proxy->id);
        proxy->id = 0;
    }
}

static void *window_manager_build_window_proxy_thread_proc(void *data)
{
    struct window_animation *animation = data;

    float alpha = 1.0f;
    SLSGetWindowAlpha(animation->cid, animation->wid, &alpha);
    animation->proxy.level = window_level(animation->wid);
    animation->proxy.sub_level = window_sub_level(animation->wid);
    SLSGetWindowBounds(animation->cid, animation->wid, &animation->proxy.frame);
    animation->proxy.tx = animation->proxy.frame.origin.x;
    animation->proxy.ty = animation->proxy.frame.origin.y;
    animation->proxy.tw = animation->proxy.frame.size.width;
    animation->proxy.th = animation->proxy.frame.size.height;

    CFArrayRef image_array = SLSHWCaptureWindowList(animation->cid, &animation->wid, 1, (1 << 11) | (1 << 8));
    if (image_array) {
        animation->proxy.image = alpha == 1.0f
                               ? (CGImageRef) CFRetain(CFArrayGetValueAtIndex(image_array, 0))
                               : cgimage_restore_alpha((CGImageRef) CFArrayGetValueAtIndex(image_array, 0));
        CFRelease(image_array);
    } else {
        animation->proxy.image = NULL;
    }

    window_manager_create_window_proxy(animation->cid, alpha, &animation->proxy);
    return NULL;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static CVReturn window_manager_animate_window_list_thread_proc(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output_time, CVOptionFlags flags, CVOptionFlags *flags_out, void *data)
{
    struct window_animation_context *context = data;
    int animation_count = context->animation_count;

    uint64_t current_clock = output_time->hostTime;
    if (!context->animation_clock) context->animation_clock = now->hostTime;

    double t = (double)(current_clock - context->animation_clock) / (double)(context->animation_duration * g_cv_host_clock_frequency);
    if (t <= 0.0) t = 0.0f;
    if (t >= 1.0) t = 1.0f;

    float mt;
    switch (context->animation_easing) {
#define ANIMATION_EASING_TYPE_ENTRY(value) case value##_type: mt = value(t); break;
        ANIMATION_EASING_TYPE_LIST
#undef ANIMATION_EASING_TYPE_ENTRY
    }

    //
    // NOTE: A new animation of the same window marks this entry as skipped and destroys its proxy
    // while holding the lock, so the proxy must not be used here without holding it as well.
    //

    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    CFTypeRef transaction = SLSTransactionCreate(context->animation_connection);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;

        context->animation_list[i].proxy.tx = lerp(context->animation_list[i].proxy.frame.origin.x,    mt, context->animation_list[i].x);
        context->animation_list[i].proxy.ty = lerp(context->animation_list[i].proxy.frame.origin.y,    mt, context->animation_list[i].y);
        context->animation_list[i].proxy.tw = lerp(context->animation_list[i].proxy.frame.size.width,  mt, context->animation_list[i].w);
        context->animation_list[i].proxy.th = lerp(context->animation_list[i].proxy.frame.size.height, mt, context->animation_list[i].h);

        CGAffineTransform transform = CGAffineTransformMakeTranslation(-context->animation_list[i].proxy.tx, -context->animation_list[i].proxy.ty);
        CGAffineTransform scale = CGAffineTransformMakeScale(context->animation_list[i].proxy.frame.size.width / context->animation_list[i].proxy.tw, context->animation_list[i].proxy.frame.size.height / context->animation_list[i].proxy.th);
        SLSTransactionSetWindowTransform(transaction, context->animation_list[i].proxy.id, 0, 0, CGAffineTransformConcat(transform, scale));

        float alpha = 0.0f;
        SLSGetWindowAlpha(context->animation_connection, context->animation_list[i].wid, &alpha);
        if (alpha != 0.0f) SLSTransactionSetWindowAlpha(transaction, context->animation_list[i].proxy.id, alpha);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
    if (t != 1.0f) {
        pthread_mutex_unlock(&g_window_manager.window_animations_lock);
        goto out;
    }

    SLSDisableUpdate(context->animation_connection);
    window_manager_notify_jankyborders(context->animation_list, context->animation_count, 1326, true, true);
    scripting_addition_swap_window_proxy_out(context->animation_list, context->animation_count);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;

        table_remove(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
        window_manager_destroy_window_proxy(context->animation_connection, &context->animation_list[i].proxy);

    }
    SLSReenableUpdate(context->animation_connection);
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);

    SLSReleaseConnection(context->animation_connection);
    free(context->animation_list);
    free(context);

    CVDisplayLinkStop(link);
    CVDisplayLinkRelease(link);

out:
    return kCVReturnSuccess;
}
#pragma clang diagnostic pop

void window_manager_animate_window_list_async(struct window_capture *window_list, int window_count)
{
    struct window_animation_context *context = malloc(sizeof(struct window_animation_context));

    SLSNewConnection(0, &context->animation_connection);
    context->animation_count    = window_count;
    context->animation_list     = malloc(window_count * sizeof(struct window_animation));
    context->animation_duration = g_window_manager.window_animation_duration;
    context->animation_easing   = g_window_manager.window_animation_easing;
    context->animation_clock    = 0;

    int thread_count = 0;
    pthread_t *threads = ts_alloc_list(pthread_t, window_count);

    TIME_BODY(window_manager_animate_window_list_async___prep_proxies, {
    SLSDisableUpdate(context->animation_connection);
    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    for (int i = 0; i < window_count; ++i) {
        context->animation_list[i].window = window_list[i].window;
        context->animation_list[i].wid    = window_list[i].window->id;
        context->animation_list[i].x      = window_list[i].x;
        context->animation_list[i].y      = window_list[i].y;
        context->animation_list[i].w      = window_list[i].w;
        context->animation_list[i].h      = window_list[i].h;
        context->animation_list[i].cid    = context->animation_connection;
        context->animation_list[i].skip   = false;
        memset(&context->animation_list[i].proxy, 0, sizeof(struct window_proxy));

        struct window_animation *existing_animation = table_find(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
        if (existing_animation) {
            __atomic_store_n(&existing_animation->skip, true, __ATOMIC_RELEASE);

            context->animation_list[i].proxy.frame.origin.x    = (int)(existing_animation->proxy.tx);
            context->animation_list[i].proxy.frame.origin.y    = (int)(existing_animation->proxy.ty);
            context->animation_list[i].proxy.frame.size.width  = (int)(existing_animation->proxy.tw);
            context->animation_list[i].proxy.frame.size.height = (int)(existing_animation->proxy.th);
            context->animation_list[i].proxy.tx                = (int)(existing_animation->proxy.tx);
            context->animation_list[i].proxy.ty                = (int)(existing_animation->proxy.ty);
            context->animation_list[i].proxy.tw                = (int)(existing_animation->proxy.tw);
            context->animation_list[i].proxy.th                = (int)(existing_animation->proxy.th);
            context->animation_list[i].proxy.level             = existing_animation->proxy.level;
            context->animation_list[i].proxy.sub_level         = existing_animation->proxy.sub_level;
            context->animation_list[i].proxy.image             = existing_animation->proxy.image
                                                               ? (CGImageRef) CFRetain(existing_animation->proxy.image)
                                                               : NULL;
            __asm__ __volatile__ ("" ::: "memory");

            float alpha = 1.0f;
            SLSGetWindowAlpha(context->animation_connection, context->animation_list[i].wid, &alpha);
            window_manager_create_window_proxy(context->animation_connection, alpha, &context->animation_list[i].proxy);
            window_manager_notify_jankyborders(&context->animation_list[i], 1, 1325, true, false);
            window_manager_notify_jankyborders(existing_animation, 1, 1326, false, false);

            CFTypeRef transaction = SLSTransactionCreate(context->animation_connection);
            SLSTransactionOrderWindowGroup(transaction, context->animation_list[i].proxy.id, 1, context->animation_list[i].wid);
            SLSTransactionSetWindowSystemAlpha(transaction, existing_animation->proxy.id, 0);
            SLSTransactionCommit(transaction, 0);
            CFRelease(transaction);

            table_remove(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
            window_manager_destroy_window_proxy(existing_animation->cid, &existing_animation->proxy);
        } else {
            pthread_t thread;
            if (pthread_create(&thread, NULL, &window_manager_build_window_proxy_thread_proc, &context->animation_list[i]) == 0) {
                threads[thread_count++] = thread;
            } else {
                window_manager_build_window_proxy_thread_proc(&context->animation_list[i]);
            }
        }

        table_add(&g_window_manager.window_animations_table, &context->animation_list[i].wid, &context->animation_list[i]);
    }
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);
    });

    TIME_BODY(window_manager_animate_window_list_async___wait_for_threads, {
    for (int i = 0; i < thread_count; ++i) {
        pthread_join(threads[i], NULL);
    }
    });

    TIME_BODY(window_manager_animate_window_list_async___swap_proxy_in, {
    scripting_addition_swap_window_proxy_in(context->animation_list, context->animation_count);
    });

    TIME_BODY(window_manager_animate_window_list_async___notify_jb, {
    window_manager_notify_jankyborders(context->animation_list, context->animation_count, 1325, true, false);
    });

    TIME_BODY(window_manager_animate_window_list_async___set_frame, {
    window_manager_set_window_frames(window_list, window_count);
    });

    CVDisplayLinkRef link;
    SLSReenableUpdate(context->animation_connection);
    CVDisplayLinkCreateWithActiveCGDisplays(&link);
    CVDisplayLinkSetOutputCallback(link, window_manager_animate_window_list_thread_proc, context);
    CVDisplayLinkStart(link);
}

//
// NOTE(asmvik): Attempting to check the window frame cache to prevent unnecessary movement and resize calls to the AX API
// is not reliable because it is possible to perform operations that should be applied, at a higher rate than the AX API events
// are received, causing our cache to become out of date and incorrectly guard against some changes that **should** be applied.
// This causes the window layout to **not** be modified the way we expect.
//
// A possible solution is to use the faster CG window notifications, as they are **a lot** more responsive, and can be used to
// track changes to the window frame in real-time without delay.
//
// NOTE: We therefore compare against the bounds of the window server instead, which change as soon as the window is moved,
// and against the frame we requested last. The window is only skipped when both match the target. If an application has not
// yet applied a previous request, the request differs from the target and the frame is set again.
//

static inline bool window_frame_is_close(CGRect frame, float x, float y, float w, float h)
{
    return fabsf((float) frame.origin.x    - x) < 1.0f &&
           fabsf((float) frame.origin.y    - y) < 1.0f &&
           fabsf((float) frame.size.width  - w) < 1.0f &&
           fabsf((float) frame.size.height - h) < 1.0f;
}

static bool window_manager_window_frame_needs_update(struct window *window, float x, float y, float w, float h)
{
    if (!window_frame_is_close(window->frame_request, x, y, w, h)) return true;

    CGRect bounds;
    if (SLSGetWindowBounds(g_connection, window->id, &bounds) != kCGErrorSuccess) return true;

    return !window_frame_is_close(bounds, x, y, w, h);
}

static int window_manager_filter_window_frames(struct window_capture *window_list, int window_count)
{
    int update_count = 0;

    for (int i = 0; i < window_count; ++i) {
        struct window_capture capture = window_list[i];
        if (window_manager_window_frame_needs_update(capture.window, capture.x, capture.y, capture.w, capture.h)) {
            window_list[update_count++] = capture;
        }
    }

    return update_count;
}

void window_manager_animate_window_list(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;

    window_count = window_manager_filter_window_frames(window_list, window_count);
    if (!window_count) return;

    if (g_window_manager.window_animation_duration) {
        window_manager_animate_window_list_async(window_list, window_count);
    } else {
        window_manager_set_window_frames(window_list, window_count);
    }
}

void window_manager_animate_window(struct window_capture capture)
{
    TIME_FUNCTION;

    if (!window_manager_window_frame_needs_update(capture.window, capture.x, capture.y, capture.w, capture.h)) return;

    if (g_window_manager.window_animation_duration) {
        window_manager_animate_window_list_async(&capture, 1);
    } else {
        window_manager_set_window_frame(capture.window, capture.x, capture.y, capture.w, capture.h);
    }
}

static AXError window_manager_set_window_frame_ax(AXUIElementRef ref, CGPoint position, CGSize size)
{
    AXError result = kAXErrorSuccess;

    CFTypeRef position_ref = AXValueCreate(kAXValueTypeCGPoint, (void *) &position);
    CFTypeRef size_ref = AXValueCreate(kAXValueTypeCGSize, (void *) &size);

    //
    // NOTE: An application that does not respond makes every call wait for the messaging timeout,
    // so the remaining calls are skipped once one of them could not complete.
    //

    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.
    if (size_ref) result = AXUIElementSetAttributeValue(ref, kAXSizeAttribute, size_ref);

    if (position_ref && result != kAXErrorCannotComplete) {
        result = AXUIElementSetAttributeValue(ref, kAXPositionAttribute, position_ref);
    }

    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
    if (size_ref && result != kAXErrorCannotComplete) {
        result = AXUIElementSetAttributeValue(ref, kAXSizeAttribute, size_ref);
    }

    if (position_ref) CFRelease(position_ref);
    if (size_ref) CFRelease(size_ref);

    return result;
}

void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height)
{
    window->frame_request = CGRectMake(x, y, width, height);

    AX_ENHANCED_UI_WORKAROUND(window->application->ref, {
        window_manager_set_window_frame_ax(window->ref, CGPointMake(x, y), CGSizeMake(width, height));
    });
}

//
// NOTE: The frames of a batch are set per application. AXEnhancedUserInterface is turned off once for
// each application instead of once for each window, and the applications are handled concurrently, so
// that an application that is slow to respond does not delay the windows of all other applications.
// The groups are built on the event loop thread; the worker threads only read the AX references of their
// own group and write its result, and must not touch the ts arena, tables or other global state.
//

int window_manager_group_window_frames(struct window_capture *window_list, int window_count, struct window_frame_group *group_list, struct window_frame_request *request_list)
{
    int group_count = 0;
    int *group_index = ts_alloc_list(int, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct application *application = window_list[i].window->application;

        int group = 0;
        while (group < group_count && group_list[group].application != application) ++group;

        if (group == group_count) {
            group_list[group_count++] = (struct window_frame_group) { .application = application, .error = kAXErrorSuccess };
        }

        group_index[i] = group;
        ++group_list[group].count;
    }

    int offset = 0;
    for (int i = 0; i < group_count; ++i) {
        group_list[i].list = request_list + offset;
        offset += group_list[i].count;
        group_list[i].count = 0;
    }

    for (int i = 0; i < window_count; ++i) {
        struct window_frame_group *group = &group_list[group_index[i]];
        group->list[group->count++] = (struct window_frame_request) {
            .ref = window_list[i].window->ref,
            .position = CGPointMake(window_list[i].x, window_list[i].y),
            .size = CGSizeMake(window_list[i].w, window_list[i].h)
        };
    }

    return group_count;
}

static void window_manager_apply_window_frame_group(struct window_frame_group *group)
{
    AXUIElementRef application_ref = group->application->ref;

    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(application_ref, kAXEnhancedUserInterface, &value);
    if (result == kAXErrorCannotComplete) {
        group->error = result;
        return;
    }

    bool eui = false;
    if (value) {
        eui = CFBooleanGetValue(value);
        CFRelease(value);
    }

    if (eui) AXUIElementSetAttributeValue(application_ref, kAXEnhancedUserInterface, kCFBooleanFalse);

    for (int i = 0; i < group->count; ++i) {
        result = window_manager_set_window_frame_ax(group->list[i].ref, group->list[i].position, group->list[i].size);
        if (result == kAXErrorCannotComplete) {
            group->error = result;
            break;
        }
    }

    if (eui) AXUIElementSetAttributeValue(application_ref, kAXEnhancedUserInterface, kCFBooleanTrue);
}

void window_manager_set_window_frames(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;

    if (window_count <= 0) return;

    for (int i = 0; i < window_count; ++i) {
        window_list[i].window->frame_request = CGRectMake(window_list[i].x, window_list[i].y, window_list[i].w, window_list[i].h);
    }

    struct window_frame_group *group_list = ts_alloc_list(struct window_frame_group, window_count);
    struct window_frame_request *request_list = ts_alloc_list(struct window_frame_request, window_count);
    int group_count = window_manager_group_window_frames(window_list, window_count, group_list, request_list);

    if (group_count == 1) {
        window_manager_apply_window_frame_group(&group_list[0]);
    } else {
        dispatch_apply(group_count, DISPATCH_APPLY_AUTO, ^(size_t i) {
            window_manager_apply_window_frame_group(&group_list[i]);
        });
    }

    for (int i = 0; i < group_count; ++i) {
        if (group_list[i].error == kAXErrorCannotComplete) {
            debug("%s: %s did not respond, %d window(s) may not have been moved\n", __FUNCTION__, group_list[i].application->name, group_list[i].count);
        }
    }
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
    CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list, window_count);
    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);

    int relation_count = 0;
    uint32_t parent_list[window_count];
    uint32_t child_list[window_count];

    while (SLSWindowIteratorAdvance(iterator)) {
        parent_list[relation_count] = SLSWindowIteratorGetParentID(iterator);
        child_list[relation_count] = SLSWindowIteratorGetWindowID(iterator);
        ++relation_count;
    }

    int check_count = 1;
    uint32_t check_list[window_count];
    check_list[0] = window->id;

    for (int i = 0; i < check_count; ++i) {
        for (int j = 0; j < window_count; ++j) {
            if (parent_list[j] != check_list[i]) continue;
            scripting_addition_set_layer(child_list[j], child_layer);
            check_list[check_count++] = child_list[j];
        }
    }

    CFRelease(query);
    CFRelease(iterator);
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

int window_manager_find_rank_of_window_in_list(uint32_t wid, uint32_t *window_list, int window_count)
{
    for (int i = 0, rank = 0; i < window_count; ++i) {
        if (window_list[i] == wid) {
            return rank;
        } else {
            ++rank;
        }
    }

    return INT_MAX;
}

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

static inline bool window_manager_window_connection_is_jankyborders(int window_cid)
{
    static char process_name[PROC_PIDPATHINFO_MAXSIZE];

    pid_t window_pid = 0;
    SLSConnectionGetPID(window_cid, &window_pid);
    proc_name(window_pid, process_name, sizeof(process_name));

    return strcmp(process_name, "borders") == 0;
}

struct window *window_manager_find_window_at_point_filtering_window(struct window_manager *wm, CGPoint point, uint32_t filter_wid)
{
    CGPoint window_point;
    uint32_t window_id;
    int window_cid;

    SLSFindWindowAndOwner(g_connection, filter_wid, -1, 0, &point, &window_point, &window_id, &window_cid);
    if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);

    if (window_manager_window_connection_is_jankyborders(window_cid)) {
        SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
        if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
    }

    return window_manager_find_window(wm, window_id);
}

struct window *window_manager_find_window_at_point(struct window_manager *wm, CGPoint point)
{
    CGPoint window_point;
    uint32_t window_id;
    int window_cid;

    SLSFindWindowAndOwner(g_connection, 0, 1, 0, &point, &window_point, &window_id, &window_cid);
    if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);

    if (window_manager_window_connection_is_jankyborders(window_cid)) {
        SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
        if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
    }

    return window_manager_find_window(wm, window_id);
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

static void window_manager_make_key_window(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    //
    // :SynthesizedEvent
    //
    // NOTE(asmvik): These events will be picked up by an event-tap
    // registered at the "Annotated Session" location; specifying that an
    // event-tap is placed at the point where session events have been
    // annotated to flow to an application.
    //

    memset(g_event_bytes, 0, 0xf8);
    g_event_bytes[0x04] = 0xf8;
    g_event_bytes[0x3a] = 0x10;
    memcpy(g_event_bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(g_event_bytes + 0x20, 0xff, 0x10);

    g_event_bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(window_psn, g_event_bytes);

    g_event_bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(window_psn, g_event_bytes);
}

void window_manager_focus_window_without_raise(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    TIME_FUNCTION;

    if (psn_equals(window_psn, &g_window_manager.focused_window_psn)) {
        memset(g_event_bytes, 0, 0xf8);
        g_event_bytes[0x04] = 0xf8;
        g_event_bytes[0x08] = 0x0d;

        g_event_bytes[0x8a] = 0x02;
        memcpy(g_event_bytes + 0x3c, &g_window_manager.focused_window_id, sizeof(uint32_t));
        SLPSPostEventRecordTo(&g_window_manager.focused_window_psn, g_event_bytes);

        //
        // @hack
        // Artificially delay the activation by 40ms. This is necessary
        // because some applications appear to be confused if both of
        // the events appear instantaneously.
        //
        // NOTE: The activation is posted back to the event loop instead of sleeping,
        // so that the event loop keeps handling events in the meantime.
        //

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            event_loop_post(&g_event_loop, WINDOW_FOCUS_DEFERRED, (void *)(intptr_t) window_id, 0);
        });

        return;
    }

    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
}

void window_manager_focus_window_without_raise_deferred(struct window *window)
{
    memset(g_event_bytes, 0, 0xf8);
    g_event_bytes[0x04] = 0xf8;
    g_event_bytes[0x08] = 0x0d;

    g_event_bytes[0x8a] = 0x01;
    memcpy(g_event_bytes + 0x3c, &window->id, sizeof(uint32_t));
    SLPSPostEventRecordTo(&window->application->psn, g_event_bytes);

    _SLPSSetFrontProcessWithOptions(&window->application->psn, window->id, kCPSUserGenerated);
    window_manager_make_key_window(&window->application->psn, window->id);
}

void window_manager_focus_window_with_raise(ProcessSerialNumber *window_psn, uint32_t window_id, AXUIElementRef window_ref)
{
    TIME_FUNCTION;

#if 1
    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
    AXUIElementPerformAction(window_ref, kAXRaiseAction);
#else
    scripting_addition_focus_window(window_id);
#endif
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
struct application *window_manager_focused_application(struct window_manager *wm)
{
    TIME_FUNCTION;

    ProcessSerialNumber psn = {0};
    _SLPSGetFrontProcess(&psn);

    pid_t pid;
    GetProcessPID(&psn, &pid);

    return window_manager_find_application(wm, pid);
}

struct window *window_manager_focused_window(struct window_manager *wm)
{
    TIME_FUNCTION;

    struct application *application = window_manager_focused_application(wm);
    if (!application) return NULL;

    uint32_t window_id = application_focused_window(application);
    return window_manager_find_window(wm, window_id);
}

//
// NOTE: A window focused by a command only reports its focus once the application has processed the
// activation, which can take longer than it takes to send the next command. Until then, the next command
// acts on the window that was asked to be focused, instead of the one the application still reports.
//

#define PENDING_FOCUS_TIMEOUT_MS 500.0f

void window_manager_set_pending_focus(struct window_manager *wm, uint32_t window_id)
{
    wm->pending_focus_window_id = window_id;
    wm->pending_focus_time = read_os_timer();
}

struct window *window_manager_acting_window(struct window_manager *wm)
{
    TIME_FUNCTION;

    if (wm->pending_focus_window_id) {
        float dt = ((float) read_os_timer() - wm->pending_focus_time) * (1000.0f / (float) read_os_freq());
        struct window *window = dt < PENDING_FOCUS_TIMEOUT_MS ? window_manager_find_window(wm, wm->pending_focus_window_id) : NULL;
        if (window) return window;

        wm->pending_focus_window_id = 0;
    }

    return window_manager_focused_window(wm);
}
#pragma clang diagnostic pop

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

struct window *window_manager_create_and_add_window(struct space_manager *sm, struct window_manager *wm, struct application *application, AXUIElementRef window_ref, uint32_t window_id, bool one_shot_rules)
{
    struct window *window = window_create(application, window_ref, window_id);

    char *window_title = window_title_ts(window);
    char *window_role = window_role_ts(window);
    char *window_subrole = window_subrole_ts(window);
    debug("%s:%d %s - %s (%s:%s:%d)\n", __FUNCTION__, window->id, window->application->name, window_title, window_role, window_subrole, window->is_root);

    if (window_is_unknown(window)) {
        debug("%s: ignoring AXUnknown window %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_manager_remove_lost_focused_event(wm, window->id);
        window_destroy(window);
        return NULL;
    }

    //
    // NOTE(asmvik): Attempt to track **all** windows.
    //

    if (!window_observe(window)) {
        debug("%s: could not observe %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_manager_remove_lost_focused_event(wm, window->id);
        window_unobserve(window);
        window_destroy(window);
        return NULL;
    }

    if (window_manager_find_lost_focused_event(wm, window->id)) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
        window_manager_remove_lost_focused_event(wm, window->id);
    }

    window_manager_add_window(wm, window);

    //
    // NOTE(asmvik): However, only **root windows** are eligible for management.
    //

    if (window->is_root) {

        //
        // NOTE(asmvik): A lot of windows misreport their accessibility role, so we allow the user
        // to specify rules to make sure that we do in fact manage these windows properly.
        //
        // This part of the rule must be applied at this stage (prior to other rule properties), and if
        // no such rule matches this window, it will be ignored if it does not have a role of kAXWindowRole.
        //

        window_manager_apply_manage_rules_to_window(sm, wm, window, window_title, window_role, window_subrole, one_shot_rules);

        if (window_manager_is_window_eligible(window)) {
            window->is_eligible = true;
            window_manager_apply_rules_to_window(sm, wm, window, window_title, window_role, window_subrole, one_shot_rules);
            window_manager_purify_window(wm, window);
            window_manager_set_window_opacity(wm, window, wm->normal_window_opacity);

            if (application->is_hidden)                              goto out;
            if (window_check_flag(window, WINDOW_MINIMIZE))          goto out;
            if (window_check_flag(window, WINDOW_FULLSCREEN))        goto out;
            if (window_check_rule_flag(window, WINDOW_RULE_MANAGED)) goto out;

            if (window_check_rule_flag(window, WINDOW_RULE_FULLSCREEN)) {
                window_clear_rule_flag(window, WINDOW_RULE_FULLSCREEN);
                goto out;
            }

            if (window_is_sticky(window->id) ||
                !window_can_move(window) ||
                !window_is_standard(window) ||
                !window_level_is_standard(window) ||
                (!window_can_resize(window) && window_is_undersized(window))) {
                window_set_flag(window, WINDOW_FLOAT);
            }
        } else {
            debug("%s ignoring incorrectly marked window %s %d\n", __FUNCTION__, window->application->name, window->id);
            window_set_flag(window, WINDOW_FLOAT);

            //
            // NOTE(asmvik): Print window information when debug_output is enabled.
            // Useful for identifying and creating rules if this window should in fact be managed.
            //

            if (g_verbose) {
                fprintf(stdout, "window info: \n");
                window_serialize(stdout, window, 0);
                fprintf(stdout, "\n");
            }
        }
    } else {
        debug("%s ignoring child window %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_set_flag(window, WINDOW_FLOAT);

        //
        // NOTE(asmvik): Print window information when debug_output is enabled.
        //

        if (g_verbose) {
            fprintf(stdout, "window info: \n");
            window_serialize(stdout, window, 0);
            fprintf(stdout, "\n");
        }
    }

out:
    return window;
}

struct window **window_manager_add_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int *count)
{
    *count = 0;
    CFArrayRef window_list = application_window_list(application);
    if (!window_list) return NULL;

    int window_count = CFArrayGetCount(window_list);
    struct window **list = ts_alloc_list(struct window *, window_count);

    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list, i);

        uint32_t window_id = ax_window_id(window_ref);
        if (!window_id || window_manager_find_window(wm, window_id)) continue;

        struct window *window = window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), window_id, true);
        if (window) list[(*count)++] = window;
    }

    int rule_len = buf_len(wm->rules);
    for (int i = 0; i < rule_len; ++i) {
        if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE)) {
            rule_destroy(&wm->rules[i]);
            if (buf_del(wm->rules, i)) {
                --i;
                --rule_len;
            }
        }
    }

    CFRelease(window_list);
    return list;
}

static uint32_t *window_manager_existing_application_window_list(struct application *application, int *window_count)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return NULL;

    int space_count = 0;
    uint64_t *space_list = NULL;

    for (int i = 0; i < display_count; ++i) {
        int count;
        uint64_t *list = display_space_list(display_list[i], &count);
        if (!list) continue;

        //
        // NOTE(asmvik): display_space_list(..) uses a linear allocator,
        // and so we only need to track the beginning of the first list along
        // with the total number of windows that have been allocated.
        //

        if (!space_list) space_list = list;
        space_count += count;
    }

    return space_list ? space_window_list_for_connection(space_list, space_count, application ? application->connection : 0, window_count, true) : NULL;
}

bool window_manager_add_existing_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int refresh_index)
{
    bool result = false;

    int global_window_count;
    uint32_t *global_window_list = window_manager_existing_application_window_list(application, &global_window_count);
    if (!global_window_list) return result;

    CFArrayRef window_list_ref = application_window_list(application);
    int window_count = window_list_ref ? CFArrayGetCount(window_list_ref) : 0;

    int empty_count = 0;
    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list_ref, i);
        uint32_t window_id = ax_window_id(window_ref);

        //
        // @cleanup
        //
        // :Workaround
        //
        // NOTE(asmvik): The AX API appears to always include a single element for Finder that returns an empty window id.
        // This is likely the desktop window. Other similar cases should be handled the same way; simply ignore the window when
        // we attempt to do an equality check to see if we have correctly discovered the number of windows to track.
        //

        if (!window_id) {
            ++empty_count;
            continue;
        }

        if (!window_manager_find_window(wm, window_id)) {
            window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), window_id, false);
        }
    }

    if (global_window_count != window_count-empty_count) {
        if (refresh_index == -1) {
            bool missing_window = false;
            uint32_t *app_window_list = NULL;

            for (int i = 0; i < global_window_count; ++i) {
                struct window *window = window_manager_find_window(wm, global_window_list[i]);
                if (!window) {
                    missing_window = true;
                    ts_buf_push(app_window_list, global_window_list[i]);
                }
            }

            if (missing_window) {
                debug("%s: %s has %d windows that are not yet resolved, attempting workaround\n", __FUNCTION__, application->name, ts_buf_len(app_window_list));

                //
                // NOTE(asmvik): MacOS API does not return AXUIElementRef of windows on inactive spaces.
                // However, we can just brute-force the element_id and create the AXUIElementRef ourselves.
                //
                // :Attribution
                // https://github.com/decodism
                // https://github.com/lwouis/alt-tab-macos/issues/1324#issuecomment-2631035482
                //

                CFMutableDataRef data_ref = CFDataCreateMutable(NULL, 0x14);
                CFDataIncreaseLength(data_ref, 0x14);

                uint8_t *data = CFDataGetMutableBytePtr(data_ref);
                *(uint32_t *) (data + 0x0) = application->pid;
                *(uint32_t *) (data + 0x8) = 0x636f636f;

                for (uint64_t element_id = 0; element_id < 0x7fff; ++element_id) {
                    int app_window_list_len = ts_buf_len(app_window_list);
                    if (app_window_list_len == 0) break;

                    memcpy(data+0xc, &element_id, sizeof(uint64_t));
                    AXUIElementRef element_ref = _AXUIElementCreateWithRemoteToken(data_ref);

                    if (!element_ref) continue;

                    const void *role = NULL;
                    AXError error = AXUIElementCopyAttributeValue(element_ref, kAXRoleAttribute, &role);

                    //
                    // NOTE: An application that does not respond makes every attempt wait for the
                    // messaging timeout, so give up on it instead of trying all element ids.
                    //

                    if (error == kAXErrorCannotComplete) {
                        CFRelease(element_ref);
                        break;
                    }

                    bool consumed = false;

                    if (role) {
                        if (CFEqual(role, kAXWindowRole)) {
                            uint32_t element_wid = ax_window_id(element_ref);
                            bool matched = false;

                            if (element_wid != 0) {
                                for (int i = 0; i < app_window_list_len; ++i) {
                                    if (app_window_list[i] == element_wid) {
                                        matched = true;
                                        ts_buf_del(app_window_list, i);
                                        break;
                                    }
                                }
                            }

                            if (matched) {
                                window_manager_create_and_add_window(sm, wm, application, element_ref, element_wid, false);
                                consumed = true;
                            }
                        }

                        CFRelease(role);
                    }

                    if (!consumed) CFRelease(element_ref);
                }

                CFRelease(data_ref);
            }

            if (ts_buf_len(app_window_list) > 0) {
                debug("%s: workaround failed to resolve all windows for %s\n", __FUNCTION__, application->name);
                buf_push(wm->applications_to_refresh, application);
            } else {
                debug("%s: workaround resolved all windows for %s\n", __FUNCTION__, application->name);
            }
        } else {
            bool missing_window = false;

            for (int i = 0; i < global_window_count; ++i) {
                struct window *window = window_manager_find_window(wm, global_window_list[i]);
                if (!window) {
                    missing_window = true;
                    break;
                }
            }

            if (!missing_window) {
                debug("%s: all windows for %s are now resolved\n", __FUNCTION__, application->name);
                buf_del(wm->applications_to_refresh, refresh_index);
                result = true;
            }
        }
    } else if (refresh_index != -1) {
        debug("%s: all windows for %s are now resolved\n", __FUNCTION__, application->name);
        buf_del(wm->applications_to_refresh, refresh_index);
        result = true;
    }

    if (window_list_ref) CFRelease(window_list_ref);

    return result;
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
        space_manager_untile_window(b_view, b);
        window_manager_remove_managed_window(wm, b->id);
        window_manager_purify_window(wm, b);
    } else if (window_check_flag(b, WINDOW_FLOAT)) {
        if (!window_manager_is_window_eligible(b)) return WINDOW_OP_ERROR_INVALID_SRC_NODE;
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
        window_manager_tree_set_view(wm, a_con, b_view);
        window_manager_tree_set_view(wm, b_con, a_view);
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
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_purify_window(wm, window);
    }

    space_manager_move_window_to_space(dst_sid, window);
    space_manager_wait_for_window_on_space(window->id, dst_sid, 200);
    SLSSpaceSetFrontPSN(g_connection, dst_sid, window->application->psn);

    if (window_manager_should_manage_window(window)) {
        struct view *view = space_manager_tile_window_on_space(sm, window, dst_sid);
        window_manager_add_managed_window(wm, window, view);
    }
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
            space_manager_untile_window(view, window);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);
        }
        window_set_flag(window, WINDOW_FLOAT);
    } else {
        window_clear_flag(window, WINDOW_FLOAT);

        if (!window_check_flag(window, WINDOW_STICKY)) {
            if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                struct view *view = space_manager_tile_window_on_space(sm, window, space_manager_active_space());
                window_manager_add_managed_window(wm, window, view);
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
                space_manager_untile_window(view, window);
                window_manager_remove_managed_window(wm, window->id);
                window_manager_purify_window(wm, window);
            }
            window_set_flag(window, WINDOW_STICKY);
        }
    } else {
        if (scripting_addition_set_sticky(window->id, false)) {
            window_clear_flag(window, WINDOW_STICKY);

            if (!window_check_flag(window, WINDOW_FLOAT)) {
                if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                    struct view *view = space_manager_tile_window_on_space(sm, window, space_manager_active_space());
                    window_manager_add_managed_window(wm, window, view);
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

void window_manager_wait_for_native_fullscreen_transition(struct window *window)
{
    TIME_FUNCTION;

    if (workspace_is_macos_monterey() ||
        workspace_is_macos_ventura() ||
        workspace_is_macos_sonoma() ||
        workspace_is_macos_sequoia() ||
        workspace_is_macos_tahoe()) {
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
    } else {
        uint32_t did = window_display_id(window->id);
        int i = 0;

        do {

            //
            // NOTE(asmvik): Window has exited native-fullscreen mode.
            // We need to spin lock until the display is finished animating
            // because we are not actually able to interact with the window.
            //

            usleep(100000);
        } while (display_manager_display_is_animating(did) && ++i < NATIVE_FULLSCREEN_WAIT_ITERATIONS);
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

    window_manager_wait_for_native_fullscreen_transition(window);
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
    return window ? window_manager_toggle_scratchpad_window(wm, window, 0) : false;
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

bool window_manager_toggle_scratchpad_window(struct window_manager *wm, struct window *window, int forced_mode)
{
    TIME_FUNCTION;

    uint64_t sid = space_manager_active_space();
    if (!sid) return false;

    // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
    bool visible_space = window_space(window->id) == sid || window_is_sticky(window->id);

    uint8_t ordered_in = 0;
    SLSWindowIsOrderedIn(g_connection, window->id, &ordered_in);

    //
    // NOTE: The scratchpad_* config options only apply when toggling
    // by label (forced_mode 0), not when a window stops being a scratchpad.
    //

    bool by_label = forced_mode == 0;
    bool shown = true;

    switch (forced_mode) {
    case 0: goto mode_0;
    case 1: goto mode_1;
    case 2: goto mode_2;
    case 3: goto mode_3;
    }

mode_0:;
    if (visible_space && ordered_in) {
        if (wm->scratchpad_raise && wm->focused_window_id != window->id && !window_check_flag(window, WINDOW_MINIMIZE) && !window->application->is_hidden) {
            window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
            goto out;
        }
mode_1:;
        shown = false;
        struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(wm, sid, 1, window->id);
        if (next) {
            window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
        } else {
            _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
        }
        scripting_addition_order_window(window->id, 0, 0);
    } else if (visible_space && !ordered_in) {
mode_2:;
        if (by_label) window_manager_apply_scratchpad_grid(wm, window);
        scripting_addition_order_window(window->id, 1, 0);
        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    } else {
mode_3:;
        space_manager_move_window_to_space(sid, window);
        space_manager_wait_for_window_on_space(window->id, sid, 200);

        if (by_label && !ordered_in) window_manager_apply_scratchpad_grid(wm, window);
        scripting_addition_order_window(window->id, 1, 0);
        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    }

out:
    if (by_label && shown && wm->scratchpad_exclusive) {
        window_manager_hide_other_scratchpad_windows(wm, window);
    }

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

bool window_manager_remove_scratchpad_for_window(struct window_manager *wm, struct window *window, bool unfloat)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        if (wm->scratchpad_window[i].window == window) {
            window->scratchpad = NULL;

            free(wm->scratchpad_window[i].label);
            buf_del(wm->scratchpad_window, i);

            if (unfloat) {
                window_manager_toggle_scratchpad_window(wm, window, 3);
                if (wm->scratchpad_below) window_manager_adjust_layer(window, LAYER_NORMAL);
                window_manager_make_window_floating(&g_space_manager, wm, window, false, false);
            }

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
            workspace_application_observe_activation_policy(g_workspace_context, process);
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
        window_manager_tree_set_view(wm, con, dst_view);
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
    //

    bool was_focused = window->id == wm->focused_window_id;
    if (!was_focused && window->id == wm->last_window_id) {
        struct window *focused = window_manager_find_window(wm, wm->focused_window_id);
        was_focused = focused && window_manager_find_tree_view(wm, focused) == view;
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
