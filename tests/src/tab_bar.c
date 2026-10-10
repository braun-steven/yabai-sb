static struct window_node *tab_bar_test_node(struct window_node *parent, uint32_t *window_list, int window_count)
{
    struct window_node *node = malloc(sizeof(struct window_node));
    memset(node, 0, sizeof(struct window_node));

    node->parent = parent;
    memcpy(node->window_list, window_list, sizeof(uint32_t) * window_count);
    memcpy(node->window_order, window_list, sizeof(uint32_t) * window_count);
    node->window_count = window_count;

    return node;
}

static void tab_bar_test_view_init(struct view *view)
{
    memset(view, 0, sizeof(struct view));
    view->layout = VIEW_BSP;
    view->split_type = SPLIT_Y;
    view->root = tab_bar_test_node(NULL, NULL, 0);
    view->root->area = (struct area) { 0, 0, 1000, 800 };
    g_space_manager.split_ratio = 0.5f;
    g_space_manager.window_placement = CHILD_SECOND;
}

TEST_FUNC(tab_bar_window_area,
{
    struct window_node node;
    memset(&node, 0, sizeof(struct window_node));
    node.area = ((struct area) { 10, 20, 400, 300 });
    node.window_count = 2;

    bool enable_tab_bar = g_window_manager.enable_tab_bar;
    int tab_bar_height = g_window_manager.tab_bar_height;
    g_window_manager.enable_tab_bar = true;
    g_window_manager.tab_bar_height = 24;

    struct area area = tab_bar_window_area(&node, node.area);
    TEST_CHECK((int) area.x, 10);
    TEST_CHECK((int) area.y, 44);
    TEST_CHECK((int) area.w, 400);
    TEST_CHECK((int) area.h, 276);

    // a single window has no tab bar
    node.window_count = 1;
    area = tab_bar_window_area(&node, node.area);
    TEST_CHECK((int) area.y, 20);
    TEST_CHECK((int) area.h, 300);
    node.window_count = 2;

    // neither does a zoomed stack
    node.zoom = &node;
    TEST_CHECK(tab_bar_node_has_bar(&node), false);
    node.zoom = NULL;

    // nor a stack too small to fit the bar
    node.area.h = 40;
    TEST_CHECK(tab_bar_node_has_bar(&node), false);
    node.area.h = 300;

    g_window_manager.enable_tab_bar = false;
    TEST_CHECK(tab_bar_node_has_bar(&node), false);

    g_window_manager.enable_tab_bar = enable_tab_bar;
    g_window_manager.tab_bar_height = tab_bar_height;
});

TEST_FUNC(tab_bar_make_tabbed,
{
    struct view view;
    tab_bar_test_view_init(&view);

    // root splits into a (1) and b, where b splits into c (2, 3) and d (4)
    struct window_node *root = view.root;
    root->left = tab_bar_test_node(root, (uint32_t[]) { 1 }, 1);
    root->right = tab_bar_test_node(root, NULL, 0);
    struct window_node *b = root->right;
    b->left = tab_bar_test_node(b, (uint32_t[]) { 2, 3 }, 2);
    b->right = tab_bar_test_node(b, (uint32_t[]) { 4 }, 1);

    // collapsing from window 4 merges its parent b into one stack
    struct window_node *node = view_make_tabbed(&view, 4);
    TEST_CHECK(node == b, true);
    TEST_CHECK(b->left == NULL, true);
    TEST_CHECK(b->right == NULL, true);
    TEST_CHECK(b->window_count, 3);
    TEST_CHECK(b->window_list[0], 2);
    TEST_CHECK(b->window_list[1], 3);
    TEST_CHECK(b->window_list[2], 4);
    TEST_CHECK(b->window_order[0], 4);
    TEST_CHECK(root->left->window_count, 1);

    // collapsing again from window 1 makes the whole space one stack
    node = view_make_tabbed(&view, 1);
    TEST_CHECK(node == root, true);
    TEST_CHECK(root->left == NULL, true);
    TEST_CHECK(root->window_count, 4);
    TEST_CHECK(root->window_list[0], 1);
    TEST_CHECK(root->window_list[3], 4);
    TEST_CHECK(root->window_order[0], 1);

    // a window that is already the root stays put
    node = view_make_tabbed(&view, 2);
    TEST_CHECK(node == root, true);
    TEST_CHECK(root->window_count, 4);

    window_node_free_subtree(view.root);
});

