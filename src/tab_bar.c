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
#define TAB_BAR_GLASS_BACKDROP_TINT_ALPHA 0.4f
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

static bool tab_bar_connection_is_jankyborders(int cid)
{
    char process_name[PROC_PIDPATHINFO_MAXSIZE];

    pid_t pid = 0;
    SLSConnectionGetPID(cid, &pid);
    if (proc_name(pid, process_name, sizeof(process_name)) <= 0) return false;

    return strcmp(process_name, "borders") == 0;
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
    while (window_id && window_cid != g_connection && tab_bar_connection_is_jankyborders(window_cid)) {
        SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
    }

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
    CGRect card;
    enum tab_bar_backdrop backdrop;
    CGFloat card_radius;
    uint64_t sid;
    uint32_t above_wid;
    int level;
    int sub_level;
    CTFontRef font;
    struct rgba_color track_tint;
    struct rgba_color backdrop_tint;
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
// NOTE: The tints are rounded layers instead of NSGlassEffectView.tintColor, because AppKit draws glass in its
// desaturated inactive look in an app that is never active, which hides most of the tint color. The pill tint sits
// below the pill, so the glass refracts and frosts it like tinted glass and keeps its edge highlight. The track tint
// sits on top of the track instead, because the glass would lighten a dark color beneath it.
//

static NSView *tab_bar_glass_create_tint(void)
{
    NSView *tint = [[NSView alloc] initWithFrame:NSZeroRect];
    tint.wantsLayer = YES;
    return tint;
}

static void tab_bar_glass_set_tint(NSView *tint, CGFloat radius, struct rgba_color color)
{
    CGColorRef cg_color = tab_bar_cgcolor(color);
    tint.layer.backgroundColor = cg_color;
    tint.layer.cornerRadius = radius;
    CGColorRelease(cg_color);
}

//
// NOTE: NSVisualEffectView only rounds its material through a mask image. A stretchable rounded rect keeps the
// corners at the given radius for any size of the card.
//

static NSImage *tab_bar_glass_create_mask(CGFloat radius)
{
    CGFloat size = 2.0f * radius + 1.0f;
    NSImage *mask = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [mask lockFocus];
    [[NSColor blackColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size, size) xRadius:radius yRadius:radius] fill];
    [mask unlockFocus];
    mask.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    mask.resizingMode = NSImageResizingModeStretch;
    return mask;
}

API_AVAILABLE(macos(26.0))
@interface tab_bar_glass : NSObject
{
    NSPanel *panel;
    NSView *root;
    NSView *backdrop;
    NSView *backdrop_tint;
    enum tab_bar_backdrop backdrop_kind;
    CGFloat backdrop_radius;
    bool below;
    NSView *track_tint;
    NSGlassEffectView *track;
    NSView *pill_tint;
    NSGlassEffectView *pill;
    tab_bar_glass_content *content;
    uint32_t panel_wid;
}
- (void)apply:(struct tab_bar_glass_snapshot *)snapshot;
- (uint32_t)panelId;
- (void)hide;
- (void)order:(uint32_t)wid;
@end

@implementation tab_bar_glass

//
// NOTE: The object is created on the event loop thread, but AppKit only allows windows and views on the main thread.
// The panel is therefore created by the first update that reaches the main queue. Until then hide and order are no-ops.
//

- (void)setup
{
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

    //
    // NOTE: Glass follows the appearance of its window and turns whiter in light mode, which would wash out the tints.
    // The panel is pinned to the dark appearance so the bar looks the same in light and dark mode.
    //

    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.collectionBehavior = NSWindowCollectionBehaviorManaged |
                               NSWindowCollectionBehaviorIgnoresCycle |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;

    root = [[NSView alloc] initWithFrame:NSZeroRect];
    track_tint = tab_bar_glass_create_tint();
    track = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    pill_tint = tab_bar_glass_create_tint();
    pill = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    content = [[tab_bar_glass_content alloc] initWithFrame:NSZeroRect];

    track_tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    track.contentView = track_tint;

    [root addSubview:track];
    [root addSubview:pill_tint];
    [root addSubview:pill];
    [root addSubview:content];
    panel.contentView = root;

    __atomic_store_n(&panel_wid, (uint32_t) panel.windowNumber, __ATOMIC_RELEASE);
}

