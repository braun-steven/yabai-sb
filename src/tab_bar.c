extern int g_connection;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

#define TAB_BAR_TITLE_PADDING 8.0f
#define TAB_BAR_MAX_HIT_COUNT 256
#define TAB_BAR_ICON_SCALE 0.7f
#define TAB_BAR_ICON_SPACING 5.0f
#define TAB_BAR_ICON_PIXEL_SIZE 64.0f
#define TAB_BAR_GLASS_ICON_SIZE 16.0f
#define TAB_BAR_GLASS_ICON_SPACING 6.0f

//
// NOTE: Tab bars that currently own a window. Only touched from the event loop thread.
// A bar is embedded in its owner (a stack leaf or a tabbed container), and the owner
// redraws it through the callback when colors or fonts change.
//

static struct tab_bar **tab_bar_list;

//
// NOTE: Snapshot of the visible tab layout, read by the mouse event tap to resolve clicks on a
// tab bar without touching the window tree from another thread.
//

static pthread_mutex_t tab_bar_hit_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tab_bar_hit tab_bar_hit_list[TAB_BAR_MAX_HIT_COUNT];
static int tab_bar_hit_count;

bool tab_bar_set_font(char *font)
{
    char *separator = strrchr(font, ':');
    if (!separator || separator == font) return false;

    float size = 0.0f;
    if (sscanf(separator + 1, "%f", &size) != 1 || size <= 0.0f) return false;

    CTFontRef ct_font = NULL;
    size_t family_length = separator - font;

    if (family_length == strlen(TAB_BAR_SYSTEM_FONT) && strncmp(font, TAB_BAR_SYSTEM_FONT, family_length) == 0) {
        ct_font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
    } else {
        CFStringRef family = CFStringCreateWithBytes(NULL, (const uint8_t *) font, family_length, kCFStringEncodingUTF8, false);
        if (!family) return false;

        ct_font = CTFontCreateWithName(family, size, NULL);
        CFRelease(family);
    }

    if (!ct_font) return false;

    if (g_window_manager.tab_bar_font) CFRelease(g_window_manager.tab_bar_font);
    if (g_window_manager.tab_bar_font_name) free(g_window_manager.tab_bar_font_name);

    g_window_manager.tab_bar_font = ct_font;
    g_window_manager.tab_bar_font_name = string_copy(font);

    return true;
}

bool tab_bar_parse_style(char *name, enum tab_bar_style *style)
{
    for (int i = 0; i < TAB_BAR_STYLE_COUNT; ++i) {
        if (string_equals(name, tab_bar_style_str[i])) {
            *style = i;
            return true;
        }
    }

    return false;
}

bool tab_bar_parse_backdrop(char *name, enum tab_bar_backdrop *backdrop)
{
    for (int i = 0; i < TAB_BAR_BACKDROP_COUNT; ++i) {
        if (string_equals(name, tab_bar_backdrop_str[i])) {
            *backdrop = i;
            return true;
        }
    }

    return false;
}

bool tab_bar_is_enabled(void)
{
    return g_window_manager.enable_tab_bar && g_window_manager.tab_bar_height > 0;
}

static void tab_bar_publish_hits(void)
{
    pthread_mutex_lock(&tab_bar_hit_lock);

    tab_bar_hit_count = 0;
    for (int i = 0; i < buf_len(tab_bar_list) && tab_bar_hit_count < TAB_BAR_MAX_HIT_COUNT; ++i) {
        struct tab_bar *bar = tab_bar_list[i];
        if (bar->hidden || !bar->entry_count) continue;

        struct tab_bar_hit *hit = &tab_bar_hit_list[tab_bar_hit_count++];
        hit->frame = bar->frame;
        hit->sid = bar->sid;
        hit->above_wid = bar->above_wid;
        hit->entry_count = bar->entry_count;
        memcpy(hit->entry_list, bar->entry_list, sizeof(uint32_t) * bar->entry_count);
    }

    pthread_mutex_unlock(&tab_bar_hit_lock);
}

//
// NOTE: The bar only sits right above the window it belongs to, so windows ordered in front of that
// window (menu bar extras, Control Center, notifications, floating windows) may cover it. A click goes
// to the bar only when the window that would receive it is one of ours or is ordered behind the bar.
//

