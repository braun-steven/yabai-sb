//
// NOTE: The handlers of the events of EVENT_TYPE_LIST, run one at a time on the event loop thread
// (see event_loop.c). Other threads only post events; the state of yabai changes in these handlers.
// This file has the helpers they share and the application handlers; event_handlers_{window,space,
// mouse,system}.c have the others.
//

extern struct event_loop g_event_loop;
extern struct process_manager g_process_manager;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern enum mission_control_mode g_mission_control_mode;
extern int g_connection;
extern void *g_workspace_context;
extern int g_layer_below_window_level;
volatile bool __pending_window_focus;
volatile bool __pending_gesture;
volatile uint64_t __last_gesture_time;
volatile uint64_t __last_cmd_tab_time;
volatile uint32_t __pending_mouse_moved;
volatile uint32_t __pending_mouse_dragged;

//
// NOTE: The event tap counts the mouse events it posts. A handler that sees a newer event of the same
// type still queued drops its own, so only the most recent one is handled.
//

static inline bool mouse_event_is_stale(volatile uint32_t *pending)
{
    return __atomic_sub_fetch(pending, 1, __ATOMIC_ACQ_REL) > 0;
}

static void update_window_notifications(void)
{
    int window_count = 0;
    int window_capacity = 1024;

    if (workspace_is_macos_sequoia_or_newer()) {
        if (g_window_manager.window.count > window_capacity) window_capacity = g_window_manager.window.count;
    }

    uint32_t *window_list = calloc(window_capacity, sizeof(uint32_t));
    if (!window_list) return;

    if (workspace_is_macos_sequoia_or_newer()) {
        // NOTE(asmvik): Subscribe to all windows because of window_destroyed (and ordered) notifications
        table_for (struct window *window, g_window_manager.window, {
            if (window_count < window_capacity) window_list[window_count++] = window->id;
        })
    } else {
        // NOTE(asmvik): Subscribe to windows that have a tab bar because of window_ordered notifications,
        // and to windows that have a border because of the window_moved and window_resized notifications.
        window_count += tab_bar_window_list(window_list + window_count, window_capacity - window_count);
        window_count += border_window_list(window_list + window_count, window_capacity - window_count);
    }

    SLSRequestNotificationsForWindows(g_connection, window_list, window_count);
    free(window_list);
}

//
// @cleanup
//
// :AXBatching
//
// NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
// making sure that each window is only moved and resized a single time, when the final layout has been computed.
// This is necessary to make sure that we do not call the AX API for each modification to the tree.
// The handlers collect the views they modified and flush them once with flush_dirty_views.
//

static void tile_window_batched(struct view *view, struct window *window, uint32_t insertion_point)
{
    window_manager_adjust_layer(window, LAYER_BELOW);
    view_add_window(view, window, insertion_point);
    window_manager_add_managed_window(&g_window_manager, window, view);
}

static void untile_window_batched(struct view *view, struct window *window)
{
    view_remove_window(view, window);
    window_manager_remove_managed_window(&g_window_manager, window->id);
}

static void flush_dirty_views(struct view **view_list, int view_count)
{
    for (int i = 0; i < view_count; ++i) {
        struct view *view = view_list[i];
        if (!space_is_visible(view->sid)) continue;
        if (!view_is_dirty(view))         continue;

        view_flush(view);
    }
}

//
// NOTE: Tiles the windows that should be managed and are not yet, each one after the previous one,
// starting after insertion_point. New windows go to the space chosen by window_origin_display, other
// windows stay on their space.
//

static void tile_windows_batched(struct window **window_list, int window_count, uint32_t insertion_point, bool new_windows)
{
    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];
        if (!window_manager_should_manage_window(window))                  continue;
        if (window_manager_find_managed_window(&g_window_manager, window)) continue;

        uint64_t sid = new_windows ? window_manager_origin_space(&g_window_manager, window) : window_space(window->id);
        struct view *view = space_manager_find_view(&g_space_manager, sid);
        if (view->layout == VIEW_FLOAT) continue;

        tile_window_batched(view, window, insertion_point);
        view_list[view_count++] = view;
        insertion_point = window->id;
    }

    flush_dirty_views(view_list, view_count);
}

