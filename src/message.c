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

static void handle_domain_query(FILE *rsp, struct token domain, char *message)
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
