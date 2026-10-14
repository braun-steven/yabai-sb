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

TEST_FUNC(tab_bar_backdrop_parse,
{
    enum tab_bar_backdrop backdrop = TAB_BAR_BACKDROP_COUNT;

    TEST_CHECK(tab_bar_parse_backdrop("glass", &backdrop), true);
    TEST_CHECK(backdrop, TAB_BAR_BACKDROP_GLASS);
    TEST_CHECK(tab_bar_parse_backdrop("blur", &backdrop), true);
    TEST_CHECK(backdrop, TAB_BAR_BACKDROP_BLUR);
    TEST_CHECK(tab_bar_parse_backdrop("off", &backdrop), true);
    TEST_CHECK(backdrop, TAB_BAR_BACKDROP_OFF);

    TEST_CHECK(tab_bar_parse_backdrop("solid", &backdrop), false);
    TEST_CHECK(backdrop, TAB_BAR_BACKDROP_OFF);
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

static double tab_bar_test_fitted_width(char *text, double max_width)
{
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 13.0f, NULL);
    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef title = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);

    CTLineRef line = tab_bar_create_fitted_line(title, attributes, max_width);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

    CFRelease(line);
    CFRelease(title);
    CFRelease(attributes);
    CFRelease(font);
    return width;
}

TEST_FUNC(tab_bar_title_fits,
{
    double full = tab_bar_test_fitted_width("Untitled Document", 1000.0);
    TEST_CHECK(full > 50.0, true);
    TEST_CHECK(tab_bar_test_fitted_width("Untitled Document", 50.0) <= 50.0, true);
    TEST_CHECK(tab_bar_test_fitted_width("Untitled Document", full) == full, true);
});

TEST_FUNC(tab_bar_slots_cover_bar,
{
    CGRect area = CGRectMake(10, 0, 100, 20);

    // NOTE: slots are whole pixels without gaps, and the last one takes the rest
    CGRect first = tab_bar_slot(area, 0, 3);
    CGRect second = tab_bar_slot(area, 1, 3);
    CGRect last = tab_bar_slot(area, 2, 3);

    TEST_CHECK((int) first.origin.x, 10);
    TEST_CHECK((int) first.size.width, 33);
    TEST_CHECK((int) second.origin.x, 43);
    TEST_CHECK((int) (second.origin.x + second.size.width), (int) last.origin.x);
    TEST_CHECK((int) (last.origin.x + last.size.width), 110);

    CGRect single = tab_bar_slot(area, 0, 1);
    TEST_CHECK((int) single.size.width, 100);
});
