#ifndef TAB_BAR_H
#define TAB_BAR_H

#define TAB_BAR_DEFAULT_FONT "Helvetica Neue:12"

struct tab_bar_hit
{
    CGRect frame;
    uint64_t sid;
    int window_count;
    uint32_t window_list[NODE_MAX_WINDOW_COUNT];
};

bool tab_bar_set_font(char *font);
bool tab_bar_is_enabled(void);
bool tab_bar_node_has_bar(struct window_node *node);
struct area tab_bar_window_area(struct window_node *node, struct area area);
void tab_bar_update(struct window_node *node);
void tab_bar_destroy(struct window_node *node);
void tab_bar_refresh_for_window(uint32_t wid);
void tab_bar_order(uint32_t wid);
int tab_bar_window_list(uint32_t *window_list, int capacity);
bool tab_bar_hit_test(CGPoint point, uint32_t *wid);
void tab_bar_redraw_all(void);
void tab_bar_refresh_all(void);

#endif
