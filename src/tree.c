extern struct space_manager g_space_manager;

//
// NOTE: The container model and the i3 algorithms that work on it. Nothing here talks to the
// window server, so that it can be tested on its own. tree_view.c applies a tree to the screen.
//
// The structure is only changed through a few primitives, like sway does it: con_insert and
// con_unlink add and remove a child, con_replace puts a container in the place of another,
// con_wrap and con_wrap_children nest containers, con_reparent_children moves all children
// and tree_reap_empty closes the containers that are left without children.
//

#define TREE_MIN_PERCENT 0.05f

struct con *con_create(enum con_layout layout)
{
    struct con *con = malloc(sizeof(struct con));
    memset(con, 0, sizeof(struct con));
    con->layout = layout;
    con->last_split = layout == CON_TABBED ? CON_SPLITH : layout;
    return con;
}

static void tree_feedback_destroy(struct con *con);

void con_free(struct con *con)
{
    for (int i = 0; i < con->child_count; ++i) {
        con_free(con->children[i]);
    }

    tree_feedback_destroy(con);
    tab_bar_release(&con->render.tab_bar);
    free(con->children);
    free(con->focus);
    free(con);
}

bool con_is_leaf(struct con *con)
{
    return con->window_id != 0;
}

enum con_orientation con_orientation(struct con *con)
{
    return con->layout == CON_SPLITV ? CON_VERTICAL : CON_HORIZONTAL;
}

static inline enum con_orientation direction_orientation(int direction)
{
    return direction == DIR_NORTH || direction == DIR_SOUTH ? CON_VERTICAL : CON_HORIZONTAL;
}

static inline bool direction_is_backward(int direction)
{
    return direction == DIR_NORTH || direction == DIR_WEST;
}

static inline enum con_layout orientation_layout(enum con_orientation orientation)
{
    return orientation == CON_VERTICAL ? CON_SPLITV : CON_SPLITH;
}

static inline bool con_is_split(struct con *con)
{
    return !con_is_leaf(con) && (con->layout == CON_SPLITH || con->layout == CON_SPLITV);
}

int con_index(struct con *con)
{
    struct con *parent = con->parent;
    if (!parent) return -1;

    for (int i = 0; i < parent->child_count; ++i) {
        if (parent->children[i] == con) return i;
    }

    return -1;
}

static int con_focus_index(struct con *con)
{
    struct con *parent = con->parent;
    if (!parent) return -1;

    for (int i = 0; i < parent->child_count; ++i) {
        if (parent->focus[i] == con) return i;
    }

    return -1;
}

static void con_reserve(struct con *con, int count)
{
    if (count <= con->child_capacity) return;

    int capacity = con->child_capacity ? con->child_capacity * 2 : 4;
    while (capacity < count) capacity *= 2;

    con->children = realloc(con->children, sizeof(struct con *) * capacity);
    con->focus = realloc(con->focus, sizeof(struct con *) * capacity);
    con->child_capacity = capacity;
}

//
// NOTE: i3 con_fix_percent. Children without a share get the average share of the others,
// then the shares are normalised so that they add up to 1.
//

void tree_fix_percent(struct con *con)
{
    if (!con->child_count) return;

    float total = 0.0f;
    int children_with_percent = 0;

    for (int i = 0; i < con->child_count; ++i) {
        if (con->children[i]->percent > 0.0f) {
            total += con->children[i]->percent;
            ++children_with_percent;
        }
    }

    if (children_with_percent != con->child_count) {
        for (int i = 0; i < con->child_count; ++i) {
            struct con *child = con->children[i];
            if (child->percent > 0.0f) continue;

            child->percent = children_with_percent == 0 ? 1.0f : total / children_with_percent;
            total += child->percent;
        }
    }

    for (int i = 0; i < con->child_count; ++i) {
        con->children[i]->percent = total > 0.0f ? con->children[i]->percent / total : 1.0f / con->child_count;
    }
}

//
// NOTE: Inserts the container among the children of the parent at the index, and at the focus index
// in their focus order (0 is the most recently focused child). Either goes to the end when it is
// out of range. The share of space is left alone.
//

#define CON_FOCUS_HEAD 0
#define CON_FOCUS_TAIL -1

