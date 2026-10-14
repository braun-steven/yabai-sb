#ifndef WINDOW_MANAGER_H
#define WINDOW_MANAGER_H

#define kCPSAllWindows    0x100
#define kCPSUserGenerated 0x200
#define kCPSNoWindows     0x400

enum window_layout
{
    WINDOW_LAYOUT_TABBED,
    WINDOW_LAYOUT_SPLIT,
    WINDOW_LAYOUT_TOGGLE,
    WINDOW_LAYOUT_SPLITH,
    WINDOW_LAYOUT_SPLITV,
    WINDOW_LAYOUT_TOGGLE_SPLIT
};

enum window_op_error
{
    WINDOW_OP_ERROR_SUCCESS,
    WINDOW_OP_ERROR_INVALID_SRC_VIEW,
    WINDOW_OP_ERROR_INVALID_SRC_NODE,
    WINDOW_OP_ERROR_INVALID_DST_VIEW,
    WINDOW_OP_ERROR_INVALID_DST_NODE,
    WINDOW_OP_ERROR_INVALID_OPERATION,
    WINDOW_OP_ERROR_SAME_WINDOW,
    WINDOW_OP_ERROR_CANT_MINIMIZE,
    WINDOW_OP_ERROR_ALREADY_MINIMIZED,
    WINDOW_OP_ERROR_MINIMIZE_FAILED,
    WINDOW_OP_ERROR_NOT_MINIMIZED,
    WINDOW_OP_ERROR_DEMINIMIZE_FAILED,
};

enum purify_mode
{
    PURIFY_DISABLED,
    PURIFY_MANAGED,
    PURIFY_ALWAYS
};

static const char *purify_mode_str[] =
{
    "on",
    "float",
    "off"
};

enum ffm_mode
{
    FFM_DISABLED,
    FFM_AUTOFOCUS,
    FFM_AUTORAISE
};

static const char *ffm_mode_str[] =
{
    "disabled",
    "autofocus",
    "autoraise"
};

enum window_origin_mode
{
    WINDOW_ORIGIN_DEFAULT,
    WINDOW_ORIGIN_FOCUSED,
    WINDOW_ORIGIN_CURSOR
};

static const char *window_origin_mode_str[] =
{
    "default",
    "focused",
    "cursor"
};

struct scratchpad
{
    char *label;
    struct window *window;
};

struct window_frame_request
{
    AXUIElementRef ref;
    CGPoint position;
    CGSize size;
};

struct window_frame_group
{
    struct application *application;
    struct window_frame_request *list;
    int count;
    AXError error;
};

struct window_manager
{
    AXUIElementRef system_element;
    struct table application;
    struct table window;
    struct table managed_window;
    struct table window_lost_focused_event;
    struct table application_lost_front_switched_event;
    struct table window_animations_table;
    pthread_mutex_t window_animations_lock;
    struct rule *rules;
    struct application **applications_to_refresh;
    uint32_t focused_window_id;
    ProcessSerialNumber focused_window_psn;
    uint32_t pending_focus_window_id;
    uint64_t pending_focus_time;
    uint32_t last_window_id;
    bool enable_mff;
    enum ffm_mode ffm_mode;
    enum purify_mode purify_mode;
    enum window_origin_mode window_origin_mode;
    bool enable_window_opacity;
    float menubar_opacity;
    float active_window_opacity;
    float normal_window_opacity;
    float window_opacity_duration;
    float window_animation_duration;
    int window_animation_easing;
    struct rgba_color insert_feedback_color;
    bool enable_window_border;
    bool window_border_hide_single;
    float window_border_width;
    struct rgba_color active_window_border_color;
    struct rgba_color normal_window_border_color;
    enum focus_wrapping focus_wrapping;
    bool enable_tab_bar;
    int tab_bar_height;
    int tab_bar_offset;
    bool tab_bar_icons;
    enum tab_bar_style tab_bar_style;
    enum tab_bar_backdrop tab_bar_backdrop;
    int tab_bar_card_padding;
    int tab_bar_window_radius;
    char *tab_bar_font_name;
    CTFontRef tab_bar_font;
    struct rgba_color tab_bar_focused_color;
    struct rgba_color tab_bar_focused_text_color;
    struct rgba_color tab_bar_inactive_color;
    struct rgba_color tab_bar_inactive_text_color;
    struct rgba_color tab_bar_unfocused_color;
    struct rgba_color tab_bar_backdrop_color;
    struct rgba_color tab_bar_unfocused_text_color;
    bool tab_bar_focused_color_custom;
    bool tab_bar_inactive_color_custom;
    bool tab_bar_unfocused_color_custom;
    bool tab_bar_backdrop_color_custom;
    struct scratchpad *scratchpad_window;
    bool scratchpad_exclusive;
    bool scratchpad_raise;
    bool scratchpad_below;
    unsigned scratchpad_grid[6];
};

