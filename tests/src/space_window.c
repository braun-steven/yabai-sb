TEST_FUNC(space_window_user_predicates,
{
    uint64_t visible_tags = 0x1;
    uint64_t minimized_tags = 0x1000000000000001;

    TEST_CHECK(space_window_is_user_window(0, 0, visible_tags, 0x2), true);
    TEST_CHECK(space_window_is_user_window(0, 8, 0x80000002, 0x2), true);
    TEST_CHECK(space_window_is_user_window(0, 3, 0x400000000000001, 0x0), true);

    // NOTE: child windows, other levels and windows without the tags are not user windows
    TEST_CHECK(space_window_is_user_window(7, 0, visible_tags, 0x2), false);
    TEST_CHECK(space_window_is_user_window(0, 25, visible_tags, 0x2), false);
    TEST_CHECK(space_window_is_user_window(0, 0, 0x2, 0x2), false);
    TEST_CHECK(space_window_is_user_window(0, 0, visible_tags, 0x0), false);

    TEST_CHECK(space_window_is_minimized_user_window(0, 0, minimized_tags, 0x0), true);
    TEST_CHECK(space_window_is_minimized_user_window(0, 0, 0x100000000000001, 0x1), true);
    TEST_CHECK(space_window_is_minimized_user_window(0, 0, minimized_tags, 0x2), false);
    TEST_CHECK(space_window_is_minimized_user_window(0, 0, visible_tags, 0x0), false);
    TEST_CHECK(space_window_is_minimized_user_window(3, 0, minimized_tags, 0x0), false);
});