static void con_insert(struct con *parent, struct con *con, int index, int focus_index)
{
    con_reserve(parent, parent->child_count + 1);

    if (index < 0 || index > parent->child_count) index = parent->child_count;
    memmove(parent->children + index + 1, parent->children + index, sizeof(struct con *) * (parent->child_count - index));
    parent->children[index] = con;

    if (focus_index < 0 || focus_index > parent->child_count) focus_index = parent->child_count;
    memmove(parent->focus + focus_index + 1, parent->focus + focus_index, sizeof(struct con *) * (parent->child_count - focus_index));
    parent->focus[focus_index] = con;

    ++parent->child_count;
    con->parent = parent;

    //
    // NOTE: The new windows have to be ordered with the tabs of every tabbed container
    // around them, also when the active tab of that container stays the same.
    //

    for (struct con *ancestor = parent; ancestor; ancestor = ancestor->parent) {
        if (ancestor->layout == CON_TABBED) ancestor->render.raised = NULL;
    }
}

static void con_unlink(struct con *con)
{
    struct con *parent = con->parent;
    if (!parent) return;

    int index = con_index(con);
    int focus_index = con_focus_index(con);

    memmove(parent->children + index, parent->children + index + 1, sizeof(struct con *) * (parent->child_count - index - 1));
    memmove(parent->focus + focus_index, parent->focus + focus_index + 1, sizeof(struct con *) * (parent->child_count - focus_index - 1));

    --parent->child_count;
    if (parent->render.raised == con) parent->render.raised = NULL;
    con->parent = NULL;
}

//
// NOTE: The replacement takes the place of the container among the children of its parent and in
// their focus order, and gets its share of the space. Like sway container_replace.
//

static void con_replace(struct con *con, struct con *replacement)
{
    struct con *parent = con->parent;

    parent->children[con_index(con)] = replacement;
    parent->focus[con_focus_index(con)] = replacement;
    if (parent->render.raised == con) parent->render.raised = NULL;

    replacement->parent = parent;
    replacement->percent = con->percent;
    con->parent = NULL;
}

//
// NOTE: Puts a new container with the layout in the place of the container, which becomes its only
// child. Like steps 2 to 4 of i3 tree_split and sway container_split.
//

static struct con *con_wrap(struct con *con, enum con_layout layout)
{
    struct con *wrap = con_create(layout);
    con_replace(con, wrap);
    con_insert(wrap, con, 0, CON_FOCUS_HEAD);
    con->percent = 1.0f;
    return wrap;
}

//
// NOTE: Moves every child of the container into another one, starting at the index. The children keep
// their order and their shares, and take the place at the focus index in the focus order of the
// other container, in the order they had among themselves.
//

static void con_reparent_children(struct con *from, struct con *to, int index, int focus_index)
{
    int count = from->child_count;
    if (!count) return;

    if (index < 0 || index > to->child_count) index = to->child_count;
    if (focus_index < 0 || focus_index > to->child_count) focus_index = to->child_count;

    struct con **focus = malloc(sizeof(struct con *) * count);
    memcpy(focus, from->focus, sizeof(struct con *) * count);

    for (int i = 0; i < count; ++i) {
        struct con *child = from->children[0];
        con_unlink(child);
        con_insert(to, child, index + i, CON_FOCUS_TAIL);
    }

    memmove(to->focus + focus_index + count, to->focus + focus_index, sizeof(struct con *) * (to->child_count - count - focus_index));
    memcpy(to->focus + focus_index, focus, sizeof(struct con *) * count);
    free(focus);
}

//
// NOTE: i3 workspace_encapsulate and sway workspace_wrap_children. Moves every child of the container
// into a new container with the same layout, which becomes its only child.
//

static struct con *con_wrap_children(struct con *con)
{
    struct con *wrap = con_create(con->layout);
    wrap->last_split = con->last_split;
    con_reparent_children(con, wrap, 0, 0);
    con_insert(con, wrap, 0, CON_FOCUS_HEAD);
    wrap->percent = 1.0f;
    return wrap;
}

//
// NOTE: Closes the container when it is left without children, and then every ancestor that is left
// empty, like i3 con_on_remove_child and sway container_reap_empty. The workspace itself stays.
// Returns the closest container that is still part of the tree, with the shares of its children fixed.
//

static struct con *tree_reap_empty(struct con *con)
{
    while (con->parent && !con_is_leaf(con) && con->child_count == 0) {
        struct con *empty = con;
        con = con->parent;
        con_unlink(empty);
        con_free(empty);
    }

    tree_fix_percent(con);
    return con;
}