void window_manager_query_window_rules(FILE *rsp);
bool window_manager_rule_matches_window(struct rule *rule, struct window *window, char *window_title, char *window_role, char *window_subrole);
void window_manager_apply_manage_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects);
void window_manager_apply_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects);
void window_manager_apply_manage_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules);
void window_manager_apply_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules);
void window_manager_center_mouse(struct window_manager *wm, struct window *window);
bool window_manager_is_window_eligible(struct window *window);
bool window_manager_should_manage_window(struct window *window);
void window_manager_move_window(struct window *window, float x, float y);
void window_manager_resize_window(struct window *window, float width, float height);
enum window_op_error window_manager_adjust_window_ratio(struct window_manager *wm, struct window *window, int action, float ratio);
void window_manager_animate_window(struct window_capture capture);
void window_manager_animate_window_list(struct window_capture *window_list, int window_count);
void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height);
int window_manager_group_window_frames(struct window_capture *window_list, int window_count, struct window_frame_group *group_list, struct window_frame_request *request_list);
void window_manager_set_window_frames(struct window_capture *window_list, int window_count);
struct window *window_manager_find_window_on_space_by_rank_filtering_window(struct window_manager *wm, uint64_t sid, int rank, uint32_t filter_wid);
struct window *window_manager_find_window_at_point_filtering_window(struct window_manager *wm, CGPoint point, uint32_t filter_wid);
struct window *window_manager_find_window_at_point(struct window_manager *wm, CGPoint point);
struct window *window_manager_find_window_below_cursor(struct window_manager *wm);
struct window *window_manager_find_closest_managed_window_in_direction(struct window_manager *wm, struct window *window, int direction);
struct window *window_manager_find_prev_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_next_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_first_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_last_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_recent_managed_window(struct window_manager *wm);
struct window *window_manager_find_prev_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_next_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_first_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_last_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_recent_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window, int index);
enum window_op_error window_manager_set_window_layout(struct window_manager *wm, struct window *window, enum window_layout layout);
void window_manager_unmanage_window(struct window_manager *wm, struct view *view, struct window *window);
void window_manager_manage_window(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t sid, uint32_t insertion_point);
struct view *window_manager_find_tree_view(struct window_manager *wm, struct window *window);
enum window_op_error window_manager_tree_focus_direction(struct window_manager *wm, struct window *window, int direction);
enum window_op_error window_manager_tree_focus_parent(struct window_manager *wm, struct window *window);
enum window_op_error window_manager_tree_focus_child(struct window_manager *wm, struct window *window);
enum window_op_error window_manager_tree_move_direction(struct space_manager *sm, struct window_manager *wm, struct window *window, int direction);
uint32_t window_manager_tree_focus_candidate(struct window_manager *wm, struct view *view, struct window *window);
void window_manager_tree_focus_after_close(struct window_manager *wm, struct view *view, uint32_t window_id);
enum window_op_error window_manager_tree_split(struct window_manager *wm, struct window *window, int orientation);
struct window *window_manager_find_largest_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_smallest_managed_window(struct space_manager *sm, struct window_manager *wm);
void window_manager_focus_window_without_raise(ProcessSerialNumber *window_psn, uint32_t window_id);
void window_manager_focus_window_without_raise_deferred(struct window *window);
void window_manager_focus_window_with_raise(ProcessSerialNumber *window_psn, uint32_t window_id, AXUIElementRef window_ref);
struct window *window_manager_focused_window(struct window_manager *wm);
struct window *window_manager_pending_focus_window(struct window_manager *wm);
struct window *window_manager_acting_window(struct window_manager *wm);
void window_manager_set_pending_focus(struct window_manager *wm, uint32_t window_id);
struct application *window_manager_focused_application(struct window_manager *wm);
struct view *window_manager_find_managed_window(struct window_manager *wm, struct window *window);
void window_manager_remove_managed_window(struct window_manager *wm, uint32_t wid);
void window_manager_add_managed_window(struct window_manager *wm, struct window *window, struct view *view);
bool window_manager_find_lost_front_switched_event(struct window_manager *wm, pid_t pid);
void window_manager_remove_lost_front_switched_event(struct window_manager *wm, pid_t pid);
void window_manager_add_lost_front_switched_event(struct window_manager *wm, pid_t pid);
bool window_manager_find_lost_focused_event(struct window_manager *wm, uint32_t window_id);
void window_manager_remove_lost_focused_event(struct window_manager *wm, uint32_t window_id);
void window_manager_add_lost_focused_event(struct window_manager *wm, uint32_t window_id);
struct window *window_manager_find_window(struct window_manager *wm, uint32_t window_id);
void window_manager_remove_window(struct window_manager *wm, uint32_t window_id);
void window_manager_add_window(struct window_manager *wm, struct window *window);
struct application *window_manager_find_application(struct window_manager *wm, pid_t pid);
void window_manager_remove_application(struct window_manager *wm, pid_t pid);
void window_manager_add_application(struct window_manager *wm, struct application *application);
struct window **window_manager_find_application_windows(struct window_manager *wm, struct application *application, int *window_count);
enum window_op_error window_manager_move_window_relative(struct window_manager *wm, struct window *window, int type, float dx, float dy);
void window_manager_resize_window_relative_internal(struct window *window, CGRect frame, int direction, float dx, float dy, bool animate);
enum window_op_error window_manager_resize_window_relative(struct window_manager *wm, struct window *window, int direction, float dx, float dy, bool animate);
void window_manager_set_purify_mode(struct window_manager *wm, enum purify_mode mode);
void window_manager_set_menubar_opacity(struct window_manager *wm, float opacity);
void window_manager_set_active_window_opacity(struct window_manager *wm, float opacity);
void window_manager_set_normal_window_opacity(struct window_manager *wm, float opacity);
void window_manager_set_window_opacity_enabled(struct window_manager *wm, bool enabled);
bool window_manager_set_opacity(struct window_manager *wm, struct window *window, float opacity);
void window_manager_set_window_opacity(struct window_manager *wm, struct window *window, float opacity);
void window_manager_set_focus_follows_mouse(struct window_manager *wm, enum ffm_mode mode);
enum window_op_error window_manager_set_window_insertion(struct space_manager *sm, struct window *window, int direction);
enum window_op_error window_manager_stack_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_warp_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_swap_window(struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_minimize_window(struct window *window);
enum window_op_error window_manager_deminimize_window(struct window *window);
bool window_manager_close_window(struct window *window);
void window_manager_send_window_to_space(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t sid, bool moved_by_rule);
struct window *window_manager_create_and_add_window(struct space_manager *sm, struct window_manager *wm, struct application *application, CF_CONSUMED AXUIElementRef window_ref, uint32_t window_id, bool one_shot_rules);
void window_manager_remove_one_shot_rules(struct window_manager *wm);
uint64_t window_manager_origin_space(struct window_manager *wm, struct window *window);
struct window **window_manager_add_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int *count);
bool window_manager_add_existing_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int refresh_index);

