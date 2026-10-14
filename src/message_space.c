//
// NOTE: The handlers of the display and space domains.
//

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
                label_set(&g_display_manager.labels, acting_did, label);
            } else {
                if (!label_remove_id(&g_display_manager.labels, acting_did)) {
                    daemon_fail(rsp, "the selected display was not associated with a label!\n");
                }
            }
        }
    } else {
        daemon_fail_unknown_command(rsp, domain, command);
    }
}

//
// NOTE: A command of a domain is either unknown to a group of commands, done, or failed in a way that
// stops the remaining commands of the message.
//

enum command_result
{
    COMMAND_UNKNOWN,
    COMMAND_DONE,
    COMMAND_STOP
};

//
// NOTE: Focusing, moving, swapping, creating and destroying spaces.
//

static enum command_result space_command_arrange(FILE *rsp, __unused struct token domain, struct token command, char **message, uint64_t *acting_sid)
{
    if (token_equals(command, COMMAND_SPACE_FOCUS) || token_equals(command, COMMAND_SPACE_SWITCH)) {
        struct selector selector = parse_space_selector(rsp, message, *acting_sid, false);
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
        struct selector selector = parse_space_selector(rsp, message, *acting_sid, false);
        if (selector.did_parse && selector.sid) {
            enum space_op_error result = space_manager_move_space_to_space(*acting_sid, selector.sid);
            if (result == SPACE_OP_ERROR_SAME_SPACE) {
                daemon_fail(rsp, "cannot move space to itself.\n");
            } else if (result == SPACE_OP_ERROR_SAME_DISPLAY) {
                daemon_fail(rsp, "cannot move space across display boundaries. use --display instead.\n");
            } else {
                daemon_fail_space_op(rsp, result, "move space");
            }
        }
    } else if (token_equals(command, COMMAND_SPACE_SWAP)) {
        struct selector selector = parse_space_selector(rsp, message, *acting_sid, false);
        if (selector.did_parse && selector.sid) {
            enum space_op_error result = space_manager_swap_space_with_space(*acting_sid, selector.sid);
            if (result == SPACE_OP_ERROR_SAME_SPACE) {
                daemon_fail(rsp, "cannot swap space with itself.\n");
            } else {
                daemon_fail_space_op(rsp, result, "swap space");
            }
        }
    } else if (token_equals(command, COMMAND_SPACE_DISPLAY)) {
        struct selector selector = parse_display_selector(rsp, message, display_manager_active_display_id(), false);
        if (selector.did_parse && selector.did) {
            enum space_op_error result = space_manager_move_space_to_display(&g_space_manager, *acting_sid, selector.did);
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
        struct selector selector = parse_display_selector(rsp, message, display_manager_active_display_id(), true);

        if (token_is_valid(selector.token)) {
            if (selector.did_parse && selector.did) {
                *acting_sid = display_space_id(selector.did);
            } else {
                return COMMAND_STOP;
            }
        }

        enum space_op_error result = space_manager_add_space(*acting_sid);
        if (result == SPACE_OP_ERROR_MISSING_SRC) {
            daemon_fail(rsp, "could not locate the space to act on.\n");
        } else {
            daemon_fail_space_op(rsp, result, "create space");
        }
    } else if (token_equals(command, COMMAND_SPACE_DESTROY)) {
        if (!parse_optional_space_selector(rsp, message, acting_sid)) return COMMAND_STOP;

        enum space_op_error result = space_manager_destroy_space(*acting_sid);
        if (result == SPACE_OP_ERROR_MISSING_SRC) {
            daemon_fail(rsp, "could not locate the space to act on.\n");
        } else if (result == SPACE_OP_ERROR_INVALID_SRC) {
            daemon_fail(rsp, "acting space is the last user-space on the source display and cannot be destroyed.\n");
        } else if (result == SPACE_OP_ERROR_INVALID_TYPE) {
            daemon_fail(rsp, "cannot destroy a macOS fullscreen space.\n");
        } else {
            daemon_fail_space_op(rsp, result, "destroy space");
        }
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
}

//
// NOTE: The layout, padding, gap and label of a space.
//

static enum command_result space_command_layout(FILE *rsp, struct token domain, struct token command, char **message, uint64_t acting_sid)
{
    if (token_equals(command, COMMAND_SPACE_EQUALIZE) || token_equals(command, COMMAND_SPACE_BALANCE)) {
        //
        // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
        //

        struct token value = get_token(message);
        if (token_is_valid(value) && !token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X) && !token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
            daemon_fail_unknown_value(rsp, domain, command, value);
        } else if (!space_manager_balance_space(&g_space_manager, acting_sid)) {
            daemon_fail(rsp, "cannot %s a non-managed space.\n", token_equals(command, COMMAND_SPACE_EQUALIZE) ? "equalize" : "balance");
        }
    } else if (token_equals(command, COMMAND_SPACE_MIRROR)) {
        struct token value = get_token(message);
        enum window_split axis = token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X) ? SPLIT_X
                               : token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y) ? SPLIT_Y
                               : SPLIT_NONE;
        if (axis == SPLIT_NONE) {
            daemon_fail_unknown_value(rsp, domain, command, value);
        } else if (!space_manager_mirror_space(&g_space_manager, acting_sid, axis)) {
            daemon_fail(rsp, "cannot mirror a non-managed space.\n");
        }
    } else if (token_equals(command, COMMAND_SPACE_ROTATE)) {
        struct token value = get_token(message);
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
        struct token value = get_token(message);
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
        struct token value = get_token(message);
        if ((sscanf(value.text, ARGUMENT_SPACE_GAP, type, &gap) == 2)) {
            if (!space_manager_set_gap_for_space(&g_space_manager, acting_sid, parse_value_type(type), gap)) {
                daemon_fail(rsp, "cannot set gap for a non-managed space.\n");
            }
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value);
        }
    } else if (token_equals(command, COMMAND_SPACE_TOGGLE)) {
        struct token value = get_token(message);
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
        struct token value = get_token(message);
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
        if (parse_label(rsp, get_token(message), LABEL_SPACE, &label)) {
            if (label) {
                label_set(&g_space_manager.labels, acting_sid, label);
            } else {
                if (!label_remove_id(&g_space_manager.labels, acting_sid)) {
                    daemon_fail(rsp, "the selected space was not associated with a label!\n");
                }
            }
        }
    } else {
        return COMMAND_UNKNOWN;
    }

    return COMMAND_DONE;
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
        enum command_result result = space_command_arrange(rsp, domain, command, &message, &acting_sid);
        if (result == COMMAND_UNKNOWN) result = space_command_layout(rsp, domain, command, &message, acting_sid);

        if (result == COMMAND_STOP) return;
        if (result == COMMAND_UNKNOWN) daemon_fail_unknown_command(rsp, domain, command);
    }
}
