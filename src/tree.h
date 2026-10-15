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
// NOTE: What TreeView.swift keeps on screen for a container: the tab that was ordered above the
// others last (with the window and backdrop card it was ordered against), the outline window
// and the tab bar.
//

struct con_render
{
    struct con *raised;
    uint32_t raised_anchor;
    uint32_t raised_card;
    struct feedback_window feedback_window;
    struct tab_bar tab_bar;
};

struct con
{
    struct con *parent;
    struct con **children;
    struct con **focus;
    int child_count;
    int child_capacity;
    enum con_layout layout;
    enum con_layout last_split;
    float percent;
    uint32_t window_id;
    struct area area;
    enum con_zoom zoom;
    bool selected;
    int insert_dir;
    struct con_render render;
};

//
// NOTE: The tree is Swift (Sources/Yabai/Tree.swift, TreeView.swift). struct con stays C while mouse_handler.c,
// border.c and tab_bar.c use it. These are the functions that C still calls (con_create, con_free, tree_attach,
// tree_focus and tree_update for the C test of border.c).
//

// implemented in Sources/Yabai/Tree.swift
struct con *con_create(enum con_layout layout);
void con_free(struct con *con);
void tree_attach(struct con *parent, struct con *con, int index);
struct con *tree_detach(struct con *con);
void tree_flatten(struct con *con);
struct con *tree_find_window(struct con *root, uint32_t window_id);
void tree_focus(struct con *con);
void tree_insert_relative(struct con *target, struct con *con, int direction);
void tree_update(struct con *con, struct area area, int gap, int bar_height, int bar_offset, int bar_inset);

// implemented in Sources/Yabai/TreeView.swift
void tree_view_update(struct view *view);
struct con *tree_view_find_window(struct view *view, uint32_t window_id);
uint32_t *tree_view_window_list(struct view *view, int *window_count);
int tree_view_tiled_count(struct view *view);
bool tree_window_border_area(struct view *view, uint32_t window_id, struct area *window_area, struct area *border_area, int *radius);
void tree_release_bars(struct con *con);
void tree_refresh_for_window(uint32_t window_id);
void tree_feedback_show(struct con *con, int insert_dir);
void tree_feedback_hide(struct con *con);

#endif
