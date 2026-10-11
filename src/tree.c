extern int g_connection;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

//
// NOTE: The first part of this file is the container model and the i3 algorithms that work on it.
// It does not talk to the window server, so that it can be tested on its own. The functions that
// apply a tree to the screen follow further down.
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
    tab_bar_release(&con->tab_bar);
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

static void tree_attach_internal(struct con *parent, struct con *con, int index, bool focus_first)
{
    con_reserve(parent, parent->child_count + 1);

    if (index < 0 || index > parent->child_count) index = parent->child_count;
    memmove(parent->children + index + 1, parent->children + index, sizeof(struct con *) * (parent->child_count - index));
    parent->children[index] = con;

    if (focus_first) {
        memmove(parent->focus + 1, parent->focus, sizeof(struct con *) * parent->child_count);
        parent->focus[0] = con;
    } else {
        parent->focus[parent->child_count] = con;
    }

    ++parent->child_count;
    con->parent = parent;
}

void tree_attach(struct con *parent, struct con *con, int index)
{
    con->percent = 0.0f;
    tree_attach_internal(parent, con, index, false);
    tree_fix_percent(parent);
}

static void tree_unlink(struct con *con)
{
    struct con *parent = con->parent;
    if (!parent) return;

    int index = con_index(con);
    int focus_index = con_focus_index(con);

    memmove(parent->children + index, parent->children + index + 1, sizeof(struct con *) * (parent->child_count - index - 1));
    memmove(parent->focus + focus_index, parent->focus + focus_index + 1, sizeof(struct con *) * (parent->child_count - focus_index - 1));

    --parent->child_count;
    if (parent->raised == con) parent->raised = NULL;
    con->parent = NULL;
}

//
// NOTE: Takes the container out of the tree. Containers that are left without children are
// closed, like i3 does in con_on_remove_child, except for the workspace itself. Returns the
// closest ancestor that is still part of the tree.
//

struct con *tree_detach(struct con *con)
{
    struct con *parent = con->parent;
    if (!parent) return NULL;

    tree_unlink(con);

    while (parent->parent && parent->child_count == 0) {
        struct con *empty = parent;
        parent = parent->parent;
        tree_unlink(empty);
        con_free(empty);
    }

    tree_fix_percent(parent);
    return parent;
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
    if (!parent || con->child_count != 1) return;

    struct con *child = con->children[0];
    if (!con_is_split(con) || !con_is_split(child)) return;
    if (con_orientation(con) == con_orientation(child)) return;
    if (con_orientation(child) != con_orientation(parent) || parent->layout == CON_TABBED) return;

    int index = con_index(con);
    int focus_index = con_focus_index(con);
    float percent = con->percent;

    for (int i = 0; i < child->child_count; ++i) {
        struct con *grandchild = child->children[i];
        grandchild->percent *= percent;
        con_reserve(parent, parent->child_count + 1);
        memmove(parent->children + index + i + 1, parent->children + index + i, sizeof(struct con *) * (parent->child_count - index - i));
        parent->children[index + i] = grandchild;
        ++parent->child_count;
        grandchild->parent = parent;
    }

    //
    // NOTE: The grandchildren take the place of the container in the focus order of the parent,
    // keeping the order they had among themselves.
    //

    memmove(parent->focus + focus_index + child->child_count, parent->focus + focus_index, sizeof(struct con *) * (parent->child_count - child->child_count - focus_index));
    memcpy(parent->focus + focus_index, child->focus, sizeof(struct con *) * child->child_count);

    child->child_count = 0;
    con->child_count = 0;
    tree_unlink(con);
    con_free(child);
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
    if (selected) selected->selected = false;
    if (con) con->selected = true;
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

static enum tree_result tree_next_internal(struct con *con, int direction, bool wrap, enum focus_wrapping wrapping, bool has_output, struct con **result)
{
    struct con *parent = con->parent;
    if (!parent) return has_output ? TREE_RESULT_OUTPUT : TREE_RESULT_NONE;

