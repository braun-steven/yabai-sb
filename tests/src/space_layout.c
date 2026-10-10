static bool parse_layout(char *text, struct space_layout *layout)
{
    return space_manager_parse_space_layout(text, strlen(text), layout);
}

TEST_FUNC(space_layout_parse,
{
    struct space_layout layout;

    TEST_CHECK(parse_layout("15", &layout), true);
    TEST_CHECK(layout.count, 1);
    TEST_CHECK(layout.target[0], 15);
    TEST_CHECK(layout.builtin_index, -1);

    TEST_CHECK(parse_layout("10:5", &layout), true);
    TEST_CHECK(layout.count, 2);
    TEST_CHECK(layout.target[0], 10);
    TEST_CHECK(layout.target[1], 5);

    TEST_CHECK(parse_layout("10:5:1b", &layout), true);
    TEST_CHECK(layout.count, 3);
    TEST_CHECK(layout.target[2], 1);
    TEST_CHECK(layout.builtin_index, 2);

    TEST_CHECK(parse_layout("", &layout), false);
    TEST_CHECK(parse_layout("0", &layout), false);
    TEST_CHECK(parse_layout("10:", &layout), false);
    TEST_CHECK(parse_layout(":10", &layout), false);
    TEST_CHECK(parse_layout("10::5", &layout), false);
    TEST_CHECK(parse_layout("10:x", &layout), false);
    TEST_CHECK(parse_layout("b", &layout), false);
    TEST_CHECK(parse_layout("1b:2b", &layout), false);
    TEST_CHECK(parse_layout("1:1:1:1:1:1:1:1:1", &layout), false);
});

TEST_FUNC(space_layout_targets,
{
    struct space_layout layout;
    int target[SPACE_LAYOUT_MAX];

    parse_layout("10:5", &layout);
    space_manager_space_layout_targets(&layout, -1, target);
    TEST_CHECK(target[0], 10);
    TEST_CHECK(target[1], 5);

    parse_layout("10:5:1b", &layout);

    space_manager_space_layout_targets(&layout, 2, target);
    TEST_CHECK(target[0], 10);
    TEST_CHECK(target[1], 5);
    TEST_CHECK(target[2], 1);

    space_manager_space_layout_targets(&layout, 0, target);
    TEST_CHECK(target[0], 1);
    TEST_CHECK(target[1], 10);
    TEST_CHECK(target[2], 5);

    space_manager_space_layout_targets(&layout, 1, target);
    TEST_CHECK(target[0], 10);
    TEST_CHECK(target[1], 1);
    TEST_CHECK(target[2], 5);

    space_manager_space_layout_targets(&layout, -1, target);
    TEST_CHECK(target[0], 10);
    TEST_CHECK(target[1], 5);
    TEST_CHECK(target[2], 1);

    parse_layout("1b:10:5", &layout);
    space_manager_space_layout_targets(&layout, 2, target);
    TEST_CHECK(target[0], 10);
    TEST_CHECK(target[1], 5);
    TEST_CHECK(target[2], 1);
});