//
// NOTE: The index of an application in applications_to_refresh (or -1), and its removal, for Swift, which cannot
// expand the sbuffer macros.
//

static inline int window_manager_application_refresh_index(struct window_manager *wm, struct application *application)
{
    for (int i = 0; i < buf_len(wm->applications_to_refresh); ++i) {
        if (application == wm->applications_to_refresh[i]) return i;
    }

    return -1;
}

static inline void window_manager_remove_application_refresh(struct window_manager *wm, int index)
{
    buf_del(wm->applications_to_refresh, index);
}
enum window_op_error window_manager_apply_grid(struct space_manager *sm, struct window_manager *wm, struct window *window, unsigned r, unsigned c, unsigned x, unsigned y, unsigned w, unsigned h);
void window_manager_purify_window(struct window_manager *wm, struct window *window);
void window_manager_make_window_floating(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_float, bool force);
void window_manager_make_window_sticky(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_sticky);
void window_manager_adjust_layer(struct window *window, int layer);
bool window_manager_set_window_layer(struct window *window, int layer);
void window_manager_toggle_window_shadow(struct window *window);
void window_manager_toggle_window_zoom_parent(struct window_manager *wm, struct window *window);
void window_manager_toggle_window_zoom_fullscreen(struct window_manager *wm, struct window *window);
void window_manager_toggle_window_windowed_fullscreen(struct window *window);
void window_manager_toggle_window_native_fullscreen(struct window *window);
void window_manager_toggle_window_expose(struct window *window);
void window_manager_toggle_window_pip(struct space_manager *sm, struct window *window);
bool window_manager_toggle_scratchpad_window_by_label(struct window_manager *wm, char *label);
void window_manager_set_scratchpad_layers(struct window_manager *wm);
bool window_manager_toggle_scratchpad_window(struct window_manager *wm, struct window *window);
bool window_manager_set_scratchpad_for_window(struct window_manager *wm, struct window *window, char *label);
bool window_manager_remove_scratchpad_for_window(struct window_manager *wm, struct window *window, bool unfloat);
void window_manager_scratchpad_recover_windows(void);
void window_manager_wait_for_native_fullscreen_transition(void);
void window_manager_validate_and_check_for_windows_on_space(struct space_manager *sm, struct window_manager *wm, uint64_t sid);
void window_manager_correct_for_mission_control_changes(struct space_manager *sm, struct window_manager *wm);
void window_manager_handle_display_add_and_remove(struct space_manager *sm, struct window_manager *wm, uint32_t did);
void window_manager_begin(struct space_manager *sm, struct window_manager *wm);
void window_manager_init(struct window_manager *wm);

#endif
