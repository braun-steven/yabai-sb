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
