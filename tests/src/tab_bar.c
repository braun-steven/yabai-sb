TEST_FUNC(tab_bar_style_parse,
{
    enum tab_bar_style style = TAB_BAR_STYLE_COUNT;

    TEST_CHECK(tab_bar_parse_style("glass", &style), true);
    TEST_CHECK(style, TAB_BAR_STYLE_GLASS);
    TEST_CHECK(tab_bar_parse_style("classic", &style), false);
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

TEST_FUNC(tab_bar_glass_tint_default,
{
    struct rgba_color color = rgba_color_from_hex(0xff285577);

    struct rgba_color tint = tab_bar_glass_tint(color, false, 0.4f);
    TEST_CHECK((int)(tint.a * 100.0f + 0.5f), 40);
    TEST_CHECK(tint.r == color.r && tint.g == color.g && tint.b == color.b, true);

    struct rgba_color custom = tab_bar_glass_tint(color, true, 0.4f);
    TEST_CHECK(custom.a == color.a, true);
    TEST_CHECK(custom.p, color.p);
});

TEST_FUNC(tab_bar_glass_track_tint_light,
{
    struct window_manager saved = g_window_manager;

    g_window_manager.tab_bar_unfocused_color = rgba_color_from_hex(0xff222222);
    g_window_manager.tab_bar_unfocused_color_light = rgba_color_from_hex(TAB_BAR_GLASS_LIGHT_TRACK_COLOR);
    g_window_manager.tab_bar_unfocused_color_custom = false;
    g_window_manager.tab_bar_unfocused_color_light_custom = false;

    struct rgba_color dark = tab_bar_glass_track_tint(false);
    TEST_CHECK((int)(dark.r * 255.0f + 0.5f), 0x22);
    TEST_CHECK((int)(dark.a * 100.0f + 0.5f), 40);

    struct rgba_color light = tab_bar_glass_track_tint(true);
    TEST_CHECK((int)(light.r * 255.0f + 0.5f), 0xf1);
    TEST_CHECK((int)(light.a * 100.0f + 0.5f), 90);

    g_window_manager.tab_bar_unfocused_color_custom = true;
    light = tab_bar_glass_track_tint(true);
    TEST_CHECK((int)(light.r * 255.0f + 0.5f), 0xf1);
    dark = tab_bar_glass_track_tint(false);
    TEST_CHECK(dark.p, 0xff222222);

    g_window_manager.tab_bar_unfocused_color_light = rgba_color_from_hex(0xffe0e0e0);
    g_window_manager.tab_bar_unfocused_color_light_custom = true;
    light = tab_bar_glass_track_tint(true);
    TEST_CHECK(light.p, 0xffe0e0e0);
    TEST_CHECK(light.a == 1.0f, true);

    g_window_manager = saved;
});
