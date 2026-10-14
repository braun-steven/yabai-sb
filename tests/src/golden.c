//
// NOTE: The golden IPC capture of the Swift port (doc/swift-port.md). golden_replay sends every command of
// GOLDEN_COMMANDS through handle_message, in order, on one fixture state of the daemon, and compares each response
// byte for byte with GOLDEN_RESPONSES. With GOLDEN_RECORD=1 in the environment it writes GOLDEN_RESPONSES instead.
//
// The fixture is a daemon without displays, spaces or windows: only the defaults of the managers. A command must
// never act on the live displays, spaces or windows of this machine, so the space and display domains are only
// covered by commands that fail before they act.
//
// GOLDEN_RESPONSES holds one record per command: a line "### <byte count> <command>", the response bytes, and a
// newline. A failure response starts with FAILURE_MESSAGE (\x07), as it does on the socket.
//

#define GOLDEN_COMMANDS  "YabaiCoreTests/Golden/commands.txt"
#define GOLDEN_RESPONSES "YabaiCoreTests/Golden/responses.txt"

static void golden_fixture(void)
{
    window_manager_init(&g_window_manager);
    space_manager_init(&g_space_manager);
    memory_pool_init(&g_signal_storage, KILOBYTES(256));
}

//
// NOTE: A command is split at spaces into the arguments of the client, and single quotes keep spaces in an argument
// like a shell does (action='echo hi'). The message is then encoded like the client does (client_encode_message).
//

static char *golden_encode(char *line)
{
    char *argv[64] = { "yabai" };
    int argc = 1;
    char *out = line;

    for (char *cursor = line; *cursor && argc < (int) array_count(argv);) {
        if (*cursor == ' ') { ++cursor; continue; }

        bool quoted = false;
        argv[argc++] = out;

        while (*cursor && (quoted || *cursor != ' ')) {
            if (*cursor == '\'') quoted = !quoted;
            else *out++ = *cursor;
            ++cursor;
        }

        bool end = *cursor == '\0';
        *out++ = '\0';
        if (!end) ++cursor;
    }

    int size;
    return client_encode_message(argc, argv, &size);
}

static char *golden_run(char *line, size_t *length)
{
    char *copy = strdup(line);
    char *message = golden_encode(copy);

    char *response = NULL;
    FILE *rsp = open_memstream(&response, length);
    handle_message(rsp, message + sizeof(int));
    fclose(rsp);

    free(message);
    free(copy);
    return response;
}

static void golden_print_escaped(char *label, char *bytes, size_t length)
{
    printf("                   %s: \"", label);
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = bytes[i];
        if (c == '\n')      printf("\\n");
        else if (c == '\t') printf("\\t");
        else if (c < 0x20)  printf("\\x%02x", c);
        else                putchar(c);
    }
    printf("\"\n");
}

//
// NOTE: Reads the next record of GOLDEN_RESPONSES. Returns false at the end of the file or on a malformed record.
//

static bool golden_read_record(FILE *file, char *command, size_t command_size, char **bytes, size_t *length)
{
    char header[4096];
    if (!fgets(header, sizeof(header), file)) return false;

    int offset = 0;
    if (sscanf(header, "### %zu %n", length, &offset) != 1 || !offset) return false;
    snprintf(command, command_size, "%s", header + offset);
    command[strcspn(command, "\n")] = '\0';

    *bytes = malloc(*length + 1);
    if (fread(*bytes, 1, *length, file) != *length || fgetc(file) != '\n') {
        free(*bytes);
        return false;
    }

    return true;
}

static bool golden_replay(void)
{
    bool record = getenv("GOLDEN_RECORD") != NULL;

    FILE *commands = fopen(GOLDEN_COMMANDS, "r");
    if (!commands) {
        printf("\e[1;31mgolden: could not open %s (run the tests from tests/)\e[m\n", GOLDEN_COMMANDS);
        return false;
    }

    FILE *responses = fopen(GOLDEN_RESPONSES, record ? "w" : "r");
    if (!responses) {
        printf("\e[1;31mgolden: could not open %s\e[m\n", GOLDEN_RESPONSES);
        fclose(commands);
        return false;
    }

    golden_fixture();

    int count = 0;
    int failed = 0;
    char line[4096];

    while (fgets(line, sizeof(line), commands)) {
        line[strcspn(line, "\n")] = '\0';
        if (line[0] == '\0' || line[0] == '#') continue;

        size_t length;
        char *response = golden_run(line, &length);
        ++count;

        if (record) {
            fprintf(responses, "### %zu %s\n", length, line);
            fwrite(response, 1, length, responses);
            fputc('\n', responses);
        } else {
            char command[4096];
            char *expected;
            size_t expected_length;

            if (!golden_read_record(responses, command, sizeof(command), &expected, &expected_length)) {
                printf("\e[1;31mgolden: %s has no valid record for '%s'; record it again\e[m\n", GOLDEN_RESPONSES, line);
                free(response);
                ++failed;
                break;
            }

            if (strcmp(command, line) != 0) {
                printf("\e[1;31mgolden: record '%s' does not match command '%s'; record it again\e[m\n", command, line);
                ++failed;
            } else if (expected_length != length || memcmp(expected, response, length) != 0) {
                printf("\e[1;31mgolden: '%s'\e[m\n", line);
                golden_print_escaped("expected", expected, expected_length);
                golden_print_escaped("actual  ", response, length);
                ++failed;
            }

            free(expected);
        }

        free(response);
    }

    if (!record && !failed && fgetc(responses) != EOF) {
        printf("\e[1;31mgolden: %s has more records than there are commands; record it again\e[m\n", GOLDEN_RESPONSES);
        ++failed;
    }

    fclose(responses);
    fclose(commands);

    if (record) {
        printf("\e[1;34m -- Recorded %d golden responses\e[m\n", count);
    } else {
        printf("\e[1;34m -- Golden IPC: %d of %d responses match\e[m\n", count - failed, count);
    }

    return failed == 0;
}
