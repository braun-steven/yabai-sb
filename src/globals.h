#ifndef GLOBALS_H
#define GLOBALS_H

//
// NOTE: The global singletons of yabai.c, which the Swift code uses while the managers are C. Swift 6 rejects references
// to mutable C globals, so Swift takes their addresses (or values) through these functions.
//

extern struct process_manager g_process_manager;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern bool g_verbose;
extern int g_connection;

static inline struct process_manager *process_manager_global(void) { return &g_process_manager; }
static inline struct display_manager *display_manager_global(void) { return &g_display_manager; }
static inline struct space_manager *space_manager_global(void) { return &g_space_manager; }
static inline struct window_manager *window_manager_global(void) { return &g_window_manager; }
static inline struct mouse_state *mouse_state_global(void) { return &g_mouse_state; }
static inline bool *verbose_global(void) { return &g_verbose; }
static inline int connection_global(void) { return g_connection; }
static inline FILE *stdout_global(void) { return stdout; }
static inline char **environ_global(void) { return *_NSGetEnviron(); }

#endif
