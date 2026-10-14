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

enum query_target_type
{
    QUERY_TARGET_ALL,
    QUERY_TARGET_DISPLAY,
    QUERY_TARGET_SPACE,
    QUERY_TARGET_WINDOW
};

struct query_target
{
    enum query_target_type type;
    uint32_t did;
    uint64_t sid;
    struct window *window;
};

//
// NOTE: The optional '--display|--space|--window [SEL]' of a query, which defaults to the active one.
// Without the option a query covers everything. Returns false when the option or its selector is invalid.
//

static bool parse_query_target(FILE *rsp, struct token domain, struct token command, char **message, struct properties properties, struct query_target *target)
{
    struct token option = properties.did_parse ? get_token(message) : properties.token;
    memset(target, 0, sizeof(struct query_target));

    if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
        target->type = QUERY_TARGET_DISPLAY;
        target->did = display_manager_active_display_id();
        return parse_optional_display_selector(rsp, message, &target->did);
    }

    if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
        target->type = QUERY_TARGET_SPACE;
        target->sid = space_manager_active_space();
        return parse_optional_space_selector(rsp, message, &target->sid);
    }

    if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
        target->type = QUERY_TARGET_WINDOW;
        target->window = window_manager_acting_window(&g_window_manager);
        return parse_optional_window_selector(rsp, message, &target->window);
    }

    if (token_is_valid(option)) {
        daemon_fail_unknown_option(rsp, domain, command, option);
        return false;
    }

    target->type = QUERY_TARGET_ALL;
    return true;
}

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

//
// NOTE: When a key is given more than once, the last value wins; the earlier one is freed.
//

static void parse_rule_string(char **field, char *value)
{
    if (*field) free(*field);
    *field = string_copy(value);
}

static bool parse_rule_pattern(struct rule *rule, char *value, bool exclusion, char **pattern, regex_t *regex, enum rule_flag valid_flag, enum rule_flag exclude_flag)
{
    if (rule_check_flag(rule, valid_flag)) regfree(regex);
    rule_clear_flag(rule, valid_flag | exclude_flag);

    parse_rule_string(pattern, value);
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

//
// NOTE: A display or space value that starts with '^' also makes the window's space follow (focus) it.
//

static char *parse_rule_follow_prefix(struct rule *rule, char *value)
{
    if (value[0] != ARGUMENT_RULE_VALUE_SPACE) return value;

    rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
    return value + 1;
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
            parse_rule_string(&rule->label, value);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SCRATCHPAD)) {
            valid_value = !label_is_reserved(LABEL_WINDOW, (struct token) { .text = value, .length = strlen(value) });
            if (valid_value) {
                parse_rule_string(&rule->effects.scratchpad, value);
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
            value = parse_rule_follow_prefix(rule, value);
            struct selector selector = parse_display_selector(rsp, &value, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                rule->effects.did = selector.did;
            } else {
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SPACE)) {
            value = parse_rule_follow_prefix(rule, value);
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