//
// NOTE: i3 workspace_attach_to. With tree_workspace_layout tabbed, a container that is attached to
// the workspace itself is put into a new tabbed container, so that the windows opened next to it
// become tabs. A tabbed container is not nested into another one.
//

static void con_apply_workspace_layout(struct con *con)
{
    if (!g_space_manager.tree_workspace_tabbed) return;

    struct con *root = con->parent;
    if (!root || root->parent) return;
    if (!con_is_leaf(con) && con->layout == CON_TABBED) return;

    con_wrap(con, CON_TABBED)->last_split = root->layout;
}

void tree_attach(struct con *parent, struct con *con, int index)
{
    con->percent = 0.0f;
    con_insert(parent, con, index, CON_FOCUS_TAIL);
    tree_fix_percent(parent);
}

//
// NOTE: Takes the container out of the tree and closes the containers that are left empty.
// Returns the closest ancestor that is still part of the tree.
//

struct con *tree_detach(struct con *con)
{
    struct con *parent = con->parent;
    if (!parent) return NULL;

    con_unlink(con);
    return tree_reap_empty(parent);
}

//
// NOTE: i3 tree_flatten. A split container with a single split child of the other orientation,
// whose own parent has the child's orientation, is pointless nesting: the grandchildren are
// moved into the parent in place of the container.
//

void tree_flatten(struct con *con)
{
    for (int i = 0; i < con->child_count; ++i) {
        tree_flatten(con->children[i]);
    }

    struct con *parent = con->parent;
    if (!parent || parent->layout == CON_TABBED) return;
    if (!con_is_split(con) || con->child_count == 0) return;

    //
    // NOTE: A split that is the only child of a split with the same orientation does not change
    // the layout either, so its children take its place.
    //

    if (parent->child_count == 1 && con_orientation(con) == con_orientation(parent)) {
        con_unlink(con);
        con_reparent_children(con, parent, 0, 0);
        con_free(con);
        return;
    }

    if (con->child_count != 1) return;

    struct con *child = con->children[0];
    if (!con_is_split(child)) return;
    if (con_orientation(con) == con_orientation(child)) return;
    if (con_orientation(child) != con_orientation(parent)) return;

    for (int i = 0; i < child->child_count; ++i) {
        child->children[i]->percent *= con->percent;
    }

    int index = con_index(con);
    int focus_index = con_focus_index(con);

    con_unlink(con);
    con_reparent_children(child, parent, index, focus_index);
    con_free(con);
    tree_fix_percent(parent);
}

struct con *tree_find_window(struct con *root, uint32_t window_id)
{
    if (!root || !window_id) return NULL;
    if (root->window_id == window_id) return root;

    for (int i = 0; i < root->child_count; ++i) {
        struct con *con = tree_find_window(root->children[i], window_id);
        if (con) return con;
    }

    return NULL;
}

struct con *tree_find_selected(struct con *root)
{
    if (!root) return NULL;
    if (root->selected) return root;

    for (int i = 0; i < root->child_count; ++i) {
        struct con *con = tree_find_selected(root->children[i]);
        if (con) return con;
    }

    return NULL;
}

void tree_select(struct con *root, struct con *con)
{
    struct con *selected = tree_find_selected(root);
    if (selected) {
        selected->selected = false;
        tree_feedback_destroy(selected);
    }

    if (con) con->selected = true;
}

//
// NOTE: The window that i3 focuses when this container goes away: the most recently focused
// sibling, or the closest ancestor's next most recently focused child.
//

struct con *tree_focus_candidate(struct con *con)
{
    for (; con->parent; con = con->parent) {
        struct con *parent = con->parent;
        for (int i = 0; i < parent->child_count; ++i) {
            if (parent->focus[i] != con) return tree_descend_focused(parent->focus[i]);
        }
    }

    return NULL;
}

int tree_window_count(struct con *con)
{
    if (con_is_leaf(con)) return 1;

    int count = 0;
    for (int i = 0; i < con->child_count; ++i) {
        count += tree_window_count(con->children[i]);
    }

    return count;
}

struct con *tree_first_leaf(struct con *con)
{
    while (con && !con_is_leaf(con)) {
        con = con->child_count ? con->children[0] : NULL;
    }

    return con;
}

struct con *tree_last_leaf(struct con *con)
{
    while (con && !con_is_leaf(con)) {
        con = con->child_count ? con->children[con->child_count - 1] : NULL;
    }

    return con;
}

