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
    struct con *zoom;
    struct con *raised;
    bool selected;
    int insert_dir;
    struct feedback_window feedback_window;
    struct tab_bar tab_bar;
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

void tree_force_orientation(struct con *root, enum con_orientation orientation);
void tree_insert_con(struct con *con, struct con *target, enum tree_position position);
enum tree_result tree_move(struct con *root, struct con *con, int direction, bool has_output);
void tree_insert_relative(struct con *target, struct con *con, int direction);
void tree_split(struct con *con, enum con_orientation orientation);
void tree_set_layout(struct con *con, enum con_layout layout);
enum con_layout tree_toggle_layout(struct con *con, bool split_only);
bool tree_resize(struct con *con, int direction, float delta);
void tree_balance(struct con *con);
void tree_rotate(struct con *con, int degrees);
void tree_mirror(struct con *con, enum con_orientation orientation);
void tree_swap(struct con *a, struct con *b);
void tree_update(struct con *con, struct area area, int gap, int bar_height);
CFStringRef tree_copy_title(struct con *con);

#endif
