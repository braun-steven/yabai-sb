#ifndef WINDOW_H
#define WINDOW_H

//
// NOTE: The functions of struct window are Swift (Sources/Yabai/Window.swift). The struct stays C until
// the remaining rule.c callers and model bridges are removed in P14. notification has the bits
// of the notifications of window_observe (minimized, deminimized, destroyed).
//

struct window
{
    struct application *application;
    AXUIElementRef ref;
    uint32_t id;
    uint32_t *volatile id_ptr;
    CFStringRef role;
    CFStringRef subrole;
    CFStringRef title;
    CGRect frame;
    CGRect frame_request;
    CGRect windowed_frame;
    bool is_root;
    bool is_eligible;
    uint8_t notification;
    uint8_t rule_flags;
    uint8_t flags;
    float opacity;
    int layer;
    char *scratchpad;
};

enum window_flag
{
    WINDOW_SHADOW     = 0x01,
    WINDOW_FULLSCREEN = 0x02,
    WINDOW_MINIMIZE   = 0x04,
    WINDOW_FLOAT      = 0x08,
    WINDOW_STICKY     = 0x10,
    WINDOW_WINDOWED   = 0x20,
    WINDOW_MOVABLE    = 0x40,
    WINDOW_RESIZABLE  = 0x80
};

enum window_rule_flag
{
    WINDOW_RULE_MANAGED    = 0x01,
    WINDOW_RULE_FULLSCREEN = 0x02,
    WINDOW_RULE_MFF        = 0x04,
    WINDOW_RULE_MFF_VALUE  = 0x08
};

static inline bool window_check_flag(struct window *w, enum window_flag x) { return w->flags & x; }
static inline void window_clear_flag(struct window *w, enum window_flag x) { w->flags &= ~x; }
static inline void window_set_flag(struct window *w, enum window_flag x) { w->flags |= x; }

static inline bool window_check_rule_flag(struct window *w, enum window_rule_flag x) { return w->rule_flags & x; }
static inline void window_clear_rule_flag(struct window *w, enum window_rule_flag x) { w->rule_flags &= ~x; }
static inline void window_set_rule_flag(struct window *w, enum window_rule_flag x) { w->rule_flags |= x; }

// implemented in Sources/Yabai/Window.swift
uint64_t window_space(uint32_t wid);
char *window_title_ts(struct window *window);
int window_level(uint32_t wid);
int window_sub_level(uint32_t wid);
bool window_is_sticky(uint32_t wid);
char *window_role_ts(struct window *window);
char *window_subrole_ts(struct window *window);
bool window_is_standard(struct window *window);
bool window_level_is_standard(struct window *window);

//
// NOTE: id_ptr points at id until the window is invalidated. Events that are already queued for a window
// hold on to its memory, so their handlers check that the window is still valid before using it.
// window_invalidate succeeds for exactly one caller, which then owns the destruction of the window.
//

static inline bool window_is_valid(struct window *window)
{
    return __sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id);
}

static inline bool window_invalidate(struct window *window)
{
    return __sync_bool_compare_and_swap(&window->id_ptr, &window->id, NULL);
}

#endif
