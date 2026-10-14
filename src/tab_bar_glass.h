#ifndef TAB_BAR_GLASS_H
#define TAB_BAR_GLASS_H

//
// NOTE: The interface between the C side of the glass tab bars (tab_bar_glass.c) and the AppKit side
// (tab_bar_glass.swift). The unity build includes it like any other header, and swiftc imports it as the
// bridging header of tab_bar_glass.swift, so it must not depend on the other headers of yabai.
//

#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdbool.h>
#include <stdint.h>

enum tab_bar_backdrop
{
    TAB_BAR_BACKDROP_OFF,
    TAB_BAR_BACKDROP_GLASS,
    TAB_BAR_BACKDROP_BLUR,
    TAB_BAR_BACKDROP_COUNT
};

CF_ASSUME_NONNULL_BEGIN

#define TAB_BAR_GLASS_TRACK_MARGIN 2.0f
#define TAB_BAR_GLASS_PILL_INSET 2.0f
#define TAB_BAR_GLASS_ANIMATION_DURATION 0.2

//
// NOTE: A snapshot holds +1 references to its CF objects. The Swift side retains what it keeps and then frees the
// snapshot with tab_bar_glass_snapshot_free.
//

struct tab_bar_glass_entry
{
    CFStringRef _Nullable title;
    CGImageRef _Nullable icon;
    CGColorRef text;
    bool active;
};

struct tab_bar_glass_snapshot
{
    CGRect frame;
    CGRect card;
    enum tab_bar_backdrop backdrop;
    CGFloat card_radius;
    uint64_t sid;
    uint32_t above_wid;
    int level;
    int sub_level;
    CTFontRef _Nullable font;
    CGColorRef track_tint;
    CGColorRef backdrop_tint;
    CGColorRef pill_tint;
    CGColorRef separator;
    int entry_count;
    struct tab_bar_glass_entry *entry_list;
};

static inline CGRect tab_bar_slot(CGRect area, int index, int count)
{
    float width = area.size.width / count;
    float x0 = area.origin.x + (int)(index * width);
    float x1 = index == count - 1 ? area.origin.x + area.size.width : area.origin.x + (int)((index + 1) * width);
    return (CGRect) {{x0, area.origin.y}, {x1 - x0, area.size.height}};
}

// implemented in C
void tab_bar_draw_title(CGContextRef context, CTFontRef _Nullable font, bool glass, CFStringRef _Nullable title, CGImageRef _Nullable icon, CGRect rect, CGColorRef color);
void tab_bar_glass_snapshot_free(struct tab_bar_glass_snapshot *snapshot);
void tab_bar_glass_move_to_space(uint32_t wid, uint64_t sid);
void tab_bar_glass_set_level(uint32_t wid, int level, int sub_level);
void tab_bar_glass_order_panel(uint32_t wid, bool below, uint32_t relative_wid);

// implemented in Swift, only called on macOS 26 and newer
void *_Nullable tab_bar_glass_create(void);
void tab_bar_glass_apply(void *glass, struct tab_bar_glass_snapshot *snapshot);
void tab_bar_glass_hide_panel(void *glass);
void tab_bar_glass_order_above(void *glass, uint32_t wid);
void tab_bar_glass_destroy(void *glass);
uint32_t tab_bar_glass_id(void *glass);

CF_ASSUME_NONNULL_END

#endif
