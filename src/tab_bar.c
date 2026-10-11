extern int g_connection;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

#define TAB_BAR_TITLE_PADDING 8.0f
#define TAB_BAR_MAX_HIT_COUNT 256
#define TAB_BAR_ICON_SCALE 0.7f
#define TAB_BAR_ICON_SPACING 5.0f
#define TAB_BAR_ICON_PIXEL_SIZE 64.0f
#define TAB_BAR_NATIVE_ICON_SIZE 16.0f
#define TAB_BAR_NATIVE_ICON_SPACING 6.0f
#define TAB_BAR_GLASS_TRACK_MARGIN 2.0f
#define TAB_BAR_GLASS_PILL_INSET 2.0f

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

//
// NOTE: System colors for the native styles, resolved for the current appearance (light, dark,
// increased contrast) and rebuilt when it changes. Only touched from the event loop thread.
//

struct tab_bar_palette
{
    bool valid;
    bool dark;
    bool high_contrast;
    struct rgba_color track;
    struct rgba_color selected;
    struct rgba_color selected_dim;
    struct rgba_color separator;
    struct rgba_color outline;
    struct rgba_color shadow;
    struct rgba_color text;
    struct rgba_color text_secondary;
    struct rgba_color text_dim;
};

static struct tab_bar_palette tab_bar_palette;

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
        hit->entry_count = bar->entry_count;
        memcpy(hit->entry_list, bar->entry_list, sizeof(uint32_t) * bar->entry_count);
    }

    pthread_mutex_unlock(&tab_bar_hit_lock);
}

bool tab_bar_hit_test(CGPoint point, uint32_t *wid)
{
    bool result = false;
    pthread_mutex_lock(&tab_bar_hit_lock);

    for (int i = 0; i < tab_bar_hit_count; ++i) {
        struct tab_bar_hit *hit = &tab_bar_hit_list[i];
        if (!CGRectContainsPoint(hit->frame, point)) continue;
        if (!space_is_visible(hit->sid)) continue;

        int index = (int)((point.x - hit->frame.origin.x) * hit->entry_count / hit->frame.size.width);
        if (index < 0) index = 0;
        if (index >= hit->entry_count) index = hit->entry_count - 1;

        *wid = hit->entry_list[index];
        result = true;
        break;
    }

    pthread_mutex_unlock(&tab_bar_hit_lock);
    return result;
}

static inline CGColorRef tab_bar_cgcolor(struct rgba_color color)
{
    return CGColorCreateSRGB(color.r, color.g, color.b, color.a);
}

static inline struct rgba_color tab_bar_rgba(float r, float g, float b, float a)
{
    return (struct rgba_color) { .r = r, .g = g, .b = b, .a = a };
}

static inline struct rgba_color tab_bar_mix(struct rgba_color a, struct rgba_color b, float t)
{
    return tab_bar_rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
}

static struct rgba_color tab_bar_resolve_color(NSColor *color)
{
    NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!srgb) return tab_bar_rgba(0.0f, 0.0f, 0.0f, 1.0f);
    return tab_bar_rgba([srgb redComponent], [srgb greenComponent], [srgb blueComponent], [srgb alphaComponent]);
}