struct con *tree_next_leaf(struct con *con)
{
    while (con->parent) {
        int index = con_index(con);
        if (index + 1 < con->parent->child_count) {
            return tree_first_leaf(con->parent->children[index + 1]);
        }

        con = con->parent;
    }

    return NULL;
}

struct con *tree_prev_leaf(struct con *con)
{
    while (con->parent) {
        int index = con_index(con);
        if (index > 0) {
            return tree_last_leaf(con->parent->children[index - 1]);
        }

        con = con->parent;
    }

    return NULL;
}

struct con *tree_tabbed_ancestor(struct con *con)
{
    for (struct con *parent = con->parent; parent; parent = parent->parent) {
        if (parent->layout == CON_TABBED) return parent;
    }

    return NULL;
}

//
// NOTE: A container is visible unless it sits in a tab that is not the active one.
//

bool tree_con_is_visible(struct con *con)
{
    for (; con->parent; con = con->parent) {
        if (con->parent->layout == CON_TABBED && con->parent->focus[0] != con) return false;
    }

    return true;
}

void tree_focus(struct con *con)
{
    for (; con->parent; con = con->parent) {
        struct con *parent = con->parent;
        int focus_index = con_focus_index(con);

        memmove(parent->focus + 1, parent->focus, sizeof(struct con *) * focus_index);
        parent->focus[0] = con;
    }
}

struct con *tree_descend_focused(struct con *con)
{
    while (con && !con_is_leaf(con) && con->child_count) {
        con = con->focus[0];
    }

    return con;
}

//
// NOTE: i3 con_descend_direction. Enters a container from the given direction: along its own
// orientation it takes the child on the near side, otherwise the most recently focused one.
//

struct con *tree_descend_direction(struct con *con, int direction)
{
    while (!con_is_leaf(con) && con->child_count) {
        if (con_orientation(con) == direction_orientation(direction)) {
            con = direction == DIR_EAST || direction == DIR_SOUTH ? con->children[0] : con->children[con->child_count - 1];
        } else {
            con = con->focus[0];
        }
    }

    return con;
}

//
// NOTE: i3 get_tree_next, for 'focus left/right/up/down'. Walks up to the closest ancestor that is
// laid out in the direction (tabbed counts as horizontal) and has a neighbouring child there, and
// focuses that child, descending along its focus history. At the edge of the workspace the result
// says to try the display in that direction. Wrapping goes around the innermost container laid out
// in the direction: right away with 'force', and with 'on' only when there is no display either.
//

enum tree_result tree_next(struct con *con, int direction, enum focus_wrapping wrapping, bool has_output, struct con **result)
{
    enum con_orientation orientation = direction_orientation(direction);
    bool backward = direction_is_backward(direction);
    struct con *wrap = NULL;

    for (; con->parent; con = con->parent) {
        struct con *parent = con->parent;
        if (parent->child_count < 2 || con_orientation(parent) != orientation) continue;

        int index = con_index(con) + (backward ? -1 : 1);
        if (index >= 0 && index < parent->child_count) {
            *result = tree_descend_focused(parent->children[index]);
            return TREE_RESULT_DONE;
        }

        struct con *first = parent->children[backward ? parent->child_count - 1 : 0];
        if (wrapping == FOCUS_WRAPPING_FORCE) {
            *result = tree_descend_focused(first);
            return TREE_RESULT_DONE;
        }

        if (wrapping == FOCUS_WRAPPING_ON && !wrap) wrap = first;
    }

    if (has_output) return TREE_RESULT_OUTPUT;
    if (!wrap) return TREE_RESULT_NONE;

    *result = tree_descend_focused(wrap);
    return TREE_RESULT_DONE;
}

//
// NOTE: i3 ws_force_orientation. Wraps everything on the workspace in a container with the
// current layout, then lays the workspace out in the requested orientation. Returns the new container.
//

struct con *tree_force_orientation(struct con *root, enum con_orientation orientation)
{
    struct con *split = con_wrap_children(root);
    root->layout = orientation_layout(orientation);
    root->last_split = root->layout;
    return split;
}

static struct con *con_lowest_common_ancestor(struct con *a, struct con *b)
{
    for (struct con *x = a; x; x = x->parent) {
        for (struct con *y = b; y; y = y->parent) {
            if (x == y) return x;
        }
    }

    return NULL;
}

static struct con *con_child_containing(struct con *ancestor, struct con *con)
{
    while (con->parent != ancestor) con = con->parent;
    return con;
}

