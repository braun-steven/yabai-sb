static struct {
    int sockfd;
    bool is_running;
    pthread_t thread;
} g_message_loop;

extern struct event_loop g_event_loop;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern bool g_verbose;

static void handle_domain_display(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    uint32_t acting_did = display_manager_active_display_id();
    struct selector selector = parse_display_selector(NULL, &message, acting_did, true);

    if (selector.did_parse) {
        acting_did = selector.did;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    if (!acting_did) {
        daemon_fail(rsp, "could not locate the display to act on!\n");
        return;
    }

    if (token_equals(command, COMMAND_DISPLAY_FOCUS)) {
        struct selector selector = parse_display_selector(rsp, &message, acting_did, false);
        if (selector.did_parse && selector.did) {
            if (acting_did != selector.did) {
                display_manager_focus_display(selector.did, display_space_id(selector.did));
            } else {
                daemon_fail(rsp, "cannot focus an already focused display.\n");
            }
        }
    } else if (token_equals(command, COMMAND_DISPLAY_SPACE)) {
        struct selector selector = parse_space_selector(rsp, &message, display_space_id(acting_did), false);
        if (selector.did_parse && selector.sid) {
            enum space_op_error result = display_manager_focus_space(acting_did, selector.sid);
            if (result == SPACE_OP_ERROR_SAME_DISPLAY) {
                daemon_fail(rsp, "acting display does not contain the given space.\n");
            } else {
                daemon_fail_space_op(rsp, result, "focus space");
            }
        }
    } else if (token_equals(command, COMMAND_DISPLAY_LABEL)) {
        char *label;
        if (parse_label(rsp, get_token(&message), LABEL_DISPLAY, &label)) {
            if (label) {
                display_manager_set_label_for_display(&g_display_manager, acting_did, label);
            } else {
                if (!display_manager_remove_label_for_display(&g_display_manager, acting_did)) {
                    daemon_fail(rsp, "the selected display was not associated with a label!\n");
                }
            }
        }
    } else {
        daemon_fail_unknown_command(rsp, domain, command);
    }
}

static void handle_domain_space(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    uint64_t acting_sid = space_manager_active_space();
    struct selector selector = parse_space_selector(NULL, &message, acting_sid, true);

    if (selector.did_parse) {
        acting_sid = selector.sid;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    if (!acting_sid) {
        daemon_fail(rsp, "could not locate the space to act on!\n");
        return;
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (token_equals(command, COMMAND_SPACE_FOCUS) || token_equals(command, COMMAND_SPACE_SWITCH)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = token_equals(command, COMMAND_SPACE_FOCUS)
                                           ? space_manager_focus_space(selector.sid)
                                           : space_manager_switch_space(selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot focus an already focused space.\n");
                } else {
                    daemon_fail_space_op(rsp, result, "focus space");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_MOVE)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_move_space_to_space(acting_sid, selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot move space to itself.\n");
                } else if (result == SPACE_OP_ERROR_SAME_DISPLAY) {
                    daemon_fail(rsp, "cannot move space across display boundaries. use --display instead.\n");
                } else {
                    daemon_fail_space_op(rsp, result, "move space");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_SWAP)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_swap_space_with_space(acting_sid, selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot swap space with itself.\n");
                } else {
                    daemon_fail_space_op(rsp, result, "swap space");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_DISPLAY)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                enum space_op_error result = space_manager_move_space_to_display(&g_space_manager, acting_sid, selector.did);
                if (result == SPACE_OP_ERROR_MISSING_SRC) {
                    daemon_fail(rsp, "could not locate the space to act on.\n");
                } else if (result == SPACE_OP_ERROR_MISSING_DST) {
                    daemon_fail(rsp, "could not locate the active space of the given display.\n");
                } else if (result == SPACE_OP_ERROR_INVALID_SRC) {
                    daemon_fail(rsp, "acting space is the last user-space on the source display and cannot be moved.\n");
                } else if (result == SPACE_OP_ERROR_INVALID_DST) {
                    daemon_fail(rsp, "acting space is already located on the given display.\n");
                } else {
                    daemon_fail_space_op(rsp, result, "send space to display");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_CREATE)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.did) {
                    acting_sid = display_space_id(selector.did);
                } else {
                    return;
                }
            }

            enum space_op_error result = space_manager_add_space(acting_sid);
            if (result == SPACE_OP_ERROR_MISSING_SRC) {
                daemon_fail(rsp, "could not locate the space to act on.\n");
            } else {
                daemon_fail_space_op(rsp, result, "create space");
            }
        } else if (token_equals(command, COMMAND_SPACE_DESTROY)) {
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            enum space_op_error result = space_manager_destroy_space(acting_sid);
            if (result == SPACE_OP_ERROR_MISSING_SRC) {
                daemon_fail(rsp, "could not locate the space to act on.\n");
            } else if (result == SPACE_OP_ERROR_INVALID_SRC) {
                daemon_fail(rsp, "acting space is the last user-space on the source display and cannot be destroyed.\n");
            } else if (result == SPACE_OP_ERROR_INVALID_TYPE) {
                daemon_fail(rsp, "cannot destroy a macOS fullscreen space.\n");
            } else {
                daemon_fail_space_op(rsp, result, "destroy space");
            }
        } else if (token_equals(command, COMMAND_SPACE_EQUALIZE) || token_equals(command, COMMAND_SPACE_BALANCE)) {
            //
            // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
            //

            struct token value = get_token(&message);
            if (token_is_valid(value) && !token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X) && !token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!space_manager_balance_space(&g_space_manager, acting_sid)) {
                daemon_fail(rsp, "cannot %s a non-managed space.\n", token_equals(command, COMMAND_SPACE_EQUALIZE) ? "equalize" : "balance");
            }
        } else if (token_equals(command, COMMAND_SPACE_MIRROR)) {
            struct token value = get_token(&message);
            enum window_split axis = token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X) ? SPLIT_X
                                   : token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y) ? SPLIT_Y
                                   : SPLIT_NONE;
            if (axis == SPLIT_NONE) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!space_manager_mirror_space(&g_space_manager, acting_sid, axis)) {
                daemon_fail(rsp, "cannot mirror a non-managed space.\n");
            }
        } else if (token_equals(command, COMMAND_SPACE_ROTATE)) {
            struct token value = get_token(&message);
            int degrees = token_equals(value, ARGUMENT_SPACE_ROTATE_90)  ? 90
                        : token_equals(value, ARGUMENT_SPACE_ROTATE_180) ? 180
                        : token_equals(value, ARGUMENT_SPACE_ROTATE_270) ? 270
                        : 0;
            if (!degrees) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!space_manager_rotate_space(&g_space_manager, acting_sid, degrees)) {
                daemon_fail(rsp, "cannot rotate a non-managed space.\n");
            }
        } else if (token_equals(command, COMMAND_SPACE_PADDING)) {
            int t, b, l, r;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_SPACE_PADDING, type, &t, &b, &l, &r) == 5)) {
                if (!space_manager_set_padding_for_space(&g_space_manager, acting_sid, parse_value_type(type), t, b, l, r)) {
                    daemon_fail(rsp, "cannot set padding for a non-managed space.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_SPACE_GAP)) {
            int gap;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_SPACE_GAP, type, &gap) == 2)) {
                if (!space_manager_set_gap_for_space(&g_space_manager, acting_sid, parse_value_type(type), gap)) {
                    daemon_fail(rsp, "cannot set gap for a non-managed space.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_SPACE_TOGGLE)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_SPACE_TGL_PADDING)) {
                if (!space_manager_toggle_padding_for_space(&g_space_manager, acting_sid)) {
                    daemon_fail(rsp, "cannot toggle padding for a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_GAP)) {
                if (!space_manager_toggle_gap_for_space(&g_space_manager, acting_sid)) {
                    daemon_fail(rsp, "cannot toggle gap for a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_MC)) {
                space_manager_toggle_mission_control(acting_sid);
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_SD)) {
                space_manager_toggle_show_desktop(acting_sid);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_SPACE_LAYOUT)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_SPACE_LAYOUT_FLT)) {
                if (space_is_user(acting_sid)) {
                    space_manager_set_layout_for_space(&g_space_manager, acting_sid, VIEW_FLOAT);
                } else {
                    daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_LAYOUT_TREE)) {
                if (space_is_user(acting_sid)) {
                    space_manager_set_layout_for_space(&g_space_manager, acting_sid, VIEW_TREE);
                } else {
                    daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_SPACE_LABEL)) {
            char *label;
            if (parse_label(rsp, get_token(&message), LABEL_SPACE, &label)) {
                if (label) {
                    space_manager_set_label_for_space(&g_space_manager, acting_sid, label);
                } else {
                    if (!space_manager_remove_label_for_space(&g_space_manager, acting_sid)) {
                        daemon_fail(rsp, "the selected space was not associated with a label!\n");
                    }
                }
            }
        } else {
            daemon_fail_unknown_command(rsp, domain, command);
        }
    }
}

static enum window_op_error window_tree_focus(struct window *window, int tree_direction)
{
    if (tree_direction == TREE_FOCUS_PARENT) return window_manager_tree_focus_parent(&g_window_manager, window);
    if (tree_direction == TREE_FOCUS_CHILD)  return window_manager_tree_focus_child(&g_window_manager, window);
    return window_manager_tree_focus_direction(&g_window_manager, window, tree_direction);
}

static int parse_window_layout(struct token value)
{
    if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_TABBED))    return WINDOW_LAYOUT_TABBED;
    if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_SPLIT))     return WINDOW_LAYOUT_SPLIT;
    if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_TOGGLE))    return WINDOW_LAYOUT_TOGGLE;
    if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_SPLITH))    return WINDOW_LAYOUT_SPLITH;
    if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_SPLITV))    return WINDOW_LAYOUT_SPLITV;
    if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_TGL_SPLIT)) return WINDOW_LAYOUT_TOGGLE_SPLIT;
    return -1;
}

