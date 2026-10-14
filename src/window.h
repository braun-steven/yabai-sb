#ifndef WINDOW_H
#define WINDOW_H

const CFStringRef kAXFullscreenAttribute = CFSTR("AXFullScreen");

#define AX_WINDOW_MINIMIZED_INDEX      0
#define AX_WINDOW_DEMINIMIZED_INDEX    1
#define AX_WINDOW_DESTROYED_INDEX      2

#define AX_WINDOW_DESTROYED      (1 << AX_WINDOW_DESTROYED_INDEX)
#define AX_WINDOW_MINIMIZED      (1 << AX_WINDOW_MINIMIZED_INDEX)
#define AX_WINDOW_DEMINIMIZED    (1 << AX_WINDOW_DEMINIMIZED_INDEX)
#define AX_WINDOW_ALL            (AX_WINDOW_DESTROYED |\
                                  AX_WINDOW_MINIMIZED |\
                                  AX_WINDOW_DEMINIMIZED)

static const char *ax_window_notification_str[] =
{
    [AX_WINDOW_DESTROYED_INDEX]      = "kAXUIElementDestroyedNotification",
    [AX_WINDOW_MINIMIZED_INDEX]      = "kAXWindowMiniaturizedNotification",
    [AX_WINDOW_DEMINIMIZED_INDEX]    = "kAXWindowDeminiaturizedNotification"
};

static CFStringRef ax_window_notification[] =
{
    [AX_WINDOW_DESTROYED_INDEX]      = kAXUIElementDestroyedNotification,
    [AX_WINDOW_MINIMIZED_INDEX]      = kAXWindowMiniaturizedNotification,
    [AX_WINDOW_DEMINIMIZED_INDEX]    = kAXWindowDeminiaturizedNotification
};

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

CF_RETURNS_RETAINED CFStringRef window_display_uuid(uint32_t wid);
uint32_t window_display_id(uint32_t wid);
uint64_t window_space(uint32_t wid);
uint64_t *window_space_list(uint32_t wid, int *count);
// implemented in Sources/Yabai/IPC/Serialize.swift
void window_serialize(FILE *rsp, struct window *window, uint64_t flags);
char *window_title_ts(struct window *window);
CF_RETURNS_RETAINED CFStringRef window_title(struct window *window);
bool window_shadow(uint32_t wid);
float window_opacity(uint32_t wid);
uint32_t window_parent(uint32_t wid);
int window_level(uint32_t wid);
int window_sub_level(uint32_t wid);
uint64_t window_tags(uint32_t wid);
bool window_is_sticky(uint32_t wid);
CGPoint window_ax_origin(struct window *window);
CGRect window_ax_frame(struct window *window);
CF_RETURNS_RETAINED CFStringRef window_ax_role(struct window *window);
CFStringRef window_role(struct window *window);
char *window_role_ts(struct window *window);
CF_RETURNS_RETAINED CFStringRef window_ax_subrole(struct window *window);
CFStringRef window_subrole(struct window *window);
char *window_subrole_ts(struct window *window);
bool window_ax_can_move(struct window *window);
bool window_can_move(struct window *window);
bool window_ax_can_resize(struct window *window);
bool window_can_resize(struct window *window);
bool window_can_minimize(struct window *window);
bool window_is_undersized(struct window *window);
bool window_is_fullscreen(struct window *window);
bool window_is_real(struct window *window);
bool window_is_standard(struct window *window);
bool window_level_is_standard(struct window *window);
bool window_is_unknown(struct window *window);
bool window_observe(struct window *window);
void window_unobserve(struct window *window);
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

void window_refresh_ax_properties(struct window *window);
struct window *window_create(struct application *application, CF_CONSUMED AXUIElementRef window_ref, uint32_t window_id);
void window_destroy(struct window *window);

#endif
