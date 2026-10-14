//
// NOTE: messages are null-separated tokens that end with an empty token, as sent by the client.
//

static char message_test_response[256];

static struct token message_test_token(char *text)
{
    return (struct token) { .text = text, .length = (int) strlen(text) };
}

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
