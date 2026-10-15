#ifndef MISSION_CONTROL_H
#define MISSION_CONTROL_H

//
// NOTE: Mission Control is Swift (Sources/Yabai/MissionControl.swift): the AX observer of the Dock and the
// notifications of the window server connection. The mode stays a C global (yabai.c) while C code reads it.
//

enum mission_control_mode
{
    MISSION_CONTROL_MODE_INACTIVE           = 0,
    MISSION_CONTROL_MODE_SHOW               = 1,
    MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS   = 2,
    MISSION_CONTROL_MODE_SHOW_FRONT_WINDOWS = 3,
    MISSION_CONTROL_MODE_SHOW_DESKTOP       = 4
};

extern enum mission_control_mode g_mission_control_mode;

static inline bool mission_control_is_active(void)
{
    return g_mission_control_mode != MISSION_CONTROL_MODE_INACTIVE;
}

#endif