static bool tab_bar_system_is_dark(void)
{
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    CFStringRef style = CFPreferencesCopyAppValue(CFSTR("AppleInterfaceStyle"), kCFPreferencesAnyApplication);
    if (!style) return false;

    bool result = CFGetTypeID(style) == CFStringGetTypeID() && CFStringCompare(style, CFSTR("Dark"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    CFRelease(style);
    return result;
}

//
// NOTE: The colors are derived from the semantic system colors, the same ones AppKit uses for window tabs.
// The appearance is read from the global defaults instead of NSApp, because NSApp updates its effective
// appearance asynchronously and may still report the old one when the change notification arrives.
//

static void tab_bar_build_palette(struct tab_bar_palette *palette, bool dark, bool high_contrast)
{
    @autoreleasepool {
        palette->dark = dark;
        palette->high_contrast = high_contrast;

        NSAppearanceName name = palette->dark
                              ? (palette->high_contrast ? NSAppearanceNameAccessibilityHighContrastDarkAqua : NSAppearanceNameDarkAqua)
                              : (palette->high_contrast ? NSAppearanceNameAccessibilityHighContrastAqua : NSAppearanceNameAqua);

        __block struct rgba_color window, control, separator, label, secondary, tertiary;
        [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
            window    = tab_bar_resolve_color([NSColor windowBackgroundColor]);
            control   = tab_bar_resolve_color([NSColor controlBackgroundColor]);
            separator = tab_bar_resolve_color([NSColor separatorColor]);
            label     = tab_bar_resolve_color([NSColor labelColor]);
            secondary = tab_bar_resolve_color([NSColor secondaryLabelColor]);
            tertiary  = tab_bar_resolve_color([NSColor tertiaryLabelColor]);
        }];

        struct rgba_color black = tab_bar_rgba(0.0f, 0.0f, 0.0f, 1.0f);
        struct rgba_color white = tab_bar_rgba(1.0f, 1.0f, 1.0f, 1.0f);

        if (palette->dark) {
            palette->track    = tab_bar_mix(window, black, 0.30f);
            palette->selected = tab_bar_mix(window, white, 0.12f);
            palette->shadow   = tab_bar_rgba(0.0f, 0.0f, 0.0f, 0.40f);
        } else {
            palette->track    = tab_bar_mix(window, black, 0.07f);
            palette->selected = control;
            palette->shadow   = tab_bar_rgba(0.0f, 0.0f, 0.0f, 0.15f);
        }

        palette->track.a = 1.0f;
        palette->selected.a = 1.0f;
        palette->selected_dim = tab_bar_mix(palette->selected, palette->track, 0.5f);
        palette->separator = separator;
        palette->outline = palette->high_contrast ? label : separator;
        palette->text = label;
        palette->text_secondary = secondary;
        palette->text_dim = tertiary;
        palette->valid = true;
    }
}

void tab_bar_update_palette(void)
{
    @autoreleasepool {
        tab_bar_build_palette(&tab_bar_palette, tab_bar_system_is_dark(), [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldIncreaseContrast]);
    }
}

static CTLineRef tab_bar_create_line(CFStringRef text, CFDictionaryRef attributes)
{
    CFAttributedStringRef string = CFAttributedStringCreate(NULL, text, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(string);
    CFRelease(string);
    return line;
}

//
// NOTE: Draws the application icon (if any) left of the title and centers both in the tab.
// The title is truncated first; the icon is dropped only when the tab is too narrow for it.
//

static void tab_bar_draw_title(CGContextRef context, CFStringRef title, CGImageRef icon, CGRect rect, struct rgba_color color)
{
    double max_width = rect.size.width - 2.0f * TAB_BAR_TITLE_PADDING;
    if (max_width <= 0) return;

    bool native = g_window_manager.tab_bar_style != TAB_BAR_STYLE_I3;
    CGFloat icon_spacing = native ? TAB_BAR_NATIVE_ICON_SPACING : TAB_BAR_ICON_SPACING;
    CGFloat icon_size = native
                      ? (int) min(TAB_BAR_NATIVE_ICON_SIZE, rect.size.height - 4.0f)
                      : (int)(rect.size.height * TAB_BAR_ICON_SCALE);
    if (!icon || icon_size <= 0 || icon_size > max_width) icon = NULL;

    double text_max_width = icon ? max_width - icon_size - icon_spacing : max_width;
    if (!g_window_manager.tab_bar_font || text_max_width <= 0) title = NULL;

    CTLineRef line = NULL;
    CFDictionaryRef attributes = NULL;
    CGColorRef text_color = NULL;
    CGFloat ascent = 0, descent = 0;
    double text_width = 0;

    if (title) {
        text_color = tab_bar_cgcolor(color);
        const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *values[] = { g_window_manager.tab_bar_font, text_color };
        attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        line = tab_bar_create_line(title, attributes);
        if (CTLineGetTypographicBounds(line, NULL, NULL, NULL) > text_max_width) {
            UniChar ellipsis_char = 0x2026;
            CFStringRef ellipsis = CFStringCreateWithCharacters(NULL, &ellipsis_char, 1);
            CTLineRef token = tab_bar_create_line(ellipsis, attributes);
            CTLineRef truncated = CTLineCreateTruncatedLine(line, text_max_width, kCTLineTruncationEnd, token);
            CFRelease(token);
            CFRelease(ellipsis);

            if (truncated) {
                CFRelease(line);
                line = truncated;
            }
        }

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
        // NOTE: The native styles center the cap height like AppKit controls do, which puts the
        // title on the optical center of the tab instead of the center of ascent and descent.
        //

        CGFloat y = native
                  ? rect.origin.y + (rect.size.height - CTFontGetCapHeight(g_window_manager.tab_bar_font)) * 0.5f
                  : rect.origin.y + (rect.size.height - (ascent + descent)) * 0.5f + descent;

        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        CGContextSetTextPosition(context, (int) x, (int) y);
        CTLineDraw(line, context);

        CFRelease(line);
    }

    if (attributes) CFRelease(attributes);
    if (text_color) CGColorRelease(text_color);
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

static void tab_bar_fill_rounded(CGContextRef context, CGRect rect, CGFloat radius, struct rgba_color fill, struct rgba_color *stroke)
{
    radius = min(radius, min(rect.size.width, rect.size.height) * 0.5f);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);

    CGContextAddPath(context, path);
    CGContextSetRGBFillColor(context, fill.r, fill.g, fill.b, fill.a);
    CGContextFillPath(context);

    if (stroke) {
        CGPathRef inset = CGPathCreateWithRoundedRect(CGRectInset(rect, 0.5f, 0.5f), radius - 0.5f, radius - 0.5f, NULL);
        CGContextAddPath(context, inset);
        CGContextSetRGBStrokeColor(context, stroke->r, stroke->g, stroke->b, stroke->a);
        CGContextSetLineWidth(context, 1.0f);
        CGContextStrokePath(context);
        CGPathRelease(inset);
    }

    CGPathRelease(path);
}

static inline CGRect tab_bar_slot(CGRect area, int index, int count)
{
    float width = area.size.width / count;
    float x0 = area.origin.x + (int)(index * width);
    float x1 = index == count - 1 ? area.origin.x + area.size.width : area.origin.x + (int)((index + 1) * width);
    return (CGRect) {{x0, area.origin.y}, {x1 - x0, area.size.height}};
}

static inline bool tab_bar_entry_is_selected(struct tab_bar_entry *entry)
{
    return entry->state != TAB_BAR_UNFOCUSED;
}

static struct rgba_color tab_bar_native_text_color(struct tab_bar_entry *entry, bool has_focus)
{
    struct tab_bar_palette *palette = &tab_bar_palette;
    if (!has_focus) return tab_bar_entry_is_selected(entry) ? palette->text_secondary : palette->text_dim;
    return tab_bar_entry_is_selected(entry) ? palette->text : palette->text_secondary;
}

static void tab_bar_draw_i3(CGContextRef context, CGRect bounds, struct tab_bar_entry *entry_list, int entry_count)
{
    for (int i = 0; i < entry_count; ++i) {
        struct rgba_color background;
        struct rgba_color text;

        switch (entry_list[i].state) {
        case TAB_BAR_FOCUSED: {
            background = g_window_manager.tab_bar_focused_color;
            text = g_window_manager.tab_bar_focused_text_color;
        } break;
        case TAB_BAR_INACTIVE: {
            background = g_window_manager.tab_bar_inactive_color;
            text = g_window_manager.tab_bar_inactive_text_color;
        } break;
        case TAB_BAR_UNFOCUSED: {
            background = g_window_manager.tab_bar_unfocused_color;
            text = g_window_manager.tab_bar_unfocused_text_color;
        } break;
        }

        CGRect tab = tab_bar_slot(bounds, i, entry_count);
        tab_bar_fill(context, tab, background);

        if (i > 0) {
            CGContextSetRGBFillColor(context, text.r, text.g, text.b, text.a * 0.25f);
            CGContextFillRect(context, (CGRect) {{tab.origin.x, 0}, {1, bounds.size.height}});
        }

        if (entry_list[i].title || entry_list[i].icon) {
            tab_bar_draw_title(context, entry_list[i].title, entry_list[i].icon, tab, text);
        }
    }
}

//
// NOTE: The pre-Tahoe window tabs: a recessed strip where the selected tab takes the window background
// and merges into the window below it, while the other tabs sit behind a hairline and full height separators.
//

static void tab_bar_draw_classic(CGContextRef context, CGRect bounds, bool has_focus, struct tab_bar_entry *entry_list, int entry_count)
{
    struct tab_bar_palette *palette = &tab_bar_palette;
    tab_bar_fill(context, bounds, palette->track);

    for (int i = 0; i < entry_count; ++i) {
        struct tab_bar_entry *entry = &entry_list[i];
        CGRect tab = tab_bar_slot(bounds, i, entry_count);

        if (tab_bar_entry_is_selected(entry)) {
            tab_bar_fill(context, tab, has_focus ? palette->selected : palette->selected_dim);
        } else {
            tab_bar_fill(context, (CGRect) {{tab.origin.x, 0}, {tab.size.width, 1}}, palette->separator);
        }

        if (i > 0 && !tab_bar_entry_is_selected(entry) && !tab_bar_entry_is_selected(&entry_list[i - 1])) {
            tab_bar_fill(context, (CGRect) {{tab.origin.x, 0}, {1, bounds.size.height}}, palette->separator);
        }

        if (entry->title || entry->icon) {
            tab_bar_draw_title(context, entry->title, entry->icon, tab, tab_bar_native_text_color(entry, has_focus));
        }
    }
}

//
// NOTE: The Liquid Glass window tabs of macOS Tahoe: a recessed capsule holds the tabs, the selected
// tab is a raised pill with a soft shadow, and short separators divide the tabs that are not selected.
//

static void tab_bar_draw_glass(CGContextRef context, CGRect bounds, bool has_focus, struct tab_bar_entry *entry_list, int entry_count)
{
    struct tab_bar_palette *palette = &tab_bar_palette;
    struct rgba_color *outline = palette->high_contrast ? &palette->outline : NULL;

    CGRect track = bounds;
    track.origin.y += TAB_BAR_GLASS_TRACK_MARGIN;
    track.size.height -= TAB_BAR_GLASS_TRACK_MARGIN;
    if (track.size.height <= 2.0f * TAB_BAR_GLASS_PILL_INSET) track = bounds;

    tab_bar_fill_rounded(context, track, track.size.height * 0.5f, palette->track, outline);

    CGRect inner = CGRectInset(track, TAB_BAR_GLASS_PILL_INSET, TAB_BAR_GLASS_PILL_INSET);
    CGFloat separator_height = (int)(inner.size.height * 0.5f);

    for (int i = 0; i < entry_count; ++i) {
        struct tab_bar_entry *entry = &entry_list[i];
        CGRect tab = tab_bar_slot(inner, i, entry_count);

        if (tab_bar_entry_is_selected(entry)) {
            CGColorRef shadow = tab_bar_cgcolor(palette->shadow);
            CGContextSaveGState(context);
            CGContextSetShadowWithColor(context, CGSizeMake(0.0f, -1.0f), 3.0f, has_focus ? shadow : NULL);
            tab_bar_fill_rounded(context, tab, tab.size.height * 0.5f, has_focus ? palette->selected : palette->selected_dim, outline);
            CGContextRestoreGState(context);
            CGColorRelease(shadow);
        }

        if (i > 0 && !tab_bar_entry_is_selected(entry) && !tab_bar_entry_is_selected(&entry_list[i - 1])) {
            CGFloat y = (int)(inner.origin.y + (inner.size.height - separator_height) * 0.5f);
            tab_bar_fill(context, (CGRect) {{tab.origin.x, y}, {1, separator_height}}, palette->separator);
        }

        if (entry->title || entry->icon) {
            tab_bar_draw_title(context, entry->title, entry->icon, tab, tab_bar_native_text_color(entry, has_focus));
        }
    }
}

static void tab_bar_draw(struct tab_bar *bar, bool has_focus, struct tab_bar_entry *entry_list, int entry_count)
{
    CGContextRef context = bar->context;
    CGRect bounds = {{0, 0}, bar->frame.size};

    if (!tab_bar_palette.valid) tab_bar_update_palette();

    SLSDisableUpdate(g_connection);
    CGContextClearRect(context, bounds);

    switch (g_window_manager.tab_bar_style) {
    case TAB_BAR_STYLE_GLASS:   tab_bar_draw_glass(context, bounds, has_focus, entry_list, entry_count);   break;
    case TAB_BAR_STYLE_CLASSIC: tab_bar_draw_classic(context, bounds, has_focus, entry_list, entry_count); break;
    case TAB_BAR_STYLE_I3:
    case TAB_BAR_STYLE_COUNT:   tab_bar_draw_i3(context, bounds, entry_list, entry_count);                 break;
    }

    CGContextFlush(context);
    SLSReenableUpdate(g_connection);
}

static void tab_bar_create(struct tab_bar *bar, CGRect frame)
{
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&frame, &frame_region);

    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();
    SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region, 13, &tags, 0, 0, 64, &bar->id, NULL);
    CFRelease(empty_region);
    CFRelease(frame_region);

    sls_window_disable_shadow(bar->id);
    SLSSetWindowResolution(g_connection, bar->id, 2.0f);
    SLSSetWindowOpacity(g_connection, bar->id, 0);
    bar->context = SLWindowContextCreate(g_connection, bar->id, 0);
    bar->frame = frame;

    buf_push(tab_bar_list, bar);
}

