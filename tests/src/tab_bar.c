TEST_FUNC(tab_bar_style_parse,
{
    enum tab_bar_style style = TAB_BAR_STYLE_COUNT;

    TEST_CHECK(tab_bar_parse_style("glass", &style), true);
    TEST_CHECK(style, TAB_BAR_STYLE_GLASS);
    TEST_CHECK(tab_bar_parse_style("classic", &style), true);
    TEST_CHECK(style, TAB_BAR_STYLE_CLASSIC);
    TEST_CHECK(tab_bar_parse_style("i3", &style), true);
    TEST_CHECK(style, TAB_BAR_STYLE_I3);

    TEST_CHECK(tab_bar_parse_style("auto", &style), false);
    TEST_CHECK(tab_bar_parse_style("", &style), false);
    TEST_CHECK(style, TAB_BAR_STYLE_I3);
});

TEST_FUNC(tab_bar_font_parse,
{
    TEST_CHECK(tab_bar_set_font("system:13"), true);
    TEST_CHECK(string_equals(g_window_manager.tab_bar_font_name, "system:13"), true);
    TEST_CHECK((int) CTFontGetSize(g_window_manager.tab_bar_font), 13);

    TEST_CHECK(tab_bar_set_font("Menlo:11"), true);
    TEST_CHECK((int) CTFontGetSize(g_window_manager.tab_bar_font), 11);

    TEST_CHECK(tab_bar_set_font("system"), false);
    TEST_CHECK(tab_bar_set_font("system:0"), false);
    TEST_CHECK(tab_bar_set_font(":12"), false);
    TEST_CHECK(string_equals(g_window_manager.tab_bar_font_name, "Menlo:11"), true);
});
