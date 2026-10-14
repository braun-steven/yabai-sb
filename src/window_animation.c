//
// NOTE: Moving and resizing windows: frame requests that are grouped per application and skipped when
// the window is already there, and animated transitions through proxy windows of the scripting addition.
//

extern int g_connection;
extern struct window_manager g_window_manager;
extern double g_cv_host_clock_frequency;

static void window_manager_create_window_proxy(int animation_connection, float alpha, struct window_proxy *proxy)
{
    if (!proxy->image) return;

    CFTypeRef frame_region;
    CGSNewRegionWithRect(&proxy->frame, &frame_region);
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();

    uint64_t tags = 1ULL << 46;
    SLSNewWindowWithOpaqueShapeAndContext(animation_connection, 2, frame_region, empty_region, 13|(1 << 18), &tags, 0, 0, 64, &proxy->id, NULL);
    sls_window_disable_shadow(proxy->id);
    SLSSetWindowOpacity(animation_connection, proxy->id, 0);
    SLSSetWindowResolution(animation_connection, proxy->id, 2.0f);
    SLSSetWindowAlpha(animation_connection, proxy->id, alpha);
    SLSSetWindowLevel(animation_connection, proxy->id, proxy->level);
    SLSSetWindowSubLevel(animation_connection, proxy->id, proxy->sub_level);
    proxy->context = SLWindowContextCreate(animation_connection, proxy->id, 0);

    CGRect frame = { {0, 0}, proxy->frame.size };
    CGContextClearRect(proxy->context, frame);
    CGContextDrawImage(proxy->context, frame, proxy->image);
    CGContextFlush(proxy->context);
    CFRelease(frame_region);
    CFRelease(empty_region);
}

static void window_manager_destroy_window_proxy(int animation_connection, struct window_proxy *proxy)
{
    if (proxy->image) {
        CFRelease(proxy->image);
        proxy->image = NULL;
    }

    if (proxy->context) {
        CGContextRelease(proxy->context);
        proxy->context = NULL;
    }

    if (proxy->id) {
        SLSReleaseWindow(animation_connection, proxy->id);
        proxy->id = 0;
    }
}