//
// NOTE: Creates the bar window if needed, moves it to the frame and to the space of the window it
// sits above, draws the entries and orders it right above that window. Titles stay owned by the caller.
//

void tab_bar_render(struct tab_bar *bar, CGRect frame, uint32_t above_wid, bool has_focus, struct tab_bar_entry *entry_list, int entry_count)
{
    if (entry_count > TAB_BAR_MAX_ENTRY_COUNT) entry_count = TAB_BAR_MAX_ENTRY_COUNT;

    if (!bar->id) {
        tab_bar_create(bar, frame);
    } else if (!CGRectEqualToRect(frame, bar->frame)) {
        CFTypeRef frame_region;
        CGSNewRegionWithRect(&frame, &frame_region);
        SLSDisableUpdate(g_connection);
        SLSSetWindowShape(g_connection, bar->id, 0.0f, 0.0f, frame_region);
        SLSReenableUpdate(g_connection);
        CFRelease(frame_region);
        bar->frame = frame;
    }

    uint64_t sid = window_space(above_wid);
    if (sid && sid != bar->sid) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&bar->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);
        bar->sid = sid;
    }

    bool above_changed = bar->above_wid != above_wid;
    bar->above_wid = above_wid;
    bar->hidden = false;
    bar->entry_count = entry_count;
    for (int i = 0; i < entry_count; ++i) {
        bar->entry_list[i] = entry_list[i].focus_wid;
    }

    tab_bar_draw(bar, has_focus, entry_list, entry_count);

    SLSSetWindowLevel(g_connection, bar->id, window_level(above_wid));
    SLSSetWindowSubLevel(g_connection, bar->id, window_sub_level(above_wid));
    SLSOrderWindow(g_connection, bar->id, 1, above_wid);

    if (above_changed && !workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    tab_bar_publish_hits();
}

