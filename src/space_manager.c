extern struct window_manager g_window_manager;
extern int g_connection;
extern volatile bool __pending_window_focus;

static TABLE_HASH_FUNC(hash_view)
{
    return *(uint64_t *) key;
}

static TABLE_COMPARE_FUNC(compare_view)
{
    return *(uint64_t *) key_a == *(uint64_t *) key_b;
}

bool space_manager_query_space(FILE *rsp, uint64_t sid, uint64_t flags)
{
    TIME_FUNCTION;

    struct view *view = space_manager_query_view(&g_space_manager, sid);
    if (!view) return false;

    view_serialize(rsp, view, flags);
    fprintf(rsp, "\n");
    return true;
}

//
// NOTE: Spaces that have no view are left out, so the separators are written before each element.
//

static void space_manager_query_space_list(FILE *rsp, uint64_t *space_list, int space_count, uint64_t flags)
{
    char *separator = "";

    fprintf(rsp, "[");
    for (int i = 0; i < space_count; ++i) {
        struct view *view = space_manager_query_view(&g_space_manager, space_list[i]);
        if (!view) continue;

        fprintf(rsp, "%s", separator);
        view_serialize(rsp, view, flags);
        separator = ",";
    }
    fprintf(rsp, "]\n");
}

bool space_manager_query_spaces_for_window(FILE *rsp, struct window *window, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count;
    uint64_t *space_list = window_space_list(window->id, &space_count);
    if (!space_list) return false;

    space_manager_query_space_list(rsp, space_list, space_count, flags);
    return true;
}

bool space_manager_query_spaces_for_display(FILE *rsp, uint32_t did, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return false;

    space_manager_query_space_list(rsp, space_list, space_count, flags);
    return true;
}

bool space_manager_query_spaces_for_displays(FILE *rsp, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    if (!space_list) return false;

    space_manager_query_space_list(rsp, space_list, space_count, flags);
    return true;
}

struct view *space_manager_query_view(struct space_manager *sm, uint64_t sid)
{
    if (sm->did_begin) return space_manager_find_view(sm, sid);
    return table_find(&sm->view, &sid);
}

struct view *space_manager_find_view(struct space_manager *sm, uint64_t sid)
{
    struct view *view = table_find(&sm->view, &sid);
    if (!view) {
        view = view_create(sid);
        table_add(&sm->view, &sid, view);
    }
    return view;
}

void space_manager_refresh_view(struct space_manager *sm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return;

    view_update_and_flush(view);
}

void space_manager_mark_view_invalid(struct space_manager *sm,  uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return;

    view_clear_flag(view, VIEW_IS_VALID);
}

void space_manager_untile_window(struct view *view, struct window *window)
{
    if (view->layout == VIEW_FLOAT) return;

    window_manager_adjust_layer(window, LAYER_NORMAL);
    if (view_remove_window(view, window)) view_flush(view);
}

struct space_label *space_manager_get_label_for_space(struct space_manager *sm, uint64_t sid)
{
    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (space_label->sid == sid) {
            return space_label;
        }
    }

    return NULL;
}

struct space_label *space_manager_get_space_for_label(struct space_manager *sm, char *label)
{
    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (string_equals(label, space_label->label)) {
            return space_label;
        }
    }

    return NULL;
}

bool space_manager_remove_label_for_space(struct space_manager *sm, uint64_t sid)
{
    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (space_label->sid == sid) {
            free(space_label->label);
            buf_del(sm->labels, i);
            return true;
        }
    }

    return false;
}

void space_manager_set_label_for_space(struct space_manager *sm, uint64_t sid, char *label)
{
    space_manager_remove_label_for_space(sm, sid);

    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (string_equals(space_label->label, label)) {
            free(space_label->label);
            buf_del(sm->labels, i);
            break;
        }
    }

    buf_push(sm->labels, ((struct space_label) {
        .sid   = sid,
        .label = label
    }));
}

void space_manager_set_layout_for_space(struct space_manager *sm, uint64_t sid, enum view_type layout)
{
    struct view *view = space_manager_find_view(sm, sid);
    view->layout = layout;
    view_clear(view);

    if (view->layout != VIEW_FLOAT) {
        window_manager_validate_and_check_for_windows_on_space(sm, &g_window_manager, sid);
    }
}

bool space_manager_set_gap_for_space(struct space_manager *sm, uint64_t sid, int type, int gap)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (type == TYPE_ABS) {
        view->window_gap = gap;
    } else if (type == TYPE_REL) {
        view->window_gap = add_and_clamp_to_zero(view->window_gap, gap);
    }

    view_update_and_flush(view);

    return true;
}

static bool space_manager_toggle_view_flag(struct space_manager *sm, uint64_t sid, enum view_flag flag)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (view_check_flag(view, flag)) {
        view_clear_flag(view, flag);
    } else {
        view_set_flag(view, flag);
    }

    view_update_and_flush(view);

    return true;
}

bool space_manager_toggle_gap_for_space(struct space_manager *sm, uint64_t sid)
{
    return space_manager_toggle_view_flag(sm, sid, VIEW_ENABLE_GAP);
}

