//
// NOTE: Discovering the windows of an application: creating a window applies the rules and decides whether
// it floats. Windows on other spaces are missing from the accessibility list of an application; they are
// resolved later, or found by element id.
//

extern struct event_loop g_event_loop;
extern struct space_manager g_space_manager;

//
// NOTE(asmvik): Print window information when debug_output is enabled.
// Useful for identifying and creating rules if this window should in fact be managed.
//

static void window_manager_debug_window_info(struct window *window)
{
    if (!g_verbose) return;

    fprintf(stdout, "window info: \n");
    window_serialize(stdout, window, 0);
    fprintf(stdout, "\n");
}

struct window *window_manager_create_and_add_window(struct space_manager *sm, struct window_manager *wm, struct application *application, CF_CONSUMED AXUIElementRef window_ref, uint32_t window_id, bool one_shot_rules)
{
    struct window *window = window_create(application, window_ref, window_id);

    char *window_title = window_title_ts(window);
    char *window_role = window_role_ts(window);
    char *window_subrole = window_subrole_ts(window);
    debug("%s:%d %s - %s (%s:%s:%d)\n", __FUNCTION__, window->id, window->application->name, window_title, window_role, window_subrole, window->is_root);

    if (window_is_unknown(window)) {
        debug("%s: ignoring AXUnknown window %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_manager_remove_lost_focused_event(wm, window->id);
        window_destroy(window);
        return NULL;
    }

    //
    // NOTE(asmvik): Attempt to track **all** windows.
    //

    if (!window_observe(window)) {
        debug("%s: could not observe %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_manager_remove_lost_focused_event(wm, window->id);
        window_unobserve(window);
        window_destroy(window);
        return NULL;
    }

    if (window_manager_find_lost_focused_event(wm, window->id)) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
        window_manager_remove_lost_focused_event(wm, window->id);
    }

    window_manager_add_window(wm, window);

    //
    // NOTE(asmvik): However, only **root windows** are eligible for management.
    //

    if (window->is_root) {

        //
        // NOTE(asmvik): A lot of windows misreport their accessibility role, so we allow the user
        // to specify rules to make sure that we do in fact manage these windows properly.
        //
        // This part of the rule must be applied at this stage (prior to other rule properties), and if
        // no such rule matches this window, it will be ignored if it does not have a role of kAXWindowRole.
        //

        window_manager_apply_manage_rules_to_window(sm, wm, window, window_title, window_role, window_subrole, one_shot_rules);

        if (window_manager_is_window_eligible(window)) {
            window->is_eligible = true;
            window_manager_apply_rules_to_window(sm, wm, window, window_title, window_role, window_subrole, one_shot_rules);
            window_manager_purify_window(wm, window);
            window_manager_set_window_opacity(wm, window, wm->normal_window_opacity);

            if (application->is_hidden)                              return window;
            if (window_check_flag(window, WINDOW_MINIMIZE))          return window;
            if (window_check_flag(window, WINDOW_FULLSCREEN))        return window;
            if (window_check_rule_flag(window, WINDOW_RULE_MANAGED)) return window;

            if (window_check_rule_flag(window, WINDOW_RULE_FULLSCREEN)) {
                window_clear_rule_flag(window, WINDOW_RULE_FULLSCREEN);
                return window;
            }

            if (window_is_sticky(window->id) ||
                !window_can_move(window) ||
                !window_is_standard(window) ||
                !window_level_is_standard(window) ||
                (!window_can_resize(window) && window_is_undersized(window))) {
                window_set_flag(window, WINDOW_FLOAT);
            }
        } else {
            debug("%s ignoring incorrectly marked window %s %d\n", __FUNCTION__, window->application->name, window->id);
            window_set_flag(window, WINDOW_FLOAT);
            window_manager_debug_window_info(window);
        }
    } else {
        debug("%s ignoring child window %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_set_flag(window, WINDOW_FLOAT);
        window_manager_debug_window_info(window);
    }

    return window;
}

//
// NOTE: The space a new window is managed on, as selected by window_origin_display.
//

uint64_t window_manager_origin_space(struct window_manager *wm, struct window *window)
{
    switch (wm->window_origin_mode) {
    case WINDOW_ORIGIN_FOCUSED: return g_space_manager.current_space_id;
    case WINDOW_ORIGIN_CURSOR:  return space_manager_cursor_space();
    default:                    return window_space(window->id);
    }
}

struct window **window_manager_add_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int *count)
{
    *count = 0;
    CFArrayRef window_list = application_window_list(application);
    if (!window_list) return NULL;

    int window_count = CFArrayGetCount(window_list);
    struct window **list = ts_alloc_list(struct window *, window_count);

    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list, i);

        uint32_t window_id = ax_window_id(window_ref);
        if (!window_id || window_manager_find_window(wm, window_id)) continue;

        struct window *window = window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), window_id, true);
        if (window) list[(*count)++] = window;
    }

    window_manager_remove_one_shot_rules(wm);

    CFRelease(window_list);
    return list;
}

