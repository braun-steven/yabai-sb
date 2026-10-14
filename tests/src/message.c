//
// NOTE: messages are null-separated tokens that end with an empty token, as sent by the client.
//

static char message_test_response[256];

static char *message_test_run_config(char *message)
{
    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    struct token domain = { .text = DOMAIN_CONFIG, .length = sizeof(DOMAIN_CONFIG) - 1 };
    handle_domain_config(rsp, domain, message);
    fclose(rsp);
    return message_test_response;
}

static bool message_test_parse_bool(char *message, bool *flag, char **response)
{
    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    struct token domain = { .text = DOMAIN_CONFIG, .length = sizeof(DOMAIN_CONFIG) - 1 };
    struct token command = { .text = "test", .length = 4 };
    bool result = parse_config_bool(rsp, domain, command, &message, flag);
    fclose(rsp);
    *response = message_test_response;
    return result;
}

static bool message_test_parse_choice(char *message, int current, int *choice, char **response)
{
    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    struct token domain = { .text = DOMAIN_CONFIG, .length = sizeof(DOMAIN_CONFIG) - 1 };
    struct token command = { .text = "test", .length = 4 };
    bool result = parse_config_choice(rsp, domain, command, &message, mouse_mod_str, MOUSE_MOD_ALT, MOUSE_MOD_FN, current, choice);
    fclose(rsp);
    *response = message_test_response;
    return result;
}

TEST_FUNC(message_config_bool,
{
    char *response;
    bool flag = false;

    TEST_CHECK(message_test_parse_bool("on\0", &flag, &response), true);
    TEST_CHECK(flag, true);
    TEST_CHECK(response[0], '\0');

    TEST_CHECK(message_test_parse_bool("\0", &flag, &response), false);
    TEST_CHECK(strcmp(response, "on\n"), 0);

    TEST_CHECK(message_test_parse_bool("off\0", &flag, &response), true);
    TEST_CHECK(flag, false);

    TEST_CHECK(message_test_parse_bool("yes\0", &flag, &response), false);
    TEST_CHECK(flag, false);
    TEST_CHECK(strstr(response, "unknown value 'yes' given to command 'test'") != NULL, true);
});

TEST_FUNC(message_config_choice,
{
    char *response;
    int choice = 0;

    TEST_CHECK(message_test_parse_choice("cmd\0", MOUSE_MOD_ALT, &choice, &response), true);
    TEST_CHECK(choice, MOUSE_MOD_CMD);

    TEST_CHECK(message_test_parse_choice("fn\0", MOUSE_MOD_ALT, &choice, &response), true);
    TEST_CHECK(choice, MOUSE_MOD_FN);

    // NOTE: names outside of first..last are rejected, gaps of the bitmask enum are skipped
    choice = 0;
    TEST_CHECK(message_test_parse_choice("none\0", MOUSE_MOD_ALT, &choice, &response), false);
    TEST_CHECK(choice, 0);
    TEST_CHECK(strstr(response, "unknown value 'none'") != NULL, true);

    TEST_CHECK(message_test_parse_choice("\0", MOUSE_MOD_SHIFT, &choice, &response), false);
    TEST_CHECK(strcmp(response, "shift\n"), 0);
});

