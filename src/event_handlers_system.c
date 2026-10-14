//
// NOTE: The handlers of system events: Mission Control, the Dock, menus, the menu bar, waking from sleep,
// space_layout passes, and messages from clients.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
EVENT_HANDLER(MISSION_CONTROL_SHOW_ALL_WINDOWS)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS;
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

EVENT_HANDLER(MISSION_CONTROL_SHOW_FRONT_WINDOWS)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW_FRONT_WINDOWS;
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

EVENT_HANDLER(MISSION_CONTROL_SHOW_DESKTOP)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW_DESKTOP;
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

EVENT_HANDLER(MISSION_CONTROL_ENTER)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(MISSION_CONTROL_CHECK_FOR_EXIT, NULL, 0);
    });

    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

EVENT_HANDLER(MISSION_CONTROL_CHECK_FOR_EXIT)
{
    if (!mission_control_is_active()) return;

    CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, 0);
    int window_count = CFArrayGetCount(window_list);
    bool found = false;

    for (int i = 0; i < window_count; ++i) {
        CFDictionaryRef dictionary = CFArrayGetValueAtIndex(window_list, i);

        CFStringRef name = CFDictionaryGetValue(dictionary, kCGWindowName);
        if (name) continue;

        CFStringRef owner = CFDictionaryGetValue(dictionary, kCGWindowOwnerName);
        if (!owner) continue;

        CFNumberRef layer_ref = CFDictionaryGetValue(dictionary, kCGWindowLayer);
        if (!layer_ref) continue;

        uint64_t layer = 0;
        CFNumberGetValue(layer_ref, CFNumberGetType(layer_ref), &layer);
        if (layer != 18) continue;

        if (CFEqual(CFSTR("Dock"), owner)) {
            found = true;
            break;
        }
    }

    if (found) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            event_loop_post(MISSION_CONTROL_CHECK_FOR_EXIT, NULL, 0);
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0f), dispatch_get_main_queue(), ^{
            event_loop_post(MISSION_CONTROL_EXIT, NULL, 0);
        });
    }

    CFRelease(window_list);
}

EVENT_HANDLER(MISSION_CONTROL_EXIT)
{
    debug("%s:\n", __FUNCTION__);

    if (g_window_manager.menubar_opacity != 1.0f) {
        float alpha = space_is_fullscreen(g_space_manager.current_space_id) ? 1.0f : g_window_manager.menubar_opacity;
        SLSSetMenuBarInsetAndAlpha(g_connection, 0, 1, alpha);
    }

    if (g_mission_control_mode == MISSION_CONTROL_MODE_SHOW || g_mission_control_mode == MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS) {
        window_manager_correct_for_mission_control_changes(&g_space_manager, &g_window_manager);
    }

    event_signal_push(SIGNAL_MISSION_CONTROL_EXIT, (void*)(uintptr_t)g_mission_control_mode);
    g_mission_control_mode = MISSION_CONTROL_MODE_INACTIVE;
}

EVENT_HANDLER(DOCK_DID_RESTART)
{
    debug("%s:\n", __FUNCTION__);

    scripting_addition_payload_changed();

    mission_control_unobserve();
    mission_control_observe();

    event_signal_push(SIGNAL_DOCK_DID_RESTART, NULL);
}

static enum ffm_mode ffm_value;
static int is_menu_open = 0;

EVENT_HANDLER(MENU_OPENED)
{
    debug("%s\n", __FUNCTION__);
    ++is_menu_open;

    if (is_menu_open == 1) {
        ffm_value = g_window_manager.ffm_mode;
        g_window_manager.ffm_mode = FFM_DISABLED;
    }
}

EVENT_HANDLER(MENU_CLOSED)
{
    debug("%s\n", __FUNCTION__);
    --is_menu_open;

    if (is_menu_open == 0) {
        g_window_manager.ffm_mode = ffm_value;
    } else if (is_menu_open < 0) {
        is_menu_open = 0;
    }
}

EVENT_HANDLER(MENU_BAR_HIDDEN_CHANGED)
{
    debug("%s:\n", __FUNCTION__);
    space_manager_mark_spaces_invalid(&g_space_manager);
    event_signal_push(SIGNAL_MENU_BAR_HIDDEN_CHANGED, NULL);
}

EVENT_HANDLER(DOCK_DID_CHANGE_PREF)
{
    debug("%s:\n", __FUNCTION__);
    space_manager_mark_spaces_invalid(&g_space_manager);
    event_signal_push(SIGNAL_DOCK_DID_CHANGE_PREF, NULL);
}

EVENT_HANDLER(SYSTEM_WOKE)
{
    debug("%s:\n", __FUNCTION__);

    struct window *focused_window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
    if (focused_window) {
        window_manager_set_window_opacity(&g_window_manager, focused_window, g_window_manager.active_window_opacity);
        window_manager_center_mouse(&g_window_manager, focused_window);
    }

    space_layout_schedule(1.0, true);
    event_signal_push(SIGNAL_SYSTEM_WOKE, NULL);
}

EVENT_HANDLER(SPACE_LAYOUT_RECONCILE)
{
    if ((uint32_t) param1 != g_space_manager.space_layout_gen) return;
    if (!g_space_manager.space_layout_count) return;

    if (mission_control_is_active()) {
        space_layout_schedule(0.5, false);
        return;
    }

    if (++g_space_manager.space_layout_passes > 40) {
        debug("%s: giving up, layout did not converge\n", __FUNCTION__);
        return;
    }

    enum space_layout_result result = space_layout_reconcile(&g_space_manager);
    if (result == SPACE_LAYOUT_RESULT_PERFORMED) {
        space_layout_schedule(0.5, false);
    } else if (result == SPACE_LAYOUT_RESULT_FAILED) {
        space_layout_schedule(1.0, false);
    } else {
        g_space_manager.space_layout_passes = 0;
    }
}

EVENT_HANDLER(DAEMON_MESSAGE)
{
    TIME_FUNCTION;

    daemon_message_handle(param1);
}
#pragma clang diagnostic pop
