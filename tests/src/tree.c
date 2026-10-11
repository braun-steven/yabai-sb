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

static uint32_t tree_test_window(struct con *con)
{
    return con && con_is_leaf(con) ? con->window_id : 0;
}

static uint32_t tree_test_child(struct con *con, int index)
{
    return index < con->child_count ? tree_test_window(con->children[index]) : 0;
}

TEST_FUNC(tree_attach_detach,
{
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *b = tree_test_leaf(root, 2);

    TEST_CHECK(root->child_count, 2);
    TEST_CHECK((int)(a->percent * 100 + 0.5f), 50);
    TEST_CHECK((int)(b->percent * 100 + 0.5f), 50);

    // a new child gets the average share and the shares are normalised
    struct con *c = tree_test_leaf(root, 3);
    TEST_CHECK((int)(c->percent * 300 + 0.5f), 100);

    // detaching the last window of a container closes the container, but never the workspace
    struct con *v = tree_test_split(root, CON_SPLITV);
    struct con *d = tree_test_leaf(v, 4);
    TEST_CHECK(root->child_count, 4);
    TEST_CHECK(tree_detach(d) == root, true);
    con_free(d);
    TEST_CHECK(root->child_count, 3);

    TEST_CHECK(tree_detach(a) == root, true);
    TEST_CHECK(tree_detach(b) == root, true);
    TEST_CHECK(tree_detach(c) == root, true);
    TEST_CHECK(root->child_count, 0);

    con_free(a);
    con_free(b);
    con_free(c);
    con_free(root);
});

TEST_FUNC(tree_flatten,
{
    // H[ V[ H[1 2] ] 3 ] flattens to H[1 2 3]
    struct con *root = con_create(CON_SPLITH);
    struct con *v = tree_test_split(root, CON_SPLITV);
    struct con *h = tree_test_split(v, CON_SPLITH);
    tree_test_leaf(h, 1);
    tree_test_leaf(h, 2);
    tree_test_leaf(root, 3);

    tree_flatten(root);
    TEST_CHECK(root->child_count, 3);
    TEST_CHECK(tree_test_child(root, 0), 1);
    TEST_CHECK(tree_test_child(root, 1), 2);
    TEST_CHECK(tree_test_child(root, 2), 3);

    float total = 0.0f;
    for (int i = 0; i < root->child_count; ++i) total += root->children[i]->percent;
    TEST_CHECK((int)(total * 100 + 0.5f), 100);

    // a single split around a window is kept, so that the next window opens inside of it
    struct con *w = tree_test_split(root, CON_SPLITV);
    tree_test_leaf(w, 4);
    tree_flatten(root);
    TEST_CHECK(root->child_count, 4);
    TEST_CHECK(root->children[3] == w, true);

    con_free(root);
});