- (uint32_t)panelId
{
    return __atomic_load_n(&panel_wid, __ATOMIC_ACQUIRE);
}

//
// NOTE: The backdrop is a rounded card behind the whole tabbed container. The panel covers the card and is ordered
// below the active window, so the window sits inside the card with the bar above it, and the card hides the other
// tabs of the container. The card has its own tint, so the track of the bar stays visible on top of it.
//

- (void)setBackdrop:(enum tab_bar_backdrop)kind
{
    if (kind == backdrop_kind) return;

    [backdrop removeFromSuperview];
    [backdrop release];
    [backdrop_tint release];
    backdrop = nil;
    backdrop_tint = nil;
    backdrop_kind = kind;
    backdrop_radius = -1.0f;

    if (kind == TAB_BAR_BACKDROP_OFF) return;

    backdrop_tint = tab_bar_glass_create_tint();
    backdrop_tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    if (kind == TAB_BAR_BACKDROP_GLASS) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        glass.contentView = backdrop_tint;
        backdrop = glass;
    } else {
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        effect.material = NSVisualEffectMaterialHUDWindow;
        effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effect.state = NSVisualEffectStateActive;
        [effect addSubview:backdrop_tint];
        backdrop = effect;
    }

    [root addSubview:backdrop positioned:NSWindowBelow relativeTo:nil];
}

- (void)layoutBackdrop:(struct tab_bar_glass_snapshot *)snapshot bounds:(NSRect)bounds
{
    [self setBackdrop:snapshot->backdrop];
    if (!backdrop) return;

    backdrop.frame = bounds;
    backdrop_tint.frame = backdrop.bounds;
    tab_bar_glass_set_tint(backdrop_tint, snapshot->card_radius, snapshot->backdrop_tint);

    if (backdrop_radius == snapshot->card_radius) return;
    backdrop_radius = snapshot->card_radius;

    if (backdrop_kind == TAB_BAR_BACKDROP_GLASS) {
        ((NSGlassEffectView *) backdrop).cornerRadius = backdrop_radius;
    } else {
        NSImage *mask = tab_bar_glass_create_mask(backdrop_radius);
        ((NSVisualEffectView *) backdrop).maskImage = mask;
        [mask release];
    }
}

- (void)layout:(struct tab_bar_glass_snapshot *)snapshot animate:(bool)animate
{
    bool card = snapshot->backdrop != TAB_BAR_BACKDROP_OFF;
    CGRect panel_frame = card ? snapshot->card : snapshot->frame;
    NSRect bounds = NSMakeRect(0, 0, panel_frame.size.width, panel_frame.size.height);
    NSRect strip = card ? NSMakeRect(snapshot->frame.origin.x - snapshot->card.origin.x,
                                     snapshot->card.size.height - (snapshot->frame.origin.y - snapshot->card.origin.y) - snapshot->frame.size.height,
                                     snapshot->frame.size.width, snapshot->frame.size.height)
                        : bounds;
    NSRect track_frame = NSRectFromCGRect(tab_bar_glass_track(NSRectToCGRect(strip)));
    CGRect inner = tab_bar_glass_inner(NSRectToCGRect(strip));

    int active = -1;
    for (int i = 0; i < snapshot->entry_count; ++i) {
        if (snapshot->entry_list[i].active) { active = i; break; }
    }

    root.frame = bounds;
    [self layoutBackdrop:snapshot bounds:bounds];

    track.frame = track_frame;
    track.cornerRadius = track_frame.size.height * 0.5f;
    tab_bar_glass_set_tint(track_tint, track_frame.size.height * 0.5f, snapshot->track_tint);
    content.frame = strip;

    pill.hidden = active < 0;
    pill_tint.hidden = active < 0;
    if (active < 0) return;

    NSRect pill_frame = NSRectFromCGRect(tab_bar_slot(inner, active, snapshot->entry_count));
    pill.cornerRadius = pill_frame.size.height * 0.5f;
    tab_bar_glass_set_tint(pill_tint, pill_frame.size.height * 0.5f, snapshot->pill_tint);

    if (animate && !NSEqualRects(pill.frame, pill_frame)) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = TAB_BAR_GLASS_ANIMATION_DURATION;
            context.allowsImplicitAnimation = YES;
            pill_tint.animator.frame = pill_frame;
            pill.animator.frame = pill_frame;
        }];
    } else {
        pill_tint.frame = pill_frame;
        pill.frame = pill_frame;
    }
}

