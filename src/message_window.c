//
// NOTE: The handler of the window domain. Its commands are grouped by what they change: the lifecycle
// of a window, its placement, its tree container, its frame and its properties.
//

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

//
// NOTE: The functions of the values of 'window --toggle', in the order of WindowToggle (Sources/YabaiCore/MessageParse.swift),
// whose index window_toggle_index returns.
//

static window_toggle_func *window_toggle_list[] =
{
    window_toggle_float,
    window_toggle_sticky,
    window_manager_toggle_window_shadow,
    window_toggle_split,
    window_toggle_zoom_parent,
    window_toggle_zoom_fullscreen,
    window_manager_toggle_window_windowed_fullscreen,
    window_manager_toggle_window_native_fullscreen,
    window_manager_toggle_window_expose,
    window_toggle_pip
};

//
// NOTE: Returns NULL when value is not a window property, so that it can be a scratchpad label.
//

static window_toggle_func *window_toggle_for_value(struct token value)
{
    int index = window_toggle_index(value);
    return index >= 0 && index < array_count(window_toggle_list) ? window_toggle_list[index] : NULL;
}

//
// NOTE: Focusing, closing, minimizing and deminimizing windows.
//

static enum command_result window_command_lifecycle(FILE *rsp, __unused struct token domain, struct token command, char **message, struct window **acting_window)
{
    struct window *window = *acting_window;

