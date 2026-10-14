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

    if (below) border_window_ordered(snapshot->above_wid);
}

- (void)hide
{
    [panel orderOut:nil];
}

- (void)order:(uint32_t)wid
{
    if (!panel.isVisible) return;

    SLSOrderWindow(g_connection, (uint32_t) panel.windowNumber, below ? -1 : 1, wid);
    if (below) border_window_ordered(wid);
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

void tab_bar_glass_render(struct tab_bar *bar, uint32_t above_wid, struct tab_bar_entry *entry_list, int entry_count)
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

void tab_bar_glass_hide(struct tab_bar *bar)
{
    if (@available(macOS 26.0, *)) {
        tab_bar_glass *glass = bar->glass;
        dispatch_async(dispatch_get_main_queue(), ^{
            [glass hide];
        });
    }
}

void tab_bar_glass_order(struct tab_bar *bar, uint32_t wid)
{
    if (@available(macOS 26.0, *)) {
        tab_bar_glass *glass = bar->glass;
        dispatch_async(dispatch_get_main_queue(), ^{
            [glass order:wid];
        });
    }
}

void tab_bar_glass_release(struct tab_bar *bar)
{
    id glass = bar->glass;
    dispatch_async(dispatch_get_main_queue(), ^{
        [glass release];
    });
}

uint32_t tab_bar_glass_panel_id(struct tab_bar *bar)
{
    if (@available(macOS 26.0, *)) {
        return [(tab_bar_glass *) bar->glass panelId];
    }

    return 0;
}