TEST_FUNC(message_config_options,
{
    bool mff = g_window_manager.enable_mff;
    enum mouse_mod modifier = g_mouse_state.modifier;
    enum focus_wrapping wrapping = g_window_manager.focus_wrapping;
    int top_padding = g_space_manager.top_padding;

    message_test_run_config("mouse_follows_focus\0on\0mouse_modifier\0ctrl\0focus_wrapping\0force\0");
    TEST_CHECK(g_window_manager.enable_mff, true);
    TEST_CHECK(g_mouse_state.modifier, MOUSE_MOD_CTRL);
    TEST_CHECK(g_window_manager.focus_wrapping, FOCUS_WRAPPING_FORCE);

    TEST_CHECK(strcmp(message_test_run_config("mouse_modifier\0"), "ctrl\n"), 0);
    TEST_CHECK(strcmp(message_test_run_config("focus_wrapping\0"), "force\n"), 0);

    g_space_manager.top_padding = 7;
    TEST_CHECK(strcmp(message_test_run_config("top_padding\0"), "7\n"), 0);
    TEST_CHECK(strstr(message_test_run_config("top_padding\0-1\0"), "unknown value '-1'") != NULL, true);
    TEST_CHECK(g_space_manager.top_padding, 7);

    TEST_CHECK(strstr(message_test_run_config("not_an_option\0"), "unknown command 'not_an_option'") != NULL, true);

    g_window_manager.enable_mff = mff;
    g_mouse_state.modifier = modifier;
    g_window_manager.focus_wrapping = wrapping;
    g_space_manager.top_padding = top_padding;
});

static struct token message_test_token(char *text)
{
    return (struct token) { .text = text, .length = (int) strlen(text) };
}

TEST_FUNC(message_window_toggle_lookup,
{
    TEST_CHECK(window_toggle_for_value(message_test_token("float")) == window_toggle_float, true);
    TEST_CHECK(window_toggle_for_value(message_test_token("zoom-fullscreen")) == window_toggle_zoom_fullscreen, true);
    TEST_CHECK(window_toggle_for_value(message_test_token("shadow")) == window_manager_toggle_window_shadow, true);

    // NOTE: anything else is a scratchpad label
    TEST_CHECK(window_toggle_for_value(message_test_token("notes")) == NULL, true);
    TEST_CHECK(window_toggle_for_value(message_test_token("floa")) == NULL, true);
});

static char message_test_rule_buffer[256];

static bool message_test_parse_rule(const char *message, size_t size, struct rule *rule, char **response)
{
    memcpy(message_test_rule_buffer, message, size);
    char *cursor = message_test_rule_buffer;

    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    memset(rule, 0, sizeof(struct rule));
    bool result = parse_rule(rsp, &cursor, rule, get_token(&cursor));
    fclose(rsp);
    *response = message_test_response;
    return result;
}

#define MESSAGE_TEST_RULE(m, rule, response) message_test_parse_rule(m, sizeof(m), rule, response)

TEST_FUNC(message_rule_parse,
{
    struct rule rule;
    char *response;

    TEST_CHECK(MESSAGE_TEST_RULE("app=^Safari$\0title!=Preferences\0manage=off\0sticky=on\0sub-layer=above\0opacity=0.5\0", &rule, &response), true);
    TEST_CHECK(rule_check_flag(&rule, RULE_APP_VALID) != 0, true);
    TEST_CHECK(rule_check_flag(&rule, RULE_APP_EXCLUDE) != 0, false);
    TEST_CHECK(rule_check_flag(&rule, RULE_TITLE_EXCLUDE) != 0, true);
    TEST_CHECK(rule.effects.manage, RULE_PROP_OFF);
    TEST_CHECK(rule.effects.sticky, RULE_PROP_ON);
    TEST_CHECK(rule.effects.mff, RULE_PROP_UD);
    TEST_CHECK(rule.effects.layer, LAYER_ABOVE);
    TEST_CHECK(rule_effects_check_flag(&rule.effects, RULE_LAYER), true);
    TEST_CHECK(rule_effects_check_flag(&rule.effects, RULE_OPACITY), true);
    TEST_CHECK(strcmp(rule.app, "^Safari$"), 0);
    TEST_CHECK(response[0], '\0');
    rule_destroy(&rule);

    TEST_CHECK(MESSAGE_TEST_RULE("app=x\0manage=maybe\0", &rule, &response), false);
    TEST_CHECK(strstr(response, "invalid value 'maybe' for key 'manage'") != NULL, true);
    rule_destroy(&rule);

    TEST_CHECK(MESSAGE_TEST_RULE("app=(\0", &rule, &response), false);
    TEST_CHECK(strstr(response, "invalid regex pattern '(' for key 'app'") != NULL, true);
    rule_destroy(&rule);

    TEST_CHECK(MESSAGE_TEST_RULE("app=x\0label!=y\0", &rule, &response), false);
    TEST_CHECK(strstr(response, "unsupported token '!' (exclusion) given for key 'label'") != NULL, true);
    rule_destroy(&rule);

    // NOTE: a repeated key replaces the earlier value, including its exclusion
    TEST_CHECK(MESSAGE_TEST_RULE("app!=a\0app=^b$\0label=x\0label=y\0", &rule, &response), true);
    TEST_CHECK(strcmp(rule.app, "^b$"), 0);
    TEST_CHECK(rule_check_flag(&rule, RULE_APP_VALID) != 0, true);
    TEST_CHECK(rule_check_flag(&rule, RULE_APP_EXCLUDE) != 0, false);
    TEST_CHECK(strcmp(rule.label, "y"), 0);
    rule_destroy(&rule);

    TEST_CHECK(MESSAGE_TEST_RULE("app=x\0app=(\0", &rule, &response), false);
    TEST_CHECK(rule_check_flag(&rule, RULE_APP_VALID) != 0, false);
    rule_destroy(&rule);

    TEST_CHECK(MESSAGE_TEST_RULE("manage=on\0colour=red\0", &rule, &response), false);
    TEST_CHECK(strstr(response, "unknown key 'colour'") != NULL, true);
    TEST_CHECK(strstr(response, "missing required key-value pair") != NULL, true);
    rule_destroy(&rule);
});