    if (token_equals(command, COMMAND_WINDOW_FOCUS)) {
        int tree_direction = window_manager_find_tree_view(&g_window_manager, window) ? peek_tree_direction(*message) : 0;
        if (tree_direction) {
            get_token(message);

            if (window_tree_focus(window, tree_direction) != WINDOW_OP_ERROR_SUCCESS) {
                daemon_fail(rsp, "could not locate a container to focus.\n");
                return COMMAND_STOP;
            }

            return COMMAND_DONE;
        }

        if (!parse_optional_window_selector(rsp, message, acting_window)) return COMMAND_STOP;
        window = *acting_window;

        if (window) {
            window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
            window_manager_set_pending_focus(&g_window_manager, window->id);
        } else {
            daemon_fail(rsp, "could not locate the window to act on!\n");
        }
    } else if (token_equals(command, COMMAND_WINDOW_CLOSE)) {
        if (!parse_optional_window_selector(rsp, message, acting_window)) return COMMAND_STOP;
        window = *acting_window;

        if (window) {
            if (!window_manager_close_window(window)) {
                daemon_fail(rsp, "could not close window with id '%d'.\n", window->id);
            }
        } else {
            daemon_fail(rsp, "could not locate the window to act on!\n");
        }
    } else if (token_equals(command, COMMAND_WINDOW_MINIMIZE)) {
        if (!parse_optional_window_selector(rsp, message, acting_window)) return COMMAND_STOP;
        window = *acting_window;

        if (window) {
            enum window_op_error result = window_manager_minimize_window(window);
            if (result == WINDOW_OP_ERROR_CANT_MINIMIZE) {
                daemon_fail(rsp, "window with id '%d' does not support the minimize operation.\n", window->id);
            } else if (result == WINDOW_OP_ERROR_ALREADY_MINIMIZED) {
                daemon_fail(rsp, "window with id '%d' is already minimized.\n", window->id);
            } else if (result == WINDOW_OP_ERROR_MINIMIZE_FAILED) {
                daemon_fail(rsp, "could not minimize window with id '%d'.\n", window->id);
            }
        } else {
            daemon_fail(rsp, "could not locate the window to act on!\n");
        }
    } else if (token_equals(command, COMMAND_WINDOW_DEMINIMIZE)) {
        struct selector selector = parse_window_selector(rsp, message, window, false);
        if (selector.did_parse && selector.window) {
            enum window_op_error result = window_manager_deminimize_window(selector.window);
            if (result == WINDOW_OP_ERROR_NOT_MINIMIZED) {
                daemon_fail(rsp, "window with id '%d' is not minimized.\n", selector.window->id);
            } else if (result == WINDOW_OP_ERROR_DEMINIMIZE_FAILED) {
                daemon_fail(rsp, "could not deminimize window with id '%d'.\n", selector.window->id);
            }
        }
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
}

//
// NOTE: Moving a window to another display, space or position in the tree.
//

static enum command_result window_command_placement(FILE *rsp, __unused struct token domain, struct token command, char **message, struct window *acting_window)
{
    if (token_equals(command, COMMAND_WINDOW_DISPLAY)) {
        struct selector selector = parse_display_selector(rsp, message, display_manager_active_display_id(), false);
        if (selector.did_parse && selector.did) {
            uint64_t sid = display_space_id(selector.did);
            if (space_is_fullscreen(sid)) {
                daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
            } else {
                window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, sid, false);
            }
        }
    } else if (token_equals(command, COMMAND_WINDOW_SPACE)) {
        struct selector selector = parse_space_selector(rsp, message, space_manager_active_space(), false);
        if (selector.did_parse && selector.sid) {
            if (space_is_fullscreen(selector.sid)) {
                daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
            } else {
                window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, selector.sid, false);
            }
        }
    } else if (token_equals(command, COMMAND_WINDOW_SWAP)) {
        struct selector selector = parse_window_selector(rsp, message, acting_window, false);
        if (selector.did_parse && selector.window) {
            enum window_op_error result = window_manager_swap_window(&g_window_manager, acting_window, selector.window);
            if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                daemon_fail(rsp, "cannot swap a window with itself.\n");
            } else {
                daemon_fail_unmanaged_window(rsp, result);
            }
        }
    } else if (token_equals(command, COMMAND_WINDOW_WARP)) {
        int tree_direction = window_manager_find_tree_view(&g_window_manager, acting_window) ? peek_tree_direction(*message) : 0;
        if (tree_direction > TREE_FOCUS_CHILD) {
            get_token(message);

            if (window_manager_tree_move_direction(&g_space_manager, &g_window_manager, acting_window, tree_direction) != WINDOW_OP_ERROR_SUCCESS) {
                daemon_fail(rsp, "could not move the container in that direction.\n");
                return COMMAND_STOP;
            }

            return COMMAND_DONE;
        }

        struct selector selector = parse_window_selector(rsp, message, acting_window, false);
        if (selector.did_parse && selector.window) {
            enum window_op_error result = window_manager_warp_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
            if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                daemon_fail(rsp, "cannot warp a window onto itself.\n");
            } else {
                daemon_fail_unmanaged_window(rsp, result);
            }
        }
    } else if (token_equals(command, COMMAND_WINDOW_STACK)) {
        struct selector selector = parse_window_selector(rsp, message, acting_window, false);
        if (selector.did_parse && selector.window) {
            enum window_op_error result = window_manager_stack_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
            if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                daemon_fail(rsp, "cannot stack a window onto itself.\n");
            } else {
                daemon_fail_unmanaged_window(rsp, result);
            }
        }
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
}

//
// NOTE: The container of a window in the tree.
//