TEST_FUNC(tree_focus_direction,
{
    // H[ 1 V[ 2 3 ] 4 ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *v = tree_test_split(root, CON_SPLITV);
    struct con *b = tree_test_leaf(v, 2);
    struct con *c = tree_test_leaf(v, 3);
    struct con *d = tree_test_leaf(root, 4);

    struct con *result = NULL;
    tree_focus(c);
    tree_focus(a);

    // entering the vertical split restores the window focused there last
    TEST_CHECK(tree_next(a, DIR_EAST, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 3);

    TEST_CHECK(tree_next(c, DIR_NORTH, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 2);

    TEST_CHECK(tree_next(b, DIR_EAST, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 4);

    // at the edge of the workspace, a display in that direction comes first
    TEST_CHECK(tree_next(d, DIR_EAST, FOCUS_WRAPPING_ON, true, &result), TREE_RESULT_OUTPUT);

    // otherwise focus wraps around, unless wrapping is off
    TEST_CHECK(tree_next(d, DIR_EAST, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 1);
    TEST_CHECK(tree_next(d, DIR_EAST, FOCUS_WRAPPING_OFF, false, &result), TREE_RESULT_NONE);

    // 'up' from the top of the vertical split has nowhere to go and wraps within it
    TEST_CHECK(tree_next(b, DIR_NORTH, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 3);

    // forced wrapping stays inside the innermost container
    TEST_CHECK(tree_next(c, DIR_SOUTH, FOCUS_WRAPPING_FORCE, true, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 2);

    con_free(root);
});

TEST_FUNC(tree_focus_tabbed,
{
    // H[ 1 T[ 2 3 ] ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *t = tree_test_split(root, CON_TABBED);
    struct con *b = tree_test_leaf(t, 2);
    struct con *c = tree_test_leaf(t, 3);

    struct con *result = NULL;
    tree_focus(b);

    // tabs are laid out horizontally, so east/west cycles them
    TEST_CHECK(tree_next(b, DIR_EAST, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 3);
    TEST_CHECK(tree_next(b, DIR_WEST, FOCUS_WRAPPING_ON, false, &result), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_window(result), 1);

    // only the active tab is visible
    TEST_CHECK(tree_con_is_visible(b), true);
    TEST_CHECK(tree_con_is_visible(c), false);
    tree_focus(c);
    TEST_CHECK(tree_con_is_visible(b), false);
    TEST_CHECK(tree_con_is_visible(a), true);

    con_free(root);
});

TEST_FUNC(tree_move_within,
{
    // H[ 1 2 V[ 3 4 ] ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    tree_test_leaf(root, 2);
    struct con *v = tree_test_split(root, CON_SPLITV);
    tree_test_leaf(v, 3);
    struct con *d = tree_test_leaf(v, 4);
    tree_focus(d);

    // a window swaps with a neighbouring window
    TEST_CHECK(tree_move(root, a, DIR_EAST, false), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_child(root, 0), 2);
    TEST_CHECK(tree_test_child(root, 1), 1);

    // and enters a neighbouring container, next to its last focused window
    TEST_CHECK(tree_move(root, a, DIR_EAST, false), TREE_RESULT_DONE);
    TEST_CHECK(root->child_count, 2);
    TEST_CHECK(v->child_count, 3);
    TEST_CHECK(tree_test_child(v, 0), 3);
    TEST_CHECK(tree_test_child(v, 1), 4);
    TEST_CHECK(tree_test_child(v, 2), 1);

    // a vertical move inside the vertical split swaps
    TEST_CHECK(tree_move(root, a, DIR_NORTH, false), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_child(v, 1), 1);

    // leaving the container at its edge places the window next to it in the workspace
    TEST_CHECK(tree_move(root, a, DIR_EAST, false), TREE_RESULT_DONE);
    TEST_CHECK(root->child_count, 3);
    TEST_CHECK(tree_test_child(root, 2), 1);
    TEST_CHECK(v->child_count, 2);

    // at the edge of the workspace a display in that direction is used
    TEST_CHECK(tree_move(root, a, DIR_EAST, true), TREE_RESULT_OUTPUT);
    TEST_CHECK(tree_move(root, a, DIR_EAST, false), TREE_RESULT_NONE);

    con_free(root);
});

TEST_FUNC(tree_move_force_orientation,
{
    // H[ 1 2 ]: moving 2 down re-orients the workspace to V[ H[1] 2 ]
    struct con *root = con_create(CON_SPLITH);
    tree_test_leaf(root, 1);
    struct con *b = tree_test_leaf(root, 2);

    TEST_CHECK(tree_move(root, b, DIR_SOUTH, false), TREE_RESULT_DONE);
    TEST_CHECK(root->layout, CON_SPLITV);
    TEST_CHECK(root->child_count, 2);
    TEST_CHECK(root->children[0]->layout, CON_SPLITH);
    TEST_CHECK(tree_test_child(root->children[0], 0), 1);
    TEST_CHECK(tree_test_child(root, 1), 2);

    // moving it back up enters the horizontal container next to window 1, like i3 does
    TEST_CHECK(tree_move(root, b, DIR_NORTH, false), TREE_RESULT_DONE);
    TEST_CHECK(root->child_count, 1);
    TEST_CHECK(tree_test_child(root->children[0], 0), 1);
    TEST_CHECK(tree_test_child(root->children[0], 1), 2);

    con_free(root);
});

TEST_FUNC(tree_move_tabbed,
{
    // H[ 1 T[ 2 3 ] ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *t = tree_test_split(root, CON_TABBED);
    tree_test_leaf(t, 2);
    struct con *c = tree_test_leaf(t, 3);

    // moving inside the tabs reorders them
    TEST_CHECK(tree_move(root, c, DIR_WEST, false), TREE_RESULT_DONE);
    TEST_CHECK(tree_test_child(t, 0), 3);

    // the first tab leaves the container to the west
    TEST_CHECK(tree_move(root, c, DIR_WEST, false), TREE_RESULT_DONE);
    TEST_CHECK(root->child_count, 3);
    TEST_CHECK(tree_test_child(root, 1), 3);
    TEST_CHECK(t->child_count, 1);

    // and a window moving into the tabbed container becomes a tab
    TEST_CHECK(tree_move(root, c, DIR_EAST, false), TREE_RESULT_DONE);
    TEST_CHECK(t->child_count, 2);
    TEST_CHECK(tree_test_child(t, 0), 3);
    TEST_CHECK(tree_move(root, a, DIR_EAST, false), TREE_RESULT_DONE);
    TEST_CHECK(t->child_count, 3);
    TEST_CHECK(root->child_count, 1);

    con_free(root);
});

TEST_FUNC(tree_split_layout,
{
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *b = tree_test_leaf(root, 2);

    // splitting wraps the window, so the next window opens below it
    tree_split(b, CON_VERTICAL);
    struct con *v = b->parent;
    TEST_CHECK(v != root, true);
    TEST_CHECK(v->layout, CON_SPLITV);
    TEST_CHECK(v->child_count, 1);
    TEST_CHECK(root->children[1] == v, true);

    // splitting the only child again just changes the orientation
    tree_split(b, CON_HORIZONTAL);
    TEST_CHECK(b->parent == v, true);
    TEST_CHECK(v->layout, CON_SPLITH);

    // tabbed on a workspace window wraps the workspace in a tabbed container
    tree_set_layout(a, CON_TABBED);
    TEST_CHECK(root->child_count, 1);
    struct con *t = a->parent;
    TEST_CHECK(t->layout, CON_TABBED);
    TEST_CHECK(t->parent == root, true);

    // toggle returns to the last split layout, toggle split flips the orientation
    TEST_CHECK(tree_toggle_layout(a, false), CON_SPLITH);
    TEST_CHECK(t->layout, CON_SPLITH);
    TEST_CHECK(tree_toggle_layout(a, true), CON_SPLITV);
    TEST_CHECK(tree_toggle_layout(a, false), CON_TABBED);
    TEST_CHECK(tree_toggle_layout(a, false), CON_SPLITV);

    con_free(root);
});

TEST_FUNC(tree_insert_relative,
{
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *b = tree_test_leaf(root, 2);

    // east of a window in a horizontal split is a plain sibling
    struct con *c = con_create(CON_SPLITH);
    c->window_id = 3;
    tree_insert_relative(a, c, DIR_EAST);
    TEST_CHECK(tree_test_child(root, 1), 3);

    // south of it splits the window
    struct con *d = con_create(CON_SPLITH);
    d->window_id = 4;
    tree_insert_relative(b, d, DIR_SOUTH);
    TEST_CHECK(b->parent->layout, CON_SPLITV);
    TEST_CHECK(tree_test_child(b->parent, 1), 4);

    // stacking creates a tabbed container around the target
    struct con *e = con_create(CON_SPLITH);
    e->window_id = 5;
    tree_insert_relative(a, e, STACK);
    TEST_CHECK(a->parent->layout, CON_TABBED);
    TEST_CHECK(tree_test_child(a->parent, 1), 5);
    TEST_CHECK(root->children[0] == a->parent, true);

    con_free(root);
});

TEST_FUNC(tree_resize_update,
{
    // H[ 1 V[ 2 3 ] ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *v = tree_test_split(root, CON_SPLITV);
    struct con *b = tree_test_leaf(v, 2);
    struct con *c = tree_test_leaf(v, 3);

    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, 0, 0);
    TEST_CHECK((int) a->area.w, 500);
    TEST_CHECK((int) v->area.x, 510);
    TEST_CHECK((int) b->area.h, 400);
    TEST_CHECK((int) c->area.y, 410);

    // growing the right edge of window 2 searches up to the horizontal split
    TEST_CHECK(tree_resize(b, DIR_WEST, -100), true);
    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, 0, 0);
    TEST_CHECK((int) a->area.w, 401);
    TEST_CHECK(tree_resize(a, DIR_WEST, 10), false);

    // the children of a tabbed container share its area below the bar
    tree_set_layout(b, CON_TABBED);
    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, 0, 0);
    TEST_CHECK((int) b->area.y, 24);
    TEST_CHECK((int) c->area.y, 24);
    TEST_CHECK((int) c->area.h, 786);

    // the bar offset moves them further down, or up under the bar when negative
    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, 6, 0);
    TEST_CHECK((int) c->area.y, 30);
    TEST_CHECK((int) c->area.h, 780);
    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, -30, 0);
    TEST_CHECK((int) c->area.y, 0);
    TEST_CHECK((int) c->area.h, 810);

    // a backdrop card insets the windows from every edge of the container, below the bar
    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, 4, 6);
    TEST_CHECK((int) c->area.x, (int) b->area.x);
    TEST_CHECK((int) c->area.x, (int) v->area.x + 6);
    TEST_CHECK((int) c->area.w, (int) v->area.w - 12);
    TEST_CHECK((int) c->area.y, 6 + 24 + 4);
    TEST_CHECK((int) c->area.h, 810 - 12 - 24 - 4);
    tree_update(root, ((struct area) { 0, 0, 1010, 810 }), 10, 24, 0, 0);

    // and resizing a tab skips the tabbed container
    TEST_CHECK(tree_resize(c, DIR_SOUTH, 10), false);

    tree_balance(root);
    TEST_CHECK((int)(a->percent * 100 + 0.5f), 50);

    con_free(root);
});

TEST_FUNC(tree_rotate_mirror_swap,
{
    // H[ 1 V[ 2 3 ] ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *v = tree_test_split(root, CON_SPLITV);
    struct con *b = tree_test_leaf(v, 2);
    tree_test_leaf(v, 3);

    tree_rotate(root, 90);
    TEST_CHECK(root->layout, CON_SPLITV);
    TEST_CHECK(v->layout, CON_SPLITH);
    TEST_CHECK(root->children[1] == a, true);

    tree_mirror(root, CON_HORIZONTAL);
    TEST_CHECK(tree_test_child(v, 0), 3);

    tree_swap(a, b);
    TEST_CHECK(root->children[1] == b, true);
    TEST_CHECK(a->parent == v, true);

    con_free(root);
});

TEST_FUNC(tree_focus_candidate,
{
    // H[ 1 T[ 2 3 ] ]: closing the active tab focuses the tab focused before it
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *t = tree_test_split(root, CON_TABBED);
    struct con *b = tree_test_leaf(t, 2);
    struct con *c = tree_test_leaf(t, 3);

    tree_focus(b);
    tree_focus(c);
    tree_focus(a);
    tree_focus(c);
    TEST_CHECK(tree_test_window(tree_focus_candidate(c)), 2);

    // the last window of a container hands focus to the previously focused sibling of the container
    tree_detach(b);
    con_free(b);
    TEST_CHECK(tree_test_window(tree_focus_candidate(c)), 1);

    con_free(root);
});

TEST_FUNC(tree_flatten_same_orientation,
{
    // H[ H[ 1 2 ] ] flattens to H[ 1 2 ], keeping the shares
    struct con *root = con_create(CON_SPLITH);
    struct con *h = tree_test_split(root, CON_SPLITH);
    struct con *a = tree_test_leaf(h, 1);
    tree_test_leaf(h, 2);
    a->percent = 0.7f;
    h->children[1]->percent = 0.3f;
    tree_focus(a);

    tree_flatten(root);
    TEST_CHECK(root->child_count, 2);
    TEST_CHECK(tree_test_child(root, 0), 1);
    TEST_CHECK((int)(a->percent * 10 + 0.5f), 7);
    TEST_CHECK(root->focus[0] == a, true);

    con_free(root);
});

static void tree_test_area(struct con *con, float w, float h)
{
    con->area.w = w;
    con->area.h = h;
}

TEST_FUNC(tree_autotiling,
{
    // a wide window in a vertical split is split side by side
    struct con *root = con_create(CON_SPLITV);
    struct con *a = tree_test_leaf(root, 1);
    tree_test_leaf(root, 2);
    tree_test_area(a, 800, 400);

    tree_autotile(a);
    TEST_CHECK(a->parent != root, true);
    TEST_CHECK(a->parent->layout, CON_SPLITH);
    TEST_CHECK(a->parent->parent == root, true);

    // a tall window in a vertical split stays, the new window goes below it
    struct con *b = root->children[1];
    tree_test_area(b, 400, 800);
    tree_autotile(b);
    TEST_CHECK(b->parent == root, true);
    con_free(root);

    // a tall window in a horizontal split is split on top of each other
    root = con_create(CON_SPLITH);
    a = tree_test_leaf(root, 1);
    tree_test_leaf(root, 2);
    tree_test_area(a, 500, 1000);

    tree_autotile(a);
    TEST_CHECK(a->parent != root, true);
    TEST_CHECK(a->parent->layout, CON_SPLITV);
    con_free(root);

    // a tab is never split
    root = con_create(CON_SPLITH);
    struct con *tabbed = tree_test_split(root, CON_TABBED);
    a = tree_test_leaf(tabbed, 1);
    tree_test_leaf(tabbed, 2);
    tree_test_area(a, 500, 1000);

    tree_autotile(a);
    TEST_CHECK(a->parent == tabbed, true);
    TEST_CHECK(tabbed->layout, CON_TABBED);
    con_free(root);
});

TEST_FUNC(tree_set_layout_single_tab,
{
    // H[ 1 T[ V[ 2 ] ] ]: splitting a single tab nests a split inside the tabbed container
    struct con *root = con_create(CON_SPLITH);
    tree_test_leaf(root, 1);
    struct con *t = tree_test_split(root, CON_TABBED);
    struct con *a = tree_test_leaf(t, 2);
    tree_split(a, CON_VERTICAL);
    TEST_CHECK(a->parent->parent == t, true);
    TEST_CHECK(a->parent->layout, CON_SPLITV);

    // switching it to tabbed closes the redundant split instead of nesting a tabbed container, like i3
    tree_set_layout(a, CON_TABBED);
    TEST_CHECK(a->parent == t, true);
    TEST_CHECK(t->layout, CON_TABBED);
    TEST_CHECK(root->children[1] == t, true);

    // and toggling back and forth keeps a single container
    tree_toggle_layout(a, false);
    TEST_CHECK(t->layout, CON_SPLITV);
    tree_toggle_layout(a, false);
    TEST_CHECK(t->layout, CON_TABBED);
    TEST_CHECK(a->parent == t, true);
    TEST_CHECK(t->parent == root, true);

    con_free(root);
});

TEST_FUNC(tree_workspace_layout_tabbed,
{
    bool workspace_tabbed = g_space_manager.tree_workspace_tabbed;
    g_space_manager.tree_workspace_tabbed = true;

    // the first window of an empty workspace opens in a tabbed container
    struct con *root = con_create(CON_SPLITH);
    struct con *a = con_create(CON_SPLITH);
    a->window_id = 1;
    tree_open_con(root, a, NULL, false);
    TEST_CHECK(root->child_count, 1);
    TEST_CHECK(root->children[0]->layout, CON_TABBED);
    struct con *t = a->parent;

    struct con *b = con_create(CON_SPLITH);
    b->window_id = 2;
    tree_open_con(root, b, a, false);
    TEST_CHECK(b->parent == t, true);
    tree_focus(b);

    // a tab that moves out to the workspace gets its own tabbed container, like i3 workspace_layout
    TEST_CHECK(tree_move(root, a, DIR_WEST, false), TREE_RESULT_DONE);
    TEST_CHECK(root->child_count, 2);
    TEST_CHECK(root->children[0]->layout, CON_TABBED);
    TEST_CHECK(tree_test_child(root->children[0], 0), 1);
    TEST_CHECK(root->children[1] == t, true);

    con_free(root);
    g_space_manager.tree_workspace_tabbed = workspace_tabbed;
});

TEST_FUNC(tree_insert_focus_order,
{
    // H[ V[ 1 2 ] T[ 3 4 ] 5 ], with 5 focused and tab 3 active
    struct con *root = con_create(CON_SPLITH);
    struct con *v = tree_test_split(root, CON_SPLITV);
    struct con *a = tree_test_leaf(v, 1);
    struct con *b = tree_test_leaf(v, 2);
    struct con *t = tree_test_split(root, CON_TABBED);
    struct con *c = tree_test_leaf(t, 3);
    struct con *d = tree_test_leaf(t, 4);
    struct con *e = tree_test_leaf(root, 5);
    tree_focus(c);
    tree_focus(e);

    // a window that was focused less recently than the tabs does not become the active tab
    tree_insert_con(b, c, TREE_AFTER);
    TEST_CHECK(t->children[1] == b, true);
    TEST_CHECK(t->focus[0] == c, true);

    // the focused window takes the focus with it
    tree_focus(a);
    tree_insert_con(a, d, TREE_AFTER);
    TEST_CHECK(t->focus[0] == a, true);
    TEST_CHECK(root->focus[0] == t, true);
    TEST_CHECK(root->child_count, 2);
    TEST_CHECK(tree_descend_focused(root) == a, true);

    con_free(root);
});

TEST_FUNC(tree_open_con_selected,
{
    // H[ 1 V[ 2 3 ] 4 ]
    struct con *root = con_create(CON_SPLITH);
    struct con *a = tree_test_leaf(root, 1);
    struct con *v = tree_test_split(root, CON_SPLITV);
    tree_test_leaf(v, 2);
    tree_test_leaf(v, 3);
    tree_test_leaf(root, 4);

    // a window opens after the selected container, not inside of it, like i3 and sway
    struct con *e = con_create(CON_SPLITH);
    e->window_id = 5;
    tree_open_con(root, e, v, false);
    TEST_CHECK(v->child_count, 2);
    TEST_CHECK(root->children[2] == e, true);

    // with the workspace selected it opens after its most recently focused child
    tree_focus(a);
    struct con *f = con_create(CON_SPLITH);
    f->window_id = 6;
    tree_open_con(root, f, root, false);
    TEST_CHECK(root->children[1] == f, true);

    con_free(root);
});

TEST_FUNC(tree_attach_from_direction,
{
    // H[ 1 2 ] receives T[ 3 4 ] from another display
    struct con *root = con_create(CON_SPLITH);
    struct con *x = tree_test_leaf(root, 1);
    tree_test_leaf(root, 2);
    struct con *t = con_create(CON_TABBED);
    tree_test_leaf(t, 3);
    tree_test_leaf(t, 4);

    // along the layout of the workspace it arrives on the near side, with its structure
    tree_attach_from_direction(root, t, DIR_EAST);
    TEST_CHECK(root->children[0] == t, true);
    TEST_CHECK(t->child_count, 2);
    TEST_CHECK(root->focus[0] == t, true);

    tree_detach(t);
    tree_attach_from_direction(root, t, DIR_WEST);
    TEST_CHECK(root->children[2] == t, true);

    // across it, it arrives next to the window focused there
    tree_detach(t);
    tree_focus(x);
    tree_attach_from_direction(root, t, DIR_SOUTH);
    TEST_CHECK(root->child_count, 3);
    TEST_CHECK(root->children[1] == t, true);

    // an empty workspace takes it as it is
    struct con *empty = con_create(CON_SPLITH);
    tree_detach(t);
    tree_attach_from_direction(empty, t, DIR_NORTH);
    TEST_CHECK(empty->children[0] == t, true);
    TEST_CHECK((int)(t->percent * 100 + 0.5f), 100);

    con_free(empty);
    con_free(root);
});

static uint32_t tree_test_order_wid(struct sa_window_order *list, int index)
{
    return index < ts_buf_len(list) ? list[index].a_wid : 0;
}

static bool tree_test_order_is(struct sa_window_order *list, int index, uint32_t a_wid, int order, uint32_t b_wid)
{
    if (index >= ts_buf_len(list)) return false;
    return list[index].a_wid == a_wid && list[index].order == order && list[index].b_wid == b_wid;
}

TEST_FUNC(tree_window_order_collect,
{
    // H[ 1 T[ 2 V[ 3 4 ] T[ 5 6 ] ] ] with 3 focused and 5 the active tab of the hidden tabbed container
    struct con *root = con_create(CON_SPLITH);
    tree_test_leaf(root, 1);
    struct con *t = tree_test_split(root, CON_TABBED);
    tree_test_leaf(t, 2);
    struct con *v = tree_test_split(t, CON_SPLITV);
    struct con *c3 = tree_test_leaf(v, 3);
    tree_test_leaf(v, 4);
    struct con *t2 = tree_test_split(t, CON_TABBED);
    struct con *c5 = tree_test_leaf(t2, 5);
    struct con *c6 = tree_test_leaf(t2, 6);
    tree_focus(c6);
    tree_focus(c5);
    tree_focus(c3);

    // ordering below collects every window, hidden tabs included
    struct sa_window_order *list = NULL;
    tree_collect_window_order(t, -1, 99, &list);
    TEST_CHECK(ts_buf_len(list), 5);
    TEST_CHECK(tree_test_order_is(list, 0, 2, -1, 99), true);
    TEST_CHECK(tree_test_order_wid(list, 1), 3);
    TEST_CHECK(tree_test_order_wid(list, 2), 4);
    TEST_CHECK(tree_test_order_wid(list, 3), 5);
    TEST_CHECK(tree_test_order_is(list, 4, 6, -1, 99), true);

    // ordering above skips hidden tabs and the relative window itself
    list = NULL;
    tree_collect_window_order(root, 1, 3, &list);
    TEST_CHECK(ts_buf_len(list), 2);
    TEST_CHECK(tree_test_order_is(list, 0, 1, 1, 3), true);
    TEST_CHECK(tree_test_order_is(list, 1, 4, 1, 3), true);

    list = NULL;
    tree_collect_window_order(v, -1, 4, &list);
    TEST_CHECK(ts_buf_len(list), 1);
    TEST_CHECK(tree_test_order_wid(list, 0), 3);

    // a tab change orders the other tabs below the focused window, then the rest of the active tab above it
    list = NULL;
    tree_collect_tab_order(root, false, &list);
    TEST_CHECK(ts_buf_len(list), 4);
    TEST_CHECK(tree_test_order_is(list, 0, 2, -1, 3), true);
    TEST_CHECK(tree_test_order_is(list, 1, 5, -1, 3), true);
    TEST_CHECK(tree_test_order_is(list, 2, 6, -1, 3), true);
    TEST_CHECK(tree_test_order_is(list, 3, 4, 1, 3), true);

    // nothing to do until the active tab changes, unless forced
    list = NULL;
    tree_collect_tab_order(root, false, &list);
    TEST_CHECK(ts_buf_len(list), 0);
    tree_collect_tab_order(root, true, &list);
    TEST_CHECK(ts_buf_len(list), 4);

    // switching to the tab that holds 2 orders every other window of the container below it
    list = NULL;
    tree_focus(t->children[0]);
    tree_collect_tab_order(root, false, &list);
    TEST_CHECK(ts_buf_len(list), 4);
    TEST_CHECK(tree_test_order_is(list, 0, 3, -1, 2), true);
    TEST_CHECK(tree_test_order_is(list, 3, 6, -1, 2), true);

    con_free(root);
});
