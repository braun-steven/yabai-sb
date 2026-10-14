static bool event_signal_test_filter(enum signal_type type, char *app, char *title, bool active, struct signal *signal)
{
    struct event_signal es = { .type = type, .app = app, .title = title, .active = active };
    return event_signal_filter(&es, signal);
}

TEST_FUNC(event_signal_filter_properties,
{
    struct signal signal = {0};
    signal.app_regex_valid = regcomp(&signal.app_regex, "^Safari$", REG_EXTENDED) == 0;
    TEST_CHECK(signal.app_regex_valid, true);

    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_FOCUSED, "Safari", "x", false, &signal), false);
    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_FOCUSED, "Mail", "x", false, &signal), true);

    // NOTE: events without an application are never filtered
    TEST_CHECK(event_signal_test_filter(SIGNAL_SPACE_CHANGED, NULL, NULL, false, &signal), false);

    signal.app_regex_exclude = true;
    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_FOCUSED, "Safari", "x", false, &signal), true);
    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_FOCUSED, "Mail", "x", false, &signal), false);

    signal.app_regex_exclude = false;
    signal.active = SIGNAL_PROP_YES;
    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_MOVED, "Safari", "x", true, &signal), false);
    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_MOVED, "Safari", "x", false, &signal), true);

    // NOTE: focused windows have no active property to filter on
    TEST_CHECK(event_signal_test_filter(SIGNAL_WINDOW_FOCUSED, "Safari", "x", false, &signal), false);

    signal.active = SIGNAL_PROP_NO;
    TEST_CHECK(event_signal_test_filter(SIGNAL_APPLICATION_HIDDEN, "Safari", NULL, false, &signal), false);
    TEST_CHECK(event_signal_test_filter(SIGNAL_APPLICATION_HIDDEN, "Safari", NULL, true, &signal), true);

    regfree(&signal.app_regex);
});

TEST_FUNC(event_signal_args,
{
    struct event_signal es = {0};
    event_signal_add_arg(&es, "YABAI_SPACE_ID", "%lld", 42ULL);
    event_signal_add_arg(&es, "YABAI_SPACE_INDEX", "%d", 3);

    TEST_CHECK(es.arg_count, 2);
    TEST_CHECK(strcmp(es.arg_name[0], "YABAI_SPACE_ID"), 0);
    TEST_CHECK(strcmp(es.arg_value[0], "42"), 0);
    TEST_CHECK(strcmp(es.arg_name[1], "YABAI_SPACE_INDEX"), 0);
    TEST_CHECK(strcmp(es.arg_value[1], "3"), 0);
});