    if (con_orientation(parent) != direction_orientation(direction) || parent->child_count == 1) {
        return tree_next_internal(parent, direction, wrap, wrapping, has_output, result);
    }

    int index = con_index(con) + (direction_is_backward(direction) ? -1 : 1);
    if (index < 0 || index >= parent->child_count) {
        if (wrapping != FOCUS_WRAPPING_FORCE) {
            enum tree_result higher = tree_next_internal(parent, direction, false, wrapping, has_output, result);
            if (higher != TREE_RESULT_NONE || !wrap) return higher;
        }

        index = direction_is_backward(direction) ? parent->child_count - 1 : 0;
    }

    *result = tree_descend_focused(parent->children[index]);
    return TREE_RESULT_DONE;
}

//
// NOTE: i3 _tree_next, for 'focus left/right/up/down'. Walks up to the closest ancestor that is laid
// out in the direction (tabbed counts as horizontal), and focuses the neighbouring child there,
// descending along its focus history. At the edge of the workspace the result says to try the
// display in that direction, and wrapping only happens when there is none.
//

enum tree_result tree_next(struct con *con, int direction, enum focus_wrapping wrapping, bool has_output, struct con **result)
{
    return tree_next_internal(con, direction, wrapping != FOCUS_WRAPPING_OFF, wrapping, has_output, result);
}

static struct con *tree_parent_with_orientation(struct con *con, enum con_orientation orientation)
{
    struct con *parent = con->parent;
    while (parent && con_orientation(parent) != orientation) {
        parent = parent->parent;
    }

    return parent;
}

static void tree_move_children(struct con *from, struct con *to)
{
    struct con **focus = malloc(sizeof(struct con *) * (from->child_count + 1));
    int count = from->child_count;
    memcpy(focus, from->focus, sizeof(struct con *) * count);

    while (from->child_count) {
        struct con *child = from->children[0];
        tree_unlink(child);
        tree_attach_internal(to, child, to->child_count, false);
    }

    memcpy(to->focus, focus, sizeof(struct con *) * count);
    free(focus);
}

//
// NOTE: i3 ws_force_orientation. Wraps everything on the workspace in a container with the
// current layout, then lays the workspace out in the requested orientation.
//

void tree_force_orientation(struct con *root, enum con_orientation orientation)
{
    struct con *split = con_create(root->layout);
    split->last_split = root->last_split;
    tree_move_children(root, split);

    root->layout = orientation_layout(orientation);
    root->last_split = root->layout;

    tree_attach_internal(root, split, 0, true);
    split->percent = 1.0f;
}

//
// NOTE: i3 insert_con_into. Places the container next to the target. It keeps the focus within
// its new parent and gets an average share of the space there.
//

void tree_insert_con(struct con *con, struct con *target, enum tree_position position)
{
    struct con *old_parent = con->parent;
    tree_unlink(con);

    struct con *parent = target->parent;
    int index = con_index(target) + (position == TREE_AFTER ? 1 : 0);
    tree_attach_internal(parent, con, index, true);
    con->percent = 0.0f;
    tree_fix_percent(parent);

    while (old_parent && old_parent->parent && old_parent->child_count == 0) {
        struct con *empty = old_parent;
        old_parent = old_parent->parent;
        tree_unlink(empty);
        con_free(empty);
    }

    if (old_parent) tree_fix_percent(old_parent);
}

//
// NOTE: i3 tree_move, for 'move left/right/up/down'. Swaps with a sibling window, moves into a
// neighbouring container, or leaves the container at its edge for the closest ancestor laid out
// in that direction. When no ancestor matches, the workspace is re-oriented (ws_force_orientation).
// The result asks the caller to move the container to the display in that direction when it
// cannot move any further on this workspace.
//

enum tree_result tree_move(struct con *root, struct con *con, int direction, bool has_output)
{
    if (con == root || !con->parent) return TREE_RESULT_NONE;