void tab_bar_hide(struct tab_bar *bar)
{
    if (!bar->id || bar->hidden) return;

    SLSOrderWindow(g_connection, bar->id, 0, 0);
    bar->hidden = true;

    tab_bar_publish_hits();
}

void tab_bar_release(struct tab_bar *bar)
{
    if (!bar->id) return;

    for (int i = 0; i < buf_len(tab_bar_list); ++i) {
        if (tab_bar_list[i] == bar) {
            buf_del(tab_bar_list, i);
            break;
        }
    }

    SLSOrderWindow(g_connection, bar->id, 0, 0);
    CGContextRelease(bar->context);
    SLSReleaseWindow(g_connection, bar->id);

    void *owner = bar->owner;
    void (*redraw)(void *owner) = bar->redraw;
    memset(bar, 0, sizeof(struct tab_bar));
    bar->owner = owner;
    bar->redraw = redraw;

    if (!workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    tab_bar_publish_hits();
}

void tab_bar_order(uint32_t wid)
{
    for (int i = 0; i < buf_len(tab_bar_list); ++i) {
        struct tab_bar *bar = tab_bar_list[i];
        if (!bar->hidden && bar->above_wid == wid) {
            SLSOrderWindow(g_connection, bar->id, 1, wid);
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
            view_update(view);
            view_flush(view);
        }
    })

    tab_bar_publish_hits();
}
