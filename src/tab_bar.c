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
#define TAB_BAR_GLASS_TRACK_MARGIN 2.0f
#define TAB_BAR_GLASS_PILL_INSET 2.0f
#define TAB_BAR_GLASS_TRACK_TINT_ALPHA 0.4f
#define TAB_BAR_GLASS_PILL_TINT_ALPHA 0.8f
#define TAB_BAR_GLASS_ANIMATION_DURATION 0.2

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

static void tab_bar_draw_title(CGContextRef context, CTFontRef font, bool glass, CFStringRef title, CGImageRef icon, CGRect rect, struct rgba_color color)
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
    CGColorRef text_color = NULL;
    CGFloat ascent = 0, descent = 0;
    double text_width = 0;

    if (title) {
        text_color = tab_bar_cgcolor(color);
        const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *values[] = { font, text_color };
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

static inline CGRect tab_bar_slot(CGRect area, int index, int count)
{
    float width = area.size.width / count;
    float x0 = area.origin.x + (int)(index * width);
    float x1 = index == count - 1 ? area.origin.x + area.size.width : area.origin.x + (int)((index + 1) * width);
    return (CGRect) {{x0, area.origin.y}, {x1 - x0, area.size.height}};
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
            tab_bar_draw_title(context, g_window_manager.tab_bar_font, false, entry_list[i].title, entry_list[i].icon, tab, text);
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

//
// NOTE: The glass style uses the Liquid Glass material of macOS 26, which the window server only renders for
// AppKit views. Each bar is therefore a borderless panel owned by AppKit instead of a raw SkyLight window. AppKit
// must be used from the main thread, so the event loop hands a snapshot of the bar to the main queue, and the
// panel is retained by every pending block so that releasing a bar never frees a panel that is still in use.
//

struct tab_bar_glass_entry
{
    CFStringRef title;
    CGImageRef icon;
    struct rgba_color text;
    bool active;
};

struct tab_bar_glass_snapshot
{
    CGRect frame;
    uint64_t sid;
    uint32_t above_wid;
    int level;
    int sub_level;
    CTFontRef font;
    struct rgba_color track_tint;
    struct rgba_color pill_tint;
    struct rgba_color separator;
    int entry_count;
    struct tab_bar_glass_entry entry_list[TAB_BAR_MAX_ENTRY_COUNT];
};

static void tab_bar_glass_snapshot_free(struct tab_bar_glass_snapshot *snapshot)
{
    if (!snapshot) return;

    for (int i = 0; i < snapshot->entry_count; ++i) {
        if (snapshot->entry_list[i].title) CFRelease(snapshot->entry_list[i].title);
        if (snapshot->entry_list[i].icon) CGImageRelease(snapshot->entry_list[i].icon);
    }

    if (snapshot->font) CFRelease(snapshot->font);
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

static inline CGRect tab_bar_glass_track(CGRect bounds)
{
    CGRect track = bounds;
    track.origin.y += TAB_BAR_GLASS_TRACK_MARGIN;
    track.size.height -= TAB_BAR_GLASS_TRACK_MARGIN;
    return track.size.height <= 2.0f * TAB_BAR_GLASS_PILL_INSET ? bounds : track;
}

static inline CGRect tab_bar_glass_inner(CGRect bounds)
{
    return CGRectInset(tab_bar_glass_track(bounds), TAB_BAR_GLASS_PILL_INSET, TAB_BAR_GLASS_PILL_INSET);
}

@interface tab_bar_glass_content : NSView
{
@public
    struct tab_bar_glass_snapshot *snapshot;
}
@end

@implementation tab_bar_glass_content
- (BOOL)isOpaque
{
    return NO;
}

- (void)drawRect:(NSRect)dirty
{
    if (!snapshot || !snapshot->entry_count) return;

    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    CGRect inner = tab_bar_glass_inner(NSRectToCGRect(self.bounds));
    CGFloat separator_height = (int)(inner.size.height * 0.5f);

    for (int i = 0; i < snapshot->entry_count; ++i) {
        struct tab_bar_glass_entry *entry = &snapshot->entry_list[i];
        CGRect tab = tab_bar_slot(inner, i, snapshot->entry_count);

        if (i > 0 && !entry->active && !snapshot->entry_list[i - 1].active) {
            CGFloat y = (int)(inner.origin.y + (inner.size.height - separator_height) * 0.5f);
            tab_bar_fill(context, (CGRect) {{tab.origin.x, y}, {1, separator_height}}, snapshot->separator);
        }

        if (entry->title || entry->icon) {
            tab_bar_draw_title(context, snapshot->font, true, entry->title, entry->icon, tab, entry->text);
        }
    }
}

- (void)dealloc
{
    tab_bar_glass_snapshot_free(snapshot);
    [super dealloc];
}
@end

//
// NOTE: The tint is a layer inside the glass instead of NSGlassEffectView.tintColor, because AppKit draws glass in its
// desaturated inactive look in an app that is never active, which hides most of the tint color. The layer sits on
// the glass, keeps its rounded shape and moves with it, so the pill keeps its color while it animates.
//

API_AVAILABLE(macos(26.0))
static void tab_bar_glass_add_tint(NSGlassEffectView *glass)
{
    NSView *tint = [[NSView alloc] initWithFrame:NSZeroRect];
    tint.wantsLayer = YES;
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.contentView = tint;
    [tint release];
}

API_AVAILABLE(macos(26.0))
static void tab_bar_glass_set_tint(NSGlassEffectView *glass, struct rgba_color color)
{
    CALayer *layer = glass.contentView.layer;
    CGColorRef cg_color = tab_bar_cgcolor(color);
    layer.backgroundColor = cg_color;
    layer.cornerRadius = glass.cornerRadius;
    CGColorRelease(cg_color);
}

API_AVAILABLE(macos(26.0))
@interface tab_bar_glass : NSObject
{
    NSPanel *panel;
    NSView *root;
    NSGlassEffectView *track;
    NSGlassEffectView *pill;
    tab_bar_glass_content *content;
}
- (void)apply:(struct tab_bar_glass_snapshot *)snapshot;
- (void)hide;
- (void)orderAbove:(uint32_t)wid;
@end

@implementation tab_bar_glass
- (id)init
{
    if ((self = [super init])) {
        panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                           styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        panel.releasedWhenClosed = NO;
        panel.opaque = NO;
        panel.backgroundColor = [NSColor clearColor];
        panel.hasShadow = NO;
        panel.ignoresMouseEvents = YES;
        panel.animationBehavior = NSWindowAnimationBehaviorNone;
        panel.collectionBehavior = NSWindowCollectionBehaviorManaged |
                                   NSWindowCollectionBehaviorIgnoresCycle |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary;

        root = [[NSView alloc] initWithFrame:NSZeroRect];
        track = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        pill = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        tab_bar_glass_add_tint(track);
        tab_bar_glass_add_tint(pill);
        content = [[tab_bar_glass_content alloc] initWithFrame:NSZeroRect];

        [root addSubview:track];
        [root addSubview:pill];
        [root addSubview:content];
        panel.contentView = root;
    }

    return self;
}

- (void)layout:(struct tab_bar_glass_snapshot *)snapshot animate:(bool)animate
{
    NSRect bounds = NSMakeRect(0, 0, snapshot->frame.size.width, snapshot->frame.size.height);
    NSRect track_frame = NSRectFromCGRect(tab_bar_glass_track(NSRectToCGRect(bounds)));
    CGRect inner = tab_bar_glass_inner(NSRectToCGRect(bounds));

    int active = -1;
    for (int i = 0; i < snapshot->entry_count; ++i) {
        if (snapshot->entry_list[i].active) { active = i; break; }
    }

    root.frame = bounds;
    track.frame = track_frame;
    track.cornerRadius = track_frame.size.height * 0.5f;
    tab_bar_glass_set_tint(track, snapshot->track_tint);
    content.frame = bounds;

    pill.hidden = active < 0;
    if (active < 0) return;

    NSRect pill_frame = NSRectFromCGRect(tab_bar_slot(inner, active, snapshot->entry_count));
    pill.cornerRadius = pill_frame.size.height * 0.5f;
    tab_bar_glass_set_tint(pill, snapshot->pill_tint);

    if (animate && !NSEqualRects(pill.frame, pill_frame)) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = TAB_BAR_GLASS_ANIMATION_DURATION;
            context.allowsImplicitAnimation = YES;
            pill.animator.frame = pill_frame;
        }];
    } else {
        pill.frame = pill_frame;
    }
}