    enum con_orientation orientation = direction_orientation(direction);
    bool backward = direction_is_backward(direction);

    if (con->parent == root && root->child_count == 1) {
        return has_output ? TREE_RESULT_OUTPUT : TREE_RESULT_NONE;
    }

    struct con *same_orientation = tree_parent_with_orientation(con, orientation);

    do {
        if (!same_orientation) {
            if (has_output) return TREE_RESULT_OUTPUT;
            tree_force_orientation(root, orientation);
            same_orientation = tree_parent_with_orientation(con, orientation);
        }

        if (same_orientation == con->parent) {
            int index = con_index(con) + (backward ? -1 : 1);
            struct con *swap = index >= 0 && index < con->parent->child_count ? con->parent->children[index] : NULL;

            if (swap) {
                if (!con_is_leaf(swap)) {
                    struct con *target = tree_descend_direction(swap, direction);
                    enum tree_position position = con_orientation(target->parent) != orientation || backward ? TREE_AFTER : TREE_BEFORE;
                    tree_insert_con(con, target, position);
                    goto end;
                }

                con->parent->children[index] = con;
                con->parent->children[index + (backward ? 1 : -1)] = swap;
                return TREE_RESULT_DONE;
            }

            if (con->parent == root) {
                return has_output ? TREE_RESULT_OUTPUT : TREE_RESULT_NONE;
            }

            same_orientation = tree_parent_with_orientation(con->parent, orientation);
        }
    } while (!same_orientation);

    struct con *above = con;
    while (above->parent != same_orientation) above = above->parent;

    int index = con_index(above) + (backward ? -1 : 1);
    struct con *next = index >= 0 && index < same_orientation->child_count ? same_orientation->children[index] : NULL;

    if (next && !con_is_leaf(next)) {
        struct con *target = tree_descend_direction(next, direction);
        enum tree_position position = con_orientation(target->parent) != orientation || backward ? TREE_AFTER : TREE_BEFORE;
        tree_insert_con(con, target, position);
    } else if (!next && con->parent->parent == root && con->parent->child_count == 1) {
        return has_output ? TREE_RESULT_OUTPUT : TREE_RESULT_NONE;
    } else {
        tree_insert_con(con, above, backward ? TREE_BEFORE : TREE_AFTER);
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
            struct con *wrap = con_create(CON_TABBED);
            wrap->last_split = target->parent->layout == CON_TABBED ? CON_SPLITH : target->parent->layout;
            int index = con_index(target);
            int focus_index = con_focus_index(target);
            struct con *parent = target->parent;

            parent->children[index] = wrap;
            parent->focus[focus_index] = wrap;
            wrap->parent = parent;
            wrap->percent = target->percent;
            target->parent = NULL;
            tree_attach_internal(wrap, target, 0, true);
            target->percent = 1.0f;
        }

        tree_attach_internal(target->parent, con, con_index(target) + 1, false);
        con->percent = 0.0f;
        tree_fix_percent(target->parent);
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

    tree_attach_internal(target->parent, con, con_index(target) + (direction_is_backward(direction) ? 0 : 1), false);
    con->percent = 0.0f;
    tree_fix_percent(target->parent);
}

static struct con *tree_encapsulate(struct con *root)
{
    struct con *con = con_create(root->layout);
    con->last_split = root->last_split;
    tree_move_children(root, con);
    tree_attach_internal(root, con, 0, true);
    con->percent = 1.0f;
    return con;
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

        con = tree_encapsulate(con);
    }

    struct con *parent = con->parent;
    if (parent->child_count == 1 && con_is_split(parent)) {
        parent->layout = orientation_layout(orientation);
        return;
    }

    struct con *split = con_create(orientation_layout(orientation));
    int index = con_index(con);
    int focus_index = con_focus_index(con);

