#ifndef BORDER_H
#define BORDER_H

#define BORDER_EDGE_TOP    0
#define BORDER_EDGE_BOTTOM 1
#define BORDER_EDGE_LEFT   2
#define BORDER_EDGE_RIGHT  3
#define BORDER_EDGE_COUNT  4

#define BORDER_DEFAULT_RADIUS 9.0f

struct border
{
    uint32_t wid;
    uint32_t id[BORDER_EDGE_COUNT];
    CGContextRef context[BORDER_EDGE_COUNT];
    CGRect edge[BORDER_EDGE_COUNT];
    CGRect frame;
    CGRect area;
    uint64_t sid;
    float radius;
    float container_radius;
    float drawn_radius;
    float inset_top;
    float inset_left;
    float inset_bottom;
    float inset_right;
    float width;
    uint32_t color;
    bool enabled;
    bool focused;
    bool shown;
    bool sticky;
    bool suspended;
    int level;
    int sub_level;
};

void border_edge_frames(CGRect frame, float width, float radius, CGRect *edge);
void border_begin_batch(void);
void border_end_batch(void);
void border_refresh(struct window *window);
void border_refresh_all(void);
void border_refresh_space(uint64_t sid);
void border_refresh_window_space(struct window *window);
void border_remove(uint32_t wid);
void border_suspend(uint32_t wid, bool suspended);
void border_window_moved(uint32_t wid);
void border_window_resized(uint32_t wid);
void border_window_ordered(uint32_t wid);
void border_window_changed(uint32_t wid);
void border_window_hidden(uint32_t wid);

#endif