- (void)apply:(struct tab_bar_glass_snapshot *)snapshot
{
    CGRect frame = snapshot->frame;
    CGFloat primary_height = CGDisplayBounds(CGMainDisplayID()).size.height;
    NSRect cocoa_frame = NSMakeRect(frame.origin.x, primary_height - frame.origin.y - frame.size.height, frame.size.width, frame.size.height);

    bool visible = panel.isVisible;
    bool resized = !NSEqualSizes(panel.frame.size, cocoa_frame.size);

    [NSAnimationContext beginGrouping];
    [NSAnimationContext currentContext].duration = 0;
    [panel setFrame:cocoa_frame display:NO];
    [self layout:snapshot animate:visible && !resized];
    [NSAnimationContext endGrouping];

    tab_bar_glass_snapshot_free(content->snapshot);
    content->snapshot = snapshot;
    [content setNeedsDisplay:YES];

    uint32_t wid = (uint32_t) panel.windowNumber;
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, snapshot->sid);

    if (!visible) [panel orderWindow:NSWindowAbove relativeTo:snapshot->above_wid];

    SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, snapshot->sid);
    CFRelease(window_list_ref);

    SLSSetWindowLevel(g_connection, wid, snapshot->level);
    SLSSetWindowSubLevel(g_connection, wid, snapshot->sub_level);
    SLSOrderWindow(g_connection, wid, 1, snapshot->above_wid);
}

- (void)hide
{
    [panel orderOut:nil];
}