static char *message_test_encode(int *size)
{
    static char *argv[] = { "-m", "window", "--focus", "", "east" };
    return client_encode_message(array_count(argv), argv, size);
}

TEST_FUNC(message_client_encoding,
{
    int size;
    char *message = message_test_encode(&size);

    int payload_length;
    memcpy(&payload_length, message, sizeof(int));
    TEST_CHECK(size, (int) sizeof(int) + payload_length);
    TEST_CHECK(payload_length, 6 + 7 + 0 + 4 + 4 + 1);

    char *cursor = message + sizeof(int);
    TEST_CHECK(token_equals(get_token(&cursor), "window"), true);
    TEST_CHECK(token_equals(get_token(&cursor), "--focus"), true);

    // NOTE: an empty argument looks like the end of the message, so the daemon stops reading there
    TEST_CHECK(token_is_valid(get_token(&cursor)), false);
    TEST_CHECK(token_is_valid(get_token(&cursor)), false);
    TEST_CHECK(memcmp(message + size - 6, "east\0\0", 6), 0);

    free(message);
});

static struct selector message_test_selector(char kind, char *text, char **response)
{
    char *cursor = text;
    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");

    struct selector result;
    if (kind == 'w')      result = parse_window_selector(rsp, &cursor, NULL, false);
    else if (kind == 'd') result = parse_display_selector(rsp, &cursor, 0, false);
    else                  result = parse_space_selector(rsp, &cursor, 0, true);

    fclose(rsp);
    *response = message_test_response;
    return result;
}

