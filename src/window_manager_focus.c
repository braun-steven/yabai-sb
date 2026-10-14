//
// NOTE: Focusing windows through synthesized event records, and the window that commands act on.
//

extern uint8_t *g_event_bytes;
extern struct event_loop g_event_loop;

static void window_manager_make_key_window(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    //
    // :SynthesizedEvent
    //
    // NOTE(asmvik): These events will be picked up by an event-tap
    // registered at the "Annotated Session" location; specifying that an
    // event-tap is placed at the point where session events have been
    // annotated to flow to an application.
    //

    memset(g_event_bytes, 0, 0xf8);
    g_event_bytes[0x04] = 0xf8;
    g_event_bytes[0x3a] = 0x10;
    memcpy(g_event_bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(g_event_bytes + 0x20, 0xff, 0x10);

    g_event_bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(window_psn, g_event_bytes);

    g_event_bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(window_psn, g_event_bytes);
}

//
// NOTE: An event record of type 0x0d tells the application of window_id that the window lost (0x02) or
// gained (0x01) focus, so that focus can move between windows of one application without raising them.
//

static void window_manager_post_focus_record(ProcessSerialNumber *psn, uint32_t window_id, uint8_t state)
{
    memset(g_event_bytes, 0, 0xf8);
    g_event_bytes[0x04] = 0xf8;
    g_event_bytes[0x08] = 0x0d;

    g_event_bytes[0x8a] = state;
    memcpy(g_event_bytes + 0x3c, &window_id, sizeof(uint32_t));
    SLPSPostEventRecordTo(psn, g_event_bytes);
}

void window_manager_focus_window_without_raise(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    TIME_FUNCTION;

    if (psn_equals(window_psn, &g_window_manager.focused_window_psn)) {
        window_manager_post_focus_record(&g_window_manager.focused_window_psn, g_window_manager.focused_window_id, 0x02);

        //
        // @hack
        // Artificially delay the activation by 40ms. This is necessary
        // because some applications appear to be confused if both of
        // the events appear instantaneously.
        //
        // NOTE: The activation is posted back to the event loop instead of sleeping,
        // so that the event loop keeps handling events in the meantime.
        //

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            event_loop_post(&g_event_loop, WINDOW_FOCUS_DEFERRED, (void *)(intptr_t) window_id, 0);
        });

        return;
    }

    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
}

void window_manager_focus_window_without_raise_deferred(struct window *window)
{
    window_manager_post_focus_record(&window->application->psn, window->id, 0x01);

    _SLPSSetFrontProcessWithOptions(&window->application->psn, window->id, kCPSUserGenerated);
    window_manager_make_key_window(&window->application->psn, window->id);
}

void window_manager_focus_window_with_raise(ProcessSerialNumber *window_psn, uint32_t window_id, AXUIElementRef window_ref)
{
    TIME_FUNCTION;

#if 1
    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
    AXUIElementPerformAction(window_ref, kAXRaiseAction);
#else
    scripting_addition_focus_window(window_id);
#endif
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
struct application *window_manager_focused_application(struct window_manager *wm)
{
    TIME_FUNCTION;

    ProcessSerialNumber psn = {0};
    _SLPSGetFrontProcess(&psn);

    pid_t pid;
    GetProcessPID(&psn, &pid);

    return window_manager_find_application(wm, pid);
}

struct window *window_manager_focused_window(struct window_manager *wm)
{
    TIME_FUNCTION;

    struct application *application = window_manager_focused_application(wm);
    if (!application) return NULL;

    uint32_t window_id = application_focused_window(application);
    return window_manager_find_window(wm, window_id);
}

//
// NOTE: A window focused by a command only reports its focus once the application has processed the
// activation, which can take longer than it takes to send the next command. Until then, the next command
// acts on the window that was asked to be focused, instead of the one the application still reports.
//

#define PENDING_FOCUS_TIMEOUT_MS 500.0f

void window_manager_set_pending_focus(struct window_manager *wm, uint32_t window_id)
{
    wm->pending_focus_window_id = window_id;
    wm->pending_focus_time = read_os_timer();
}

struct window *window_manager_pending_focus_window(struct window_manager *wm)
{
    if (!wm->pending_focus_window_id) return NULL;

    float dt = os_timer_ms_between(wm->pending_focus_time, read_os_timer());
    struct window *window = dt < PENDING_FOCUS_TIMEOUT_MS ? window_manager_find_window(wm, wm->pending_focus_window_id) : NULL;
    if (!window) wm->pending_focus_window_id = 0;

    return window;
}

struct window *window_manager_acting_window(struct window_manager *wm)
{
    TIME_FUNCTION;

    struct window *window = window_manager_pending_focus_window(wm);
    return window ? window : window_manager_focused_window(wm);
}
#pragma clang diagnostic pop
