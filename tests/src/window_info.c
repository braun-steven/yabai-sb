static char window_info_test_output[1024];

static char *window_info_test_serialize(struct window_info *info, uint64_t flags)
{
    memset(window_info_test_output, 0, sizeof(window_info_test_output));
    FILE *rsp = fmemopen(window_info_test_output, sizeof(window_info_test_output), "w");
    window_info_serialize(rsp, info, flags);
    fclose(rsp);
    return window_info_test_output;
}

static struct window_info window_info_test_fixture(void)
{
    return (struct window_info) {
        .id = 42,
        .app = "Text\"Edit",
        .title = "a\tb",
        .split = SPLIT_X,
        .is_visible = true
    };
}

TEST_FUNC(window_info_serialize_selected,
{
    struct window_info info = window_info_test_fixture();

    TEST_CHECK(strcmp(window_info_test_serialize(&info, WINDOW_PROPERTY_ID), "{\n\t\"id\":42\n}"), 0);
    TEST_CHECK(strcmp(window_info_test_serialize(&info, WINDOW_PROPERTY_ID | WINDOW_PROPERTY_APP | WINDOW_PROPERTY_TITLE),
                      "{\n\t\"id\":42,\n\t\"app\":\"Text\\\"Edit\",\n\t\"title\":\"a\\tb\"\n}"), 0);
    TEST_CHECK(strcmp(window_info_test_serialize(&info, WINDOW_PROPERTY_SPLIT_TYPE | WINDOW_PROPERTY_IS_VISIBLE),
                      "{\n\t\"split-type\":\"horizontal\",\n\t\"is-visible\":true\n}"), 0);
});

TEST_FUNC(window_info_tree_fields,
{
    struct con *root = con_create(CON_SPLITH);
    struct con *tabs = tree_test_split(root, CON_TABBED);
    tree_test_leaf(tabs, 1);
    struct con *split = tree_test_split(tabs, CON_SPLITV);
    struct con *leaf = tree_test_leaf(split, 2);
    struct con *side = tree_test_leaf(root, 3);
    leaf->zoom = CON_ZOOM_PARENT;

    struct window_info info = {0};
    window_info_set_tree(&info, leaf);
    TEST_CHECK(info.split, SPLIT_X);
    TEST_CHECK(info.stack_index, 2);
    TEST_CHECK(info.has_parent_zoom, true);
    TEST_CHECK(info.has_fullscreen_zoom, false);

    info = (struct window_info) {0};
    window_info_set_tree(&info, side);
    TEST_CHECK(info.split, SPLIT_Y);
    TEST_CHECK(info.stack_index, 0);

    info = (struct window_info) {0};
    window_info_set_tree(&info, NULL);
    TEST_CHECK(info.split, SPLIT_NONE);

    con_free(root);
});