static bool tab_bar_is_covered_at_point(CGPoint point, uint32_t above_wid)
{
    CGPoint window_point;
    uint32_t window_id = 0;
    int window_cid = 0;

    SLSFindWindowAndOwner(g_connection, 0, 1, 0, &point, &window_point, &window_id, &window_cid);

    if (!window_id || window_cid == g_connection || window_id == above_wid) return false;

    CFArrayRef window_list = CGWindowListCreate(kCGWindowListOptionOnScreenAboveWindow, above_wid);
    if (!window_list) return false;

    bool result = CFArrayContainsValue(window_list, CFRangeMake(0, CFArrayGetCount(window_list)), (void *)(uintptr_t) window_id);
    CFRelease(window_list);

    return result;
}

bool tab_bar_hit_test(CGPoint point, uint32_t *wid)
{
    bool found = false;
    uint32_t above_wid = 0;
    pthread_mutex_lock(&tab_bar_hit_lock);

    for (int i = 0; i < tab_bar_hit_count; ++i) {
        struct tab_bar_hit *hit = &tab_bar_hit_list[i];
        if (!CGRectContainsPoint(hit->frame, point)) continue;
        if (!space_is_visible(hit->sid)) continue;

        int index = (int)((point.x - hit->frame.origin.x) * hit->entry_count / hit->frame.size.width);
        if (index < 0) index = 0;
        if (index >= hit->entry_count) index = hit->entry_count - 1;

        *wid = hit->entry_list[index];
        above_wid = hit->above_wid;
        found = true;
        break;
    }

    pthread_mutex_unlock(&tab_bar_hit_lock);
    return found && !tab_bar_is_covered_at_point(point, above_wid);
}

static inline CGColorRef tab_bar_cgcolor(struct rgba_color color)
{
    return CGColorCreateSRGB(color.r, color.g, color.b, color.a);
}

static CTLineRef tab_bar_create_line(CFStringRef text, CFDictionaryRef attributes)
{
    CFAttributedStringRef string = CFAttributedStringCreate(NULL, text, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(string);
    CFRelease(string);
    return line;
}

//
// NOTE: A title that is wider than max_width ends in an ellipsis.
//

static CTLineRef tab_bar_create_fitted_line(CFStringRef title, CFDictionaryRef attributes, double max_width)
{
    CTLineRef line = tab_bar_create_line(title, attributes);
    if (CTLineGetTypographicBounds(line, NULL, NULL, NULL) <= max_width) return line;

    UniChar ellipsis_char = 0x2026;
    CFStringRef ellipsis = CFStringCreateWithCharacters(NULL, &ellipsis_char, 1);
    CTLineRef token = tab_bar_create_line(ellipsis, attributes);
    CTLineRef truncated = CTLineCreateTruncatedLine(line, max_width, kCTLineTruncationEnd, token);
    CFRelease(token);
    CFRelease(ellipsis);

    if (!truncated) return line;

    CFRelease(line);
    return truncated;
}

//
// NOTE: Draws the application icon (if any) left of the title and centers both in the tab.
// The title is truncated first; the icon is dropped only when the tab is too narrow for it.
//

void tab_bar_draw_title(CGContextRef context, CTFontRef font, bool glass, CFStringRef title, CGImageRef icon, CGRect rect, CGColorRef color)
{
    double max_width = rect.size.width - 2.0f * TAB_BAR_TITLE_PADDING;
    if (max_width <= 0) return;

    CGFloat icon_spacing = glass ? TAB_BAR_GLASS_ICON_SPACING : TAB_BAR_ICON_SPACING;
    CGFloat icon_size = glass
                      ? (int) min(TAB_BAR_GLASS_ICON_SIZE, rect.size.height - 4.0f)
                      : (int)(rect.size.height * TAB_BAR_ICON_SCALE);
    if (!icon || icon_size <= 0 || icon_size > max_width) icon = NULL;

    double text_max_width = icon ? max_width - icon_size - icon_spacing : max_width;
    if (!font || text_max_width <= 0) title = NULL;

    CTLineRef line = NULL;
    CFDictionaryRef attributes = NULL;
    CGFloat ascent = 0, descent = 0;
    double text_width = 0;

    if (title) {
        const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *values[] = { font, color };
        attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        line = tab_bar_create_fitted_line(title, attributes, text_max_width);
        text_width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    }

    double content_width = text_width;
    if (icon) content_width += icon_size + (line ? icon_spacing : 0);

    CGFloat x = (int)(rect.origin.x + (rect.size.width - content_width) * 0.5f);

    if (icon) {
        CGFloat y = (int)(rect.origin.y + (rect.size.height - icon_size) * 0.5f);
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, (CGRect) {{x, y}, {icon_size, icon_size}}, icon);
        x += icon_size + icon_spacing;
    }

    if (line) {
        //
        // NOTE: The glass style centers the cap height like AppKit controls do, which puts the
        // title on the optical center of the tab instead of the center of ascent and descent.
        //

        CGFloat y = glass
                  ? rect.origin.y + (rect.size.height - CTFontGetCapHeight(font)) * 0.5f
                  : rect.origin.y + (rect.size.height - (ascent + descent)) * 0.5f + descent;

        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        CGContextSetTextPosition(context, (int) x, (int) y);
        CTLineDraw(line, context);

        CFRelease(line);
    }

    if (attributes) CFRelease(attributes);
}