//
// NOTE: -1 toggles the orientation of the parent container.
//

static bool parse_split_orientation(struct token value, int *orientation)
{
    if (token_equals(value, ARGUMENT_WINDOW_SPLIT_H)) {
        *orientation = CON_HORIZONTAL;
    } else if (token_equals(value, ARGUMENT_WINDOW_SPLIT_V)) {
        *orientation = CON_VERTICAL;
    } else if (token_equals(value, ARGUMENT_WINDOW_SPLIT_TOGGLE)) {
        *orientation = -1;
    } else {
        return false;
    }

    return true;
}

static void window_toggle_float(struct window *window)           { window_manager_make_window_floating(&g_space_manager, &g_window_manager, window, !window_check_flag(window, WINDOW_FLOAT), false); }
static void window_toggle_sticky(struct window *window)          { window_manager_make_window_sticky(&g_space_manager, &g_window_manager, window, !window_check_flag(window, WINDOW_STICKY)); }
static void window_toggle_split(struct window *window)           { space_manager_toggle_window_split(&g_space_manager, window); }
static void window_toggle_zoom_parent(struct window *window)     { window_manager_toggle_window_zoom_parent(&g_window_manager, window); }
static void window_toggle_zoom_fullscreen(struct window *window) { window_manager_toggle_window_zoom_fullscreen(&g_window_manager, window); }
static void window_toggle_pip(struct window *window)             { window_manager_toggle_window_pip(&g_space_manager, window); }