static bool con_is_focused_descendant(struct con *con, struct con *ancestor)
{
    for (; con != ancestor; con = con->parent) {
        if (con->parent->focus[0] != con) return false;
    }

    return true;
}

//
// NOTE: i3 insert_con_into. Places the container next to the target, where it gets an average share
// of the space. Its place in the focus order of the new parent follows the focus order of the lowest
// common ancestor: when it was focused more recently than the target, it goes before the target.
// So a container that was not focused does not become the active tab of a tabbed container, and
// one that was focused keeps the focus. A container that is not part of a tree goes first.
//

void tree_insert_con(struct con *con, struct con *target, enum tree_position position)
{
    struct con *parent = target->parent;
    struct con *old_parent = con->parent;
    bool focus_before = true;
    struct con *lca = NULL;

    if (old_parent) {
        lca = con_lowest_common_ancestor(con, parent);
        if (!lca || lca == con) return;

        struct con *con_ancestor = con_child_containing(lca, con);
        struct con *target_ancestor = con_child_containing(lca, target);
        bool moves_focus = con_is_focused_descendant(con, con_ancestor);

        if (con_ancestor == target_ancestor) {
            focus_before = moves_focus;
        } else {
            focus_before = con_focus_index(con_ancestor) < con_focus_index(target_ancestor);

            //
            // NOTE: The focused container takes the focus with it to the ancestor it moves into,
            // so that it stays focused when the workspace is focused again later.
            //

            if (moves_focus && focus_before) {
                int con_focus = con_focus_index(con_ancestor);
                int target_focus = con_focus_index(target_ancestor);
                memmove(lca->focus + con_focus + 1, lca->focus + con_focus, sizeof(struct con *) * (target_focus - con_focus));
                lca->focus[con_focus] = target_ancestor;
            }
        }

        con_unlink(con);
    }

    int focus_index;
    if (parent == lca) {
        focus_index = con_focus_index(target) + (focus_before ? 0 : 1);
    } else {
        focus_index = focus_before ? CON_FOCUS_HEAD : CON_FOCUS_TAIL;
    }

    con->percent = 0.0f;
    con_insert(parent, con, con_index(target) + (position == TREE_AFTER ? 1 : 0), focus_index);
    tree_fix_percent(parent);
    con_apply_workspace_layout(con);

    if (old_parent) tree_reap_empty(old_parent);
}

//
// NOTE: The container moves toward next, its neighbour in the direction, or the neighbour of its
// ancestor above. A window of its own container swaps places with it. A container is entered on
// the near side (i3 con_descend_direction), next to the window found there. Otherwise it is placed
// between above and next.
//

static void tree_move_toward(struct con *con, struct con *above, struct con *next, int direction)
{
    bool backward = direction_is_backward(direction);

    if (!con_is_leaf(next)) {
        struct con *target = tree_descend_direction(next, direction);
        bool after = con_orientation(target->parent) != direction_orientation(direction) || backward;
        tree_insert_con(con, target, after ? TREE_AFTER : TREE_BEFORE);
    } else if (above == con) {
        struct con *parent = con->parent;
        int index = con_index(con);
        int next_index = con_index(next);
        parent->children[index] = next;
        parent->children[next_index] = con;
    } else {
        tree_insert_con(con, above, backward ? TREE_BEFORE : TREE_AFTER);
    }
}

//
// NOTE: i3 tree_move, for 'move left/right/up/down', written as the single loop of sway
// container_move_in_direction. Walks up from the container to the closest ancestor that is laid out
// in the direction and has a neighbour there. The container swaps with a sibling window, moves into
// a neighbouring container, or leaves its container at the edge and is placed next to the ancestor.
// When no ancestor is laid out in the direction, the workspace is re-oriented (ws_force_orientation).
// The result asks the caller to move the container to the display in that direction when it
// cannot move any further on this workspace, which is tried before re-orienting.
//

enum tree_result tree_move(struct con *root, struct con *con, int direction, bool has_output)
{
    if (con == root || !con->parent) return TREE_RESULT_NONE;

    enum tree_result edge = has_output ? TREE_RESULT_OUTPUT : TREE_RESULT_NONE;
    if (con->parent == root && root->child_count == 1) return edge;

    enum con_orientation orientation = direction_orientation(direction);
    int offset = direction_is_backward(direction) ? -1 : 1;
    bool wrapped = false;

    struct con *current = con;
    struct con *next = NULL;