    parent->children[index] = split;
    parent->focus[focus_index] = split;
    split->parent = parent;
    split->percent = con->percent;

    con->parent = NULL;
    tree_attach_internal(split, con, 0, true);
    con->percent = 1.0f;
}

//
// NOTE: i3 con_set_layout. The layout of the parent changes, unless the container is the workspace.
// The workspace itself is always a split, so a tabbed layout wraps its contents in a new container.
//

void tree_set_layout(struct con *con, enum con_layout layout)
{
    if (con->parent) con = con->parent;
    if (con->layout != CON_TABBED) con->last_split = con->layout;

    if (!con->parent) {
        if (layout != CON_TABBED) {
            con->layout = layout;
            con->last_split = layout;
        } else if (con->child_count) {
            struct con *wrap = tree_encapsulate(con);
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
// NOTE: Rotates the layout like the bsp layout does: 90 and 270 degrees swap the split orientation,
// reversing the side-by-side (90) or top-to-bottom (270) splits, and 180 reverses every split.
//

void tree_rotate(struct con *con, int degrees)
{
    if (con_is_split(con) || (!con->parent && !con_is_leaf(con))) {
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
    if (con_is_split(con) || (!con->parent && !con_is_leaf(con))) {
        if (con_orientation(con) == orientation) con_reverse_children(con);
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

    if (a_parent->raised == a) a_parent->raised = NULL;
    if (b_parent->raised == b) b_parent->raised = NULL;
}

//
// NOTE: Computes the area of every container. Splits divide the area along their orientation by
// the share of each child, with the window gap in between. The children of a tabbed container
// share its area below the tab bar.
//

void tree_update(struct con *con, struct area area, int gap, int bar_height)
{
    con->area = area;
    if (con_is_leaf(con) || !con->child_count) return;

    if (con->layout == CON_TABBED) {
        struct area child_area = area;
        if (bar_height > 0 && area.h > 2 * bar_height) {
            child_area.y += bar_height;
            child_area.h -= bar_height;
        }

        for (int i = 0; i < con->child_count; ++i) {
            tree_update(con->children[i], child_area, gap, bar_height);
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

        tree_update(child, child_area, gap, bar_height);
        offset += size + gap;
    }
}

static void tree_append_title(CFMutableStringRef string, struct con *con)
{
    if (con_is_leaf(con)) {
        struct window *window = window_manager_find_window(&g_window_manager, con->window_id);
        if (window && window->application && window->application->name) {
            CFStringAppendCString(string, window->application->name, kCFStringEncodingUTF8);
        }
        return;
    }

    CFStringAppendCString(string, con->layout == CON_SPLITH ? "H[" : con->layout == CON_SPLITV ? "V[" : "T[", kCFStringEncodingUTF8);

    for (int i = 0; i < con->child_count; ++i) {
        if (i > 0) CFStringAppendCString(string, " ", kCFStringEncodingUTF8);
        tree_append_title(string, con->children[i]);
    }

    CFStringAppendCString(string, "]", kCFStringEncodingUTF8);
}

//
// NOTE: The tab title of a container: the window title for a window, or the layout and the
// applications inside for a container, like i3 shows it (H[iTerm2 Safari]).
//

CFStringRef tree_copy_title(struct con *con)
{
    if (con_is_leaf(con)) return tab_bar_copy_title(con->window_id);

    CFMutableStringRef string = CFStringCreateMutable(NULL, 0);
    tree_append_title(string, con);
    return string;
}

static void tree_feedback_destroy(struct con *con)
{
    if (!con->feedback_window.id) return;

    SLSOrderWindow(g_connection, con->feedback_window.id, 0, 0);
    CGContextRelease(con->feedback_window.context);
    SLSReleaseWindow(g_connection, con->feedback_window.id);
    memset(&con->feedback_window, 0, sizeof(struct feedback_window));
}
