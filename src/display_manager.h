#ifndef DISPLAY_MANAGER_H
#define DISPLAY_MANAGER_H

#define DOCK_ORIENTATION_BOTTOM 2
#define DOCK_ORIENTATION_LEFT   3
#define DOCK_ORIENTATION_RIGHT  4

enum display_arrangement_order
{
    DISPLAY_ARRANGEMENT_ORDER_DEFAULT,
    DISPLAY_ARRANGEMENT_ORDER_X,
    DISPLAY_ARRANGEMENT_ORDER_Y
};

static const char *display_arrangement_order_str[] =
{
    "default",
    "horizontal",
    "vertical"
};

enum external_bar_mode
{
    EXTERNAL_BAR_OFF,
    EXTERNAL_BAR_MAIN,
    EXTERNAL_BAR_ALL
};

static const char *external_bar_mode_str[] =
{
    "off",
    "main",
    "all"
};

//
// NOTE: The displays are Swift (Sources/Yabai/Display.swift, DisplayManager.swift).
//

#endif