typedef void window_toggle_func(struct window *window);

static const struct {
    char *value;
    window_toggle_func *toggle;
} window_toggle_list[] = {
    { ARGUMENT_WINDOW_TOGGLE_FLOAT,    window_toggle_float },
    { ARGUMENT_WINDOW_TOGGLE_STICKY,   window_toggle_sticky },
    { ARGUMENT_WINDOW_TOGGLE_SHADOW,   window_manager_toggle_window_shadow },
    { ARGUMENT_WINDOW_TOGGLE_SPLIT,    window_toggle_split },
    { ARGUMENT_WINDOW_TOGGLE_PARENT,   window_toggle_zoom_parent },
    { ARGUMENT_WINDOW_TOGGLE_FULLSC,   window_toggle_zoom_fullscreen },
    { ARGUMENT_WINDOW_TOGGLE_WINDOWED, window_manager_toggle_window_windowed_fullscreen },
    { ARGUMENT_WINDOW_TOGGLE_NATIVE,   window_manager_toggle_window_native_fullscreen },
    { ARGUMENT_WINDOW_TOGGLE_EXPOSE,   window_manager_toggle_window_expose },
    { ARGUMENT_WINDOW_TOGGLE_PIP,      window_toggle_pip }
};

//
// NOTE: Returns NULL when value is not a window property, so that it can be a scratchpad label.
//

static window_toggle_func *window_toggle_for_value(struct token value)
{
    for (int i = 0; i < array_count(window_toggle_list); ++i) {
        if (token_equals(value, window_toggle_list[i].value)) {
            return window_toggle_list[i].toggle;
        }
    }

    return NULL;
}

