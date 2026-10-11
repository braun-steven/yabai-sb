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

// NOTE: The display holds the spaces 1..n, one per character of the mask, and 'u' marks a user space.
static int space_test_lists(char *mask, uint64_t *space_list, bool *user_list)
{
    int count = strlen(mask);
    for (int i = 0; i < count; ++i) {
        space_list[i] = i + 1;
        user_list[i] = mask[i] == 'u';
    }
    return count;
}

static int move_replacement(char *mask, uint64_t sid, uint64_t visible_sid)
{
    uint64_t space_list[16];
    bool user_list[16];
    int count = space_test_lists(mask, space_list, user_list);
    return (int) space_manager_move_space_replacement(space_list, user_list, count, sid, visible_sid);
}

static int move_candidate(char *mask, uint64_t visible_sid, bool from_end)
{
    uint64_t space_list[16];
    bool user_list[16];
    int count = space_test_lists(mask, space_list, user_list);
    return (int) space_manager_space_layout_move_candidate(space_list, user_list, count, visible_sid, from_end);
}

TEST_FUNC(space_move_replacement,
{
    // NOTE: The regression: a visible space is replaced even when it is not the focused space,
    // so the scripting addition hides it before the move and it never stays shown on the
    // destination display as a second menubar.
    TEST_CHECK(move_replacement("uuuu", 1, 1), 2);
    TEST_CHECK(move_replacement("uuuu", 3, 3), 2);
    TEST_CHECK(move_replacement("uuuu", 4, 4), 3);

    // A hidden space needs no replacement.
    TEST_CHECK(move_replacement("uuuu", 2, 1), 0);

    // The replacement is always a user space on the same display.
    TEST_CHECK(move_replacement("-u-u", 2, 2), 4);
    TEST_CHECK(move_replacement("-u-u", 4, 4), 2);
    TEST_CHECK(move_replacement("u", 1, 1), 0);
});

TEST_FUNC(space_layout_move_candidate,
{
    // The visible space is skipped, from either edge.
    TEST_CHECK(move_candidate("uuuu", 3, false), 1);
    TEST_CHECK(move_candidate("uuuu", 1, false), 2);
    TEST_CHECK(move_candidate("uuuu", 3, true), 4);
    TEST_CHECK(move_candidate("uuuu", 4, true), 3);

    TEST_CHECK(move_candidate("-uu-", 2, false), 3);
    TEST_CHECK(move_candidate("-uu-", 3, true), 2);

    // The visible space is only moved when it is the only user space.
    TEST_CHECK(move_candidate("-u--", 2, false), 2);
    TEST_CHECK(move_candidate("----", 2, false), 0);
});