void space_manager_toggle_mission_control(uint64_t sid)
{
    space_manager_focus_space(sid);
    CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
}

void space_manager_toggle_show_desktop(uint64_t sid)
{
    space_manager_focus_space(sid);
    CoreDockSendNotification(CFSTR("com.apple.showdesktop.awake"), 0);
}

void space_manager_set_layout_for_all_spaces(struct space_manager *sm, enum view_type layout)
{
    sm->layout = layout;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_LAYOUT)) {
            if (space_is_user(view->sid)) {
                view->layout = layout;
                view_clear(view);

                if (view->layout != VIEW_FLOAT) {
                    window_manager_validate_and_check_for_windows_on_space(sm, &g_window_manager, view->sid);
                }
            }
        }
    })
}

void space_manager_set_spacing_for_all_spaces(struct space_manager *sm, enum view_flag flag, int value)
{
    *space_manager_spacing(sm, flag) = value;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, flag)) {
            *view_spacing(view, flag) = value;
            view_update_and_flush(view);
        }
    })
}

static void space_manager_apply_auto_padding(struct view *view, bool auto_padding)
{
    if (view->auto_padding == auto_padding) return;

    view->auto_padding = auto_padding;
    if (view->layout == VIEW_FLOAT) return;

    view_update_and_flush(view);
}

void space_manager_set_auto_padding_for_all_spaces(struct space_manager *sm, bool auto_padding)
{
    sm->auto_padding = auto_padding;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_AUTO_PADDING)) {
            space_manager_apply_auto_padding(view, auto_padding);
        }
    })
}

void space_manager_set_auto_padding_for_space(struct space_manager *sm, uint64_t sid, bool auto_padding)
{
    struct view *view = space_manager_find_view(sm, sid);
    view_set_flag(view, VIEW_AUTO_PADDING);
    space_manager_apply_auto_padding(view, auto_padding);
}

bool space_manager_set_padding_for_space(struct space_manager *sm, uint64_t sid, int type, int top, int bottom, int left, int right)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (type == TYPE_ABS) {
        view->top_padding    = top;
        view->bottom_padding = bottom;
        view->left_padding   = left;
        view->right_padding  = right;
    } else if (type == TYPE_REL) {
        view->top_padding    = add_and_clamp_to_zero(view->top_padding, top);
        view->bottom_padding = add_and_clamp_to_zero(view->bottom_padding, bottom);
        view->left_padding   = add_and_clamp_to_zero(view->left_padding, left);
        view->right_padding  = add_and_clamp_to_zero(view->right_padding, right);
    }

    view_update_and_flush(view);

    return true;
}

bool space_manager_toggle_padding_for_space(struct space_manager *sm, uint64_t sid)
{
    return space_manager_toggle_view_flag(sm, sid, VIEW_ENABLE_PADDING);
}

static struct view *space_manager_find_tree_view(struct space_manager *sm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    return view->layout == VIEW_TREE && view->tree ? view : NULL;
}

bool space_manager_rotate_space(struct space_manager *sm, uint64_t sid, int degrees)
{
    struct view *view = space_manager_find_tree_view(sm, sid);
    if (!view) return false;

    tree_rotate(view->tree, degrees);
    view_update_and_flush(view);

    return true;
}

bool space_manager_mirror_space(struct space_manager *sm, uint64_t sid, enum window_split axis)
{
    struct view *view = space_manager_find_tree_view(sm, sid);
    if (!view) return false;

    tree_mirror(view->tree, axis == SPLIT_X ? CON_VERTICAL : CON_HORIZONTAL);
    view_update_and_flush(view);

    return true;
}

bool space_manager_balance_space(struct space_manager *sm, uint64_t sid)
{
    struct view *view = space_manager_find_tree_view(sm, sid);
    if (!view) return false;

    tree_balance(view->tree);
    view_update_and_flush(view);

    return true;
}

struct view *space_manager_tile_window_on_space_with_insertion_point(struct space_manager *sm, struct window *window, uint64_t sid, uint32_t insertion_point)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return view;

    window_manager_adjust_layer(window, LAYER_BELOW);
    view_add_window(view, window, insertion_point);
    view_flush(view);

    return view;
}

struct view *space_manager_tile_window_on_space(struct space_manager *sm, struct window *window, uint64_t sid)
{
    return space_manager_tile_window_on_space_with_insertion_point(sm, window, sid, 0);
}

void space_manager_toggle_window_split(struct space_manager *sm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, window_space(window->id));
    if (view->layout != VIEW_TREE) return;

    window_manager_set_window_layout(&g_window_manager, window, WINDOW_LAYOUT_TOGGLE_SPLIT);
}

//
// NOTE: Every space in the order Mission Control numbers them, display by display. The list lives in
// temporary storage.
//