    for (;;) {
        struct con *parent = current->parent;

        if (!parent) {
            if (has_output) return TREE_RESULT_OUTPUT;
            current = tree_force_orientation(root, orientation);
            wrapped = true;
            continue;
        }

        if (con_orientation(parent) != orientation) {
            current = parent;
            continue;
        }

        int index = con_index(current) + offset;
        next = index >= 0 && index < parent->child_count ? parent->children[index] : NULL;
        if (current != con) break;

        if (next) {
            tree_move_toward(con, con, next, direction);
            goto end;
        }

        if (parent == root) return edge;
        current = parent;
    }

    if (next) {
        tree_move_toward(con, current, next, direction);
    } else if (!wrapped && con->parent->parent == root && con->parent->child_count == 1) {
        //
        // NOTE: The lone child of a container at the edge of the workspace is treated as if the
        // workspace was its parent, like i3 does.
        //

        return edge;
    } else {
        tree_insert_con(con, current, offset < 0 ? TREE_BEFORE : TREE_AFTER);
    }

end:
    tree_flatten(root);
    return TREE_RESULT_DONE;
}

//
// NOTE: Places the container on one side of the target, as seen on screen. Used for insertion points
// and mouse drops. Within a split of the matching orientation it becomes a sibling, otherwise the
// target is split first. STACK puts it into the tabbed container of the target, creating one if needed.
//

void tree_insert_relative(struct con *target, struct con *con, int direction)
{
    if (direction == STACK) {
        if (target->parent->layout != CON_TABBED) {
            enum con_layout last_split = target->parent->layout;
            con_wrap(target, CON_TABBED)->last_split = last_split;
        }

        tree_attach(target->parent, con, con_index(target) + 1);
        return;
    }

    enum con_orientation orientation = direction_orientation(direction);
    bool matches = con_is_split(target->parent) && con_orientation(target->parent) == orientation;

    if (!matches) {
        if (target->parent->parent && target->parent->child_count == 1 && con_is_split(target->parent)) {
            target->parent->layout = orientation_layout(orientation);
        } else if (!target->parent->parent && target->parent->child_count == 1) {
            target->parent->layout = orientation_layout(orientation);
            target->parent->last_split = target->parent->layout;
        } else {
            tree_split(target, orientation);
        }
    }

    tree_attach(target->parent, con, con_index(target) + (direction_is_backward(direction) ? 0 : 1));
    con_apply_workspace_layout(con);
}

//
// NOTE: i3 tree_split. If the parent only holds this container, its orientation is changed.
// Otherwise the container is wrapped in a new split container, so that the next window opens
// inside of it, next to this one.
//

void tree_split(struct con *con, enum con_orientation orientation)
{
    if (!con->parent) {
        if (con->child_count < 2) {
            con->layout = orientation_layout(orientation);
            con->last_split = con->layout;
            return;
        }

        con = con_wrap_children(con);
    }

    struct con *parent = con->parent;
    if (parent->child_count == 1 && con_is_split(parent)) {
        parent->layout = orientation_layout(orientation);
        return;
    }

    con_wrap(con, orientation_layout(orientation));
}

//
// NOTE: Like the i3 autotiling script: a window that opens next to the target splits it along its
// longer side, so every new window halves the target. Tabbed containers are left alone.
//

void tree_autotile(struct con *target)
{
    if (!target->parent || target->parent->layout == CON_TABBED) return;

    enum con_orientation orientation = target->area.w >= target->area.h ? CON_HORIZONTAL : CON_VERTICAL;
    if (con_orientation(target->parent) != orientation) tree_split(target, orientation);
}

//
// NOTE: i3 tree_open_con. A new window opens right after the target, inside the same container:
// after the focused window, or after the selected container like i3 and sway do it. On an empty
// workspace, or when the workspace itself is the target, it opens after the most recently focused
// child of the workspace. With autotile, a target window is split along its longer side first.
//

void tree_open_con(struct con *root, struct con *con, struct con *target, bool autotile)
{
    if (!target || target == root) {
        tree_attach(root, con, root->child_count ? con_index(root->focus[0]) + 1 : -1);
    } else {
        if (autotile && con_is_leaf(target)) tree_autotile(target);
        tree_attach(target->parent, con, con_index(target) + 1);
    }

    con_apply_workspace_layout(con);
}

//
// NOTE: sway container_move_to_workspace_from_direction. A container that moves here from the display
// in the opposite direction keeps its structure and arrives on the near side: first or last on a
// workspace laid out in the direction, and otherwise next to the window focused there, entered
// from that side like a neighbouring container in tree_move.
//