static enum command_result window_command_tree(FILE *rsp, struct token domain, struct token command, char **message, struct window *acting_window)
{
    if (token_equals(command, COMMAND_WINDOW_LAYOUT)) {
        struct token value = get_token(message);
        int layout = parse_window_layout(value);
        if (layout == -1) {
            daemon_fail_unknown_value(rsp, domain, command, value);
            return COMMAND_STOP;
        }

        daemon_fail_unmanaged_window(rsp, window_manager_set_window_layout(&g_window_manager, acting_window, layout));
    } else if (token_equals(command, COMMAND_WINDOW_SPLIT)) {
        struct token value = get_token(message);
        int orientation;
        if (!parse_split_orientation(value, &orientation)) {
            daemon_fail_unknown_value(rsp, domain, command, value);
            return COMMAND_STOP;
        }

        daemon_fail_unmanaged_window(rsp, window_manager_tree_split(&g_window_manager, acting_window, orientation));
    } else if (token_equals(command, COMMAND_WINDOW_INSERT)) {
        struct selector selector = parse_insert_selector(rsp, message);
        if (selector.did_parse && selector.dir) {
            daemon_fail_unmanaged_window(rsp, window_manager_set_window_insertion(&g_space_manager, acting_window, selector.dir));
        }
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
}

//
// NOTE: The frame of a floating window and the share of a tiled one.
//

static enum command_result window_command_frame(FILE *rsp, struct token domain, struct token command, char **message, struct window *acting_window)
{
    if (token_equals(command, COMMAND_WINDOW_GRID)) {
        unsigned r, c, x, y, w, h;
        struct token value = get_token(message);
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
        struct token value = get_token(message);
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
        struct token value = get_token(message);
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
        struct token value = get_token(message);
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
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
}

//
// NOTE: Window properties: toggles, layer, opacity, order and scratchpads.
//

static enum command_result window_command_property(FILE *rsp, struct token domain, struct token command, char **message, struct window *acting_window)
{
    if (token_equals(command, COMMAND_WINDOW_TOGGLE)) {
        struct token value = get_token(message);
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
        struct token value = get_token(message);
        int layer = parse_layer(value.text);
        if (layer == -1) {
            daemon_fail_unknown_value(rsp, domain, command, value);
        } else if (!window_manager_set_window_layer(acting_window, layer)) {
            daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
        }
    } else if (token_equals(command, COMMAND_WINDOW_OPACITY)) {
        struct token_value value = token_to_value(get_token(message));
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
        struct selector selector = parse_window_selector(rsp, message, acting_window, true);
        uint32_t relative_wid = 0;

        if (token_is_valid(selector.token)) {
            if (!selector.did_parse || !selector.window) return COMMAND_STOP;
            relative_wid = selector.window->id;
        }

        if (!scripting_addition_order_window(acting_window->id, raise ? 1 : -1, relative_wid)) {
            daemon_fail(rsp, "could not %s window with id '%d' due to an error with the scripting-addition.\n", raise ? "raise" : "lower", acting_window->id);
        }
    } else if (token_equals(command, COMMAND_WINDOW_SCRATCHPAD)) {
        char *label;
        struct token token = get_token(message);
        if (token_is_valid(token) && token_equals(token, ARGUMENT_WINDOW_SCRATCHPAD_RECOVER)) {
            window_manager_scratchpad_recover_windows();
        } else if (parse_label(rsp, token, LABEL_WINDOW, &label)) {
            if (label) {
                if (!window_manager_set_scratchpad_for_window(&g_window_manager, acting_window, label)) {
                    free(label);
                    daemon_fail(rsp, "the given scratchpad is already assigned to a different window!\n");
                }
            } else {
                if (!window_manager_remove_scratchpad_for_window(&g_window_manager, acting_window, true)) {
                    daemon_fail(rsp, "the selected window was not assigned to a scratchpad!\n");
                }
            }
        }
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
}

void handle_domain_window(FILE *rsp, struct token domain, char *message)
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

        enum command_result result = window_command_lifecycle(rsp, domain, command, &message, &acting_window);
        if (result == COMMAND_UNKNOWN) result = window_command_placement(rsp, domain, command, &message, acting_window);
        if (result == COMMAND_UNKNOWN) result = window_command_tree(rsp, domain, command, &message, acting_window);
        if (result == COMMAND_UNKNOWN) result = window_command_frame(rsp, domain, command, &message, acting_window);
        if (result == COMMAND_UNKNOWN) result = window_command_property(rsp, domain, command, &message, acting_window);

        if (result == COMMAND_STOP) return;
        if (result == COMMAND_UNKNOWN) daemon_fail_unknown_command(rsp, domain, command);
    }
}