static void *window_manager_build_window_proxy_thread_proc(void *data)
{
    struct window_animation *animation = data;

    float alpha = 1.0f;
    SLSGetWindowAlpha(animation->cid, animation->wid, &alpha);
    animation->proxy.level = window_level(animation->wid);
    animation->proxy.sub_level = window_sub_level(animation->wid);
    SLSGetWindowBounds(animation->cid, animation->wid, &animation->proxy.frame);
    animation->proxy.tx = animation->proxy.frame.origin.x;
    animation->proxy.ty = animation->proxy.frame.origin.y;
    animation->proxy.tw = animation->proxy.frame.size.width;
    animation->proxy.th = animation->proxy.frame.size.height;

    CFArrayRef image_array = SLSHWCaptureWindowList(animation->cid, &animation->wid, 1, (1 << 11) | (1 << 8));
    if (image_array) {
        animation->proxy.image = alpha == 1.0f
                               ? (CGImageRef) CFRetain(CFArrayGetValueAtIndex(image_array, 0))
                               : cgimage_restore_alpha((CGImageRef) CFArrayGetValueAtIndex(image_array, 0));
        CFRelease(image_array);
    } else {
        animation->proxy.image = NULL;
    }

    window_manager_create_window_proxy(animation->cid, alpha, &animation->proxy);
    return NULL;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static CVReturn window_manager_animate_window_list_thread_proc(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output_time, CVOptionFlags flags, CVOptionFlags *flags_out, void *data)
{
    struct window_animation_context *context = data;
    int animation_count = context->animation_count;

    uint64_t current_clock = output_time->hostTime;
    if (!context->animation_clock) context->animation_clock = now->hostTime;

    double t = (double)(current_clock - context->animation_clock) / (double)(context->animation_duration * g_cv_host_clock_frequency);
    if (t <= 0.0) t = 0.0f;
    if (t >= 1.0) t = 1.0f;

    float mt;
    switch (context->animation_easing) {
#define ANIMATION_EASING_TYPE_ENTRY(value) case value##_type: mt = value(t); break;
        ANIMATION_EASING_TYPE_LIST
#undef ANIMATION_EASING_TYPE_ENTRY
    }

    //
    // NOTE: A new animation of the same window marks this entry as skipped and destroys its proxy
    // while holding the lock, so the proxy must not be used here without holding it as well.
    //

    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    CFTypeRef transaction = SLSTransactionCreate(context->animation_connection);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;

        context->animation_list[i].proxy.tx = lerp(context->animation_list[i].proxy.frame.origin.x,    mt, context->animation_list[i].x);
        context->animation_list[i].proxy.ty = lerp(context->animation_list[i].proxy.frame.origin.y,    mt, context->animation_list[i].y);
        context->animation_list[i].proxy.tw = lerp(context->animation_list[i].proxy.frame.size.width,  mt, context->animation_list[i].w);
        context->animation_list[i].proxy.th = lerp(context->animation_list[i].proxy.frame.size.height, mt, context->animation_list[i].h);

        CGAffineTransform transform = CGAffineTransformMakeTranslation(-context->animation_list[i].proxy.tx, -context->animation_list[i].proxy.ty);
        CGAffineTransform scale = CGAffineTransformMakeScale(context->animation_list[i].proxy.frame.size.width / context->animation_list[i].proxy.tw, context->animation_list[i].proxy.frame.size.height / context->animation_list[i].proxy.th);
        SLSTransactionSetWindowTransform(transaction, context->animation_list[i].proxy.id, 0, 0, CGAffineTransformConcat(transform, scale));

        float alpha = 0.0f;
        SLSGetWindowAlpha(context->animation_connection, context->animation_list[i].wid, &alpha);
        if (alpha != 0.0f) SLSTransactionSetWindowAlpha(transaction, context->animation_list[i].proxy.id, alpha);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
    if (t != 1.0f) {
        pthread_mutex_unlock(&g_window_manager.window_animations_lock);
        goto out;
    }

    SLSDisableUpdate(context->animation_connection);
    scripting_addition_swap_window_proxy_out(context->animation_list, context->animation_count);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;

        table_remove(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
        window_manager_destroy_window_proxy(context->animation_connection, &context->animation_list[i].proxy);

    }
    SLSReenableUpdate(context->animation_connection);
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);

    SLSReleaseConnection(context->animation_connection);
    free(context->animation_list);
    free(context);

    CVDisplayLinkStop(link);
    CVDisplayLinkRelease(link);

out:
    return kCVReturnSuccess;
}
#pragma clang diagnostic pop

//
// NOTE: A window that is still animating continues from where its running animation is: the new
// proxy starts at the target of the old one and replaces it on screen, and the old animation is
// told to skip the window.
//

static void window_animation_take_over(struct window_animation *animation, struct window_animation *existing_animation)
{
    __atomic_store_n(&existing_animation->skip, true, __ATOMIC_RELEASE);

    animation->proxy.frame.origin.x    = (int)(existing_animation->proxy.tx);
    animation->proxy.frame.origin.y    = (int)(existing_animation->proxy.ty);
    animation->proxy.frame.size.width  = (int)(existing_animation->proxy.tw);
    animation->proxy.frame.size.height = (int)(existing_animation->proxy.th);
    animation->proxy.tx                = (int)(existing_animation->proxy.tx);
    animation->proxy.ty                = (int)(existing_animation->proxy.ty);
    animation->proxy.tw                = (int)(existing_animation->proxy.tw);
    animation->proxy.th                = (int)(existing_animation->proxy.th);
    animation->proxy.level             = existing_animation->proxy.level;
    animation->proxy.sub_level         = existing_animation->proxy.sub_level;
    animation->proxy.image             = existing_animation->proxy.image
                                       ? (CGImageRef) CFRetain(existing_animation->proxy.image)
                                       : NULL;
    __asm__ __volatile__ ("" ::: "memory");

    float alpha = 1.0f;
    SLSGetWindowAlpha(animation->cid, animation->wid, &alpha);
    window_manager_create_window_proxy(animation->cid, alpha, &animation->proxy);

    CFTypeRef transaction = SLSTransactionCreate(animation->cid);
    SLSTransactionOrderWindowGroup(transaction, animation->proxy.id, 1, animation->wid);
    SLSTransactionSetWindowSystemAlpha(transaction, existing_animation->proxy.id, 0);
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);

    table_remove(&g_window_manager.window_animations_table, &animation->wid);
    window_manager_destroy_window_proxy(existing_animation->cid, &existing_animation->proxy);
}

