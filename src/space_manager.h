#ifndef SPACE_MANAGER
#define SPACE_MANAGER

struct space_manager
{
    struct table view;
    uint64_t current_space_id;
    uint64_t last_space_id;
    bool did_begin;
    enum view_type layout;
    int top_padding;
    int bottom_padding;
    int left_padding;
    int right_padding;
    int window_gap;
    bool auto_padding;
    enum tree_orientation tree_default_orientation;
    bool tree_workspace_tabbed;
    bool tree_autotiling;
    struct label_list *labels;
    bool skip_window_focus_animation;
    struct space_layout space_layout[SPACE_LAYOUT_MAX];
    int space_layout_count;
    char *space_layout_spec;
    uint32_t space_layout_gen;
    int space_layout_passes;
};

static inline int *space_manager_spacing(struct space_manager *sm, enum view_flag flag)
{
    switch (flag) {
    case VIEW_TOP_PADDING:    return &sm->top_padding;
    case VIEW_BOTTOM_PADDING: return &sm->bottom_padding;
    case VIEW_LEFT_PADDING:   return &sm->left_padding;
    case VIEW_RIGHT_PADDING:  return &sm->right_padding;
    case VIEW_WINDOW_GAP:     return &sm->window_gap;
    default:                  assert(0); return NULL;
    }
}

enum space_op_error
{
    SPACE_OP_ERROR_SUCCESS              = 0,
    SPACE_OP_ERROR_MISSING_SRC          = 1,
    SPACE_OP_ERROR_MISSING_DST          = 2,
    SPACE_OP_ERROR_INVALID_SRC          = 3,
    SPACE_OP_ERROR_INVALID_DST          = 4,
    SPACE_OP_ERROR_INVALID_TYPE         = 5,
    SPACE_OP_ERROR_SAME_SPACE           = 6,
    SPACE_OP_ERROR_SAME_DISPLAY         = 7,
    SPACE_OP_ERROR_IN_MISSION_CONTROL   = 9,
    SPACE_OP_ERROR_SCRIPTING_ADDITION   = 10,
};

// implemented in Sources/Yabai/SpaceManager.swift (and Space.swift, DisplayManager.swift for the lists they return)
struct view *space_manager_query_view(struct space_manager *sm, uint64_t sid);
struct view *space_manager_find_view(struct space_manager *sm, uint64_t sid);
void space_manager_refresh_view(struct space_manager *sm, uint64_t sid);
void space_manager_mark_view_invalid(struct space_manager *sm,  uint64_t sid);
void space_manager_untile_window(struct view *view, struct window *window);
struct view *space_manager_tile_window_on_space_with_insertion_point(struct space_manager *sm, struct window *window, uint64_t sid, uint32_t insertion_point);
struct view *space_manager_tile_window_on_space(struct space_manager *sm, struct window *window, uint64_t sid);
bool space_manager_balance_space(struct space_manager *sm, uint64_t sid);
void space_manager_toggle_window_split(struct space_manager *sm, struct window *window);
uint64_t *space_manager_mission_control_space_list(int *count);
int space_manager_mission_control_index(uint64_t sid);
uint64_t space_manager_mission_control_space(int desktop_id);
uint64_t space_manager_cursor_space(void);
uint64_t space_manager_prev_space(uint64_t sid);
uint64_t space_manager_next_space(uint64_t sid);
uint64_t space_manager_first_space(void);
uint64_t space_manager_last_space(void);
uint64_t space_manager_active_space(void);
void space_manager_set_layout_for_space(struct space_manager *sm, uint64_t sid, enum view_type type);
bool space_manager_set_gap_for_space(struct space_manager *sm, uint64_t sid, int type, int gap);
bool space_manager_toggle_gap_for_space(struct space_manager *sm, uint64_t sid);
void space_manager_toggle_mission_control(uint64_t sid);
void space_manager_toggle_show_desktop(uint64_t sid);
void space_manager_set_layout_for_all_spaces(struct space_manager *sm, enum view_type layout);
void space_manager_set_spacing_for_all_spaces(struct space_manager *sm, enum view_flag flag, int value);
void space_manager_set_auto_padding_for_all_spaces(struct space_manager *sm, bool auto_padding);
void space_manager_set_auto_padding_for_space(struct space_manager *sm, uint64_t sid, bool auto_padding);
bool space_manager_set_padding_for_space(struct space_manager *sm, uint64_t sid, int type, int top, int bottom, int left, int right);
bool space_manager_toggle_padding_for_space(struct space_manager *sm, uint64_t sid);
bool space_manager_rotate_space(struct space_manager *sm, uint64_t sid, int degrees);
bool space_manager_mirror_space(struct space_manager *sm, uint64_t sid, enum window_split axis);
void space_manager_move_window_list_to_space(uint64_t sid, uint32_t *window_list, int window_count);
bool space_manager_wait_for_window_on_space(uint32_t wid, uint64_t sid, int timeout_ms);
bool space_manager_wait_for_windows_on_space(uint32_t *window_list, int window_count, uint64_t sid, int timeout_ms);
void space_manager_move_window_to_space(uint64_t sid, struct window *window);
bool space_manager_focus_space_using_gesture(uint32_t new_did, uint64_t new_sid);
enum space_op_error space_manager_focus_space(uint64_t sid);
enum space_op_error space_manager_switch_space(uint64_t sid);
enum space_op_error space_manager_swap_space_with_space(uint64_t acting_sid, uint64_t selector_sid);
enum space_op_error space_manager_move_space_to_space(uint64_t acting_sid, uint64_t selector_sid);
enum space_op_error space_manager_move_space_to_display(struct space_manager *sm, uint64_t sid, uint32_t did);
enum space_op_error space_manager_destroy_space(uint64_t sid);
enum space_op_error space_manager_add_space(uint64_t sid);
bool space_manager_is_window_on_space(uint64_t sid, struct window *window);
void space_manager_mark_spaces_invalid_for_display(struct space_manager *sm, uint32_t did);
void space_manager_mark_spaces_invalid(struct space_manager *sm);
bool space_manager_refresh_application_windows(struct space_manager *sm);
void space_manager_handle_display_add(struct space_manager *sm, uint32_t did);
void space_manager_init(struct space_manager *sm);
void space_manager_begin(struct space_manager *sm);

#endif
