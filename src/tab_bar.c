extern int g_connection;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

#define TAB_BAR_TITLE_PADDING 8.0f
#define TAB_BAR_MAX_HIT_COUNT 256

//
// NOTE: Nodes that currently own a tab bar window. Only touched from the event loop thread.
//

static struct window_node **tab_bar_nodes;

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

    CFStringRef family = CFStringCreateWithBytes(NULL, (const uint8_t *) font, separator - font, kCFStringEncodingUTF8, false);
    if (!family) return false;

    CTFontRef ct_font = CTFontCreateWithName(family, size, NULL);
    CFRelease(family);
    if (!ct_font) return false;

    if (g_window_manager.tab_bar_font) CFRelease(g_window_manager.tab_bar_font);
    if (g_window_manager.tab_bar_font_name) free(g_window_manager.tab_bar_font_name);

    g_window_manager.tab_bar_font = ct_font;
    g_window_manager.tab_bar_font_name = string_copy(font);

    return true;
}

bool tab_bar_is_enabled(void)
{
    return g_window_manager.enable_tab_bar && g_window_manager.tab_bar_height > 0;
}

bool tab_bar_node_has_bar(struct window_node *node)
{
    return tab_bar_is_enabled() &&
           node->left == NULL &&
           node->right == NULL &&
           node->window_count > 1 &&
           node->zoom == NULL &&
           node->area.h > 2 * g_window_manager.tab_bar_height;
}

struct area tab_bar_window_area(struct window_node *node, struct area area)
{
    if (tab_bar_node_has_bar(node)) {
        area.y += g_window_manager.tab_bar_height;
        area.h -= g_window_manager.tab_bar_height;
    }

    return area;
}

static void tab_bar_publish_hits(void)
{
    pthread_mutex_lock(&tab_bar_hit_lock);

    tab_bar_hit_count = 0;
    for (int i = 0; i < buf_len(tab_bar_nodes) && tab_bar_hit_count < TAB_BAR_MAX_HIT_COUNT; ++i) {
        struct window_node *node = tab_bar_nodes[i];
        struct tab_bar_hit *hit = &tab_bar_hit_list[tab_bar_hit_count++];

        hit->frame = node->tab_bar.frame;
        hit->sid = node->tab_bar.sid;
        hit->window_count = node->window_count;
        memcpy(hit->window_list, node->window_list, sizeof(uint32_t) * node->window_count);
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

        int index = (int)((point.x - hit->frame.origin.x) * hit->window_count / hit->frame.size.width);
        if (index < 0) index = 0;
        if (index >= hit->window_count) index = hit->window_count - 1;

        *wid = hit->window_list[index];
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

static void tab_bar_draw_title(CGContextRef context, CFStringRef title, CGRect rect, struct rgba_color color)
{
    double max_width = rect.size.width - 2.0f * TAB_BAR_TITLE_PADDING;
    if (max_width <= 0 || !g_window_manager.tab_bar_font) return;

    CGColorRef text_color = tab_bar_cgcolor(color);
    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *values[] = { g_window_manager.tab_bar_font, text_color };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CTLineRef line = tab_bar_create_line(title, attributes);
    if (CTLineGetTypographicBounds(line, NULL, NULL, NULL) > max_width) {
        UniChar ellipsis_char = 0x2026;
        CFStringRef ellipsis = CFStringCreateWithCharacters(NULL, &ellipsis_char, 1);
        CTLineRef token = tab_bar_create_line(ellipsis, attributes);
        CTLineRef truncated = CTLineCreateTruncatedLine(line, max_width, kCTLineTruncationEnd, token);
        CFRelease(token);
        CFRelease(ellipsis);

        if (truncated) {
            CFRelease(line);
            line = truncated;
        }
    }

    CGFloat ascent, descent;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);

    CGFloat x = rect.origin.x + (rect.size.width - width) * 0.5f;
    CGFloat y = rect.origin.y + (rect.size.height - (ascent + descent)) * 0.5f + descent;

    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetTextPosition(context, (int) x, (int) y);
    CTLineDraw(line, context);

    CFRelease(line);
    CFRelease(attributes);
    CGColorRelease(text_color);
}

static CFStringRef tab_bar_copy_title(uint32_t wid)
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

static void tab_bar_draw(struct window_node *node)
{
    CGContextRef context = node->tab_bar.context;
    CGRect bounds = {{0, 0}, node->tab_bar.frame.size};
    float tab_width = bounds.size.width / node->window_count;
    bool node_has_focus = window_node_contains_window(node, g_window_manager.focused_window_id);

    SLSDisableUpdate(g_connection);
    CGContextClearRect(context, bounds);

    for (int i = 0; i < node->window_count; ++i) {
        uint32_t wid = node->window_list[i];

        struct rgba_color background;
        struct rgba_color text;

        if (wid == node->window_order[0]) {
            background = node_has_focus ? g_window_manager.tab_bar_focused_color : g_window_manager.tab_bar_inactive_color;
            text = node_has_focus ? g_window_manager.tab_bar_focused_text_color : g_window_manager.tab_bar_inactive_text_color;
        } else {
            background = g_window_manager.tab_bar_unfocused_color;
            text = g_window_manager.tab_bar_unfocused_text_color;
        }

        float x0 = (int)(i * tab_width);
        float x1 = i == node->window_count - 1 ? bounds.size.width : (int)((i + 1) * tab_width);
        CGRect tab = {{x0, 0}, {x1 - x0, bounds.size.height}};

        CGContextSetRGBFillColor(context, background.r, background.g, background.b, background.a);
        CGContextFillRect(context, tab);

        if (i > 0) {
            CGContextSetRGBFillColor(context, text.r, text.g, text.b, text.a * 0.25f);
            CGContextFillRect(context, (CGRect) {{x0, 0}, {1, bounds.size.height}});
        }

        CFStringRef title = tab_bar_copy_title(wid);
        if (title) {
            tab_bar_draw_title(context, title, tab, text);
            CFRelease(title);
        }
    }

    CGContextFlush(context);
    SLSReenableUpdate(g_connection);
}

static void tab_bar_create(struct window_node *node, CGRect frame)
{
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&frame, &frame_region);

    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();
    SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region, 13, &tags, 0, 0, 64, &node->tab_bar.id, NULL);
    CFRelease(empty_region);
    CFRelease(frame_region);

    sls_window_disable_shadow(node->tab_bar.id);
    SLSSetWindowResolution(g_connection, node->tab_bar.id, 2.0f);
    SLSSetWindowOpacity(g_connection, node->tab_bar.id, 0);
    node->tab_bar.context = SLWindowContextCreate(g_connection, node->tab_bar.id, 0);
    node->tab_bar.frame = frame;

    buf_push(tab_bar_nodes, node);

    if (!workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
        update_window_notifications();
    }
}