TEST_FUNC(tab_bar_make_tabbed_max,
{
    struct view view;
    tab_bar_test_view_init(&view);

    uint32_t window_list[NODE_MAX_WINDOW_COUNT];
    for (int i = 0; i < NODE_MAX_WINDOW_COUNT; ++i) window_list[i] = i + 1;

    struct window_node *root = view.root;
    root->left = tab_bar_test_node(root, window_list, NODE_MAX_WINDOW_COUNT - 1);
    root->right = tab_bar_test_node(root, (uint32_t[]) { 100 }, 1);

    // the merged stack would exceed the capacity, so the tree is left untouched
    TEST_CHECK(view_make_tabbed(&view, 100) == NULL, true);
    TEST_CHECK(root->left != NULL, true);
    TEST_CHECK(root->right->window_list[0], 100);

    window_node_free_subtree(view.root);
});

TEST_FUNC(tab_bar_make_split,
{
    struct view view;
    tab_bar_test_view_init(&view);

    struct window_node *root = view.root;
    memcpy(root->window_list, ((uint32_t[]) { 1, 2, 3 }), sizeof(uint32_t) * 3);
    memcpy(root->window_order, ((uint32_t[]) { 2, 1, 3 }), sizeof(uint32_t) * 3);
    root->window_count = 3;

    struct window_node *node = view_make_split(&view, 2);
    TEST_CHECK(node == root, true);
    TEST_CHECK(root->window_count, 0);

    // windows are tiled in tab order, first to last
    int window_count = 0;
    uint32_t window_list[3] = {0};
    for (struct window_node *leaf = window_node_find_first_leaf(root); leaf; leaf = window_node_find_next_leaf(leaf)) {
        TEST_CHECK(leaf->window_count, 1);
        if (window_count < 3) window_list[window_count] = leaf->window_list[0];
        ++window_count;
    }

    TEST_CHECK(window_count, 3);
    TEST_CHECK(window_list[0], 1);
    TEST_CHECK(window_list[1], 2);
    TEST_CHECK(window_list[2], 3);

    // the first window keeps half of the area
    struct window_node *first = window_node_find_first_leaf(root);
    TEST_CHECK((int) first->area.w, 500);

    // and the stack round-trips back into a single stack
    node = view_make_tabbed(&view, 3);
    TEST_CHECK(node != NULL, true);
    node = view_make_tabbed(&view, 3);
    TEST_CHECK(node == root, true);
    TEST_CHECK(root->window_count, 3);
    TEST_CHECK(root->window_list[0], 1);
    TEST_CHECK(root->window_list[2], 3);

    window_node_free_subtree(view.root);
});

TEST_FUNC(tab_bar_unstack,
{
    struct view view;
    tab_bar_test_view_init(&view);

    struct window_node *root = view.root;
    memcpy(root->window_list, ((uint32_t[]) { 1, 2, 3 }), sizeof(uint32_t) * 3);
    memcpy(root->window_order, ((uint32_t[]) { 1, 2, 3 }), sizeof(uint32_t) * 3);
    root->window_count = 3;

    struct window window;
    memset(&window, 0, sizeof(struct window));

    // the first tab leaves westward, to the left of the remaining stack
    window.id = 1;
    struct window_node *node = view_unstack_window_node(&view, &window, DIR_WEST);
    TEST_CHECK(node == root, true);
    TEST_CHECK(root->left->window_count, 1);
    TEST_CHECK(root->left->window_list[0], 1);
    TEST_CHECK(root->right->window_count, 2);
    TEST_CHECK(root->right->window_list[0], 2);
    TEST_CHECK(root->right->window_list[1], 3);
    TEST_CHECK((int) root->left->area.w, 500);
    TEST_CHECK((int) root->right->area.x, 500);

    // the last tab leaves eastward, to the right of the remaining window
    window.id = 3;
    node = view_unstack_window_node(&view, &window, DIR_EAST);
    TEST_CHECK(node == root->right, true);
    TEST_CHECK(node->left->window_count, 1);
    TEST_CHECK(node->left->window_list[0], 2);
    TEST_CHECK(node->right->window_list[0], 3);

    // a window that is not stacked is left alone
    TEST_CHECK(view_unstack_window_node(&view, &window, DIR_EAST) == NULL, true);

    window_node_free_subtree(view.root);
});