uint64_t *space_manager_mission_control_space_list(int *count)
{
    *count = 0;

    CFArrayRef display_spaces_ref = display_manager_copy_managed_display_spaces();
    if (!display_spaces_ref) return NULL;

    uint64_t *space_list = NULL;
    int display_spaces_count = CFArrayGetCount(display_spaces_ref);

    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        int spaces_count = CFArrayGetCount(spaces_ref);

        for (int j = 0; j < spaces_count; ++j) {
            CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
            CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));

            uint64_t sid = 0;
            CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &sid);
            ts_buf_push(space_list, sid);
        }
    }

    CFRelease(display_spaces_ref);
    *count = ts_buf_len(space_list);
    return space_list;
}

static inline int space_list_index_of(uint64_t *space_list, int space_count, uint64_t sid)
{
    for (int i = 0; i < space_count; ++i) {
        if (space_list[i] == sid) return i;
    }

    return -1;
}

//
// NOTE: Returns the space offset positions from sid in the list, or 0 when sid is not in the list or
// the position is outside of it.
//

static inline uint64_t space_list_neighbour(uint64_t *space_list, int space_count, uint64_t sid, int offset)
{
    int index = space_list_index_of(space_list, space_count, sid);
    if (index == -1) return 0;

    index += offset;
    return in_range_ie(index, 0, space_count) ? space_list[index] : 0;
}

int space_manager_mission_control_index(uint64_t sid)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    return space_list_index_of(space_list, space_count, sid) + 1;
}

uint64_t space_manager_mission_control_space(int desktop_id)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    return in_range_ii(desktop_id, 1, space_count) ? space_list[desktop_id-1] : 0;
}

uint64_t space_manager_cursor_space(void)
{
    uint32_t did = display_manager_cursor_display_id();
    return display_space_id(did);
}

uint64_t space_manager_prev_space(uint64_t sid)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    return space_list_neighbour(space_list, space_count, sid, -1);
}

uint64_t space_manager_next_space(uint64_t sid)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    return space_list_neighbour(space_list, space_count, sid, 1);
}

uint64_t space_manager_first_space(void)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    return space_count ? space_list[0] : 0;
}

uint64_t space_manager_last_space(void)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);
    return space_count ? space_list[space_count-1] : 0;
}

//
// NOTE: Asking the frontmost application for its focused window is an accessibility round trip, which
// blocks for up to the accessibility timeout when the application does not respond. When the front
// process still owns the window that last received focus, and no focus change has been reported since,
// that window is still the focused one and the question can be skipped. The display and space of the
// window are always looked up again.
//

static inline bool space_manager_can_use_known_focus(ProcessSerialNumber *front, struct window_manager *wm, bool pending_focus)
{
    if (pending_focus)          return false;
    if (!wm->focused_window_id) return false;

    return psn_equals(front, &wm->focused_window_psn);
}

static struct window *space_manager_focused_window(void)
{
    ProcessSerialNumber front = {0};
    _SLPSGetFrontProcess(&front);

    bool pending_focus = __atomic_load_n(&__pending_window_focus, __ATOMIC_ACQUIRE);
    if (space_manager_can_use_known_focus(&front, &g_window_manager, pending_focus)) {
        struct window *window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
        if (window) return window;
    }

    return window_manager_focused_window(&g_window_manager);
}

uint64_t space_manager_active_space(void)
{
    uint32_t did = 0;
    struct window *window = space_manager_focused_window();

    if (window) did = window_display_id(window->id);
    if (!did)   did = display_manager_active_display_id();
    if (!did)   return 0;

    return display_space_id(did);
}

void space_manager_move_window_list_to_space(uint64_t sid, uint32_t *window_list, int window_count)
{
    if (SLSPerformAsynchronousBridgedWindowManagementOperation) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(window_list, sizeof(uint32_t), window_count, kCFNumberSInt32Type);
        Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        SEL sel = sel_registerName("initWithWindows:spaceID:");
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], sel, (__bridge id)window_list_ref, sid);
        SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
        [operation release];
        CFRelease(window_list_ref);
    } else if (!workspace_use_macos_space_workaround()) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(window_list, sizeof(uint32_t), window_count, kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);
    } else if (!scripting_addition_move_window_list_to_space(sid, window_list, window_count)) {
        SLSSpaceSetCompatID(g_connection, sid, 0x79616265);
        SLSSetWindowListWorkspace(g_connection, window_list, window_count, 0x79616265);
        SLSSpaceSetCompatID(g_connection, sid, 0x0);
    }
}

//
// NOTE: The bridged operation moves windows asynchronously. Laying out or focusing a window before it has
// arrived on its new space places it on the wrong display, or makes macOS switch to the space it came from.
// The wait is bounded, because it blocks the event loop and a window may not be moved at all.
//

bool space_manager_wait_for_window_on_space(uint32_t wid, uint64_t sid, int timeout_ms)
{
    for (int i = 0; i < timeout_ms / 10; ++i) {
        if (window_space(wid) == sid) return true;
        usleep(10000);
    }

    return window_space(wid) == sid;
}

bool space_manager_wait_for_windows_on_space(uint32_t *window_list, int window_count, uint64_t sid, int timeout_ms)
{
    int arrived = 0;

    for (int i = 0; i < timeout_ms / 10; ++i) {
        while (arrived < window_count && window_space(window_list[arrived]) == sid) ++arrived;
        if (arrived == window_count) return true;
        usleep(10000);
    }

    while (arrived < window_count && window_space(window_list[arrived]) == sid) ++arrived;
    return arrived == window_count;
}