static void handle_domain_window(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    struct window *acting_window = window_manager_acting_window(&g_window_manager);
    struct selector selector = parse_window_selector(NULL, &message, acting_window, true);

    if (selector.did_parse) {
        acting_window = selector.window;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (!acting_window &&
            !token_equals(command, COMMAND_WINDOW_FOCUS) &&
            !token_equals(command, COMMAND_WINDOW_CLOSE) &&
            !token_equals(command, COMMAND_WINDOW_MINIMIZE) &&
            !token_equals(command, COMMAND_WINDOW_DEMINIMIZE) &&
            !token_equals(command, COMMAND_WINDOW_TOGGLE)) {
            daemon_fail(rsp, "could not locate the window to act on!\n");
            return;
        }

        if (token_equals(command, COMMAND_WINDOW_FOCUS)) {
            int tree_direction = window_manager_find_tree_view(&g_window_manager, acting_window) ? peek_tree_direction(message) : 0;
            if (tree_direction) {
                get_token(&message);

                if (window_tree_focus(acting_window, tree_direction) != WINDOW_OP_ERROR_SUCCESS) {
                    daemon_fail(rsp, "could not locate a container to focus.\n");
                    return;
                }

                continue;
            }

            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                window_manager_focus_window_with_raise(&acting_window->application->psn, acting_window->id, acting_window->ref);
                window_manager_set_pending_focus(&g_window_manager, acting_window->id);
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_CLOSE)) {
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                if (!window_manager_close_window(acting_window)) {
                    daemon_fail(rsp, "could not close window with id '%d'.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_MINIMIZE)) {
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                enum window_op_error result = window_manager_minimize_window(acting_window);
                if (result == WINDOW_OP_ERROR_CANT_MINIMIZE) {
                    daemon_fail(rsp, "window with id '%d' does not support the minimize operation.\n", acting_window->id);
                } else if (result == WINDOW_OP_ERROR_ALREADY_MINIMIZED) {
                    daemon_fail(rsp, "window with id '%d' is already minimized.\n", acting_window->id);
                } else if (result == WINDOW_OP_ERROR_MINIMIZE_FAILED) {
                    daemon_fail(rsp, "could not minimize window with id '%d'.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_DEMINIMIZE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_deminimize_window(selector.window);
                if (result == WINDOW_OP_ERROR_NOT_MINIMIZED) {
                    daemon_fail(rsp, "window with id '%d' is not minimized.\n", selector.window->id);
                } else if (result == WINDOW_OP_ERROR_DEMINIMIZE_FAILED) {
                    daemon_fail(rsp, "could not deminimize window with id '%d'.\n", selector.window->id);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_DISPLAY)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                uint64_t sid = display_space_id(selector.did);
                if (space_is_fullscreen(sid)) {
                    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
                } else {
                    window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, sid, false);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_SPACE)) {
            struct selector selector = parse_space_selector(rsp, &message, space_manager_active_space(), false);
            if (selector.did_parse && selector.sid) {
                if (space_is_fullscreen(selector.sid)) {
                    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
                } else {
                    window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, selector.sid, false);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_SWAP)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_swap_window(&g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot swap a window with itself.\n");
                } else {
                    daemon_fail_unmanaged_window(rsp, result);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_WARP)) {
            int tree_direction = window_manager_find_tree_view(&g_window_manager, acting_window) ? peek_tree_direction(message) : 0;
            if (tree_direction > TREE_FOCUS_CHILD) {
                get_token(&message);

                if (window_manager_tree_move_direction(&g_space_manager, &g_window_manager, acting_window, tree_direction) != WINDOW_OP_ERROR_SUCCESS) {
                    daemon_fail(rsp, "could not move the container in that direction.\n");
                    return;
                }

                continue;
            }

            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_warp_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot warp a window onto itself.\n");
                } else {
                    daemon_fail_unmanaged_window(rsp, result);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_STACK)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_stack_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot stack a window onto itself.\n");
                } else {
                    daemon_fail_unmanaged_window(rsp, result);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_LAYOUT)) {
            struct token value = get_token(&message);
            int layout = parse_window_layout(value);
            if (layout == -1) {
                daemon_fail_unknown_value(rsp, domain, command, value);
                return;
            }

            daemon_fail_unmanaged_window(rsp, window_manager_set_window_layout(&g_window_manager, acting_window, layout));
        } else if (token_equals(command, COMMAND_WINDOW_SPLIT)) {
            struct token value = get_token(&message);
            int orientation;
            if (!parse_split_orientation(value, &orientation)) {
                daemon_fail_unknown_value(rsp, domain, command, value);
                return;
            }

            daemon_fail_unmanaged_window(rsp, window_manager_tree_split(&g_window_manager, acting_window, orientation));
        } else if (token_equals(command, COMMAND_WINDOW_INSERT)) {
            struct selector selector = parse_insert_selector(rsp, &message);
            if (selector.did_parse && selector.dir) {
                daemon_fail_unmanaged_window(rsp, window_manager_set_window_insertion(&g_space_manager, acting_window, selector.dir));
            }
        } else if (token_equals(command, COMMAND_WINDOW_GRID)) {
            unsigned r, c, x, y, w, h;
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_GRID, &r, &c, &x, &y, &w, &h) == 6)) {
                enum window_op_error result = window_manager_apply_grid(&g_space_manager, &g_window_manager, acting_window, r, c, x, y, w, h);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot apply grid layout to a managed window.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_MOVE)) {
            float x, y;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_MOVE, type, &x, &y) == 3)) {
                enum window_op_error result = window_manager_move_window_relative(&g_window_manager, acting_window, parse_value_type(type), x, y);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot move a managed window.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RESIZE)) {
            float w, h;
            char handle[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_RESIZE, handle, &w, &h) == 3)) {
                enum window_op_error result = window_manager_resize_window_relative(&g_window_manager, acting_window, parse_resize_handle(handle), w, h, true);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "cannot locate the container of the managed window.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_NODE) {
                    daemon_fail(rsp, "cannot resize the container in that direction.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_OPERATION) {
                    daemon_fail(rsp, "cannot use absolute resizing on a managed window.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RATIO)) {
            float r;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_RATIO, type, &r) == 2)) {
                enum window_op_error result = window_manager_adjust_window_ratio(&g_window_manager, acting_window, parse_value_type(type), r);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot adjust ratio of a non-managed window.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "cannot adjust ratio of a root node.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_TOGGLE)) {
            struct token value = get_token(&message);
            window_toggle_func *toggle = window_toggle_for_value(value);
            if (!toggle) {
                if (!window_manager_toggle_scratchpad_window_by_label(&g_window_manager, value.text)) {
                    daemon_fail_unknown_value(rsp, domain, command, value);
                }
            } else if (acting_window) {
                toggle(acting_window);
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_SUB_LAYER)) {
            struct token value = get_token(&message);
            int layer = parse_layer(value.text);
            if (layer == -1) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!window_manager_set_window_layer(acting_window, layer)) {
                daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (token_value_float(value, &opacity) && in_range_ii(opacity, 0.0f, 1.0f)) {
                if (window_manager_set_opacity(&g_window_manager, acting_window, opacity)) {
                    acting_window->opacity = opacity;
                } else {
                    daemon_fail(rsp, "could not change opacity of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RAISE) || token_equals(command, COMMAND_WINDOW_LOWER)) {
            bool raise = token_equals(command, COMMAND_WINDOW_RAISE);
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);
            uint32_t relative_wid = 0;

            if (token_is_valid(selector.token)) {
                if (!selector.did_parse || !selector.window) return;
                relative_wid = selector.window->id;
            }

            if (!scripting_addition_order_window(acting_window->id, raise ? 1 : -1, relative_wid)) {
                daemon_fail(rsp, "could not %s window with id '%d' due to an error with the scripting-addition.\n", raise ? "raise" : "lower", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_SCRATCHPAD)) {
            char *label;
            struct token token = get_token(&message);
            if (token_is_valid(token) && token_equals(token, ARGUMENT_WINDOW_SCRATCHPAD_RECOVER)) {
                window_manager_scratchpad_recover_windows();
            } else if (parse_label(rsp, token, LABEL_WINDOW, &label)) {
                if (label) {
                    if (!window_manager_set_scratchpad_for_window(&g_window_manager, acting_window, label)) {
                        daemon_fail(rsp, "the given scratchpad is already assigned to a different window!\n");
                    }
                } else {
                    if (!window_manager_remove_scratchpad_for_window(&g_window_manager, acting_window, true)) {
                        daemon_fail(rsp, "the selected window was not assigned to a scratchpad!\n");
                    }
                }
            }
        } else {
            daemon_fail_unknown_command(rsp, domain, command);
        }
    }
}

static void handle_domain_query(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_QUERY_DISPLAYS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), display_property_val, display_property_str, array_count(display_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            if (!parse_optional_display_selector(rsp, &message, &acting_did)) return;

            display_serialize(rsp, acting_did, properties.flags);
            fprintf(rsp, "\n");
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            display_serialize(rsp, space_display_id(acting_sid), properties.flags);
            fprintf(rsp, "\n");
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_acting_window(&g_window_manager);
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                display_serialize(rsp, window_display_id(acting_window->id), properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not find window to retrieve display details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
        } else {
            display_manager_query_displays(rsp, properties.flags);
        }
    } else if (token_equals(command, COMMAND_QUERY_SPACES)) {
        struct properties properties = parse_properties(rsp, get_token(&message), space_property_val, space_property_str, array_count(space_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            if (!parse_optional_display_selector(rsp, &message, &acting_did)) return;

            if (!space_manager_query_spaces_for_display(rsp, acting_did, properties.flags)) {
                daemon_fail(rsp, "could not retrieve spaces for display.\n");
            }
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            if (!space_manager_query_space(rsp, acting_sid, properties.flags)) {
                daemon_fail(rsp, "could not retrieve space details.\n");
            }
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_acting_window(&g_window_manager);
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                space_manager_query_spaces_for_window(rsp, acting_window, properties.flags);
            } else {
                daemon_fail(rsp, "could not find window to retrieve space details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
        } else if (!space_manager_query_spaces_for_displays(rsp, properties.flags)) {
            daemon_fail(rsp, "could not retrieve spaces for displays.\n");
        }
    } else if (token_equals(command, COMMAND_QUERY_WINDOWS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), window_property_val, window_property_str, array_count(window_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            if (!parse_optional_display_selector(rsp, &message, &acting_did)) return;

            window_manager_query_windows_for_display(rsp, acting_did, properties.flags);
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            window_manager_query_windows_for_spaces(rsp, &acting_sid, 1, properties.flags);
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_acting_window(&g_window_manager);
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                window_serialize(rsp, acting_window, properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not retrieve window details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
        } else {
            window_manager_query_windows_for_displays(rsp, properties.flags);
        }
    } else if (token_equals(command, COMMAND_QUERY_TREE)) {
        uint64_t acting_sid = space_manager_active_space();
        struct token option = get_token(&message);

        if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
            return;
        }

        struct view *view = space_manager_find_view(&g_space_manager, acting_sid);
        if (!view || !tree_serialize(rsp, view)) {
            daemon_fail(rsp, "the selected space does not use the tree layout.\n");
        }
    } else {
        daemon_fail_unknown_command(rsp, domain, command);
    }
}

static bool parse_rule_pattern(struct rule *rule, char *value, bool exclusion, char **pattern, regex_t *regex, enum rule_flag valid_flag, enum rule_flag exclude_flag)
{
    *pattern = string_copy(value);
    if (exclusion) rule_set_flag(rule, exclude_flag);
    if (regcomp(regex, value, REG_EXTENDED) != 0) return false;

    rule_set_flag(rule, valid_flag);
    return true;
}

static bool parse_rule_prop(char *value, int *prop)
{
    if (string_equals(value, ARGUMENT_COMMON_VAL_ON)) {
        *prop = RULE_PROP_ON;
    } else if (string_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        *prop = RULE_PROP_OFF;
    } else {
        return false;
    }

    return true;
}

static bool parse_rule(FILE *rsp, char **message, struct rule *rule, struct token token)
{
    TIME_FUNCTION;

    char *unsupported_exclusion = NULL;
    bool did_parse = true;
    bool has_filter = false;

    for (; token_is_valid(token); token = get_token(message)) {
        char *key = NULL;
        char *value = NULL;
        bool exclusion = false;
        parse_key_value_pair(token.text, &key, &value, &exclusion);

        if (!key || !value) {
            daemon_fail(rsp, "invalid key-value pair '%s'\n", token.text);
            did_parse = false;
            continue;
        }

        bool is_filter = false;
        bool valid_value = true;
        bool valid_pattern = true;

        if (string_equals(key, ARGUMENT_RULE_KEY_LABEL)) {
            rule->label = string_copy(value);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SCRATCHPAD)) {
            for (int i = 0; i < array_count(reserved_window_identifiers); ++i) {
                if (string_equals(value, reserved_window_identifiers[i])) {
                    valid_value = false;
                    break;
                }
            }

            if (valid_value) {
                rule->effects.scratchpad = string_copy(value);
                rule->effects.manage = RULE_PROP_OFF;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_APP)) {
            is_filter = true;
            valid_pattern = parse_rule_pattern(rule, value, exclusion, &rule->app, &rule->app_regex, RULE_APP_VALID, RULE_APP_EXCLUDE);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_TITLE)) {
            is_filter = true;
            valid_pattern = parse_rule_pattern(rule, value, exclusion, &rule->title, &rule->title_regex, RULE_TITLE_VALID, RULE_TITLE_EXCLUDE);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_ROLE)) {
            is_filter = true;
            valid_pattern = parse_rule_pattern(rule, value, exclusion, &rule->role, &rule->role_regex, RULE_ROLE_VALID, RULE_ROLE_EXCLUDE);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SUBROLE)) {
            is_filter = true;
            valid_pattern = parse_rule_pattern(rule, value, exclusion, &rule->subrole, &rule->subrole_regex, RULE_SUBROLE_VALID, RULE_SUBROLE_EXCLUDE);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_DISPLAY)) {
            if (value[0] == ARGUMENT_RULE_VALUE_SPACE) {
                ++value;
                rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
            }

            struct selector selector = parse_display_selector(rsp, &value, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                rule->effects.did = selector.did;
            } else {
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SPACE)) {
            if (value[0] == ARGUMENT_RULE_VALUE_SPACE) {
                ++value;
                rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
            }

            struct selector selector = parse_space_selector(rsp, &value, space_manager_active_space(), false);
            if (selector.did_parse && selector.sid) {
                rule->effects.sid = selector.sid;
            } else {
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_GRID)) {
            valid_value = sscanf(value, ARGUMENT_RULE_VALUE_GRID,
                                 &rule->effects.grid[0], &rule->effects.grid[1],
                                 &rule->effects.grid[2], &rule->effects.grid[3],
                                 &rule->effects.grid[4], &rule->effects.grid[5]) == 6;
        } else if (string_equals(key, ARGUMENT_RULE_KEY_OPACITY)) {
            valid_value = (sscanf(value, "%f", &rule->effects.opacity) == 1) && (in_range_ii(rule->effects.opacity, 0.0f, 1.0f));
            if (valid_value) rule_effects_set_flag(&rule->effects, RULE_OPACITY);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_MANAGE)) {
            valid_value = parse_rule_prop(value, &rule->effects.manage);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_STICKY)) {
            valid_value = parse_rule_prop(value, &rule->effects.sticky);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_MFF)) {
            valid_value = parse_rule_prop(value, &rule->effects.mff);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_FULLSCR)) {
            valid_value = parse_rule_prop(value, &rule->effects.fullscreen);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SUB_LAYER)) {
            int layer = parse_layer(value);
            valid_value = layer != -1;
            if (valid_value) {
                rule->effects.layer = layer;
                rule_effects_set_flag(&rule->effects, RULE_LAYER);
            }
        } else {
            daemon_fail(rsp, "unknown key '%s'\n", key);
            did_parse = false;
            continue;
        }

        has_filter |= is_filter;
        if (exclusion && !is_filter) unsupported_exclusion = key;

        if (!valid_value) {
            daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
            did_parse = false;
        }

        if (!valid_pattern) {
            daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
            did_parse = false;
        }
    }

    if (!has_filter) {
        daemon_fail(rsp, "missing required key-value pair 'app[!]=..' or 'title[!]=..'\n");
        did_parse = false;
    }

    if (unsupported_exclusion) {
        daemon_fail(rsp, "unsupported token '!' (exclusion) given for key '%s'\n", unsupported_exclusion);
        did_parse = false;
    }

    return did_parse;
}

