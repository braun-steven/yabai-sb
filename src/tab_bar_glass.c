//
// NOTE: The glass style uses the Liquid Glass material of macOS 26, which the window server only renders for
// AppKit views. Each bar is therefore a borderless panel owned by AppKit (tab_bar_glass.swift) instead of a raw
// SkyLight window. This side runs on the event loop: it takes a snapshot of a bar and hands it to the Swift side,
// which shows it on the main queue.
//

#define TAB_BAR_GLASS_TRACK_TINT_ALPHA 0.4f
#define TAB_BAR_GLASS_PILL_TINT_ALPHA 0.8f
#define TAB_BAR_GLASS_BACKDROP_TINT_ALPHA 0.4f

void tab_bar_glass_snapshot_free(struct tab_bar_glass_snapshot *snapshot)
{
    for (int i = 0; i < snapshot->entry_count; ++i) {
        struct tab_bar_glass_entry *entry = &snapshot->entry_list[i];
        if (entry->title) CFRelease(entry->title);
        if (entry->icon) CGImageRelease(entry->icon);
        CGColorRelease(entry->text);
    }

    if (snapshot->font) CFRelease(snapshot->font);
    CGColorRelease(snapshot->track_tint);
    CGColorRelease(snapshot->backdrop_tint);
    CGColorRelease(snapshot->pill_tint);
    CGColorRelease(snapshot->separator);
    free(snapshot->entry_list);
    free(snapshot);
}

//
// NOTE: Glass is translucent, so a background color that was never configured is applied as a tint of the i3 color
// with the given alpha instead of the opaque i3 color itself. A configured color is used exactly as given.
//

struct rgba_color tab_bar_glass_tint(struct rgba_color color, bool custom, float alpha)
{
    if (!custom) color.a = alpha;
    return color;
}

void tab_bar_glass_move_to_space(uint32_t wid, uint64_t sid)
{
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
    CFRelease(window_list_ref);
}

void tab_bar_glass_set_level(uint32_t wid, int level, int sub_level)
{
    SLSSetWindowLevel(g_connection, wid, level);
    SLSSetWindowSubLevel(g_connection, wid, sub_level);
}

//
// NOTE: A card ordered below the window lands between the window and its border, so the border is ordered
// right below the window again to stay on top of the card.
//

void tab_bar_glass_order_panel(uint32_t wid, bool below, uint32_t relative_wid)
{
    SLSOrderWindow(g_connection, wid, below ? -1 : 1, relative_wid);
    if (below) border_window_ordered(relative_wid);
}

void tab_bar_glass_render(struct tab_bar *bar, uint32_t above_wid, struct tab_bar_entry *entry_list, int entry_count)
{
    if (@available(macOS 26.0, *)) {
        struct rgba_color track_tint = tab_bar_glass_tint(g_window_manager.tab_bar_unfocused_color, g_window_manager.tab_bar_unfocused_color_custom, TAB_BAR_GLASS_TRACK_TINT_ALPHA);
        struct rgba_color pill_tint = track_tint;

        struct tab_bar_glass_snapshot *snapshot = malloc(sizeof(struct tab_bar_glass_snapshot));
        snapshot->frame = bar->frame;
        snapshot->card = bar->card;
        snapshot->backdrop = g_window_manager.tab_bar_backdrop;
        snapshot->card_radius = g_window_manager.tab_bar_window_radius + (bar->frame.origin.x - bar->card.origin.x);
        snapshot->sid = bar->sid;
        snapshot->above_wid = above_wid;
        snapshot->level = window_level(above_wid);
        snapshot->sub_level = window_sub_level(above_wid);
        snapshot->font = g_window_manager.tab_bar_font ? CFRetain(g_window_manager.tab_bar_font) : NULL;
        snapshot->track_tint = tab_bar_cgcolor(track_tint);
        snapshot->backdrop_tint = tab_bar_cgcolor(tab_bar_glass_tint(g_window_manager.tab_bar_backdrop_color, g_window_manager.tab_bar_backdrop_color_custom, TAB_BAR_GLASS_BACKDROP_TINT_ALPHA));
        snapshot->separator = tab_bar_cgcolor(tab_bar_separator_color(g_window_manager.tab_bar_unfocused_text_color));
        snapshot->entry_count = entry_count;
        snapshot->entry_list = malloc(sizeof(struct tab_bar_glass_entry) * entry_count);

        for (int i = 0; i < entry_count; ++i) {
            struct rgba_color background, text;
            struct tab_bar_glass_entry *entry = &snapshot->entry_list[i];
            tab_bar_state_colors(entry_list[i].state, &background, &text);

            entry->title = entry_list[i].title ? CFRetain(entry_list[i].title) : NULL;
            entry->icon = entry_list[i].icon ? CGImageRetain(entry_list[i].icon) : NULL;
            entry->text = tab_bar_cgcolor(text);
            entry->active = entry_list[i].state != TAB_BAR_UNFOCUSED;

            if (entry_list[i].state == TAB_BAR_FOCUSED) {
                pill_tint = tab_bar_glass_tint(background, g_window_manager.tab_bar_focused_color_custom, TAB_BAR_GLASS_PILL_TINT_ALPHA);
            } else if (entry_list[i].state == TAB_BAR_INACTIVE) {
                pill_tint = tab_bar_glass_tint(background, g_window_manager.tab_bar_inactive_color_custom, TAB_BAR_GLASS_PILL_TINT_ALPHA);
            }
        }

        snapshot->pill_tint = tab_bar_cgcolor(pill_tint);

        if (!bar->glass) bar->glass = tab_bar_glass_create();
        tab_bar_glass_apply(bar->glass, snapshot);
    }
}

void tab_bar_glass_hide(struct tab_bar *bar)
{
    if (bar->glass) tab_bar_glass_hide_panel(bar->glass);
}

void tab_bar_glass_order(struct tab_bar *bar, uint32_t wid)
{
    if (bar->glass) tab_bar_glass_order_above(bar->glass, wid);
}

void tab_bar_glass_release(struct tab_bar *bar)
{
    if (bar->glass) tab_bar_glass_destroy(bar->glass);
}

uint32_t tab_bar_glass_panel_id(struct tab_bar *bar)
{
    return bar->glass ? tab_bar_glass_id(bar->glass) : 0;
}