void tab_bar_destroy(struct window_node *node)
{
    if (!node->tab_bar.id) return;

    for (int i = 0; i < buf_len(tab_bar_nodes); ++i) {
        if (tab_bar_nodes[i] == node) {
            buf_del(tab_bar_nodes, i);
            break;
        }
    }

    SLSOrderWindow(g_connection, node->tab_bar.id, 0, 0);
    CGContextRelease(node->tab_bar.context);
    SLSReleaseWindow(g_connection, node->tab_bar.id);
    memset(&node->tab_bar, 0, sizeof(struct tab_bar));

    if (!workspace_is_macos_sequoia() && !workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    tab_bar_publish_hits();
}

void tab_bar_update(struct window_node *node)
{
    if (!tab_bar_node_has_bar(node)) {
        tab_bar_destroy(node);
        return;
    }

    uint32_t active_wid = node->window_order[0];
    uint64_t sid = window_space(active_wid);
    CGRect frame = {{node->area.x, node->area.y}, {node->area.w, g_window_manager.tab_bar_height}};

    if (!node->tab_bar.id) {
        tab_bar_create(node, frame);
    } else if (!CGRectEqualToRect(frame, node->tab_bar.frame)) {
        CFTypeRef frame_region;
        CGSNewRegionWithRect(&frame, &frame_region);
        SLSDisableUpdate(g_connection);
        SLSSetWindowShape(g_connection, node->tab_bar.id, 0.0f, 0.0f, frame_region);
        SLSReenableUpdate(g_connection);
        CFRelease(frame_region);
        node->tab_bar.frame = frame;
    }

    if (sid && sid != node->tab_bar.sid) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&node->tab_bar.id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);
        node->tab_bar.sid = sid;
    }

    tab_bar_draw(node);

    SLSSetWindowLevel(g_connection, node->tab_bar.id, window_level(active_wid));
    SLSSetWindowSubLevel(g_connection, node->tab_bar.id, window_sub_level(active_wid));
    SLSOrderWindow(g_connection, node->tab_bar.id, 1, active_wid);

    tab_bar_publish_hits();
}

static struct window_node *tab_bar_find_node(uint32_t wid)
{
    struct view *view = table_find(&g_window_manager.managed_window, &wid);
    if (!view || view->layout == VIEW_FLOAT) return NULL;

    return view_find_window_node(view, wid);
}

void tab_bar_refresh_for_window(uint32_t wid)
{
    if (!wid) return;

    struct window_node *node = tab_bar_find_node(wid);
    if (node && node->tab_bar.id) tab_bar_update(node);
}

void tab_bar_order(uint32_t wid)
{
    for (int i = 0; i < buf_len(tab_bar_nodes); ++i) {
        struct window_node *node = tab_bar_nodes[i];
        if (node->window_order[0] == wid) {
            SLSOrderWindow(g_connection, node->tab_bar.id, 1, wid);
        }
    }
}

int tab_bar_window_list(uint32_t *window_list, int capacity)
{
    int count = 0;

    for (int i = 0; i < buf_len(tab_bar_nodes) && count < capacity; ++i) {
        window_list[count++] = tab_bar_nodes[i]->window_order[0];
    }

    return count;
}

static void tab_bar_destroy_tree(struct window_node *node)
{
    if (node->left)  tab_bar_destroy_tree(node->left);
    if (node->right) tab_bar_destroy_tree(node->right);
    tab_bar_destroy(node);
}

void tab_bar_redraw_all(void)
{
    for (int i = 0; i < buf_len(tab_bar_nodes); ++i) {
        tab_bar_draw(tab_bar_nodes[i]);
    }
}

//
// NOTE: Called after a tab bar config change that affects the layout. Drops every bar so that the next layout pass
// recreates them with the new settings, then re-lays out all views to apply the new window area.
//

void tab_bar_refresh_all(void)
{
    table_for (struct view *view, g_space_manager.view, {
        if (view->layout != VIEW_FLOAT && view->root) {
            tab_bar_destroy_tree(view->root);
            view_update(view);
            view_flush(view);
        }
    })

    tab_bar_publish_hits();
}