- (void)orderAbove:(uint32_t)wid
{
    if (panel.isVisible) SLSOrderWindow(g_connection, (uint32_t) panel.windowNumber, 1, wid);
}

- (void)dealloc
{
    [panel orderOut:nil];
    [panel close];
    [panel release];
    [root release];
    [track release];
    [pill release];
    [content release];
    [super dealloc];
}
@end

static inline bool tab_bar_uses_glass(void)
{
    if (@available(macOS 26.0, *)) return g_window_manager.tab_bar_style == TAB_BAR_STYLE_GLASS;
    return false;
}

static inline bool tab_bar_exists(struct tab_bar *bar)
{
    return bar->id || bar->glass;
}

static void tab_bar_glass_render(struct tab_bar *bar, uint32_t above_wid, struct tab_bar_entry *entry_list, int entry_count)
{
    if (@available(macOS 26.0, *)) {
        struct tab_bar_glass_snapshot *snapshot = malloc(sizeof(struct tab_bar_glass_snapshot));
        snapshot->frame = bar->frame;
        snapshot->sid = bar->sid;
        snapshot->above_wid = above_wid;
        snapshot->level = window_level(above_wid);
        snapshot->sub_level = window_sub_level(above_wid);
        snapshot->font = g_window_manager.tab_bar_font ? CFRetain(g_window_manager.tab_bar_font) : NULL;
        snapshot->track_tint = tab_bar_glass_tint(g_window_manager.tab_bar_unfocused_color, g_window_manager.tab_bar_unfocused_color_custom, TAB_BAR_GLASS_TRACK_TINT_ALPHA);
        snapshot->pill_tint = snapshot->track_tint;
        snapshot->separator = tab_bar_separator_color(g_window_manager.tab_bar_unfocused_text_color);
        snapshot->entry_count = entry_count;

        for (int i = 0; i < entry_count; ++i) {
            struct rgba_color background;
            struct tab_bar_glass_entry *entry = &snapshot->entry_list[i];
            tab_bar_state_colors(entry_list[i].state, &background, &entry->text);

            entry->title = entry_list[i].title ? CFRetain(entry_list[i].title) : NULL;
            entry->icon = entry_list[i].icon ? CGImageRetain(entry_list[i].icon) : NULL;
            entry->active = entry_list[i].state != TAB_BAR_UNFOCUSED;

            if (entry_list[i].state == TAB_BAR_FOCUSED) {
                snapshot->pill_tint = tab_bar_glass_tint(background, g_window_manager.tab_bar_focused_color_custom, TAB_BAR_GLASS_PILL_TINT_ALPHA);
            } else if (entry_list[i].state == TAB_BAR_INACTIVE) {
                snapshot->pill_tint = tab_bar_glass_tint(background, g_window_manager.tab_bar_inactive_color_custom, TAB_BAR_GLASS_PILL_TINT_ALPHA);
            }
        }

        if (!bar->glass) bar->glass = [[tab_bar_glass alloc] init];
        tab_bar_glass *glass = bar->glass;

        dispatch_async(dispatch_get_main_queue(), ^{
            [glass apply:snapshot];
        });
    }
}

static void tab_bar_glass_hide(struct tab_bar *bar)
{
    if (@available(macOS 26.0, *)) {
        tab_bar_glass *glass = bar->glass;
        dispatch_async(dispatch_get_main_queue(), ^{
            [glass hide];
        });
    }
}

static void tab_bar_glass_order(struct tab_bar *bar, uint32_t wid)
{
    if (@available(macOS 26.0, *)) {
        tab_bar_glass *glass = bar->glass;
        dispatch_async(dispatch_get_main_queue(), ^{
            [glass orderAbove:wid];
        });
    }
}

static void tab_bar_glass_release(struct tab_bar *bar)
{
    id glass = bar->glass;
    dispatch_async(dispatch_get_main_queue(), ^{
        [glass release];
    });
}

static void tab_bar_create(struct tab_bar *bar, CGRect frame)
{
    bar->frame = frame;
    buf_push(tab_bar_list, bar);

    if (tab_bar_uses_glass()) return;

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
}

//
// NOTE: Creates the bar window if needed, moves it to the frame and to the space of the window it
// sits above, draws the entries and orders it right above that window. Titles stay owned by the caller.
//

void tab_bar_render(struct tab_bar *bar, CGRect frame, uint32_t above_wid, struct tab_bar_entry *entry_list, int entry_count)
{
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
    } else {
        tab_bar_glass_render(bar, above_wid, entry_list, entry_count);
    }

    if (above_changed && !workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
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

    if (!workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    tab_bar_publish_hits();
}

void tab_bar_order(uint32_t wid)
{
    for (int i = 0; i < buf_len(tab_bar_list); ++i) {
        struct tab_bar *bar = tab_bar_list[i];
        if (bar->hidden || bar->above_wid != wid) continue;

        if (bar->id) {
            SLSOrderWindow(g_connection, bar->id, 1, wid);
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
            view_update(view);
            view_flush(view);
        }
    })

    tab_bar_publish_hits();
}
