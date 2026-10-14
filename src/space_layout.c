//
// NOTE: space_layout keeps a number of user spaces per display, chosen by the number of displays. When the
// displays change, reconcile passes move, create or destroy one space each until the counts match.
//

extern struct space_manager g_space_manager;

static int space_layout_user_space_count(uint64_t *space_list, int space_count)
{
    int result = 0;

    for (int i = 0; i < space_count; ++i) {
        if (space_is_user(space_list[i])) ++result;
    }

    return result;
}

static uint64_t space_layout_destroy_candidate(uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return 0;

    uint64_t visible_sid = display_space_id(did);
    uint64_t fallback_sid = 0;

    for (int i = space_count - 1; i >= 0; --i) {
        uint64_t sid = space_list[i];
        if (!space_is_user(sid)) continue;
        if (space_manager_is_space_last_user_space(sid)) continue;

        int window_count = -1;
        space_window_list(sid, &window_count, true);
        if (window_count != 0) continue;

        if (sid != visible_sid) return sid;
        if (!fallback_sid) fallback_sid = sid;
    }

    return fallback_sid;
}

enum space_layout_result space_layout_reconcile(struct space_manager *sm)
{
    int display_count = display_manager_active_display_count();
    if (display_count < 1 || display_count > SPACE_LAYOUT_MAX) return SPACE_LAYOUT_RESULT_DONE;

    struct space_layout *layout = NULL;
    for (int i = 0; i < sm->space_layout_count; ++i) {
        if (sm->space_layout[i].count == display_count) {
            layout = &sm->space_layout[i];
            break;
        }
    }

    if (!layout) {
        debug("%s: no space_layout for %d display(s)\n", __FUNCTION__, display_count);
        return SPACE_LAYOUT_RESULT_DONE;
    }

    uint32_t did_list[SPACE_LAYOUT_MAX];
    int target[SPACE_LAYOUT_MAX];
    int actual[SPACE_LAYOUT_MAX];
    int builtin = -1;

    for (int i = 0; i < display_count; ++i) {
        did_list[i] = display_manager_arrangement_display_id(i + 1);
        if (!did_list[i]) return SPACE_LAYOUT_RESULT_FAILED;
        if (builtin == -1 && CGDisplayIsBuiltin(did_list[i])) builtin = i;
    }

    space_layout_targets(layout, builtin, target);

    for (int i = 0; i < display_count; ++i) {
        int space_count;
        uint64_t *space_list = display_space_list(did_list[i], &space_count);
        if (!space_list) return SPACE_LAYOUT_RESULT_FAILED;
        actual[i] = space_layout_user_space_count(space_list, space_count);
    }

    int surplus = -1;
    int deficit = -1;
    for (int i = 0; i < display_count; ++i) {
        if (surplus == -1 && actual[i] > target[i]) surplus = i;
        if (deficit == -1 && actual[i] < target[i]) deficit = i;
    }

    if (surplus == -1 && deficit == -1) return SPACE_LAYOUT_RESULT_DONE;

    enum space_op_error result;

    if (surplus != -1 && deficit != -1) {
        int space_count;
        uint64_t *space_list = display_space_list(did_list[surplus], &space_count);
        if (!space_list) return SPACE_LAYOUT_RESULT_FAILED;

        bool *user_list = space_manager_user_list(space_list, space_count);
        uint64_t sid = space_layout_move_candidate(space_list, user_list, space_count, display_space_id(did_list[surplus]), deficit > surplus);

        debug("%s: move space %lld from display %d to display %d\n", __FUNCTION__, sid, surplus + 1, deficit + 1);
        result = space_manager_move_space_to_display(sm, sid, did_list[deficit]);
    } else if (deficit != -1) {
        debug("%s: create space on display %d (%d/%d)\n", __FUNCTION__, deficit + 1, actual[deficit], target[deficit]);
        result = space_manager_add_space(display_space_id(did_list[deficit]));
    } else {
        uint64_t sid = space_layout_destroy_candidate(did_list[surplus]);
        if (!sid) {
            debug("%s: display %d has %d/%d spaces, but no empty space can be destroyed\n", __FUNCTION__, surplus + 1, actual[surplus], target[surplus]);
            return SPACE_LAYOUT_RESULT_DONE;
        }

        debug("%s: destroy empty space %lld on display %d (%d/%d)\n", __FUNCTION__, sid, surplus + 1, actual[surplus], target[surplus]);
        result = space_manager_destroy_space(sid);
    }

    return result == SPACE_OP_ERROR_SUCCESS ? SPACE_LAYOUT_RESULT_PERFORMED : SPACE_LAYOUT_RESULT_FAILED;
}

//
// NOTE: A schedule replaces the pending one: SPACE_LAYOUT_RECONCILE only runs for the latest generation.
// reset_passes restarts the limit of passes for a new change of the displays.
//

void space_layout_schedule(double delay, bool reset_passes)
{
    if (!g_space_manager.space_layout_count) return;
    if (reset_passes) g_space_manager.space_layout_passes = 0;

    uint32_t gen = ++g_space_manager.space_layout_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(SPACE_LAYOUT_RECONCILE, NULL, (int) gen);
    });
}