static void handle_domain_rule(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_RULE_ADD)) {
        struct rule rule = {0};

        struct token token = get_token(&message);
        if (token_equals(token, ARGUMENT_RULE_ONE_SHOT)) {
            rule_set_flag(&rule, RULE_ONE_SHOT);
            token = get_token(&message);
        }

        if (parse_rule(rsp, &message, &rule, token)) {
            rule_add(&rule);
        } else {
            rule_destroy(&rule);
        }
    } else if (token_equals(command, COMMAND_RULE_APPLY)) {
        struct token_value value = token_to_value(get_token(&message));
        if (value.type == TOKEN_TYPE_INT) {
            if (!rule_reapply_by_index(value.int_value)) {
                daemon_fail(rsp, "rule with index '%d' not found.\n", value.int_value);
            }
        } else if (value.type == TOKEN_TYPE_STRING) {
            if (!rule_reapply_by_label(value.string_value)) {
                struct rule rule = {0};
                if (parse_rule(rsp, &message, &rule, value.token)) {
                    rule_apply(&rule);
                }
                rule_destroy(&rule);
            }
        } else if (value.type == TOKEN_TYPE_INVALID) {
            rule_reapply_all();
        } else {
            daemon_fail(rsp, "value '%.*s' is not a valid option for RULE_SEL\n", value.token.length, value.token.text);
        }
    } else if (token_equals(command, COMMAND_RULE_REM)) {
        struct token_value value = token_to_value(get_token(&message));
        if (value.type == TOKEN_TYPE_INT) {
            if (!rule_remove_by_index(value.int_value)) {
                daemon_fail(rsp, "rule with index '%d' not found.\n", value.int_value);
            }
        } else if (value.type == TOKEN_TYPE_STRING) {
            if (!rule_remove_by_label(value.string_value)) {
                daemon_fail(rsp, "rule with label '%s' not found.\n", value.string_value);
            }
        } else {
            daemon_fail(rsp, "value '%.*s' is not a valid option for RULE_SEL\n", value.token.length, value.token.text);
        }
    } else if (token_equals(command, COMMAND_RULE_LS)) {
        window_manager_query_window_rules(rsp);
    } else {
        daemon_fail_unknown_command(rsp, domain, command);
    }
}