TEST_FUNC(message_selectors,
{
    char *response;

    struct selector window = message_test_selector('w', "east\0", &response);
    TEST_CHECK(window.did_parse, true);
    TEST_CHECK(window.window == NULL, true);
    TEST_CHECK(strstr(response, "could not locate the selected window.") != NULL, true);

    window = message_test_selector('w', "stack.bogus\0", &response);
    TEST_CHECK(strstr(response, "could not locate the selected window.") != NULL, true);

    window = message_test_selector('w', "bogus\0", &response);
    TEST_CHECK(window.did_parse, false);
    TEST_CHECK(strstr(response, "value 'bogus' is not a valid option for WINDOW_SEL") != NULL, true);

    struct selector display = message_test_selector('d', "next\0", &response);
    TEST_CHECK(strstr(response, "could not locate the selected display.") != NULL, true);

    display = message_test_selector('d', "unlabeled\0", &response);
    TEST_CHECK(display.did_parse, false);
    TEST_CHECK(strstr(response, "is not a valid option for DISPLAY_SEL") != NULL, true);

    // NOTE: an optional selector that is missing does not report an error
    struct selector space = message_test_selector('s', "\0", &response);
    TEST_CHECK(space.did_parse, false);
    TEST_CHECK(response[0], '\0');

    uint64_t last_space_id = g_space_manager.last_space_id;
    g_space_manager.last_space_id = 77;
    space = message_test_selector('s', "recent\0", &response);
    TEST_CHECK((int) space.sid, 77);
    g_space_manager.last_space_id = last_space_id;

    TEST_CHECK(parse_direction(message_test_token("west")), DIR_WEST);
    TEST_CHECK(parse_direction(message_test_token("up")), 0);
});

static bool message_test_parse_signal(const char *message, size_t size, struct signal *signal, enum signal_type *type, char **response)
{
    memcpy(message_test_rule_buffer, message, size);
    char *cursor = message_test_rule_buffer;

    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    memset(signal, 0, sizeof(struct signal));
    bool result = parse_signal(rsp, &cursor, signal, type);
    fclose(rsp);
    *response = message_test_response;
    return result;
}

#define MESSAGE_TEST_SIGNAL(m, signal, type, response) message_test_parse_signal(m, sizeof(m), signal, type, response)

TEST_FUNC(message_signal_parse,
{
    struct signal signal;
    enum signal_type type;
    char *response;

    TEST_CHECK(MESSAGE_TEST_SIGNAL("event=window_focused\0app!=^Finder$\0action=echo hi\0active=yes\0", &signal, &type, &response), true);
    TEST_CHECK(type, SIGNAL_WINDOW_FOCUSED);
    TEST_CHECK(signal.app_regex_valid, true);
    TEST_CHECK(signal.app_regex_exclude, true);
    TEST_CHECK(signal.active, SIGNAL_PROP_YES);
    TEST_CHECK(strcmp(signal.command, "echo hi"), 0);
    TEST_CHECK(response[0], '\0');
    event_signal_destroy(&signal);

    TEST_CHECK(MESSAGE_TEST_SIGNAL("event=nope\0action=x\0", &signal, &type, &response), false);
    TEST_CHECK(strstr(response, "invalid value 'nope' for key 'event'") != NULL, true);
    TEST_CHECK(strstr(response, "missing required") == NULL, true);
    event_signal_destroy(&signal);

    TEST_CHECK(MESSAGE_TEST_SIGNAL("label!=x\0", &signal, &type, &response), false);
    TEST_CHECK(strstr(response, "missing required key-value pair 'event=..'") != NULL, true);
    TEST_CHECK(strstr(response, "missing required key-value pair 'action=..'") != NULL, true);
    TEST_CHECK(strstr(response, "unsupported token '!' (exclusion) given for key 'label'") != NULL, true);
    event_signal_destroy(&signal);
});

TEST_FUNC(json_string_escaping,
{
    TEST_CHECK(strcmp(json_string(NULL), ""), 0);
    TEST_CHECK(strcmp(json_string("plain"), "plain"), 0);
    TEST_CHECK(strcmp(json_string("say \"hi\"\n"), "say \\\"hi\\\"\\n"), 0);
});

static struct rule_effects rule_effects_test_space(uint64_t sid, bool follow)
{
    struct rule_effects effects = { .sid = sid, .manage = RULE_PROP_OFF };
    if (follow) rule_effects_set_flag(&effects, RULE_FOLLOW_SPACE);
    effects.grid[0] = 2; effects.grid[1] = 2; effects.grid[4] = 1; effects.grid[5] = 1;
    return effects;
}

