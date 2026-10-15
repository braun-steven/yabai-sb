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

struct window_manager
{
    AXUIElementRef system_element;
    struct table application;
    struct table window;
    struct table managed_window;
    struct table window_lost_focused_event;
    struct table application_lost_front_switched_event;
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

//
// NOTE: The window manager is Swift (Sources/Yabai/WindowManager*.swift). struct window_manager stays C while
// rule.c and the C startup code read its fields (model cleanup is P14). These are the
// functions that C still calls.
//

// implemented in Sources/Yabai/WindowManagerRules.swift
bool window_manager_rule_matches_window(struct rule *rule, struct window *window, char *window_title, char *window_role, char *window_subrole);
void window_manager_apply_manage_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects);
void window_manager_apply_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects);
void window_manager_apply_manage_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules);
void window_manager_apply_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules);

// implemented in Sources/Yabai/WindowManager.swift
bool window_manager_is_window_eligible(struct window *window);
struct view *window_manager_find_managed_window(struct window_manager *wm, struct window *window);
void window_manager_remove_managed_window(struct window_manager *wm, uint32_t wid);
void window_manager_unmanage_window(struct window_manager *wm, struct view *view, struct window *window);
void window_manager_manage_window(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t sid, uint32_t insertion_point);
enum window_op_error window_manager_resize_window_relative(struct window_manager *wm, struct window *window, int direction, float dx, float dy, bool animate);
struct window *window_manager_find_window(struct window_manager *wm, uint32_t window_id);
enum window_op_error window_manager_stack_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_swap_window(struct window_manager *wm, struct window *a, struct window *b);
void window_manager_begin(struct space_manager *sm, struct window_manager *wm);
void window_manager_init(struct window_manager *wm);

//
// NOTE: The sbuffers of the window manager (applications_to_refresh, rules, scratchpad_window) for Swift, which cannot
// expand the sbuffer macros. buf_del moves the last element into the hole.
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

static inline int window_manager_application_refresh_count(struct window_manager *wm)
{
    return buf_len(wm->applications_to_refresh);
}

static inline struct application *window_manager_application_refresh_at(struct window_manager *wm, int index)
{
    return wm->applications_to_refresh[index];
}

static inline void window_manager_add_application_refresh(struct window_manager *wm, struct application *application)
{
    buf_push(wm->applications_to_refresh, application);
}

static inline int window_manager_rule_count(struct window_manager *wm)
{
    return buf_len(wm->rules);
}

static inline struct rule *window_manager_rule_at(struct window_manager *wm, int index)
{
    return &wm->rules[index];
}

static inline void window_manager_add_rule(struct window_manager *wm, struct rule rule)
{
    buf_push(wm->rules, rule);
}

static inline void window_manager_remove_rule(struct window_manager *wm, int index)
{
    buf_del(wm->rules, index);
}

static inline void window_manager_free_rules(struct window_manager *wm)
{
    buf_free(wm->rules);
    wm->rules = NULL;
}

static inline int window_manager_scratchpad_count(struct window_manager *wm)
{
    return buf_len(wm->scratchpad_window);
}

static inline struct scratchpad *window_manager_scratchpad_at(struct window_manager *wm, int index)
{
    return &wm->scratchpad_window[index];
}

static inline void window_manager_add_scratchpad(struct window_manager *wm, char *label, struct window *window)
{
    buf_push(wm->scratchpad_window, ((struct scratchpad) { .label = label, .window = window }));
}

static inline void window_manager_remove_scratchpad(struct window_manager *wm, int index)
{
    buf_del(wm->scratchpad_window, index);
}

#endif