void tree_attach_from_direction(struct con *root, struct con *con, int direction)
{
    if (!root->child_count || con_orientation(root) == direction_orientation(direction)) {
        con->percent = 0.0f;
        con_insert(root, con, direction_is_backward(direction) ? -1 : 0, CON_FOCUS_HEAD);
        tree_fix_percent(root);
        con_apply_workspace_layout(con);
        return;
    }

    struct con *target = tree_descend_direction(root, direction);
    bool after = con_orientation(target->parent) != direction_orientation(direction) || direction_is_backward(direction);
    tree_insert_con(con, target, after ? TREE_AFTER : TREE_BEFORE);
}

//
// NOTE: i3 con_set_layout. The layout of the parent changes, unless the container is the workspace.
// The workspace itself is always a split, so a tabbed layout wraps its contents in a new container.
// A container that is the only child of a container that holds nothing else is closed first and
// the layout of its parent changes instead (i3 #3001), so that switching a single tab between split
// and tabbed does not nest one more container each time.
//

void tree_set_layout(struct con *con, enum con_layout layout)
{
    if (con->parent) con = con->parent;
    if (con->layout != CON_TABBED) con->last_split = con->layout;

    if (con->parent && con->parent->parent && con->child_count == 1 && con->parent->child_count == 1) {
        struct con *parent = con->parent;
        struct con *child = con->children[0];

        con_unlink(child);
        con_replace(con, child);
        parent->last_split = con->last_split;
        con_free(con);
        con = parent;
    }

    if (!con->parent) {
        if (layout != CON_TABBED) {
            con->layout = layout;
            con->last_split = layout;
        } else if (con->child_count) {
            struct con *wrap = con_wrap_children(con);
            wrap->layout = CON_TABBED;
        }

        return;
    }

    con->layout = layout;
}

//
// NOTE: i3 'layout toggle split' when split_only is set, which switches between the two split layouts,
// or returns to the last split layout from tabbed. Otherwise switches between tabbed and the last split.
//

enum con_layout tree_toggle_layout(struct con *con, bool split_only)
{
    struct con *parent = con->parent ? con->parent : con;
    enum con_layout layout;

    if (split_only) {
        if (parent->layout == CON_TABBED) {
            layout = parent->last_split;
        } else {
            layout = parent->layout == CON_SPLITH ? CON_SPLITV : CON_SPLITH;
        }
    } else {
        layout = parent->layout == CON_TABBED ? parent->last_split : CON_TABBED;
    }

    tree_set_layout(con, layout);
    return layout;
}

//
// NOTE: i3 resize_find_tiling_participants + resize_neighboring_cons. Moves the edge of the container in
// the given direction by delta pixels (positive is right or down), taking the space from or giving it to
// the neighbour on the other side of that edge. Tabbed containers are skipped while searching.
//

bool tree_resize(struct con *con, int direction, float delta)
{
    enum con_orientation orientation = direction_orientation(direction);
    bool backward = direction_is_backward(direction);

    struct con *first = con;
    struct con *second = NULL;

    while (first->parent && !second) {
        struct con *parent = first->parent;
        if (con_orientation(parent) != orientation || parent->layout == CON_TABBED) {
            first = parent;
            continue;
        }

        int index = con_index(first) + (backward ? -1 : 1);
        if (index >= 0 && index < parent->child_count) {
            second = parent->children[index];
        } else {
            first = parent;
        }
    }

    if (!second) return false;

    struct con *parent = first->parent;
    float size = orientation == CON_HORIZONTAL ? parent->area.w : parent->area.h;
    if (size <= 0.0f) return false;

    float change = (backward ? -delta : delta) / size;
    float first_percent = first->percent + change;
    float second_percent = second->percent - change;

    if (first_percent < TREE_MIN_PERCENT) {
        second_percent -= TREE_MIN_PERCENT - first_percent;
        first_percent = TREE_MIN_PERCENT;
    }

    if (second_percent < TREE_MIN_PERCENT) {
        first_percent -= TREE_MIN_PERCENT - second_percent;
        second_percent = TREE_MIN_PERCENT;
    }

    first->percent = first_percent;
    second->percent = second_percent;
    tree_fix_percent(parent);

    return true;
}

void tree_balance(struct con *con)
{
    for (int i = 0; i < con->child_count; ++i) {
        con->children[i]->percent = 1.0f / con->child_count;
        tree_balance(con->children[i]);
    }
}