static uint32_t *window_manager_existing_application_window_list(struct application *application, int *window_count)
{
    int space_count;
    uint64_t *space_list = space_manager_mission_control_space_list(&space_count);

    return space_list ? space_window_list_for_connection(space_list, space_count, application ? application->connection : 0, window_count, true) : NULL;
}

static uint32_t *window_manager_unresolved_windows(struct window_manager *wm, uint32_t *window_list, int window_count)
{
    uint32_t *result = NULL;

    for (int i = 0; i < window_count; ++i) {
        if (!window_manager_find_window(wm, window_list[i])) {
            ts_buf_push(result, window_list[i]);
        }
    }

    return result;
}

//
// NOTE(asmvik): MacOS API does not return AXUIElementRef of windows on inactive spaces.
// However, we can just brute-force the element_id and create the AXUIElementRef ourselves.
// Every window that is found is removed from the unresolved list.
//
// :Attribution
// https://github.com/decodism
// https://github.com/lwouis/alt-tab-macos/issues/1324#issuecomment-2631035482
//

static void window_manager_add_windows_by_element_id(struct space_manager *sm, struct window_manager *wm, struct application *application, uint32_t *unresolved)
{
    CFMutableDataRef data_ref = CFDataCreateMutable(NULL, 0x14);
    CFDataIncreaseLength(data_ref, 0x14);

    uint8_t *data = CFDataGetMutableBytePtr(data_ref);
    *(uint32_t *) (data + 0x0) = application->pid;
    *(uint32_t *) (data + 0x8) = 0x636f636f;

    for (uint64_t element_id = 0; element_id < 0x7fff; ++element_id) {
        int unresolved_count = ts_buf_len(unresolved);
        if (unresolved_count == 0) break;

        memcpy(data+0xc, &element_id, sizeof(uint64_t));
        AXUIElementRef element_ref = _AXUIElementCreateWithRemoteToken(data_ref);

        if (!element_ref) continue;

        const void *role = NULL;
        AXError error = AXUIElementCopyAttributeValue(element_ref, kAXRoleAttribute, &role);

        //
        // NOTE: An application that does not respond makes every attempt wait for the
        // messaging timeout, so give up on it instead of trying all element ids.
        //

        if (error == kAXErrorCannotComplete) {
            CFRelease(element_ref);
            break;
        }

        bool consumed = false;

        if (role) {
            uint32_t element_wid = CFEqual(role, kAXWindowRole) ? ax_window_id(element_ref) : 0;

            for (int i = 0; element_wid && i < unresolved_count; ++i) {
                if (unresolved[i] == element_wid) {
                    ts_buf_del(unresolved, i);
                    window_manager_create_and_add_window(sm, wm, application, element_ref, element_wid, false);
                    consumed = true;
                    break;
                }
            }

            CFRelease(role);
        }

        if (!consumed) CFRelease(element_ref);
    }

    CFRelease(data_ref);
}

bool window_manager_add_existing_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int refresh_index)
{
    int global_window_count;
    uint32_t *global_window_list = window_manager_existing_application_window_list(application, &global_window_count);
    if (!global_window_list) return false;

    CFArrayRef window_list_ref = application_window_list(application);
    int window_count = window_list_ref ? CFArrayGetCount(window_list_ref) : 0;

    int empty_count = 0;
    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list_ref, i);
        uint32_t window_id = ax_window_id(window_ref);

        //
        // @cleanup
        //
        // :Workaround
        //
        // NOTE(asmvik): The AX API appears to always include a single element for Finder that returns an empty window id.
        // This is likely the desktop window. Other similar cases should be handled the same way; simply ignore the window when
        // we attempt to do an equality check to see if we have correctly discovered the number of windows to track.
        //

        if (!window_id) {
            ++empty_count;
            continue;
        }

        if (!window_manager_find_window(wm, window_id)) {
            window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), window_id, false);
        }
    }

    if (window_list_ref) CFRelease(window_list_ref);

    bool resolved = global_window_count == window_count-empty_count;
    if (!resolved) {
        uint32_t *unresolved = window_manager_unresolved_windows(wm, global_window_list, global_window_count);
        resolved = ts_buf_len(unresolved) == 0;

        if (!resolved && refresh_index == -1) {
            debug("%s: %s has %d windows that are not yet resolved, attempting workaround\n", __FUNCTION__, application->name, ts_buf_len(unresolved));
            window_manager_add_windows_by_element_id(sm, wm, application, unresolved);

            if (ts_buf_len(unresolved) > 0) {
                debug("%s: workaround failed to resolve all windows for %s\n", __FUNCTION__, application->name);
                buf_push(wm->applications_to_refresh, application);
            } else {
                debug("%s: workaround resolved all windows for %s\n", __FUNCTION__, application->name);
            }

            return false;
        }
    }

    if (!resolved || refresh_index == -1) return false;

    debug("%s: all windows for %s are now resolved\n", __FUNCTION__, application->name);
    buf_del(wm->applications_to_refresh, refresh_index);
    return true;
}
