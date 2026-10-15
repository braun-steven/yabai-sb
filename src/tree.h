#ifndef TREE_H
#define TREE_H

//
// NOTE: i3-style container tree used by spaces with the 'tree' layout. The root is the
// workspace container. Leaves hold exactly one window, every other container is either a
// horizontal split, a vertical split or a tabbed container, with any number of children.
//

enum con_layout
{
    CON_SPLITH,
    CON_SPLITV,
    CON_TABBED
};

enum con_orientation
{
    CON_HORIZONTAL,
    CON_VERTICAL
};

enum tree_orientation
{
    TREE_ORIENTATION_AUTO,
    TREE_ORIENTATION_HORIZONTAL,
    TREE_ORIENTATION_VERTICAL
};

static const char *tree_orientation_str[] =
{
    "auto",
    "horizontal",
    "vertical"
};

enum focus_wrapping
{
    FOCUS_WRAPPING_OFF,
    FOCUS_WRAPPING_ON,
    FOCUS_WRAPPING_FORCE
};

static const char *focus_wrapping_str[] =
{
    "off",
    "on",
    "force"
};

enum con_zoom
{
    CON_ZOOM_NONE,
    CON_ZOOM_PARENT,
    CON_ZOOM_FULLSCREEN
};

enum tree_result
{
    TREE_RESULT_NONE,
    TREE_RESULT_DONE,
    TREE_RESULT_OUTPUT
};

enum tree_position
{
    TREE_BEFORE,
    TREE_AFTER
};

//
// NOTE: The tree is Swift (Sources/Yabai/Tree.swift, TreeView.swift).
//

#endif