void space_manager_move_window_to_space(uint64_t sid, struct window *window)
{
    if (SLSPerformAsynchronousBridgedWindowManagementOperation) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&window->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        SEL sel = sel_registerName("initWithWindows:spaceID:");
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], sel, (__bridge id)window_list_ref, sid);
        SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
        [operation release];
        CFRelease(window_list_ref);
    } else if (!workspace_use_macos_space_workaround()) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&window->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);
    } else if (!scripting_addition_move_window_to_space(sid, window->id)) {
        SLSSpaceSetCompatID(g_connection, sid, 0x79616265);
        SLSSetWindowListWorkspace(g_connection, &window->id, 1, 0x79616265);
        SLSSpaceSetCompatID(g_connection, sid, 0x0);
    }
}

static inline uint64_t space_manager_find_first_user_space_for_display(uint32_t did)
{
    int count;
    uint64_t *space_list = display_space_list(did, &count);
    if (!space_list) return 0;

    for (int i = 0; i < count; ++i) {
        uint64_t sid = space_list[i];

        if (space_is_user(sid)) {
            return sid;
        }
    }

    return 0;
}

static inline bool space_manager_is_space_last_user_space(uint64_t sid)
{
    bool result = true;

    int count;
    uint64_t *space_list = display_space_list(space_display_id(sid), &count);
    if (!space_list) return true;

    for (int i = 0; i < count; ++i) {
        uint64_t c_sid = space_list[i];
        if (sid == c_sid) continue;

        if (space_is_user(c_sid)) {
            result = false;
            break;
        }
    }

    return result;
}

static enum space_op_error space_manager_swap_space_with_space_on_display(uint32_t a_did, uint64_t a_sid, uint32_t b_did, uint64_t b_sid)
{
    if (display_manager_display_is_animating(a_did)) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;
    if (display_manager_display_is_animating(b_did)) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    float window_animation_duration = g_window_manager.window_animation_duration;
    g_window_manager.window_animation_duration = 0.0f;
    __asm__ __volatile__ ("" ::: "memory");

    int a_window_list_count = 0;
    uint32_t *a_window_list = space_window_list(a_sid, &a_window_list_count, true);

    int b_window_list_count = 0;
    uint32_t *b_window_list = space_window_list(b_sid, &b_window_list_count, true);

    struct view *a_view = table_find(&g_space_manager.view, &a_sid);
    struct view *b_view = table_find(&g_space_manager.view, &b_sid);

    table_remove(&g_space_manager.view, &a_sid);
    table_remove(&g_space_manager.view, &b_sid);

    a_view->sid = b_sid;
    b_view->sid = a_sid;

    CFStringRef tmp = a_view->uuid;
    a_view->uuid    = b_view->uuid;
    b_view->uuid    = tmp;

    table_add(&g_space_manager.view, &a_sid, b_view);
    table_add(&g_space_manager.view, &b_sid, a_view);

    if (a_window_list_count) {
        space_manager_move_window_list_to_space(b_sid, a_window_list, a_window_list_count);
    }

    if (b_window_list_count) {
        space_manager_move_window_list_to_space(a_sid, b_window_list, b_window_list_count);
    }

    for (int i = 0; i < buf_len(g_space_manager.labels); ++i) {
        struct space_label *label = &g_space_manager.labels[i];
        if      (label->sid == a_sid) label->sid = b_sid;
        else if (label->sid == b_sid) label->sid = a_sid;
    }

    view_update(a_view);
    view_update(b_view);

    view_flush(a_view);
    view_flush(b_view);

