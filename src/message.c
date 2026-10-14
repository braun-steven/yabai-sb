extern struct event_loop g_event_loop;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern bool g_verbose;

void handle_domain_query(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_QUERY_DISPLAYS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), display_property_val, display_property_str, array_count(display_property_str));
        if (properties.did_error) return;

        struct query_target target;
        if (!parse_query_target(rsp, domain, command, &message, properties, &target)) return;

        switch (target.type) {
        case QUERY_TARGET_ALL:     display_manager_query_displays(rsp, properties.flags); break;
        case QUERY_TARGET_DISPLAY: display_serialize(rsp, target.did, properties.flags); fprintf(rsp, "\n"); break;
        case QUERY_TARGET_SPACE:   display_serialize(rsp, space_display_id(target.sid), properties.flags); fprintf(rsp, "\n"); break;
        case QUERY_TARGET_WINDOW: {
            if (target.window) {
                display_serialize(rsp, window_display_id(target.window->id), properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not find window to retrieve display details.\n");
            }
        } break;
        }
    } else if (token_equals(command, COMMAND_QUERY_SPACES)) {
        struct properties properties = parse_properties(rsp, get_token(&message), space_property_val, space_property_str, array_count(space_property_str));
        if (properties.did_error) return;

        struct query_target target;
        if (!parse_query_target(rsp, domain, command, &message, properties, &target)) return;

        switch (target.type) {
        case QUERY_TARGET_ALL: {
            if (!space_manager_query_spaces_for_displays(rsp, properties.flags)) daemon_fail(rsp, "could not retrieve spaces for displays.\n");
        } break;
        case QUERY_TARGET_DISPLAY: {
            if (!space_manager_query_spaces_for_display(rsp, target.did, properties.flags)) daemon_fail(rsp, "could not retrieve spaces for display.\n");
        } break;
        case QUERY_TARGET_SPACE: {
            if (!space_manager_query_space(rsp, target.sid, properties.flags)) daemon_fail(rsp, "could not retrieve space details.\n");
        } break;
        case QUERY_TARGET_WINDOW: {
            if (target.window) {
                space_manager_query_spaces_for_window(rsp, target.window, properties.flags);
            } else {
                daemon_fail(rsp, "could not find window to retrieve space details.\n");
            }
        } break;
        }
    } else if (token_equals(command, COMMAND_QUERY_WINDOWS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), window_property_val, window_property_str, array_count(window_property_str));
        if (properties.did_error) return;

        struct query_target target;
        if (!parse_query_target(rsp, domain, command, &message, properties, &target)) return;

        switch (target.type) {
        case QUERY_TARGET_ALL:     window_manager_query_windows_for_displays(rsp, properties.flags); break;
        case QUERY_TARGET_DISPLAY: window_manager_query_windows_for_display(rsp, target.did, properties.flags); break;
        case QUERY_TARGET_SPACE:   window_manager_query_windows_for_spaces(rsp, &target.sid, 1, properties.flags); break;
        case QUERY_TARGET_WINDOW: {
            if (target.window) {
                window_serialize(rsp, target.window, properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not retrieve window details.\n");
            }
        } break;
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

void handle_domain_rule(FILE *rsp, struct token domain, char *message)
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

void handle_domain_signal(FILE *rsp, struct token domain, char *message)
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
