static void auto_padding_view_init(struct view *view, struct window_node *root)
{
    memset(view, 0, sizeof(struct view));
    memset(root, 0, sizeof(struct window_node));

    view->root = root;
    view->layout = VIEW_BSP;
    view->auto_padding = true;
    view->top_padding = 10;
    view->bottom_padding = 20;
    view->left_padding = 30;
    view->right_padding = 40;
    view->window_gap = 8;
    view_set_flag(view, VIEW_ENABLE_PADDING);
    view_set_flag(view, VIEW_ENABLE_GAP);
}

static void auto_padding_node_split(struct window_node *node, struct window_node *left, struct window_node *right)
{
    memset(left, 0, sizeof(struct window_node));
    memset(right, 0, sizeof(struct window_node));

    left->parent = node;
    right->parent = node;
    node->left = left;
    node->right = right;
    node->split = SPLIT_Y;
    node->ratio = 0.5f;
}

TEST_FUNC(auto_padding_applies,
{
    TEST_CHECK(view_auto_padding_applies(VIEW_BSP, true, 0), true);
    TEST_CHECK(view_auto_padding_applies(VIEW_BSP, true, 1), true);
    TEST_CHECK(view_auto_padding_applies(VIEW_BSP, true, 2), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_BSP, true, 5), false);

    TEST_CHECK(view_auto_padding_applies(VIEW_BSP, false, 0), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_BSP, false, 1), false);

    TEST_CHECK(view_auto_padding_applies(VIEW_STACK, true, 1), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_FLOAT, true, 1), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_DEFAULT, true, 1), false);
});

TEST_FUNC(auto_padding_tiled_window_count,
{
    struct view view;
    struct window_node root;
    struct window_node a;
    struct window_node b;
    struct window_node c;
    struct window_node d;
    auto_padding_view_init(&view, &root);

    TEST_CHECK(view_tiled_window_count(&view), 0);

    root.window_count = 1;
    TEST_CHECK(view_tiled_window_count(&view), 1);

    // stacked windows in one leaf count individually
    root.window_count = 2;
    TEST_CHECK(view_tiled_window_count(&view), 2);

    root.window_count = 0;
    auto_padding_node_split(&root, &a, &b);
    a.window_count = 1;
    b.window_count = 1;
    TEST_CHECK(view_tiled_window_count(&view), 2);

    // a window in zoom-fullscreen does not count
    a.zoom = &root;
    TEST_CHECK(view_tiled_window_count(&view), 1);

    // ..neither does a stack in zoom-fullscreen
    a.window_count = 3;
    TEST_CHECK(view_tiled_window_count(&view), 1);
    a.window_count = 1;
    a.zoom = NULL;

    // zoom-parent below the root still counts
    auto_padding_node_split(&b, &c, &d);
    b.window_count = 0;
    c.window_count = 1;
    d.window_count = 1;
    c.zoom = &b;
    TEST_CHECK(view_tiled_window_count(&view), 3);

    // zoom-parent where the parent is the root is zoom-fullscreen
    a.zoom = &root;
    TEST_CHECK(view_tiled_window_count(&view), 2);
    c.zoom = &root;
    TEST_CHECK(view_tiled_window_count(&view), 1);
});

TEST_FUNC(auto_padding_root_area,
{
    struct view view;
    struct window_node root;
    auto_padding_view_init(&view, &root);

    CGRect frame = CGRectMake(0, 25, 1000, 775);

    struct area area = view_root_area(&view, frame);
    TEST_CHECK((int) area.x, 30);
    TEST_CHECK((int) area.y, 35);
    TEST_CHECK((int) area.w, 930);
    TEST_CHECK((int) area.h, 745);

    view_set_flag(&view, VIEW_IS_UNPADDED);
    area = view_root_area(&view, frame);
    TEST_CHECK((int) area.x, 0);
    TEST_CHECK((int) area.y, 25);
    TEST_CHECK((int) area.w, 1000);
    TEST_CHECK((int) area.h, 775);

    // padding toggled off stays off regardless of auto_padding
    view_clear_flag(&view, VIEW_IS_UNPADDED);
    view_clear_flag(&view, VIEW_ENABLE_PADDING);
    area = view_root_area(&view, frame);
    TEST_CHECK((int) area.x, 0);
    TEST_CHECK((int) area.y, 25);
    TEST_CHECK((int) area.w, 1000);
    TEST_CHECK((int) area.h, 775);

    // configured padding is never modified
    TEST_CHECK(view.top_padding, 10);
    TEST_CHECK(view.bottom_padding, 20);
    TEST_CHECK(view.left_padding, 30);
    TEST_CHECK(view.right_padding, 40);
});

TEST_FUNC(auto_padding_gap,
{
    struct view view;
    struct window_node root;
    struct window_node a;
    struct window_node b;
    auto_padding_view_init(&view, &root);
    auto_padding_node_split(&root, &a, &b);

    CGRect frame = CGRectMake(0, 0, 1000, 800);

    TEST_CHECK(window_node_get_gap(&view), 8);

    view.root->area = view_root_area(&view, frame);
    window_node_update(&view, view.root);
    TEST_CHECK((int) a.area.x, 30);
    TEST_CHECK((int) a.area.w, 461);
    TEST_CHECK((int) b.area.x, 30 + 461 + 8);
    TEST_CHECK((int) b.area.w, 461);

    // one tiled window next to a zoom-fullscreen one: no padding, no gap
    view_set_flag(&view, VIEW_IS_UNPADDED);
    TEST_CHECK(window_node_get_gap(&view), 0);

    view.root->area = view_root_area(&view, frame);
    window_node_update(&view, view.root);
    TEST_CHECK((int) a.area.x, 0);
    TEST_CHECK((int) a.area.w, 500);
    TEST_CHECK((int) b.area.x, 500);
    TEST_CHECK((int) b.area.w, 500);

    // the configured gap used by --grid is unchanged
    TEST_CHECK(view.window_gap, 8);

    view_clear_flag(&view, VIEW_IS_UNPADDED);
    view_clear_flag(&view, VIEW_ENABLE_GAP);
    TEST_CHECK(window_node_get_gap(&view), 0);
});