static void window_did_receive_focus(struct window_manager *wm, struct mouse_state *ms, struct window *window)
{
    struct window *focused_window = window_manager_find_window(wm, wm->focused_window_id);
    if (focused_window && focused_window != window && window_space(focused_window->id) == window_space(window->id)) {
        window_manager_set_window_opacity(wm, focused_window, g_window_manager.normal_window_opacity);
    }

    window_manager_set_window_opacity(wm, window, wm->active_window_opacity);

    if (wm->focused_window_id != window->id) {
        if (ms->ffm_window_id != window->id) {
            window_manager_center_mouse(wm, window);
        }

        wm->last_window_id = wm->focused_window_id;
    }

    uint32_t prev_focused_window_id = wm->focused_window_id;
    wm->focused_window_id = window->id;
    wm->focused_window_psn = window->application->psn;
    ms->ffm_window_id = 0;

    //
    // NOTE: Late focus events of windows focused earlier must not end a pending focus, so it is only
    // cleared when the window that was asked to be focused reports it.
    //

    if (wm->pending_focus_window_id == window->id) wm->pending_focus_window_id = 0;

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (view && view->layout == VIEW_TREE) tree_window_did_receive_focus(view, window->id);

    if (prev_focused_window_id != window->id) {
        tab_bar_refresh_for_window(prev_focused_window_id);
    }

    border_begin_batch();
    if (prev_focused_window_id != window->id) {
        border_refresh(window_manager_find_window(wm, prev_focused_window_id));
    }
    border_refresh(window);
    border_end_batch();
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
//
// NOTE: An application that cannot be observed yet is tried again with a growing delay. After
// APPLICATION_LAUNCH_MAX_ATTEMPTS attempts (about 36s) it is given up on, until the user
// activates it, so that an application that never responds is not polled forever.
//

#define APPLICATION_LAUNCH_MAX_ATTEMPTS 12

static inline float application_launch_retry_delay(int attempt)
{
    return min(0.1f * (float)(1 << min(attempt, 16)), 5.0f);
}

static inline bool application_launch_can_retry(int attempt)
{
    return attempt < APPLICATION_LAUNCH_MAX_ATTEMPTS;
}

static void application_launch_retry(struct process *process)
{
    if (!application_launch_can_retry(process->launch_attempts)) {
        process->launch_given_up = true;
        debug("%s: giving up on %s (%d) after %d attempts\n", __FUNCTION__, process->name, process->pid, process->launch_attempts);
        return;
    }

    float delay = application_launch_retry_delay(process->launch_attempts++);
    debug("%s: retrying %s (%d) in %.1fs (attempt %d)\n", __FUNCTION__, process->name, process->pid, delay, process->launch_attempts);

    __block ProcessSerialNumber psn = process->psn;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        struct process *_process = process_manager_find_process(&g_process_manager, &psn);
        if (_process) event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, _process, 0);
    });
}

static EVENT_HANDLER(APPLICATION_LAUNCHED)
{
    struct process *process = context;

    if (__atomic_load_n(&process->terminated, __ATOMIC_RELAXED)) {
        debug("%s: %s (%d) terminated during launch\n", __FUNCTION__, process->name, process->pid);
        window_manager_remove_lost_front_switched_event(&g_window_manager, process->pid);
        return;
    }

    if (!__atomic_load_n(&process->ns_application, __ATOMIC_RELAXED)) {
        debug("%s: %s (%d) missing ns_application. fetching..\n", __FUNCTION__, process->name, process->pid);
        __atomic_store_n(&process->ns_application, workspace_application_create_running_ns_application(process), __ATOMIC_RELEASE);

        if (!__atomic_load_n(&process->ns_application, __ATOMIC_RELAXED)) {
            debug("%s: %s (%d) unable to fetch ns_application..\n", __FUNCTION__, process->name, process->pid);
            application_launch_retry(process);
            return;
        }
    }

    if (!workspace_application_is_finished_launching(process)) {
        debug("%s: %s (%d) is not finished launching, subscribing to finishedLaunching changes\n", __FUNCTION__, process->name, process->pid);
        workspace_application_observe_finished_launching(g_workspace_context, process);

        //
        // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
        // Not actually sure if this can happen in practice..
        //

        if (!workspace_application_is_finished_launching(process)) return;
        workspace_application_unobserve_finished_launching(g_workspace_context, process);
    }

    if (!workspace_application_is_observable(process)) {
        debug("%s: %s (%d) is not observable, subscribing to activationPolicy changes\n", __FUNCTION__, process->name, process->pid);
        workspace_application_observe_activation_policy(g_workspace_context, process);

        //
        // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
        // Not actually sure if this can happen in practice..
        //

        if (!workspace_application_is_observable(process)) return;
        workspace_application_unobserve_activation_policy(g_workspace_context, process);
    }

    //
    // NOTE(asmvik): If we somehow receive a duplicate launched event due to the subscription-timing-mess above,
    // simply ignore the event..
    //

    struct application *application = window_manager_find_application(&g_window_manager, process->pid);
    if (application) { return; } else { application = application_create(process); }

    if (!application_observe(application)) {
        bool ax_retry = application->ax_retry;

        application_unobserve(application);
        application_destroy(application);
        debug("%s: could not observe notifications for %s (%d) (%d)\n", __FUNCTION__, process->name, process->pid, ax_retry);

        if (ax_retry) application_launch_retry(process);
        return;
    }

    if (window_manager_find_lost_front_switched_event(&g_window_manager, process->pid)) {
        event_loop_post(&g_event_loop, APPLICATION_FRONT_SWITCHED, process, 0);
        window_manager_remove_lost_front_switched_event(&g_window_manager, process->pid);
    }

    debug("%s: %s (%d)\n", __FUNCTION__, process->name, process->pid);
    window_manager_add_application(&g_window_manager, application);
    event_signal_push(SIGNAL_APPLICATION_LAUNCHED, application);
    process->launch_attempts = 0;
    process->launch_given_up = false;

    int window_count;
    struct window **window_list = window_manager_add_application_windows(&g_space_manager, &g_window_manager, application, &window_count);
    tile_windows_batched(window_list, window_count, g_window_manager.focused_window_id, true);

    for (int i = 0; i < window_count; ++i) {
        if (window_manager_is_window_eligible(window_list[i])) {
            event_signal_push(SIGNAL_WINDOW_CREATED, window_list[i]);
        }
    }

    if (workspace_is_macos_sequoia_or_newer()) {
        update_window_notifications();
    }
}

