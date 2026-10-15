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

static struct window mouse_drop_test_window(void)
{
    return (struct window) { .frame = CGRectMake(100, 100, 200, 100) };
}

TEST_FUNC(mouse_drop_action_regions,
{
    struct window window = mouse_drop_test_window();
    struct mouse_state ms = { .drop_action = MOUSE_MODE_SWAP };

    TEST_CHECK(mouse_determine_drop_action(&ms, &window, CGPointMake(200, 150)), MOUSE_DROP_ACTION_SWAP);
    TEST_CHECK(mouse_determine_drop_action(&ms, &window, CGPointMake(200, 105)), MOUSE_DROP_ACTION_WARP_TOP);
    TEST_CHECK(mouse_determine_drop_action(&ms, &window, CGPointMake(295, 150)), MOUSE_DROP_ACTION_WARP_RIGHT);
    TEST_CHECK(mouse_determine_drop_action(&ms, &window, CGPointMake(200, 195)), MOUSE_DROP_ACTION_WARP_BOTTOM);
    TEST_CHECK(mouse_determine_drop_action(&ms, &window, CGPointMake(105, 150)), MOUSE_DROP_ACTION_WARP_LEFT);

    // NOTE: mouse_drop_action stack makes the center a tab of the window instead
    ms.drop_action = MOUSE_MODE_STACK;
    TEST_CHECK(mouse_determine_drop_action(&ms, &window, CGPointMake(200, 150)), MOUSE_DROP_ACTION_STACK);
});
