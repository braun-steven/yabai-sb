#ifndef TAB_BAR_H
#define TAB_BAR_H

#define TAB_BAR_DEFAULT_FONT "system:12"
#define TAB_BAR_SYSTEM_FONT  "system"

enum tab_bar_style
{
    TAB_BAR_STYLE_GLASS,
    TAB_BAR_STYLE_I3,
    TAB_BAR_STYLE_COUNT
};

static const char *tab_bar_style_str[] =
{
    "glass",
    "i3"
};

static const char *tab_bar_backdrop_str[] =
{
    "off",
    "glass",
    "blur"
};

enum tab_bar_state
{
    TAB_BAR_UNFOCUSED,
    TAB_BAR_INACTIVE,
    TAB_BAR_FOCUSED
};

//
// NOTE: The tab bars are Swift (Sources/Yabai/TabBar.swift, TabBarGlass.swift).
//

#endif