CFStringRef tab_bar_copy_title(uint32_t wid)
{
    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window) return NULL;

    if (window->title && CFStringGetLength(window->title) > 0) {
        return CFRetain(window->title);
    }

    if (window->application && window->application->name) {
        return CFStringCreateWithCString(NULL, window->application->name, kCFStringEncodingUTF8);
    }

    return NULL;
}

//
// NOTE: The application icon of a window, loaded once per application and owned by it.
//

CGImageRef tab_bar_icon(uint32_t wid)
{
    if (!g_window_manager.tab_bar_icons) return NULL;

    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window || !window->application) return NULL;

    struct application *application = window->application;
    if (application->icon) return application->icon;

    @autoreleasepool {
        NSImage *image = [[NSRunningApplication runningApplicationWithProcessIdentifier:application->pid] icon];
        if (image) {
            NSRect rect = NSMakeRect(0, 0, TAB_BAR_ICON_PIXEL_SIZE, TAB_BAR_ICON_PIXEL_SIZE);
            CGImageRef cg_image = [image CGImageForProposedRect:&rect context:nil hints:nil];
            if (cg_image) application->icon = CGImageRetain(cg_image);
        }
    }

    return application->icon;
}

static inline void tab_bar_fill(CGContextRef context, CGRect rect, struct rgba_color color)
{
    CGContextSetRGBFillColor(context, color.r, color.g, color.b, color.a);
    CGContextFillRect(context, rect);
}

static void tab_bar_state_colors(enum tab_bar_state state, struct rgba_color *background, struct rgba_color *text)
{
    switch (state) {
    case TAB_BAR_FOCUSED: {
        *background = g_window_manager.tab_bar_focused_color;
        *text = g_window_manager.tab_bar_focused_text_color;
    } break;
    case TAB_BAR_INACTIVE: {
        *background = g_window_manager.tab_bar_inactive_color;
        *text = g_window_manager.tab_bar_inactive_text_color;
    } break;
    case TAB_BAR_UNFOCUSED: {
        *background = g_window_manager.tab_bar_unfocused_color;
        *text = g_window_manager.tab_bar_unfocused_text_color;
    } break;
    }
}

static inline struct rgba_color tab_bar_separator_color(struct rgba_color text)
{
    text.a *= 0.25f;
    return text;
}

static void tab_bar_draw_i3(CGContextRef context, CGRect bounds, struct tab_bar_entry *entry_list, int entry_count)
{
    for (int i = 0; i < entry_count; ++i) {
        struct rgba_color background;
        struct rgba_color text;
        tab_bar_state_colors(entry_list[i].state, &background, &text);

        CGRect tab = tab_bar_slot(bounds, i, entry_count);
        tab_bar_fill(context, tab, background);

        if (i > 0) {
            tab_bar_fill(context, (CGRect) {{tab.origin.x, 0}, {1, bounds.size.height}}, tab_bar_separator_color(text));
        }

        if (entry_list[i].title || entry_list[i].icon) {
            CGColorRef text_color = tab_bar_cgcolor(text);
            tab_bar_draw_title(context, g_window_manager.tab_bar_font, false, entry_list[i].title, entry_list[i].icon, tab, text_color);
            CGColorRelease(text_color);
        }
    }
}

