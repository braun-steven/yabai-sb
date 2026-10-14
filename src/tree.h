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

static const char *con_layout_str[] =
{
    "splith",
    "splitv",
    "tabbed"
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
// NOTE: What tree_view.c keeps on screen for a container: the tab that was ordered above the
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

struct con *con_create(enum con_layout layout);
void con_free(struct con *con);
bool con_is_leaf(struct con *con);
enum con_orientation con_orientation(struct con *con);
int con_index(struct con *con);

void tree_attach(struct con *parent, struct con *con, int index);
struct con *tree_detach(struct con *con);
void tree_fix_percent(struct con *con);
void tree_flatten(struct con *con);
struct con *tree_find_window(struct con *root, uint32_t window_id);
struct con *tree_find_selected(struct con *root);
void tree_select(struct con *root, struct con *con);
struct con *tree_focus_candidate(struct con *con);
int tree_window_count(struct con *con);

struct con *tree_first_leaf(struct con *con);
struct con *tree_last_leaf(struct con *con);
struct con *tree_next_leaf(struct con *con);
struct con *tree_prev_leaf(struct con *con);
struct con *tree_tabbed_ancestor(struct con *con);
bool tree_con_is_visible(struct con *con);

void tree_focus(struct con *con);
struct con *tree_descend_focused(struct con *con);
struct con *tree_descend_direction(struct con *con, int direction);
enum tree_result tree_next(struct con *con, int direction, enum focus_wrapping wrapping, bool has_output, struct con **result);

struct con *tree_force_orientation(struct con *root, enum con_orientation orientation);
void tree_insert_con(struct con *con, struct con *target, enum tree_position position);
enum tree_result tree_move(struct con *root, struct con *con, int direction, bool has_output);
void tree_insert_relative(struct con *target, struct con *con, int direction);
void tree_split(struct con *con, enum con_orientation orientation);
void tree_autotile(struct con *target);
void tree_open_con(struct con *root, struct con *con, struct con *target, bool autotile);
void tree_attach_from_direction(struct con *root, struct con *con, int direction);
void tree_set_layout(struct con *con, enum con_layout layout);
enum con_layout tree_toggle_layout(struct con *con, bool split_only);
bool tree_resize(struct con *con, int direction, float delta);
void tree_balance(struct con *con);
void tree_rotate(struct con *con, int degrees);
void tree_mirror(struct con *con, enum con_orientation orientation);
void tree_swap(struct con *a, struct con *b);
int tree_bar_card_inset(struct area area, int bar_height, int bar_inset);
void tree_update(struct con *con, struct area area, int gap, int bar_height, int bar_offset, int bar_inset);
CFStringRef tree_copy_title(struct con *con);

struct con *tree_view_root(struct view *view);
void tree_view_update(struct view *view);
void tree_view_clear(struct view *view);
struct con *tree_view_find_window(struct view *view, uint32_t window_id);
void tree_add_window(struct view *view, struct window *window, uint32_t insertion_point);
void tree_view_attach_from_direction(struct view *view, struct con *con, int direction);
bool tree_remove_window(struct view *view, struct window *window);
uint32_t *tree_view_window_list(struct view *view, int *window_count);
int tree_view_tiled_count(struct view *view);
bool tree_window_border_area(struct view *view, uint32_t window_id, struct area *window_area, struct area *border_area, int *radius);
struct area tree_con_frame(struct view *view, struct con *con);
bool tree_window_needs_flush(struct view *view, uint32_t window_id, CGRect frame);
void tree_flush(struct view *view);
void tree_render_bars(struct con *con);
void tree_release_bars(struct con *con);
void tree_raise_tabs(struct con *con, bool force);
void tree_window_did_receive_focus(struct view *view, uint32_t window_id);
void tree_refresh_for_window(uint32_t window_id);
void tree_selection_show(struct con *con);
void tree_feedback_show(struct con *con, int insert_dir);
void tree_feedback_hide(struct con *con);
bool tree_serialize(FILE *rsp, struct view *view);

#endif