static void con_reverse_children(struct con *con)
{
    for (int i = 0, j = con->child_count - 1; i < j; ++i, --j) {
        struct con *temp = con->children[i];
        con->children[i] = con->children[j];
        con->children[j] = temp;
    }
}

//
// NOTE: Rotates the layout like yabai always has: 90 and 270 degrees swap the split orientation,
// reversing the side-by-side (90) or top-to-bottom (270) splits, and 180 reverses every split.
//

void tree_rotate(struct con *con, int degrees)
{
    if (con_is_split(con)) {
        if ((degrees ==  90 && con->layout == CON_SPLITH) ||
            (degrees == 270 && con->layout == CON_SPLITV) ||
            (degrees == 180)) {
            con_reverse_children(con);
        }

        if (degrees != 180) {
            con->layout = con->layout == CON_SPLITH ? CON_SPLITV : CON_SPLITH;
            con->last_split = con->layout;
        }
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_rotate(con->children[i], degrees);
    }
}

void tree_mirror(struct con *con, enum con_orientation orientation)
{
    if (con_is_split(con) && con_orientation(con) == orientation) {
        con_reverse_children(con);
    }

    for (int i = 0; i < con->child_count; ++i) {
        tree_mirror(con->children[i], orientation);
    }
}

//
// NOTE: Swaps two containers in place. They keep the share of space of the position they move to.
//

void tree_swap(struct con *a, struct con *b)
{
    if (a == b) return;

    struct con *a_parent = a->parent;
    struct con *b_parent = b->parent;
    int a_index = con_index(a);
    int b_index = con_index(b);
    int a_focus_index = con_focus_index(a);
    int b_focus_index = con_focus_index(b);

    a_parent->children[a_index] = b;
    a_parent->focus[a_focus_index] = b;
    b_parent->children[b_index] = a;
    b_parent->focus[b_focus_index] = a;

    a->parent = b_parent;
    b->parent = a_parent;

    float percent = a->percent;
    a->percent = b->percent;
    b->percent = percent;

    if (a_parent->render.raised == a) a_parent->render.raised = NULL;
    if (b_parent->render.raised == b) b_parent->render.raised = NULL;
}

//
// NOTE: Computes the area of every container. Splits divide the area along their orientation by
// the share of each child, with the window gap in between. The children of a tabbed container
// share its area below the tab bar, moved down by the bar offset (a negative offset lets them
// reach under the bar). They always keep at least the height of the bar. With a backdrop card
// the bar and the windows are additionally inset from every edge of the container by bar_inset.
//

int tree_bar_card_inset(struct area area, int bar_height, int bar_inset)
{
    if (bar_inset <= 0) return 0;
    if (area.w <= 4 * bar_inset || area.h - 2 * bar_inset <= 2 * bar_height) return 0;
    return bar_inset;
}

void tree_update(struct con *con, struct area area, int gap, int bar_height, int bar_offset, int bar_inset)
{
    con->area = area;
    if (con_is_leaf(con) || !con->child_count) return;

    if (con->layout == CON_TABBED) {
        struct area child_area = area;
        if (bar_height > 0 && area.h > 2 * bar_height) {
            int inset = tree_bar_card_inset(area, bar_height, bar_inset);
            child_area.x += inset;
            child_area.y += inset;
            child_area.w -= 2 * inset;
            child_area.h -= 2 * inset;

            int reserve = max(0, min(bar_height + bar_offset, (int) child_area.h - bar_height));
            child_area.y += reserve;
            child_area.h -= reserve;
        }

        for (int i = 0; i < con->child_count; ++i) {
            tree_update(con->children[i], child_area, gap, bar_height, bar_offset, bar_inset);
        }

        return;
    }

    bool horizontal = con->layout == CON_SPLITH;
    float total = (horizontal ? area.w : area.h) - gap * (con->child_count - 1);
    float offset = horizontal ? area.x : area.y;
    float end = horizontal ? area.x + area.w : area.y + area.h;

    for (int i = 0; i < con->child_count; ++i) {
        struct con *child = con->children[i];
        float size = i == con->child_count - 1 ? end - offset : (int)(total * child->percent + 0.5f);

        struct area child_area = area;
        if (horizontal) {
            child_area.x = offset;
            child_area.w = size;
        } else {
            child_area.y = offset;
            child_area.h = size;
        }

        tree_update(child, child_area, gap, bar_height, bar_offset, bar_inset);
        offset += size + gap;
    }
}
