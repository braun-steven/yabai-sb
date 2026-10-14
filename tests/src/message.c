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