TEST_FUNC(rule_effects_combine,
{
    struct rule_effects combined = {0};
    struct rule_effects first = rule_effects_test_space(4, true);
    rule_combine_effects(&first, &combined);
    TEST_CHECK((int) combined.sid, 4);
    TEST_CHECK(rule_effects_check_flag(&combined, RULE_FOLLOW_SPACE), true);
    TEST_CHECK(combined.manage, RULE_PROP_OFF);
    TEST_CHECK((int) combined.grid[4], 1);

    // NOTE: a later rule that does not set a property keeps the earlier value
    struct rule_effects second = { .sticky = RULE_PROP_ON };
    rule_combine_effects(&second, &combined);
    TEST_CHECK((int) combined.sid, 4);
    TEST_CHECK(combined.manage, RULE_PROP_OFF);
    TEST_CHECK(combined.sticky, RULE_PROP_ON);

    struct rule_effects third = rule_effects_test_space(6, false);
    rule_combine_effects(&third, &combined);
    TEST_CHECK((int) combined.sid, 6);
    TEST_CHECK(rule_effects_check_flag(&combined, RULE_FOLLOW_SPACE), false);
});

TEST_FUNC(message_config_values,
{
    unsigned grid[6];
    memcpy(grid, g_window_manager.scratchpad_grid, sizeof(grid));
    float duration = g_window_manager.window_animation_duration;

    TEST_CHECK(strcmp(message_test_run_config("scratchpad_grid\0off\0scratchpad_grid\0"), "off\n"), 0);
    TEST_CHECK(strcmp(message_test_run_config("scratchpad_grid\0004:4:1:1:2:2\0scratchpad_grid\0"), "4:4:1:1:2:2\n"), 0);
    TEST_CHECK(strstr(message_test_run_config("scratchpad_grid\0000:4:1:1:2:2\0"), "unknown value '0:4:1:1:2:2'") != NULL, true);

    TEST_CHECK(strcmp(message_test_run_config("window_animation_duration\0" "0\0window_animation_duration\0"), "0.000000\n"), 0);
    TEST_CHECK(strstr(message_test_run_config("window_animation_duration\0fast\0"), "unknown value 'fast'") != NULL, true);

    TEST_CHECK(strstr(message_test_run_config("layout\0bsp\0"), "unknown value 'bsp'") != NULL, true);
    TEST_CHECK(strstr(message_test_run_config("external_bar\0some:1:2\0"), "unknown mode 'some'") != NULL, true);

    // NOTE: float options also take integers
    float opacity_duration = g_window_manager.window_opacity_duration;
    TEST_CHECK(strcmp(message_test_run_config("window_opacity_duration\0" "1\0window_opacity_duration\0"), "1.000000\n"), 0);
    g_window_manager.window_opacity_duration = opacity_duration;

    // NOTE: only the menubar accepts an opacity of 0
    TEST_CHECK(strstr(message_test_run_config("active_window_opacity\0" "0\0"), "unknown value '0'") != NULL, true);
    TEST_CHECK(strstr(message_test_run_config("menubar_opacity\0" "1.5\0"), "unknown value '1.5'") != NULL, true);
    TEST_CHECK(strstr(message_test_run_config("normal_window_opacity\0half\0"), "unknown value 'half'") != NULL, true);

    bool workspace_tabbed = g_space_manager.tree_workspace_tabbed;
    TEST_CHECK(strcmp(message_test_run_config("tree_workspace_layout\0tabbed\0tree_workspace_layout\0"), "tabbed\n"), 0);
    TEST_CHECK(strcmp(message_test_run_config("tree_workspace_layout\0default\0tree_workspace_layout\0"), "default\n"), 0);
    TEST_CHECK(strstr(message_test_run_config("tree_workspace_layout\0stacked\0"), "unknown value 'stacked'") != NULL, true);
    g_space_manager.tree_workspace_tabbed = workspace_tabbed;

    memcpy(g_window_manager.scratchpad_grid, grid, sizeof(grid));
    g_window_manager.window_animation_duration = duration;
});

