static void auto_padding_view_init(struct view *view)
{
    memset(view, 0, sizeof(struct view));

    view->tree = con_create(CON_SPLITH);
    view->layout = VIEW_TREE;
    view->auto_padding = true;
    view->top_padding = 10;
    view->bottom_padding = 20;
    view->left_padding = 30;
    view->right_padding = 40;
    view->window_gap = 8;
    view_set_flag(view, VIEW_ENABLE_PADDING);
    view_set_flag(view, VIEW_ENABLE_GAP);
}

static struct con *auto_padding_leaf(struct con *parent, uint32_t window_id)
{
    struct con *con = con_create(CON_SPLITH);
    con->window_id = window_id;
    tree_attach(parent, con, -1);
    return con;
}

TEST_FUNC(auto_padding_applies,
{
    TEST_CHECK(view_auto_padding_applies(VIEW_TREE, true, 0), true);
    TEST_CHECK(view_auto_padding_applies(VIEW_TREE, true, 1), true);
    TEST_CHECK(view_auto_padding_applies(VIEW_TREE, true, 2), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_TREE, true, 5), false);

    TEST_CHECK(view_auto_padding_applies(VIEW_TREE, false, 0), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_TREE, false, 1), false);

    TEST_CHECK(view_auto_padding_applies(VIEW_FLOAT, true, 1), false);
    TEST_CHECK(view_auto_padding_applies(VIEW_DEFAULT, true, 1), false);
});

TEST_FUNC(auto_padding_tiled_count,
{
    struct view view;
    auto_padding_view_init(&view);

    TEST_CHECK(view_tiled_count(&view), 0);

    struct con *a = auto_padding_leaf(view.tree, 1);
    TEST_CHECK(view_tiled_count(&view), 1);

    // a tabbed container counts once, however many tabs it holds
    struct con *tabbed = con_create(CON_TABBED);
    tree_attach(view.tree, tabbed, -1);
    struct con *b = auto_padding_leaf(tabbed, 2);
    struct con *c = auto_padding_leaf(tabbed, 3);
    TEST_CHECK(view_tiled_count(&view), 2);

    // a split inside a tab is still part of that one container
    tree_split(c, CON_VERTICAL);
    auto_padding_leaf(c->parent, 4);
    TEST_CHECK(view_tiled_count(&view), 2);

    // a window in zoom-fullscreen does not count
    a->zoom = CON_ZOOM_FULLSCREEN;
    TEST_CHECK(view_tiled_count(&view), 1);

    // zoom-parent still counts
    b->zoom = CON_ZOOM_PARENT;
    TEST_CHECK(view_tiled_count(&view), 1);

    // a tabbed container as the only container: no padding
    TEST_CHECK(view_auto_padding_applies(view.layout, view.auto_padding, view_tiled_count(&view)), true);

    // tabs turned into a split count individually again
    tabbed->layout = CON_SPLITH;
    TEST_CHECK(view_tiled_count(&view), 3);

    con_free(view.tree);
    view.tree = NULL;
    TEST_CHECK(view_tiled_count(&view), 0);
});

TEST_FUNC(auto_padding_root_area,
{
    struct view view;
    auto_padding_view_init(&view);

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

    con_free(view.tree);
});

TEST_FUNC(auto_padding_gap,
{
    struct view view;
    auto_padding_view_init(&view);
    struct con *a = auto_padding_leaf(view.tree, 1);
    struct con *b = auto_padding_leaf(view.tree, 2);

    CGRect frame = CGRectMake(0, 0, 1000, 800);

    TEST_CHECK(view_window_gap(&view), 8);

    view.area = view_root_area(&view, frame);
    tree_view_update(&view);
    TEST_CHECK((int) a->area.x, 30);
    TEST_CHECK((int) a->area.w, 461);
    TEST_CHECK((int) b->area.x, 30 + 461 + 8);
    TEST_CHECK((int) b->area.w, 461);

    // one tiled window next to a zoom-fullscreen one: no padding, the gap stays
    view_set_flag(&view, VIEW_IS_UNPADDED);
    TEST_CHECK(view_window_gap(&view), 8);

    view.area = view_root_area(&view, frame);
    tree_view_update(&view);
    TEST_CHECK((int) a->area.x, 0);
    TEST_CHECK((int) a->area.w, 496);
    TEST_CHECK((int) b->area.x, 496 + 8);
    TEST_CHECK((int) b->area.w, 496);

    // the configured gap used by --grid is unchanged
    TEST_CHECK(view.window_gap, 8);

    view_clear_flag(&view, VIEW_IS_UNPADDED);
    view_clear_flag(&view, VIEW_ENABLE_GAP);
    TEST_CHECK(view_window_gap(&view), 0);

    con_free(view.tree);
});

TEST_FUNC(auto_padding_split_in_tab,
{
    struct view view;
    auto_padding_view_init(&view);
    view.tree->layout = CON_TABBED;

    struct con *split = con_create(CON_SPLITH);
    tree_attach(view.tree, split, -1);
    struct con *a = auto_padding_leaf(split, 1);
    struct con *b = auto_padding_leaf(split, 2);

    // the tabbed container is the only container: no padding, but its split keeps the gap
    bool unpadded = view_auto_padding_applies(view.layout, view.auto_padding, view_tiled_count(&view));
    TEST_CHECK(unpadded, true);
    view_set_flag(&view, VIEW_IS_UNPADDED);

    view.area = view_root_area(&view, CGRectMake(0, 0, 1000, 800));
    tree_view_update(&view);
    TEST_CHECK((int) a->area.x, 0);
    TEST_CHECK((int) a->area.w, 496);
    TEST_CHECK((int) b->area.x, 496 + 8);
    TEST_CHECK((int) b->area.x + (int) b->area.w, 1000);

    con_free(view.tree);
});
