TEST_FUNC(window_frame_close,
{
    CGRect frame = CGRectMake(100, 200, 300, 400);

    TEST_CHECK(window_frame_is_close(frame, 100, 200, 300, 400), true);
    TEST_CHECK(window_frame_is_close(frame, 100.5f, 199.5f, 300.9f, 399.1f), true);

    TEST_CHECK(window_frame_is_close(frame, 101, 200, 300, 400), false);
    TEST_CHECK(window_frame_is_close(frame, 100, 199, 300, 400), false);
    TEST_CHECK(window_frame_is_close(frame, 100, 200, 301, 400), false);
    TEST_CHECK(window_frame_is_close(frame, 100, 200, 300, 398.5f), false);

    TEST_CHECK(window_frame_is_close(CGRectZero, 100, 200, 300, 400), false);
});

static struct application window_frame_app_a;
static struct application window_frame_app_b;
static struct window window_frame_windows[5];
static struct window_capture window_frame_captures[5];

static void window_frame_captures_init(void)
{
    struct application *owners[5] = { &window_frame_app_a, &window_frame_app_b, &window_frame_app_a, &window_frame_app_b, &window_frame_app_a };

    for (int i = 0; i < 5; ++i) {
        memset(&window_frame_windows[i], 0, sizeof(struct window));
        window_frame_windows[i].application = owners[i];
        window_frame_windows[i].ref = (AXUIElementRef)(uintptr_t)(i + 1);

        window_frame_captures[i].window = &window_frame_windows[i];
        window_frame_captures[i].x = i;
        window_frame_captures[i].y = 10 * i;
        window_frame_captures[i].w = 100;
        window_frame_captures[i].h = 200;
    }
}

TEST_FUNC(window_frame_group_by_application,
{
    window_frame_captures_init();

    struct window_frame_group groups[5];
    struct window_frame_request requests[5];
    int group_count = window_manager_group_window_frames(window_frame_captures, 5, groups, requests);

    TEST_CHECK(group_count, 2);
    TEST_CHECK(groups[0].application == &window_frame_app_a, true);
    TEST_CHECK(groups[0].count, 3);
    TEST_CHECK(groups[1].application == &window_frame_app_b, true);
    TEST_CHECK(groups[1].count, 2);

    //
    // NOTE: Windows keep their order within a group, and each request carries the frame of its window.
    //

    TEST_CHECK((int)(uintptr_t) groups[0].list[0].ref, 1);
    TEST_CHECK((int)(uintptr_t) groups[0].list[1].ref, 3);
    TEST_CHECK((int)(uintptr_t) groups[0].list[2].ref, 5);
    TEST_CHECK((int)(uintptr_t) groups[1].list[0].ref, 2);
    TEST_CHECK((int)(uintptr_t) groups[1].list[1].ref, 4);
    TEST_CHECK((int) groups[0].list[1].position.y, 20);
    TEST_CHECK((int) groups[1].list[1].position.x, 3);
    TEST_CHECK((int) groups[1].list[1].size.height, 200);
});

TEST_FUNC(window_frame_needs_update_decision,
{
    CGRect target = CGRectMake(10, 20, 300, 400);
    CGRect other = CGRectMake(10, 20, 500, 400);

    //
    // NOTE: A window is only skipped when both the last request and the window server bounds match.
    //

    TEST_CHECK(window_frame_needs_update(target, true, target, 10, 20, 300, 400), false);
    TEST_CHECK(window_frame_needs_update(target, true, other,  10, 20, 300, 400), true);
    TEST_CHECK(window_frame_needs_update(other,  true, target, 10, 20, 300, 400), true);
    TEST_CHECK(window_frame_needs_update(target, false, target, 10, 20, 300, 400), true);
    TEST_CHECK(window_frame_needs_update(CGRectZero, true, target, 10, 20, 300, 400), true);

    //
    // NOTE: An application that has not applied the previous request yet still reports the frame it had
    // before. Going back to that frame must not be skipped, because the pending request would win.
    //

    TEST_CHECK(window_frame_needs_update(other, true, target, 10, 20, 300, 400), true);
});

static struct window_manager pending_focus_wm;
static struct window pending_focus_window;

static void pending_focus_init(void)
{
    memset(&pending_focus_wm, 0, sizeof(struct window_manager));
    table_init(&pending_focus_wm.window, 16, hash_wm, compare_wm);

    memset(&pending_focus_window, 0, sizeof(struct window));
    pending_focus_window.id = 42;
    pending_focus_window.id_ptr = &pending_focus_window.id;
    window_manager_add_window(&pending_focus_wm, &pending_focus_window);
}