static bool parse_signal(FILE *rsp, char **message, struct signal *signal, enum signal_type *signal_type)
{
    char *unsupported_exclusion = NULL;
    bool did_parse = true;
    bool has_signal_type = false;
    *signal_type = SIGNAL_TYPE_UNKNOWN;

    for (struct token token = get_token(message); token_is_valid(token); token = get_token(message)) {
        char *key = NULL;
        char *value = NULL;
        bool exclusion = false;
        parse_key_value_pair(token.text, &key, &value, &exclusion);

        if (!key || !value) {
            daemon_fail(rsp, "invalid key-value pair '%s'\n", token.text);
            did_parse = false;
            continue;
        }

        bool is_filter = false;
        bool valid_value = true;
        bool valid_pattern = true;

        if (string_equals(key, ARGUMENT_SIGNAL_KEY_LABEL)) {
            signal->label = string_copy(value);
        } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_APP)) {
            is_filter = true;
            signal->app = string_copy(value);
            signal->app_regex_exclude = exclusion;
            valid_pattern = signal->app_regex_valid = regcomp(&signal->app_regex, value, REG_EXTENDED) == 0;
        } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_TITLE)) {
            is_filter = true;
            signal->title = string_copy(value);
            signal->title_regex_exclude = exclusion;
            valid_pattern = signal->title_regex_valid = regcomp(&signal->title_regex, value, REG_EXTENDED) == 0;
        } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_ACTIVE)) {
            if (string_equals(value, ARGUMENT_SIGNAL_VALUE_YES)) {
                signal->active = SIGNAL_PROP_YES;
            } else if (string_equals(value, ARGUMENT_SIGNAL_VALUE_NO)) {
                signal->active = SIGNAL_PROP_NO;
            } else {
                valid_value = false;
            }
        } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_ACTION)) {
            signal->command = string_copy(value);
        } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_EVENT)) {
            has_signal_type = true;
            *signal_type = signal_type_from_string(value);
            valid_value = *signal_type != SIGNAL_TYPE_UNKNOWN;
        } else {
            daemon_fail(rsp, "unknown key '%s'\n", key);
            did_parse = false;
            continue;
        }

        if (exclusion && !is_filter) unsupported_exclusion = key;

        if (!valid_value) {
            daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
            did_parse = false;
        }

        if (!valid_pattern) {
            daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
            did_parse = false;
        }
    }

    if (!has_signal_type) {
        daemon_fail(rsp, "missing required key-value pair 'event=..'\n");
        did_parse = false;
    }

    if (!signal->command) {
        daemon_fail(rsp, "missing required key-value pair 'action=..'\n");
        did_parse = false;
    }

    if (unsupported_exclusion) {
        daemon_fail(rsp, "unsupported token '!' (exclusion) given for key '%s'\n", unsupported_exclusion);
        did_parse = false;
    }

    return did_parse;
}