- (void)apply:(struct tab_bar_glass_snapshot *)snapshot
{
    if (!panel) [self setup];

    below = snapshot->backdrop != TAB_BAR_BACKDROP_OFF;
    CGRect frame = below ? snapshot->card : snapshot->frame;
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

    if (!visible) [panel orderWindow:below ? NSWindowBelow : NSWindowAbove relativeTo:snapshot->above_wid];

    SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, snapshot->sid);
    CFRelease(window_list_ref);

    SLSSetWindowLevel(g_connection, wid, snapshot->level);
    SLSSetWindowSubLevel(g_connection, wid, snapshot->sub_level);
    SLSOrderWindow(g_connection, wid, below ? -1 : 1, snapshot->above_wid);

    //
    // NOTE: A card ordered below the window lands between the window and its border, so the border is ordered
    // right below the window again to stay on top of the card.
    //

    if (below) border_window_changed(snapshot->above_wid);
}

- (void)hide
{
    [panel orderOut:nil];
}

- (void)order:(uint32_t)wid
{
    if (!panel.isVisible) return;

    SLSOrderWindow(g_connection, (uint32_t) panel.windowNumber, below ? -1 : 1, wid);
    if (below) border_window_changed(wid);
}

- (void)dealloc
{
    [panel orderOut:nil];
    [panel close];
    [panel release];
    [root release];
    [backdrop release];
    [backdrop_tint release];
    [track_tint release];
    [track release];
    [pill_tint release];
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

int tab_bar_card_padding(void)
{
    if (!tab_bar_uses_glass() || g_window_manager.tab_bar_backdrop == TAB_BAR_BACKDROP_OFF) return 0;
    return g_window_manager.tab_bar_card_padding;
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
        snapshot->card = bar->card;
        snapshot->backdrop = g_window_manager.tab_bar_backdrop;
        snapshot->card_radius = g_window_manager.tab_bar_window_radius + (bar->frame.origin.x - bar->card.origin.x);
        snapshot->sid = bar->sid;
        snapshot->above_wid = above_wid;
        snapshot->level = window_level(above_wid);
        snapshot->sub_level = window_sub_level(above_wid);
        snapshot->font = g_window_manager.tab_bar_font ? CFRetain(g_window_manager.tab_bar_font) : NULL;
        snapshot->track_tint = tab_bar_glass_tint(g_window_manager.tab_bar_unfocused_color, g_window_manager.tab_bar_unfocused_color_custom, TAB_BAR_GLASS_TRACK_TINT_ALPHA);
        snapshot->pill_tint = snapshot->track_tint;
        snapshot->backdrop_tint = tab_bar_glass_tint(g_window_manager.tab_bar_backdrop_color, g_window_manager.tab_bar_backdrop_color_custom, TAB_BAR_GLASS_BACKDROP_TINT_ALPHA);
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
            [glass order:wid];
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

//
// NOTE: Window id of the backdrop card of a visible bar, or 0 when it has none (yet). The panel is created on the
// main queue, so the id only becomes known after the first update of the bar reaches it.
//

uint32_t tab_bar_card_id(struct tab_bar *bar)
{
    if (bar->hidden || !bar->glass) return 0;
    if (!tab_bar_uses_glass() || g_window_manager.tab_bar_backdrop == TAB_BAR_BACKDROP_OFF) return 0;

    if (@available(macOS 26.0, *)) {
        return [(tab_bar_glass *) bar->glass panelId];
    }

    return 0;
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
            view_update(view);
            view_flush(view);
        }
    })

    tab_bar_publish_hits();
}