void window_manager_animate_window_list_async(struct window_capture *window_list, int window_count)
{
    struct window_animation_context *context = malloc(sizeof(struct window_animation_context));

    SLSNewConnection(0, &context->animation_connection);
    context->animation_count    = window_count;
    context->animation_list     = malloc(window_count * sizeof(struct window_animation));
    context->animation_duration = g_window_manager.window_animation_duration;
    context->animation_easing   = g_window_manager.window_animation_easing;
    context->animation_clock    = 0;

    int thread_count = 0;
    pthread_t *threads = ts_alloc_list(pthread_t, window_count);

    TIME_BODY(window_manager_animate_window_list_async___prep_proxies, {
    SLSDisableUpdate(context->animation_connection);
    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    for (int i = 0; i < window_count; ++i) {
        context->animation_list[i].window = window_list[i].window;
        context->animation_list[i].wid    = window_list[i].window->id;
        context->animation_list[i].x      = window_list[i].x;
        context->animation_list[i].y      = window_list[i].y;
        context->animation_list[i].w      = window_list[i].w;
        context->animation_list[i].h      = window_list[i].h;
        context->animation_list[i].cid    = context->animation_connection;
        context->animation_list[i].skip   = false;
        memset(&context->animation_list[i].proxy, 0, sizeof(struct window_proxy));

        struct window_animation *existing_animation = table_find(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
        if (existing_animation) {
            window_animation_take_over(&context->animation_list[i], existing_animation);
        } else {
            pthread_t thread;
            if (pthread_create(&thread, NULL, &window_manager_build_window_proxy_thread_proc, &context->animation_list[i]) == 0) {
                threads[thread_count++] = thread;
            } else {
                window_manager_build_window_proxy_thread_proc(&context->animation_list[i]);
            }
        }

        table_add(&g_window_manager.window_animations_table, &context->animation_list[i].wid, &context->animation_list[i]);
    }
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);
    });

    TIME_BODY(window_manager_animate_window_list_async___wait_for_threads, {
    for (int i = 0; i < thread_count; ++i) {
        pthread_join(threads[i], NULL);
    }
    });

    TIME_BODY(window_manager_animate_window_list_async___swap_proxy_in, {
    scripting_addition_swap_window_proxy_in(context->animation_list, context->animation_count);
    for (int i = 0; i < context->animation_count; ++i) {
        border_suspend(context->animation_list[i].wid, true);
    }
    });

    TIME_BODY(window_manager_animate_window_list_async___set_frame, {
    window_manager_set_window_frames(window_list, window_count);
    });

    CVDisplayLinkRef link;
    SLSReenableUpdate(context->animation_connection);
    CVDisplayLinkCreateWithActiveCGDisplays(&link);
    CVDisplayLinkSetOutputCallback(link, window_manager_animate_window_list_thread_proc, context);
    CVDisplayLinkStart(link);
}

