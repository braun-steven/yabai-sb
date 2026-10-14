static struct view tree_view_test_view(struct con *root)
{
    return (struct view) { .layout = VIEW_TREE, .tree = root };
}

TEST_FUNC(tree_view_window_list_order,
{
    struct con *root = con_create(CON_SPLITH);
    struct con *tabs = tree_test_split(root, CON_TABBED);
    for (uint32_t wid = 1; wid <= 10; ++wid) tree_test_leaf(tabs, wid);
    for (uint32_t wid = 11; wid <= 20; ++wid) tree_test_leaf(root, wid);
    struct view view = tree_view_test_view(root);

    // NOTE: more windows than the initial capacity, so the list has to grow
    int count;
    uint32_t *list = tree_view_window_list(&view, &count);
    TEST_CHECK(count, 20);

    bool ordered = true;
    for (int i = 0; i < count; ++i) ordered &= list[i] == (uint32_t)(i + 1);
    TEST_CHECK(ordered, true);

    struct view empty = tree_view_test_view(NULL);
    tree_view_window_list(&empty, &count);
    TEST_CHECK(count, 0);

    con_free(root);
});

static void tree_view_test_set_area(struct con *con, float x, float w, float h)
{
    con->area = (struct area) { .x = x, .y = 0, .w = w, .h = h };
}

TEST_FUNC(tree_view_zoom_frames,
{
    struct con *root = con_create(CON_SPLITH);
    struct con *split = tree_test_split(root, CON_SPLITV);
    struct con *a = tree_test_leaf(split, 1);
    struct con *b = tree_test_leaf(root, 2);
    struct view view = tree_view_test_view(root);

    tree_view_test_set_area(root,  0,   1000, 800);
    tree_view_test_set_area(split, 0,   500,  800);
    tree_view_test_set_area(a,     0,   500,  400);
    tree_view_test_set_area(b,     500, 500,  800);

    TEST_CHECK(tree_has_zoom(root, CON_ZOOM_NONE), false);
    TEST_CHECK((int) tree_con_frame(&view, a).h, 400);

    a->zoom = CON_ZOOM_PARENT;
    TEST_CHECK(tree_has_zoom(root, CON_ZOOM_NONE), true);
    TEST_CHECK(tree_has_zoom(root, CON_ZOOM_FULLSCREEN), false);
    TEST_CHECK((int) tree_con_frame(&view, a).h, 800);
    TEST_CHECK((int) tree_con_frame(&view, a).w, 500);

    a->zoom = CON_ZOOM_FULLSCREEN;
    TEST_CHECK(tree_has_zoom(root, CON_ZOOM_FULLSCREEN), true);
    TEST_CHECK((int) tree_con_frame(&view, a).w, 1000);

    TEST_CHECK(tree_contains_window(root, 2), true);
    TEST_CHECK(tree_contains_window(root, 3), false);
    TEST_CHECK(tree_contains_window(root, 0), false);

    con_free(root);
});