static EVENT_HANDLER(APPLICATION_TERMINATED)
{
    struct process *process = context;
    struct application *application = window_manager_find_application(&g_window_manager, process->pid);

    if (!application) {
        debug("%s: %s (%d) (not observed)\n", __FUNCTION__, process->name, process->pid);
        goto out;
    }

    debug("%s: %s (%d)\n", __FUNCTION__, process->name, process->pid);
    event_signal_push(SIGNAL_APPLICATION_TERMINATED, application);
    window_manager_remove_application(&g_window_manager, application->pid);

    for (int i = 0; i < buf_len(g_window_manager.applications_to_refresh); ++i) {
        if (application == g_window_manager.applications_to_refresh[i]) {
            buf_del(g_window_manager.applications_to_refresh, i);
            break;
        }
    }

    int window_count;
    struct window **window_list = window_manager_find_application_windows(&g_window_manager, application, &window_count);

    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];

        if (!window_invalidate(window)) {
            window->application = NULL;
            continue;
        }

        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        if (view) {
            untile_window_batched(view, window);
            view_list[view_count++] = view;
        }

        if (g_mouse_state.window == window) g_mouse_state.window = NULL;
        if (g_mouse_state.ffm_window_id == window->id) g_mouse_state.ffm_window_id = 0;

        if (window->is_eligible) {
            event_signal_push(SIGNAL_WINDOW_DESTROYED, window);
        }

        window_manager_remove_scratchpad_for_window(&g_window_manager, window, false);
        window_manager_remove_window(&g_window_manager, window->id);
        window_unobserve(window);
        window_destroy(window);
    }

    application_unobserve(application);
    application_destroy(application);

    flush_dirty_views(view_list, view_count);

    if (workspace_is_macos_sequoia_or_newer()) {
        update_window_notifications();
    }

out:
    process_destroy(process);
}

//
// NOTE: With skip_window_focus_animation, an application activated on a space that is not visible
// (e.g. by cmd-tab) brings that space to front without the space switch animation.
//

static void application_front_switched_focus_space(struct application *application, struct process *process)
{
    uint64_t psn_sid = process_manager_active_space_for_psn(application->connection);

    uint64_t last_cmd_tab_time = __atomic_load_n(&__last_cmd_tab_time, __ATOMIC_RELAXED);
    float dt = os_timer_ms_between(last_cmd_tab_time, read_os_timer());
    if (dt > 1500.0f) {
        CFTypeRef dummy = NULL;
        AXUIElementCopyAttributeValue(application->ref, CFSTR("__fence"), &dummy);
    }

    if (__atomic_load_n(&__pending_window_focus, __ATOMIC_RELAXED) == false) {
        if (psn_sid && !space_is_visible(psn_sid)) {
            SLSSpaceSetFrontPSN(g_connection, psn_sid, process->psn);
            space_manager_focus_space_using_gesture(space_display_id(psn_sid), psn_sid);
        }
    }
}

static struct window *dim_focused_window(void)
{
    struct window *focused_window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
    if (focused_window) {
        window_manager_set_window_opacity(&g_window_manager, focused_window, g_window_manager.normal_window_opacity);
    }

    return focused_window;
}

