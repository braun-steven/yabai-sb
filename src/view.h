#ifndef VIEW_H
#define VIEW_H

#define AX_ABS(a, b) (((a) - (b) < 0) ? (((a) - (b)) * -1) : ((a) - (b)))
#define AX_DIFF(a, b) (AX_ABS(a, b) >= 1.5f)

#define SPACE_PROPERTY_LIST \
    SPACE_PROPERTY_ENTRY("id",                   SPACE_PROPERTY_ID,            0x001) \
    SPACE_PROPERTY_ENTRY("uuid",                 SPACE_PROPERTY_UUID,          0x002) \
    SPACE_PROPERTY_ENTRY("index",                SPACE_PROPERTY_INDEX,         0x004) \
    SPACE_PROPERTY_ENTRY("label",                SPACE_PROPERTY_LABEL,         0x008) \
    SPACE_PROPERTY_ENTRY("type",                 SPACE_PROPERTY_TYPE,          0x010) \
    SPACE_PROPERTY_ENTRY("display",              SPACE_PROPERTY_DISPLAY,       0x020) \
    SPACE_PROPERTY_ENTRY("windows",              SPACE_PROPERTY_WINDOWS,       0x040) \
    SPACE_PROPERTY_ENTRY("first-window",         SPACE_PROPERTY_FIRST_WINDOW,  0x080) \
    SPACE_PROPERTY_ENTRY("last-window",          SPACE_PROPERTY_LAST_WINDOW,   0x100) \
    SPACE_PROPERTY_ENTRY("has-focus",            SPACE_PROPERTY_HAS_FOCUS,     0x200) \
    SPACE_PROPERTY_ENTRY("is-visible",           SPACE_PROPERTY_IS_VISIBLE,    0x400) \
    SPACE_PROPERTY_ENTRY("is-native-fullscreen", SPACE_PROPERTY_IS_FULLSCREEN, 0x800)

enum space_property
{
#define SPACE_PROPERTY_ENTRY(n, p, v) p = v,
    SPACE_PROPERTY_LIST
#undef SPACE_PROPERTY_ENTRY
};

static uint64_t space_property_val[] =
{
#define SPACE_PROPERTY_ENTRY(n, p, v) p,
    SPACE_PROPERTY_LIST
#undef SPACE_PROPERTY_ENTRY
};

static char *space_property_str[] =
{
#define SPACE_PROPERTY_ENTRY(n, p, v) n,
    SPACE_PROPERTY_LIST
#undef SPACE_PROPERTY_ENTRY
};

struct area
{
    float x;
    float y;
    float w;
    float h;
};

struct window;
struct window_capture
{
    struct window *window;
    float x, y, w, h;
};

struct window_proxy
{
    uint32_t id;
    CGContextRef context;
    float tx, ty, tw, th;
    CGRect frame;
    int level;
    int sub_level;
    CGImageRef image;
};

struct window_animation
{
    struct window *window;
    uint32_t wid;
    float x, y, w, h;
    int cid;
    struct window_proxy proxy;
    volatile bool skip;
};

struct window_animation_context
{
    int animation_connection;
    int animation_easing;
    float animation_duration;
    uint64_t animation_clock;
    struct window_animation *animation_list;
    int animation_count;
};

enum window_insertion_point
{
    INSERT_FOCUSED,
    INSERT_FIRST,
    INSERT_LAST
};

static const char *window_insertion_point_str[] =
{
    "focused",
    "first",
    "last"
};

enum window_node_child
{
    CHILD_NONE,
    CHILD_SECOND,
    CHILD_FIRST,
};

static const char *window_node_child_str[] =
{
    "none",
    "second_child",
    "first_child"
};

enum window_node_split
{
    SPLIT_NONE,
    SPLIT_Y,
    SPLIT_X,
    SPLIT_AUTO
};

static const char *window_node_split_str[] =
{
    "none",
    "vertical",
    "horizontal",
    "auto"
};

static const char *auto_balance_str[] = {
    "off",
    "vertical",
    "horizontal",
    "on"
};

struct feedback_window
{
    uint32_t id;
    CGContextRef context;
};

#define TAB_BAR_MAX_ENTRY_COUNT 64
struct tab_bar
{
    uint32_t id;
    CGContextRef context;
    CGRect frame;
    uint64_t sid;
    uint32_t above_wid;
    bool hidden;
    int entry_count;
    uint32_t entry_list[TAB_BAR_MAX_ENTRY_COUNT];
    void *owner;
    void (*redraw)(void *owner);
};

enum view_type
{
    VIEW_DEFAULT,
    VIEW_FLOAT,
    VIEW_TREE
};

static const char *view_type_str[] =
{
    "default",
    "float",
    "tree"
};

enum view_flag
{
    VIEW_LAYOUT         = 0x001,
    VIEW_TOP_PADDING    = 0x002,
    VIEW_BOTTOM_PADDING = 0x004,
    VIEW_LEFT_PADDING   = 0x008,
    VIEW_RIGHT_PADDING  = 0x010,
    VIEW_WINDOW_GAP     = 0x020,
    VIEW_AUTO_BALANCE   = 0x040,
    VIEW_ENABLE_PADDING = 0x080,
    VIEW_ENABLE_GAP     = 0x100,
    VIEW_IS_VALID       = 0x200,
    VIEW_IS_DIRTY       = 0x400,
    VIEW_SPLIT_TYPE     = 0x800,
    VIEW_AUTO_PADDING   = 0x1000,
    VIEW_IS_UNPADDED    = 0x2000,
};

struct view
{
    CFStringRef uuid;
    uint64_t sid;
    struct area area;
    struct con *tree;
    uint32_t insertion_point;
    enum view_type layout;
    enum window_node_split split_type;
    int top_padding;
    int bottom_padding;
    int left_padding;
    int right_padding;
    int window_gap;
    uint32_t auto_balance;
    bool auto_padding;
    uint64_t flags;
};

#define view_check_flag(v, x) ((v)->flags  &  (x))
#define view_clear_flag(v, x) ((v)->flags &= ~(x))
#define view_set_flag(v, x)   ((v)->flags |=  (x))

void view_add_window(struct view *view, struct window *window, uint32_t insertion_point);
bool view_remove_window(struct view *view, struct window *window);
uint32_t *view_find_window_list(struct view *view, int *window_count);

int view_window_gap(struct view *view);
bool view_auto_padding_applies(enum view_type layout, bool auto_padding, int tiled_window_count);
int view_tiled_window_count(struct view *view);
bool view_update_auto_padding(struct view *view);

void view_serialize(FILE *rsp, struct view *view, uint64_t flags);
bool view_is_invalid(struct view *view);
bool view_is_dirty(struct view *view);
void view_flush(struct view *view);
void view_update(struct view *view);
struct view *view_create(uint64_t sid);
void view_destroy(struct view *view);
void view_clear(struct view *view);

#endif