static void tab_bar_draw(struct tab_bar *bar, struct tab_bar_entry *entry_list, int entry_count)
{
    CGContextRef context = bar->context;
    CGRect bounds = {{0, 0}, bar->frame.size};

    SLSDisableUpdate(g_connection);
    CGContextClearRect(context, bounds);

    tab_bar_draw_i3(context, bounds, entry_list, entry_count);

    CGContextFlush(context);
    SLSReenableUpdate(g_connection);
}

static inline bool tab_bar_uses_glass(void)
{
    if (@available(macOS 26.0, *)) return g_window_manager.tab_bar_style == TAB_BAR_STYLE_GLASS;
    return false;
}

int tab_bar_card_padding(void)
{
    if (!tab_bar_uses_glass() || g_window_manager.tab_bar_backdrop == TAB_BAR_BACKDROP_OFF) return 0;
    return g_window_manager.tab_bar_card_padding;
}

static inline bool tab_bar_exists(struct tab_bar *bar)
{
    return bar->id || bar->glass;
}

static void tab_bar_create(struct tab_bar *bar, CGRect frame)
{
    bar->frame = frame;
    buf_push(tab_bar_list, bar);

    if (tab_bar_uses_glass()) return;

    //
    // NOTE: Created with SLSNewWindow instead of SLSNewWindowWithOpaqueShapeAndContext, because a window of the latter
    // is moved to the active space each time it is ordered in again, so a bar that was hidden and shown again would
    // land on whatever space is visible instead of the space of its window.
    //

    CFTypeRef frame_region;
    CGSNewRegionWithRect(&frame, &frame_region);
    SLSNewWindow(g_connection, 2, 0, 0, frame_region, &bar->id);
    CFRelease(frame_region);

    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    SLSSetWindowTags(g_connection, bar->id, &tags, 64);
    sls_window_disable_shadow(bar->id);
    SLSSetWindowResolution(g_connection, bar->id, 2.0f);
    SLSSetWindowOpacity(g_connection, bar->id, 0);
    bar->context = SLWindowContextCreate(g_connection, bar->id, 0);
}

//
// NOTE: Ordering a bar in can still move it to the active space, so its space is checked after every order and
// fixed up when it no longer matches the space of the window it sits above.
//

static void tab_bar_keep_on_space(struct tab_bar *bar)
{
    if (!bar->id || !bar->sid || window_space(bar->id) == bar->sid) return;

    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&bar->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, bar->sid);
    CFRelease(window_list_ref);
}

//
// NOTE: Creates the bar window if needed, moves it to the frame and to the space of the window it
// sits above, draws the entries and orders it right above that window (right below it for a glass bar
// with a backdrop card, which then covers the whole card). Titles stay owned by the caller.
//

