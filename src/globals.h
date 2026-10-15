#ifndef GLOBALS_H
#define GLOBALS_H

//
// NOTE: The global singletons (manifest.m), which the Swift code uses while their structs are C. Swift 6 rejects
// references to mutable C globals, so Swift takes their addresses through these functions.
//

extern bool g_verbose;

static inline bool *verbose_global(void) { return &g_verbose; }
static inline enum mission_control_mode *mission_control_mode_global(void) { return &g_mission_control_mode; }

#endif