TEST_FUNC(message_window_layout_values,
{
    TEST_CHECK(parse_window_layout(message_test_token("tabbed")), WINDOW_LAYOUT_TABBED);
    TEST_CHECK(parse_window_layout(message_test_token("toggle-split")), WINDOW_LAYOUT_TOGGLE_SPLIT);
    TEST_CHECK(parse_window_layout(message_test_token("stacked")), -1);

    int orientation = 0;
    TEST_CHECK(parse_split_orientation(message_test_token("vertical"), &orientation), true);
    TEST_CHECK(orientation, CON_VERTICAL);
    TEST_CHECK(parse_split_orientation(message_test_token("toggle"), &orientation), true);
    TEST_CHECK(orientation, -1);
    TEST_CHECK(parse_split_orientation(message_test_token("diagonal"), &orientation), false);
});

static bool message_test_query_target(char *option, struct query_target *target, char **response)
{
    char *cursor = "\0";
    struct properties properties = { .token = message_test_token(option) };
    struct token domain = message_test_token(DOMAIN_QUERY);
    struct token command = message_test_token("--windows");

    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    bool result = parse_query_target(rsp, domain, command, &cursor, properties, target);
    fclose(rsp);
    *response = message_test_response;
    return result;
}

TEST_FUNC(message_query_target,
{
    struct query_target target;
    char *response;

    TEST_CHECK(message_test_query_target("", &target, &response), true);
    TEST_CHECK(target.type, QUERY_TARGET_ALL);

    TEST_CHECK(message_test_query_target("--everything", &target, &response), false);
    TEST_CHECK(strstr(response, "unknown option '--everything' given to command '--windows'") != NULL, true);
});

static enum command_result message_test_window_tree_command(char *command_text, char *message, char **response)
{
    char *cursor = message;
    struct token domain = message_test_token(DOMAIN_WINDOW);
    struct token command = message_test_token(command_text);

    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    enum command_result result = window_command_tree(rsp, domain, command, &cursor, NULL);
    fclose(rsp);
    *response = message_test_response;
    return result;
}

TEST_FUNC(message_window_command_groups,
{
    char *response;

    // NOTE: commands of other groups are left to them
    TEST_CHECK(message_test_window_tree_command("--focus", "\0", &response), COMMAND_UNKNOWN);
    TEST_CHECK(response[0], '\0');

    // NOTE: an invalid value stops the remaining commands of the message
    TEST_CHECK(message_test_window_tree_command("--layout", "stacked\0", &response), COMMAND_STOP);
    TEST_CHECK(strstr(response, "unknown value 'stacked' given to command '--layout'") != NULL, true);
});

static enum command_result message_test_space_layout_command(char *command_text, char *message, char **response)
{
    char *cursor = message;
    struct token domain = message_test_token(DOMAIN_SPACE);
    struct token command = message_test_token(command_text);

    memset(message_test_response, 0, sizeof(message_test_response));
    FILE *rsp = fmemopen(message_test_response, sizeof(message_test_response), "w");
    enum command_result result = space_command_layout(rsp, domain, command, &cursor, 1);
    fclose(rsp);
    *response = message_test_response;
    return result;
}

TEST_FUNC(message_space_command_groups,
{
    char *response;

    TEST_CHECK(message_test_space_layout_command("--focus", "\0", &response), COMMAND_UNKNOWN);

    TEST_CHECK(message_test_space_layout_command("--rotate", "45\0", &response), COMMAND_DONE);
    TEST_CHECK(strstr(response, "unknown value '45' given to command '--rotate'") != NULL, true);

    TEST_CHECK(message_test_space_layout_command("--mirror", "z-axis\0", &response), COMMAND_DONE);
    TEST_CHECK(strstr(response, "unknown value 'z-axis' given to command '--mirror'") != NULL, true);
});