static void handle_domain_signal(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_SIGNAL_ADD)) {
        struct signal signal = {0};
        enum signal_type signal_type;

        if (parse_signal(rsp, &message, &signal, &signal_type)) {
            event_signal_add(signal_type, &signal);
        } else {
            event_signal_destroy(&signal);
        }
    } else if (token_equals(command, COMMAND_SIGNAL_REM)) {
        struct token_value value = token_to_value(get_token(&message));
        if (value.type == TOKEN_TYPE_INT) {
            if (!event_signal_remove_by_index(value.int_value)) {
                daemon_fail(rsp, "signal with index '%d' not found.\n", value.int_value);
            }
        } else if (value.type == TOKEN_TYPE_STRING) {
            if (!event_signal_remove(value.string_value)) {
                daemon_fail(rsp, "signal with label '%s' not found.\n", value.string_value);
            }
        } else {
            daemon_fail(rsp, "value '%.*s' is not a valid option for SIGNAL_SEL\n", value.token.length, value.token.text);
        }
    } else if (token_equals(command, COMMAND_SIGNAL_LS)) {
        event_signal_list(rsp);
    } else {
        daemon_fail_unknown_command(rsp, domain, command);
    }
}

void handle_message(FILE *rsp, char *message)
{
    struct token domain = get_token(&message);
    if (token_equals(domain, DOMAIN_CONFIG)) {
        handle_domain_config(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_DISPLAY)) {
        handle_domain_display(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_SPACE)) {
        handle_domain_space(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_WINDOW)) {
        handle_domain_window(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_QUERY)) {
        handle_domain_query(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_RULE)) {
        handle_domain_rule(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_SIGNAL)) {
        handle_domain_signal(rsp, domain, message);
    } else {
        daemon_fail(rsp, "unknown domain '%.*s'\n", domain.length, domain.text);
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static void *message_loop_run(void *context)
{
    while (g_message_loop.is_running) {
        int sockfd = accept(g_message_loop.sockfd, NULL, 0);
        if (sockfd == -1) continue;

        //
        // NOTE: The message is read and the response written on the event loop thread. A client that
        // stalls must not be able to block it, so reads and writes on the socket time out.
        //

        struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        event_loop_post(&g_event_loop, DAEMON_MESSAGE, NULL, sockfd);
    }

    return NULL;
}
#pragma clang diagnostic pop

bool message_loop_begin(char *socket_path)
{
    struct sockaddr_un socket_address;
    socket_address.sun_family = AF_UNIX;
    snprintf(socket_address.sun_path, sizeof(socket_address.sun_path), "%s", socket_path);
    unlink(socket_path);

    if ((g_message_loop.sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        return false;
    }

    if (bind(g_message_loop.sockfd, (struct sockaddr *) &socket_address, sizeof(socket_address)) == -1) {
        return false;
    }

    if (chmod(socket_path, 0600) != 0) {
        return false;
    }

    if (listen(g_message_loop.sockfd, SOMAXCONN) == -1) {
        return false;
    }

    fcntl(g_message_loop.sockfd, F_SETFD, FD_CLOEXEC | fcntl(g_message_loop.sockfd, F_GETFD));

    g_message_loop.is_running = true;
    pthread_create(&g_message_loop.thread, NULL, &message_loop_run, NULL);

    return true;
}