//
// NOTE: The activated application has no focused window (e.g. Finder with only the desktop), so no window
// has focus until one of its windows is focused.
//

static void application_front_switched_without_window(struct application *application)
{
    struct window *focused_window = dim_focused_window();

    uint32_t prev_focused_window_id = g_window_manager.focused_window_id;
    g_window_manager.last_window_id = prev_focused_window_id;
    g_window_manager.focused_window_id = 0;
    g_window_manager.focused_window_psn = application->psn;
    g_mouse_state.ffm_window_id = 0;

    if (prev_focused_window_id) {
        tab_bar_refresh_for_window(prev_focused_window_id);
        border_refresh(focused_window);
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static EVENT_HANDLER(APPLICATION_FRONT_SWITCHED)
{
    struct process *process = context;
    struct application *application = window_manager_find_application(&g_window_manager, process->pid);

    if (!application) {
        window_manager_add_lost_front_switched_event(&g_window_manager, process->pid);

        if (process->launch_given_up) {
            debug("%s: %s (%d) was activated, trying to observe it again\n", __FUNCTION__, process->name, process->pid);
            process->launch_attempts = 0;
            process->launch_given_up = false;
            event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, process, 0);
        }

        return;
    }

    if (g_space_manager.skip_window_focus_animation) {
        application_front_switched_focus_space(application, process);
    }

    struct application *deactivated_application = window_manager_find_application(&g_window_manager, g_process_manager.front_pid);
    if (deactivated_application) event_signal_push(SIGNAL_APPLICATION_DEACTIVATED, deactivated_application);

    debug("%s: %s (%d)\n", __FUNCTION__, process->name, process->pid);
    event_signal_push(SIGNAL_APPLICATION_ACTIVATED, application);
    g_process_manager.switch_event_time = GetCurrentEventTime();
    g_process_manager.last_front_pid = g_process_manager.front_pid;
    g_process_manager.front_pid = process->pid;
    event_signal_push(SIGNAL_APPLICATION_FRONT_SWITCHED, NULL);

    for (int i = 0; i < buf_len(g_window_manager.applications_to_refresh); ++i) {
        if (application == g_window_manager.applications_to_refresh[i]) {
            debug("%s: %s has windows that are not yet resolved\n", __FUNCTION__, application->name);
            window_manager_add_existing_application_windows(&g_space_manager, &g_window_manager, application, i);
            break;
        }
    }

    uint32_t application_focused_window_id = application_focused_window(application);
    if (!application_focused_window_id) {
        application_front_switched_without_window(application);
        return;
    }

    struct window *window = window_manager_find_window(&g_window_manager, application_focused_window_id);
    if (!window) {
        dim_focused_window();
        window_manager_add_lost_focused_event(&g_window_manager, application_focused_window_id);
        return;
    }

    window_did_receive_focus(&g_window_manager, &g_mouse_state, window);
    event_signal_push(SIGNAL_WINDOW_FOCUSED, window);
    __atomic_store_n(&__pending_window_focus, false, __ATOMIC_RELEASE);
}
#pragma clang diagnostic pop

static EVENT_HANDLER(APPLICATION_VISIBLE)
{
    struct application *application = window_manager_find_application(&g_window_manager, (pid_t)(intptr_t) context);
    if (!application) return;

    debug("%s: %s\n", __FUNCTION__, application->name);
    application->is_hidden = false;

    int window_count;
    struct window **window_list = window_manager_find_application_windows(&g_window_manager, application, &window_count);
    tile_windows_batched(window_list, window_count, g_window_manager.last_window_id, false);

    for (int i = 0; i < window_count; ++i) {
        border_refresh_window_space(window_list[i]);
    }

    event_signal_push(SIGNAL_APPLICATION_VISIBLE, application);
}

static EVENT_HANDLER(APPLICATION_HIDDEN)
{
    struct application *application = window_manager_find_application(&g_window_manager, (pid_t)(intptr_t) context);
    if (!application) return;

    debug("%s: %s\n", __FUNCTION__, application->name);
    application->is_hidden = true;

    int window_count;
    struct window **window_list = window_manager_find_application_windows(&g_window_manager, application, &window_count);

    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];

        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        if (view) {

            window_manager_adjust_layer(window, LAYER_NORMAL);
            untile_window_batched(view, window);
            window_manager_purify_window(&g_window_manager, window);
            view_list[view_count++] = view;
        }
    }

    flush_dirty_views(view_list, view_count);

    for (int i = 0; i < window_count; ++i) {
        border_refresh_window_space(window_list[i]);
    }

    event_signal_push(SIGNAL_APPLICATION_HIDDEN, application);
}
#pragma clang diagnostic pop