TEST_FUNC(window_pending_focus,
{
    pending_focus_init();

    TEST_CHECK(window_manager_pending_focus_window(&pending_focus_wm) == NULL, true);

    window_manager_set_pending_focus(&pending_focus_wm, 42);
    TEST_CHECK(window_manager_pending_focus_window(&pending_focus_wm) == &pending_focus_window, true);
    TEST_CHECK(pending_focus_wm.pending_focus_window_id, 42);

    //
    // NOTE: A pending focus expires, and is dropped for windows that no longer exist.
    //

    pending_focus_wm.pending_focus_time = read_os_timer() - (uint64_t)(read_os_freq() * 0.6);
    TEST_CHECK(window_manager_pending_focus_window(&pending_focus_wm) == NULL, true);
    TEST_CHECK(pending_focus_wm.pending_focus_window_id, 0);

    window_manager_set_pending_focus(&pending_focus_wm, 7);
    TEST_CHECK(window_manager_pending_focus_window(&pending_focus_wm) == NULL, true);
    TEST_CHECK(pending_focus_wm.pending_focus_window_id, 0);

    table_free(&pending_focus_wm.window);
});

TEST_FUNC(mouse_event_coalescing,
{
    volatile uint32_t pending = 0;

    //
    // NOTE: Three events were posted before the handler ran: only the last one is handled.
    //

    __atomic_add_fetch(&pending, 3, __ATOMIC_ACQ_REL);
    TEST_CHECK(mouse_event_is_stale(&pending), true);
    TEST_CHECK(mouse_event_is_stale(&pending), true);
    TEST_CHECK(mouse_event_is_stale(&pending), false);

    __atomic_add_fetch(&pending, 1, __ATOMIC_ACQ_REL);
    TEST_CHECK(mouse_event_is_stale(&pending), false);
    TEST_CHECK((int) pending, 0);
});

static ProcessSerialNumber known_focus_psn(uint32_t low)
{
    ProcessSerialNumber psn = {0};
    psn.lowLongOfPSN = low;
    return psn;
}

TEST_FUNC(space_known_focus,
{
    struct window_manager wm;
    memset(&wm, 0, sizeof(wm));

    ProcessSerialNumber owner = known_focus_psn(0x1234);
    ProcessSerialNumber other = known_focus_psn(0x5678);
    wm.focused_window_id = 42;
    wm.focused_window_psn = owner;

    //
    // NOTE: The known focus is used only while the front process owns it and no focus change is pending.
    //

    TEST_CHECK(space_manager_can_use_known_focus(&owner, &wm, false), true);
    TEST_CHECK(space_manager_can_use_known_focus(&other, &wm, false), false);
    TEST_CHECK(space_manager_can_use_known_focus(&owner, &wm, true), false);

    wm.focused_window_id = 0;
    TEST_CHECK(space_manager_can_use_known_focus(&owner, &wm, false), false);
});

TEST_FUNC(application_launch_retry_backoff,
{
    //
    // NOTE: The delay doubles from 100ms and is capped at 5s; delays are compared in milliseconds.
    //

    TEST_CHECK((int)(application_launch_retry_delay(0) * 1000.0f + 0.5f), 100);
    TEST_CHECK((int)(application_launch_retry_delay(1) * 1000.0f + 0.5f), 200);
    TEST_CHECK((int)(application_launch_retry_delay(5) * 1000.0f + 0.5f), 3200);
    TEST_CHECK((int)(application_launch_retry_delay(6) * 1000.0f + 0.5f), 5000);
    TEST_CHECK((int)(application_launch_retry_delay(40) * 1000.0f + 0.5f), 5000);

    float total = 0.0f;
    int attempts = 0;
    while (application_launch_can_retry(attempts)) total += application_launch_retry_delay(attempts++);

    TEST_CHECK(attempts, APPLICATION_LAUNCH_MAX_ATTEMPTS);
    TEST_CHECK(total > 30.0f && total < 40.0f, true);
});

static uint32_t *unresolved_window_ids(struct window_manager *wm, int *count)
{
    static uint32_t window_list[] = { 11, 12, 13, 14 };
    uint32_t *result = window_manager_unresolved_windows(wm, window_list, array_count(window_list));
    *count = ts_buf_len(result);
    return result;
}

TEST_FUNC(window_unresolved_list,
{
    struct window_manager wm = {0};
    table_init(&wm.window, 16, hash_wm, compare_wm);

    struct window a = { .id = 12 };
    struct window b = { .id = 14 };
    window_manager_add_window(&wm, &a);
    window_manager_add_window(&wm, &b);

    int count;
    uint32_t *unresolved = unresolved_window_ids(&wm, &count);
    TEST_CHECK(count, 2);
    TEST_CHECK(unresolved[0], 11);
    TEST_CHECK(unresolved[1], 13);

    struct window c = { .id = 11 };
    struct window d = { .id = 13 };
    window_manager_add_window(&wm, &c);
    window_manager_add_window(&wm, &d);
    TEST_CHECK(unresolved_window_ids(&wm, &count) == NULL, true);
    TEST_CHECK(count, 0);

    table_free(&wm.window);
});
