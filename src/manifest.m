#include "include/yabai_c.h"

#define HASHTABLE_IMPLEMENTATION
#include "misc/hashtable.h"
#undef HASHTABLE_IMPLEMENTATION

//
// NOTE: The global singletons, C until their structs are Swift (doc/swift-port.md, P14). The daemon starts in
// Sources/Yabai/Yabai.swift.
//


enum mission_control_mode g_mission_control_mode;

char g_sa_socket_file[MAXLEN];

bool g_verbose;
