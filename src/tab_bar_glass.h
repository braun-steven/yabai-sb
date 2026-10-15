#ifndef TAB_BAR_GLASS_H
#define TAB_BAR_GLASS_H

//
// NOTE: The shared backdrop enum and slot geometry for the tab bars. Snapshot ownership and rendering
// live entirely in Sources/Yabai/TabBarGlass.swift.
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

static inline CGRect tab_bar_slot(CGRect area, int index, int count)
{
    float width = area.size.width / count;
    float x0 = area.origin.x + (int)(index * width);
    float x1 = index == count - 1 ? area.origin.x + area.size.width : area.origin.x + (int)((index + 1) * width);
    return (CGRect) {{x0, area.origin.y}, {x1 - x0, area.size.height}};
}

CF_ASSUME_NONNULL_END

#endif