void tab_bar_render(struct tab_bar *bar, CGRect frame, CGRect card, uint32_t above_wid, struct tab_bar_entry *entry_list, int entry_count)
{
    bar->card = card;
    if (entry_count > TAB_BAR_MAX_ENTRY_COUNT) entry_count = TAB_BAR_MAX_ENTRY_COUNT;

    if (!tab_bar_exists(bar)) {
        tab_bar_create(bar, frame);
    } else if (!CGRectEqualToRect(frame, bar->frame)) {
        if (bar->id) {
            CFTypeRef frame_region;
            CGSNewRegionWithRect(&frame, &frame_region);
            SLSDisableUpdate(g_connection);
            SLSSetWindowShape(g_connection, bar->id, 0.0f, 0.0f, frame_region);
            SLSReenableUpdate(g_connection);
            CFRelease(frame_region);
        }
        bar->frame = frame;
    }

    uint64_t sid = window_space(above_wid);
    if (sid && sid != bar->sid) {
        if (bar->id) {
            CFArrayRef window_list_ref = cfarray_of_cfnumbers(&bar->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
            SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
            CFRelease(window_list_ref);
        }
        bar->sid = sid;
    }

    bool above_changed = bar->above_wid != above_wid;
    bar->above_wid = above_wid;
    bar->hidden = false;
    bar->entry_count = entry_count;
    for (int i = 0; i < entry_count; ++i) {
        bar->entry_list[i] = entry_list[i].focus_wid;
    }

    if (bar->id) {
        tab_bar_draw(bar, entry_list, entry_count);

        SLSSetWindowLevel(g_connection, bar->id, window_level(above_wid));
        SLSSetWindowSubLevel(g_connection, bar->id, window_sub_level(above_wid));
        SLSOrderWindow(g_connection, bar->id, 1, above_wid);
        tab_bar_keep_on_space(bar);
    } else {
        tab_bar_glass_render(bar, above_wid, entry_list, entry_count);
    }

    if (above_changed && !workspace_is_macos_sequoia_or_newer()) {
        update_window_notifications();
    }

    tab_bar_publish_hits();
}

void tab_bar_hide(struct tab_bar *bar)
{
    if (!tab_bar_exists(bar) || bar->hidden) return;

    if (bar->id) {
        SLSOrderWindow(g_connection, bar->id, 0, 0);
    } else {
        tab_bar_glass_hide(bar);
    }

    bar->hidden = true;

    tab_bar_publish_hits();
}

void tab_bar_release(struct tab_bar *bar)
{
    if (!tab_bar_exists(bar)) return;

    for (int i = 0; i < buf_len(tab_bar_list); ++i) {
        if (tab_bar_list[i] == bar) {
            buf_del(tab_bar_list, i);
            break;
        }
    }

    if (bar->id) {
        SLSOrderWindow(g_connection, bar->id, 0, 0);
        CGContextRelease(bar->context);
        SLSReleaseWindow(g_connection, bar->id);
    } else {
        tab_bar_glass_release(bar);
    }

    void *owner = bar->owner;
    void (*redraw)(void *owner) = bar->redraw;
    memset(bar, 0, sizeof(struct tab_bar));
    bar->owner = owner;
    bar->redraw = redraw;

    if (!workspace_is_macos_sequoia_or_newer()) {
        update_window_notifications();
    }

    tab_bar_publish_hits();
}

//
// NOTE: Window id of the backdrop card of a visible bar, or 0 when it has none (yet). The panel is created on the
// main queue, so the id only becomes known after the first update of the bar reaches it.
//

uint32_t tab_bar_card_id(struct tab_bar *bar)
{
    if (bar->hidden || !bar->glass) return 0;
    if (!tab_bar_uses_glass() || g_window_manager.tab_bar_backdrop == TAB_BAR_BACKDROP_OFF) return 0;

    return tab_bar_glass_panel_id(bar);
}

void tab_bar_order(uint32_t wid)
{
    for (int i = 0; i < buf_len(tab_bar_list); ++i) {
        struct tab_bar *bar = tab_bar_list[i];
        if (bar->hidden || bar->above_wid != wid) continue;

        if (bar->id) {
            SLSOrderWindow(g_connection, bar->id, 1, wid);
            tab_bar_keep_on_space(bar);
        } else {
            tab_bar_glass_order(bar, wid);
        }
    }
}

int tab_bar_window_list(uint32_t *window_list, int capacity)
{
    int count = 0;

    for (int i = 0; i < buf_len(tab_bar_list) && count < capacity; ++i) {
        window_list[count++] = tab_bar_list[i]->above_wid;
    }

    return count;
}

void tab_bar_redraw_all(void)
{
    for (int i = 0; i < buf_len(tab_bar_list); ++i) {
        struct tab_bar *bar = tab_bar_list[i];
        if (bar->redraw) bar->redraw(bar->owner);
    }
}

void tab_bar_refresh_for_window(uint32_t wid)
{
    if (!wid) return;

    struct view *view = table_find(&g_window_manager.managed_window, &wid);
    if (!view || view->layout != VIEW_TREE) return;

    tree_refresh_for_window(wid);
}

//
// NOTE: Called after a tab bar config change that affects the layout. Drops every bar so that the next layout pass
// recreates them with the new settings, then re-lays out all views to apply the new window area.
//

void tab_bar_refresh_all(void)
{
    table_for (struct view *view, g_space_manager.view, {
        if (view->layout == VIEW_TREE) {
            if (view->tree) tree_release_bars(view->tree);
            view_update_and_flush(view);
        }
    })

    tab_bar_publish_hits();
}
