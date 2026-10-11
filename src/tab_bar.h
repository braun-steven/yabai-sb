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

enum tab_bar_state
{
    TAB_BAR_UNFOCUSED,
    TAB_BAR_INACTIVE,
    TAB_BAR_FOCUSED
};

struct tab_bar_entry
{
    uint32_t focus_wid;
    CFStringRef title;
    CGImageRef icon;
    enum tab_bar_state state;
};

struct tab_bar_hit
{
    CGRect frame;
    uint64_t sid;
    int entry_count;
    uint32_t entry_list[TAB_BAR_MAX_ENTRY_COUNT];
};

bool tab_bar_set_font(char *font);
bool tab_bar_parse_style(char *name, enum tab_bar_style *style);
void tab_bar_update_palette(void);
bool tab_bar_is_enabled(void);
CFStringRef tab_bar_copy_title(uint32_t wid);
CGImageRef tab_bar_icon(uint32_t wid);
void tab_bar_render(struct tab_bar *bar, CGRect frame, uint32_t above_wid, bool has_focus, struct tab_bar_entry *entry_list, int entry_count);
void tab_bar_hide(struct tab_bar *bar);
void tab_bar_release(struct tab_bar *bar);

void tab_bar_refresh_for_window(uint32_t wid);
void tab_bar_order(uint32_t wid);
int tab_bar_window_list(uint32_t *window_list, int capacity);
bool tab_bar_hit_test(CGPoint point, uint32_t *wid);
void tab_bar_redraw_all(void);
void tab_bar_refresh_all(void);

#endif
