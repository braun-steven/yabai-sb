static bool border_test_rect(CGRect rect, float x, float y, float w, float h)
{
    return rect.origin.x == x && rect.origin.y == y && rect.size.width == w && rect.size.height == h;
}

TEST_FUNC(border_edge_frames_split,
{
    CGRect edge[BORDER_EDGE_COUNT];

    border_edge_frames(CGRectMake(100, 200, 800, 600), 6.0f, 10.0f, edge);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_TOP],      94, 194, 812, 16), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_BOTTOM],   94, 790, 812, 16), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_LEFT],     94, 210,   7, 580), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_RIGHT],   899, 210,   7, 580), true);

    border_edge_frames(CGRectMake(0, 0, 400, 20), 6.0f, 10.0f, edge);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_TOP],      -6, -6, 412, 16), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_BOTTOM],   -6, 10, 412, 16), true);
    TEST_CHECK((int) edge[BORDER_EDGE_LEFT].size.height, 0);
    TEST_CHECK((int) edge[BORDER_EDGE_RIGHT].size.height, 0);

    border_edge_frames(CGRectMake(0, 0, 400, 21), 4.0f, 12.5f, edge);
    TEST_CHECK((int) edge[BORDER_EDGE_TOP].size.height, 14);
    TEST_CHECK((int) edge[BORDER_EDGE_BOTTOM].size.height, 15);
    TEST_CHECK((int) edge[BORDER_EDGE_LEFT].size.height, 0);
});

// NOTE: the tree fixtures of the former tests/src/tree.c (tree_test_leaf, tree_test_split), on the Swift tree
static struct con *tree_test_leaf(struct con *parent, uint32_t window_id)
{
    struct con *con = con_create(CON_SPLITH);
    con->window_id = window_id;
    tree_attach(parent, con, -1);
    return con;
}

static struct con *tree_test_split(struct con *parent, enum con_layout layout)
{
    struct con *con = con_create(layout);
    tree_attach(parent, con, -1);
    return con;
}

static struct area border_test_root_area(void)
{
    return (struct area) { 0, 0, 1010, 810 };
}

static bool border_test_area(struct area area, float x, float y, float w, float h)
{
    return area.x == x && area.y == y && area.w == w && area.h == h;
}

TEST_FUNC(border_tabbed_container_area,
{
    bool enable_tab_bar = g_window_manager.enable_tab_bar;
    int tab_bar_height = g_window_manager.tab_bar_height;
    enum tab_bar_backdrop backdrop = g_window_manager.tab_bar_backdrop;
    g_window_manager.enable_tab_bar = true;
    g_window_manager.tab_bar_height = 24;
    g_window_manager.tab_bar_backdrop = TAB_BAR_BACKDROP_OFF;

    // H[ 1 T[ 2 T[ 4 5 ] 3 ] ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *t = tree_test_split(root, CON_TABBED);
    struct con *b = tree_test_leaf(t, 2);
    struct con *nested = tree_test_split(t, CON_TABBED);
    struct con *d = tree_test_leaf(nested, 4);
    tree_test_leaf(nested, 5);
    tree_test_leaf(t, 3);
    tree_focus(b);
    tree_update(root, border_test_root_area(), 10, 24, 0, 0);

    struct view view;
    memset(&view, 0, sizeof(view));
    view.tree = root;

    struct area window_area;
    struct area border_area;
    int radius = -1;

    // a plain tiled window is wrapped by itself
    TEST_CHECK(tree_window_border_area(&view, 1, &window_area, &border_area, &radius), true);
    TEST_CHECK(border_test_area(border_area, a->area.x, a->area.y, a->area.w, a->area.h), true);
    TEST_CHECK(radius, 0);

    // the active tab wraps the whole container, tab bar included
    TEST_CHECK(tree_window_border_area(&view, 2, &window_area, &border_area, &radius), true);
    TEST_CHECK(border_test_area(border_area, t->area.x, t->area.y, t->area.w, t->area.h), true);
    TEST_CHECK(border_test_area(window_area, b->area.x, b->area.y, b->area.w, b->area.h), true);
    TEST_CHECK((int) (window_area.y - border_area.y), 24);

    // hidden tabs have no border
    TEST_CHECK(tree_window_border_area(&view, 3, &window_area, &border_area, &radius), false);
    TEST_CHECK(tree_window_border_area(&view, 4, &window_area, &border_area, &radius), false);

    // a nested tabbed container wraps both bars
    tree_focus(d);
    tree_update(root, border_test_root_area(), 10, 24, 0, 0);
    TEST_CHECK(tree_window_border_area(&view, 4, &window_area, &border_area, &radius), true);
    TEST_CHECK(border_test_area(border_area, t->area.x, t->area.y, t->area.w, t->area.h), true);
    TEST_CHECK((int) (window_area.y - border_area.y), 48);

    // a window outside the tree gets empty areas
    TEST_CHECK(tree_window_border_area(&view, 99, &window_area, &border_area, &radius), true);
    TEST_CHECK((int) border_area.w, 0);

    con_free(root);
    g_window_manager.enable_tab_bar = enable_tab_bar;
    g_window_manager.tab_bar_height = tab_bar_height;
    g_window_manager.tab_bar_backdrop = backdrop;
});
