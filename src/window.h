#ifndef WINDOW_H
#define WINDOW_H

//
// NOTE: The windows are Swift (Sources/Yabai/Window.swift); these are the bits of window.flags and window.rule_flags.
//

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

#endif