//
// NOTE(asmvik): Attempting to check the window frame cache to prevent unnecessary movement and resize calls to the AX API
// is not reliable because it is possible to perform operations that should be applied, at a higher rate than the AX API events
// are received, causing our cache to become out of date and incorrectly guard against some changes that **should** be applied.
// This causes the window layout to **not** be modified the way we expect.
//
// A possible solution is to use the faster CG window notifications, as they are **a lot** more responsive, and can be used to
// track changes to the window frame in real-time without delay.
//
// NOTE: We therefore compare against the bounds of the window server instead, which change as soon as the window is moved,
// and against the frame we requested last. The window is only skipped when both match the target. If an application has not
// yet applied a previous request, the request differs from the target and the frame is set again.
//

static inline bool window_frame_is_close(CGRect frame, float x, float y, float w, float h)
{
    return fabsf((float) frame.origin.x    - x) < 1.0f &&
           fabsf((float) frame.origin.y    - y) < 1.0f &&
           fabsf((float) frame.size.width  - w) < 1.0f &&
           fabsf((float) frame.size.height - h) < 1.0f;
}

static inline bool window_frame_needs_update(CGRect request, bool has_bounds, CGRect bounds, float x, float y, float w, float h)
{
    if (!window_frame_is_close(request, x, y, w, h)) return true;
    if (!has_bounds) return true;

    return !window_frame_is_close(bounds, x, y, w, h);
}

static bool window_manager_window_frame_needs_update(struct window *window, float x, float y, float w, float h)
{
    if (!window_frame_is_close(window->frame_request, x, y, w, h)) return true;

    CGRect bounds;
    bool has_bounds = SLSGetWindowBounds(g_connection, window->id, &bounds) == kCGErrorSuccess;

    return window_frame_needs_update(window->frame_request, has_bounds, bounds, x, y, w, h);
}

static int window_manager_filter_window_frames(struct window_capture *window_list, int window_count)
{
    int update_count = 0;

    for (int i = 0; i < window_count; ++i) {
        struct window_capture capture = window_list[i];
        if (window_manager_window_frame_needs_update(capture.window, capture.x, capture.y, capture.w, capture.h)) {
            window_list[update_count++] = capture;
        }
    }

    return update_count;
}

void window_manager_animate_window_list(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;

    window_count = window_manager_filter_window_frames(window_list, window_count);
    if (!window_count) return;

    if (g_window_manager.window_animation_duration) {
        window_manager_animate_window_list_async(window_list, window_count);
    } else {
        window_manager_set_window_frames(window_list, window_count);
    }
}

void window_manager_animate_window(struct window_capture capture)
{
    TIME_FUNCTION;

    if (!window_manager_window_frame_needs_update(capture.window, capture.x, capture.y, capture.w, capture.h)) return;

    if (g_window_manager.window_animation_duration) {
        window_manager_animate_window_list_async(&capture, 1);
    } else {
        window_manager_set_window_frame(capture.window, capture.x, capture.y, capture.w, capture.h);
    }
}

static AXError window_manager_set_window_frame_ax(AXUIElementRef ref, CGPoint position, CGSize size)
{
    AXError result = kAXErrorSuccess;

    CFTypeRef position_ref = AXValueCreate(kAXValueTypeCGPoint, (void *) &position);
    CFTypeRef size_ref = AXValueCreate(kAXValueTypeCGSize, (void *) &size);

    //
    // NOTE: An application that does not respond makes every call wait for the messaging timeout,
    // so the remaining calls are skipped once one of them could not complete.
    //

    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.
    if (size_ref) result = AXUIElementSetAttributeValue(ref, kAXSizeAttribute, size_ref);

    if (position_ref && result != kAXErrorCannotComplete) {
        result = AXUIElementSetAttributeValue(ref, kAXPositionAttribute, position_ref);
    }

    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
    if (size_ref && result != kAXErrorCannotComplete) {
        result = AXUIElementSetAttributeValue(ref, kAXSizeAttribute, size_ref);
    }

    if (position_ref) CFRelease(position_ref);
    if (size_ref) CFRelease(size_ref);

    return result;
}