    __asm__ __volatile__ ("" ::: "memory");
    g_window_manager.window_animation_duration = window_animation_duration;
    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_swap_space_with_space(uint64_t acting_sid, uint64_t selector_sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint32_t acting_did = space_display_id(acting_sid);
    uint32_t selector_did = space_display_id(selector_sid);

    if (acting_sid == selector_sid) return SPACE_OP_ERROR_SAME_SPACE;
    if (acting_did != selector_did) return space_manager_swap_space_with_space_on_display(acting_did, acting_sid, selector_did, selector_sid);

    bool is_animating = display_manager_display_is_animating(acting_did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint64_t acting_prev_sid = space_manager_prev_space(acting_sid);
    uint64_t selector_prev_sid = space_manager_prev_space(selector_sid);

    uint32_t acting_prev_did = acting_prev_sid ? space_display_id(acting_prev_sid) : 0;
    uint32_t selector_prev_did = selector_prev_sid ? space_display_id(selector_prev_sid) : 0;

    bool acting_sid_is_first = !acting_prev_sid || acting_prev_did != acting_did;
    bool selector_sid_is_first = !selector_prev_sid || selector_prev_did != selector_did;

    int acting_mci = space_manager_mission_control_index(acting_sid);
    int selector_mci = space_manager_mission_control_index(selector_sid);
    bool success = true;

    if (acting_sid_is_first && !selector_sid_is_first && selector_mci - acting_mci == 1) {
        success = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
    } else if (!acting_sid_is_first && selector_sid_is_first && acting_mci - selector_mci == 1) {
        success = scripting_addition_move_space_after_space(selector_sid, acting_sid, selector_sid == space_manager_active_space());
    } else if (acting_sid_is_first && !selector_sid_is_first) {
        success  = scripting_addition_move_space_after_space(selector_sid, acting_sid, false);
        success &= scripting_addition_move_space_after_space(acting_sid, selector_prev_sid, acting_sid == space_manager_active_space());
    } else if (!acting_sid_is_first && selector_sid_is_first) {
        success  = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
        success &= scripting_addition_move_space_after_space(selector_sid, acting_prev_sid, false);
    } else if (!acting_sid_is_first && !selector_sid_is_first) {
        if (acting_mci > selector_mci) {
            success  = scripting_addition_move_space_after_space(selector_sid, acting_sid, false);
            success &= scripting_addition_move_space_after_space(acting_sid, selector_prev_sid, acting_sid == space_manager_active_space());
        } else {
            success  = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
            success &= scripting_addition_move_space_after_space(selector_sid, acting_prev_sid, false);
        }
    }

    return success ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

enum space_op_error space_manager_move_space_to_space(uint64_t acting_sid, uint64_t selector_sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint32_t acting_did = space_display_id(acting_sid);
    uint32_t selector_did = space_display_id(selector_sid);

    if (acting_sid == selector_sid) return SPACE_OP_ERROR_SAME_SPACE;
    if (acting_did != selector_did) return SPACE_OP_ERROR_SAME_DISPLAY;

    bool is_animating = display_manager_display_is_animating(acting_did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint64_t acting_prev_sid = space_manager_prev_space(acting_sid);
    uint64_t selector_prev_sid = space_manager_prev_space(selector_sid);

    uint32_t acting_prev_did = acting_prev_sid ? space_display_id(acting_prev_sid) : 0;
    uint32_t selector_prev_did = selector_prev_sid ? space_display_id(selector_prev_sid) : 0;

    bool acting_sid_is_first = !acting_prev_sid || acting_prev_did != acting_did;
    bool selector_sid_is_first = !selector_prev_sid || selector_prev_did != selector_did;
    bool success = true;

    if (acting_sid_is_first && !selector_sid_is_first) {
        success = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
    } else if (!acting_sid_is_first && selector_sid_is_first) {
        success  = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
        success &= scripting_addition_move_space_after_space(selector_sid, acting_sid, false);
    } else if (!acting_sid_is_first && !selector_sid_is_first) {
        if (space_manager_mission_control_index(acting_sid) > space_manager_mission_control_index(selector_sid)) {
            success = scripting_addition_move_space_after_space(acting_sid, selector_prev_sid, acting_sid == space_manager_active_space());
        } else {
            success = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
        }
    }

    return success ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

uint64_t space_manager_move_space_replacement(uint64_t *space_list, bool *user_list, int space_count, uint64_t sid, uint64_t visible_sid)
{
    if (sid != visible_sid) return 0;

    uint64_t prev_sid = 0;
    for (int i = 0; i < space_count; ++i) {
        if (space_list[i] == sid) {
            if (prev_sid) return prev_sid;

            for (int j = i + 1; j < space_count; ++j) {
                if (user_list[j]) return space_list[j];
            }

            return 0;
        }

        if (user_list[i]) prev_sid = space_list[i];
    }

    return 0;
}

uint64_t space_manager_space_layout_move_candidate(uint64_t *space_list, bool *user_list, int space_count, uint64_t visible_sid, bool from_end)
{
    for (int k = 0; k < space_count; ++k) {
        int i = from_end ? space_count - 1 - k : k;
        if (user_list[i] && space_list[i] != visible_sid) return space_list[i];
    }

    for (int i = 0; i < space_count; ++i) {
        if (user_list[i] && space_list[i] == visible_sid) return visible_sid;
    }

    return 0;
}

static bool *space_manager_user_list(uint64_t *space_list, int space_count)
{
    bool *user_list = ts_alloc_list(bool, space_count);
    for (int i = 0; i < space_count; ++i) {
        user_list[i] = space_is_user(space_list[i]);
    }
    return user_list;
}

enum space_op_error space_manager_move_space_to_display(struct space_manager *sm, uint64_t sid, uint32_t did)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;
    if (!sid)     return SPACE_OP_ERROR_MISSING_SRC;

    uint32_t s_did = space_display_id(sid);
    if (s_did == did) return SPACE_OP_ERROR_INVALID_DST;

    bool is_src_animating = display_manager_display_is_animating(s_did);
    if (is_src_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    bool last_space = space_manager_is_space_last_user_space(sid);
    if (last_space) return SPACE_OP_ERROR_INVALID_SRC;

    bool is_dst_animating = display_manager_display_is_animating(did);
    if (is_dst_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint64_t d_sid = display_space_id(did);
    if (!d_sid) return SPACE_OP_ERROR_MISSING_DST;

    bool focus_space = sid == space_manager_active_space();

    //
    // NOTE: A visible space must be replaced on its display before the move, even when it is
    // not focused. Otherwise the WindowServer keeps it shown on the destination display next
    // to that display's current space, and its menubar stays on screen above the real one.
    //

    int space_count;
    uint64_t *space_list = display_space_list(s_did, &space_count);
    if (!space_list) return SPACE_OP_ERROR_MISSING_SRC;

    bool *user_list = space_manager_user_list(space_list, space_count);
    uint64_t replacement_sid = space_manager_move_space_replacement(space_list, user_list, space_count, sid, display_space_id(s_did));

    if (scripting_addition_move_space_to_display(sid, d_sid, replacement_sid, focus_space ? 1 : 0)) {
        space_manager_mark_view_invalid(sm, sid);
        if (focus_space) {
            space_manager_focus_space(sid);
        }
        return SPACE_OP_ERROR_SUCCESS;
    }

    return SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool space_manager_focus_space_using_gesture(uint32_t new_did, uint64_t new_sid)
{
    int cur_index = space_manager_mission_control_index(display_space_id(new_did));
    int new_index = space_manager_mission_control_index(new_sid);

    int count = abs(new_index - cur_index);
    if (count == 0) {
        display_manager_focus_display(new_did, new_sid);
        return true;
    }

    CGPoint point = display_center(new_did);
    uint32_t cur_did = display_manager_cursor_display_id();

    bool focus_display = cur_did != new_did;
    if (focus_display) CGWarpMouseCursorPosition(point);

    //
    // NOTE(asmvik): MacOS does not have an API that allows for space activation.
    // However, we can synthesize a sequence of high velocity gestures to skip the
    // animation instead.
    //
    // :Attribution
    // https://github.com/jurplel/InstantSpaceSwitcher
    // https://github.com/thenickdude/wacom-driver-fix/blob/bdfda9a788934c88d09d31ea6a42664b9ba1471e/Readme.md
    // Technique first observed in practice, and reverse-engineered from, BetterTouchTool.
    //

    CGEventRef event_dock_control = CGEventCreate(NULL);
    if (!event_dock_control) return false;

    float sign = (new_index - cur_index) > 0 ? 1.0 : -1.0;
    CGEventSetIntegerValueField(event_dock_control, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(event_dock_control, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event_dock_control, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(event_dock_control,  kCGEventGestureSwipeProgress, sign);
    CGEventSetDoubleValueField(event_dock_control,  kCGEventGestureSwipeVelocityX, sign * 9999.0);

    for (int i = 0; i < count; ++i) {
        CGEventSetIntegerValueField(event_dock_control, kCGEventGesturePhase, kCGSGesturePhaseBegan);
        CGEventPost(kCGSessionEventTap, event_dock_control);
        CGEventSetIntegerValueField(event_dock_control, kCGEventGesturePhase, kCGSGesturePhaseEnded);
        CGEventPost(kCGSessionEventTap, event_dock_control);
    }
    CFRelease(event_dock_control);

    if (focus_display) {
        display_manager_set_active_display_id(new_did);
        if (space_manager_active_space() != new_sid) {
            CGPostMouseEvent(point, false, 1, true);
            CGPostMouseEvent(point, false, 1, false);
        }
    }

    return true;
}
#pragma clang diagnostic pop

enum space_op_error space_manager_focus_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint64_t cur_sid = space_manager_active_space();
    if (cur_sid == sid) return SPACE_OP_ERROR_SAME_SPACE;

    uint32_t cur_did = space_display_id(cur_sid);
    uint32_t new_did = space_display_id(sid);
    bool focus_display = cur_did != new_did;

    bool is_animating = display_manager_display_is_animating(new_did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    if (scripting_addition_focus_space(sid)) {
        if (focus_display) {
            display_manager_focus_display(new_did, sid);
        }
    } else {
        space_manager_focus_space_using_gesture(new_did, sid);
    }

    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_switch_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint64_t cur_sid = space_manager_active_space();
    if (cur_sid == sid) return SPACE_OP_ERROR_SAME_SPACE;

    uint32_t cur_did = space_display_id(cur_sid);
    uint32_t did     = space_display_id(sid);

    bool is_src_animating = display_manager_display_is_animating(cur_did);
    if (is_src_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    bool is_dst_animating = display_manager_display_is_animating(did);
    if (is_dst_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    if (cur_did != did) {
        space_manager_swap_space_with_space_on_display(cur_did, cur_sid, did, sid);
        display_manager_focus_display(cur_did, cur_sid);
        return SPACE_OP_ERROR_SUCCESS;
    }

    return scripting_addition_focus_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

enum space_op_error space_manager_destroy_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    if (!sid) return SPACE_OP_ERROR_MISSING_SRC;
    if (!space_is_user(sid)) return SPACE_OP_ERROR_INVALID_TYPE;
    if (space_manager_is_space_last_user_space(sid)) return SPACE_OP_ERROR_INVALID_SRC;

    uint32_t did = space_display_id(sid);
    uint64_t first_sid = space_manager_find_first_user_space_for_display(did);

    bool is_animating = display_manager_display_is_animating(did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    bool success = scripting_addition_destroy_space(sid);
    if (!success) return SPACE_OP_ERROR_SCRIPTING_ADDITION;

    if (first_sid) {
        window_manager_validate_and_check_for_windows_on_space(&g_space_manager, &g_window_manager, first_sid);
    }

    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_add_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;
    if (!sid)     return SPACE_OP_ERROR_MISSING_SRC;

    bool is_animating = display_manager_display_is_animating(space_display_id(sid));
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    return scripting_addition_create_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

bool space_manager_parse_space_layout(char *text, int length, struct space_layout *layout)
{
    layout->count = 0;
    layout->builtin_index = -1;

    int i = 0;
    while (i < length) {
        if (layout->count == SPACE_LAYOUT_MAX) return false;

        int value = 0;
        int digits = 0;
        while (i < length && text[i] >= '0' && text[i] <= '9') {
            value = value * 10 + (text[i] - '0');
            if (value > 1000) return false;
            ++digits;
            ++i;
        }
        if (!digits || value < 1) return false;

        if (i < length && text[i] == 'b') {
            if (layout->builtin_index != -1) return false;
            layout->builtin_index = layout->count;
            ++i;
        }

        layout->target[layout->count++] = value;

        if (i < length) {
            if (text[i] != ':' || i + 1 == length) return false;
            ++i;
        }
    }

    return layout->count > 0;
}

void space_manager_space_layout_targets(struct space_layout *layout, int builtin, int *target)
{
    if (layout->builtin_index != -1 && builtin != -1) {
        target[builtin] = layout->target[layout->builtin_index];
        for (int i = 0, j = 0; i < layout->count; ++i) {
            if (i == builtin) continue;
            if (j == layout->builtin_index) ++j;
            target[i] = layout->target[j++];
        }
    } else {
        for (int i = 0; i < layout->count; ++i) {
            target[i] = layout->target[i];
        }
    }
}

static int space_manager_user_space_count(uint64_t *space_list, int space_count)
{
    int result = 0;

    for (int i = 0; i < space_count; ++i) {
        if (space_is_user(space_list[i])) ++result;
    }

    return result;
}

static uint64_t space_manager_find_space_layout_destroy_candidate(uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return 0;

    uint64_t visible_sid = display_space_id(did);
    uint64_t fallback_sid = 0;

    for (int i = space_count - 1; i >= 0; --i) {
        uint64_t sid = space_list[i];
        if (!space_is_user(sid)) continue;
        if (space_manager_is_space_last_user_space(sid)) continue;

        int window_count = -1;
        space_window_list(sid, &window_count, true);
        if (window_count != 0) continue;

        if (sid != visible_sid) return sid;
        if (!fallback_sid) fallback_sid = sid;
    }

    return fallback_sid;
}

enum space_layout_result space_manager_reconcile_space_layout(struct space_manager *sm)
{
    int display_count = display_manager_active_display_count();
    if (display_count < 1 || display_count > SPACE_LAYOUT_MAX) return SPACE_LAYOUT_RESULT_DONE;

    struct space_layout *layout = NULL;
    for (int i = 0; i < sm->space_layout_count; ++i) {
        if (sm->space_layout[i].count == display_count) {
            layout = &sm->space_layout[i];
            break;
        }
    }

    if (!layout) {
        debug("%s: no space_layout for %d display(s)\n", __FUNCTION__, display_count);
        return SPACE_LAYOUT_RESULT_DONE;
    }

    uint32_t did_list[SPACE_LAYOUT_MAX];
    int target[SPACE_LAYOUT_MAX];
    int actual[SPACE_LAYOUT_MAX];
    int builtin = -1;

    for (int i = 0; i < display_count; ++i) {
        did_list[i] = display_manager_arrangement_display_id(i + 1);
        if (!did_list[i]) return SPACE_LAYOUT_RESULT_FAILED;
        if (builtin == -1 && CGDisplayIsBuiltin(did_list[i])) builtin = i;
    }

    space_manager_space_layout_targets(layout, builtin, target);

    for (int i = 0; i < display_count; ++i) {
        int space_count;
        uint64_t *space_list = display_space_list(did_list[i], &space_count);
        if (!space_list) return SPACE_LAYOUT_RESULT_FAILED;
        actual[i] = space_manager_user_space_count(space_list, space_count);
    }

    int surplus = -1;
    int deficit = -1;
    for (int i = 0; i < display_count; ++i) {
        if (surplus == -1 && actual[i] > target[i]) surplus = i;
        if (deficit == -1 && actual[i] < target[i]) deficit = i;
    }

    if (surplus == -1 && deficit == -1) return SPACE_LAYOUT_RESULT_DONE;

    enum space_op_error result;

    if (surplus != -1 && deficit != -1) {
        int space_count;
        uint64_t *space_list = display_space_list(did_list[surplus], &space_count);
        if (!space_list) return SPACE_LAYOUT_RESULT_FAILED;

        bool *user_list = space_manager_user_list(space_list, space_count);
        uint64_t sid = space_manager_space_layout_move_candidate(space_list, user_list, space_count, display_space_id(did_list[surplus]), deficit > surplus);

        debug("%s: move space %lld from display %d to display %d\n", __FUNCTION__, sid, surplus + 1, deficit + 1);
        result = space_manager_move_space_to_display(sm, sid, did_list[deficit]);
    } else if (deficit != -1) {
        debug("%s: create space on display %d (%d/%d)\n", __FUNCTION__, deficit + 1, actual[deficit], target[deficit]);
        result = space_manager_add_space(display_space_id(did_list[deficit]));
    } else {
        uint64_t sid = space_manager_find_space_layout_destroy_candidate(did_list[surplus]);
        if (!sid) {
            debug("%s: display %d has %d/%d spaces, but no empty space can be destroyed\n", __FUNCTION__, surplus + 1, actual[surplus], target[surplus]);
            return SPACE_LAYOUT_RESULT_DONE;
        }

        debug("%s: destroy empty space %lld on display %d (%d/%d)\n", __FUNCTION__, sid, surplus + 1, actual[surplus], target[surplus]);
        result = space_manager_destroy_space(sid);
    }

    return result == SPACE_OP_ERROR_SUCCESS ? SPACE_LAYOUT_RESULT_PERFORMED : SPACE_LAYOUT_RESULT_FAILED;
}

bool space_manager_is_window_on_space(uint64_t sid, struct window *window)
{
    int space_count;
    uint64_t *space_list = window_space_list(window->id, &space_count);
    if (!space_list) return false;

    for (int i = 0; i < space_count; ++i) {
        if (sid == space_list[i]) {
            return true;
        }
    }

    return false;
}

void space_manager_mark_spaces_invalid_for_display(struct space_manager *sm, uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return;

    uint64_t sid = display_space_id(did);
    for (int i = 0; i < space_count; ++i) {
        if (space_list[i] == sid) {
            space_manager_refresh_view(sm, sid);
        } else {
            space_manager_mark_view_invalid(sm, space_list[i]);
        }
    }
}

void space_manager_mark_spaces_invalid(struct space_manager *sm)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    for (int i = 0; i < display_count; ++i) {
        space_manager_mark_spaces_invalid_for_display(sm, display_list[i]);
    }
}

bool space_manager_refresh_application_windows(struct space_manager *sm)
{
    int refresh_count = buf_len(g_window_manager.applications_to_refresh);
    if (!refresh_count) return false;
    int window_count = g_window_manager.window.count;
    for (int i = 0; i < refresh_count; ++i) {
        struct application *application = g_window_manager.applications_to_refresh[i];
        debug("%s: %s has windows that are not yet resolved\n", __FUNCTION__, application->name);
        bool result = window_manager_add_existing_application_windows(sm, &g_window_manager, application, i);
        if (result) {
            --refresh_count;
            --i;
        }
    }
    return window_count != g_window_manager.window.count;
}

void space_manager_handle_display_add(struct space_manager *sm, uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return;

    int list_count = 0;
    struct view *view_list[sm->view.count];
    CFStringRef uuid_list[sm->view.count];

    table_for (struct view *view, sm->view, {
        view_list[list_count] = view;
        uuid_list[list_count] = view->uuid;
        ++list_count;
    })

    for (int i = 0; i < space_count; ++i) {
        uint64_t sid = space_list[i];
        CFStringRef uuid = SLSSpaceCopyName(g_connection, sid);
        if (!uuid) continue;

        for (int j = 0; j < list_count; ++j) {
            CFStringRef view_uuid = uuid_list[j];
            if (!view_uuid) continue;

            if (CFEqual(view_uuid, uuid)) {
                struct view *view = view_list[j];

                uuid_list[j] = NULL;
                view_list[j] = NULL;

                table_remove(&sm->view, &view->sid);
                CFRelease(view->uuid);

                struct space_label *label = space_manager_get_label_for_space(sm, view->sid);
                if (label) label->sid = sid;

                view->sid = sid;
                view->uuid = CFRetain(uuid);

                table_add(&sm->view, &sid, view);
                break;
            }
        }

        CFRelease(uuid);
    }

    sm->current_space_id = space_manager_active_space();
    sm->last_space_id = sm->current_space_id;
}

void space_manager_begin(struct space_manager *sm)
{
    sm->layout = VIEW_TREE;
    sm->auto_padding = false;
    sm->tree_default_orientation = TREE_ORIENTATION_AUTO;
    sm->tree_workspace_tabbed = false;
    sm->tree_autotiling = false;
    sm->labels = NULL;
    sm->skip_window_focus_animation = false;
    table_init(&sm->view, 23, hash_view, compare_view);

    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    for (int i = 0; i < display_count; ++i) {
        int space_count;
        uint64_t *space_list = display_space_list(display_list[i], &space_count);
        if (!space_list) continue;

        for (int j = 0; j < space_count; ++j) {
            struct view *view = view_create(space_list[j]);
            table_add(&sm->view, &space_list[j], view);
        }
    }

    sm->current_space_id = space_manager_active_space();
    sm->last_space_id = sm->current_space_id;
    sm->did_begin = true;
}