void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height)
{
    window->frame_request = CGRectMake(x, y, width, height);

    AX_ENHANCED_UI_WORKAROUND(window->application->ref, {
        window_manager_set_window_frame_ax(window->ref, CGPointMake(x, y), CGSizeMake(width, height));
    });
}

//
// NOTE: The frames of a batch are set per application. AXEnhancedUserInterface is turned off once for
// each application instead of once for each window, and the applications are handled concurrently, so
// that an application that is slow to respond does not delay the windows of all other applications.
// The groups are built on the event loop thread; the worker threads only read the AX references of their
// own group and write its result, and must not touch the ts arena, tables or other global state.
//

int window_manager_group_window_frames(struct window_capture *window_list, int window_count, struct window_frame_group *group_list, struct window_frame_request *request_list)
{
    int group_count = 0;
    int *group_index = ts_alloc_list(int, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct application *application = window_list[i].window->application;

        int group = 0;
        while (group < group_count && group_list[group].application != application) ++group;

        if (group == group_count) {
            group_list[group_count++] = (struct window_frame_group) { .application = application, .error = kAXErrorSuccess };
        }

        group_index[i] = group;
        ++group_list[group].count;
    }

    int offset = 0;
    for (int i = 0; i < group_count; ++i) {
        group_list[i].list = request_list + offset;
        offset += group_list[i].count;
        group_list[i].count = 0;
    }

    for (int i = 0; i < window_count; ++i) {
        struct window_frame_group *group = &group_list[group_index[i]];
        group->list[group->count++] = (struct window_frame_request) {
            .ref = window_list[i].window->ref,
            .position = CGPointMake(window_list[i].x, window_list[i].y),
            .size = CGSizeMake(window_list[i].w, window_list[i].h)
        };
    }

    return group_count;
}

static void window_manager_apply_window_frame_group(struct window_frame_group *group)
{
    AXUIElementRef application_ref = group->application->ref;

    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(application_ref, kAXEnhancedUserInterface, &value);
    if (result == kAXErrorCannotComplete) {
        group->error = result;
        return;
    }

    bool eui = false;
    if (value) {
        eui = CFBooleanGetValue(value);
        CFRelease(value);
    }

    if (eui) AXUIElementSetAttributeValue(application_ref, kAXEnhancedUserInterface, kCFBooleanFalse);

    for (int i = 0; i < group->count; ++i) {
        result = window_manager_set_window_frame_ax(group->list[i].ref, group->list[i].position, group->list[i].size);
        if (result == kAXErrorCannotComplete) {
            group->error = result;
            break;
        }
    }

    if (eui) AXUIElementSetAttributeValue(application_ref, kAXEnhancedUserInterface, kCFBooleanTrue);
}

void window_manager_set_window_frames(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;

    if (window_count <= 0) return;

    for (int i = 0; i < window_count; ++i) {
        window_list[i].window->frame_request = CGRectMake(window_list[i].x, window_list[i].y, window_list[i].w, window_list[i].h);
    }

    struct window_frame_group *group_list = ts_alloc_list(struct window_frame_group, window_count);
    struct window_frame_request *request_list = ts_alloc_list(struct window_frame_request, window_count);
    int group_count = window_manager_group_window_frames(window_list, window_count, group_list, request_list);

    if (group_count == 1) {
        window_manager_apply_window_frame_group(&group_list[0]);
    } else {
        dispatch_apply(group_count, DISPATCH_APPLY_AUTO, ^(size_t i) {
            window_manager_apply_window_frame_group(&group_list[i]);
        });
    }

    for (int i = 0; i < group_count; ++i) {
        if (group_list[i].error == kAXErrorCannotComplete) {
            debug("%s: %s did not respond, %d window(s) may not have been moved\n", __FUNCTION__, group_list[i].application->name, group_list[i].count);
        }
    }
}
