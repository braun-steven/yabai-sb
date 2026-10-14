//
// NOTE: The protocol of the messages of the client: the domains, commands and arguments, the tokens a
// message is made of, and the failure responses. The handlers of the domains are in message_space.c,
// message_window.c and message.c; the config domain is Swift (Sources/Yabai/IPC/MessageConfig.swift). The
// values, labels, properties and selectors are parsed by the Swift port (src/message_parse.h).
//

extern struct event_loop g_event_loop;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern bool g_verbose;

//
// NOTE: The domains are dispatched by handleMessage (Sources/Yabai/IPC/MessageLoop.swift); the tests of the space and
// window handlers still name theirs.
//

#define DOMAIN_SPACE   "space"
#define DOMAIN_WINDOW  "window"

/* --------------------------------DOMAIN DISPLAY------------------------------- */
#define COMMAND_DISPLAY_FOCUS "--focus"
#define COMMAND_DISPLAY_SPACE "--space"
#define COMMAND_DISPLAY_LABEL "--label"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN SPACE--------------------------------- */
#define COMMAND_SPACE_FOCUS    "--focus"
#define COMMAND_SPACE_SWITCH   "--switch"
#define COMMAND_SPACE_CREATE   "--create"
#define COMMAND_SPACE_DESTROY  "--destroy"
#define COMMAND_SPACE_MOVE     "--move"
#define COMMAND_SPACE_SWAP     "--swap"
#define COMMAND_SPACE_DISPLAY  "--display"
#define COMMAND_SPACE_EQUALIZE "--equalize"
#define COMMAND_SPACE_BALANCE  "--balance"
#define COMMAND_SPACE_MIRROR   "--mirror"
#define COMMAND_SPACE_ROTATE   "--rotate"
#define COMMAND_SPACE_PADDING  "--padding"
#define COMMAND_SPACE_GAP      "--gap"
#define COMMAND_SPACE_TOGGLE   "--toggle"
#define COMMAND_SPACE_LAYOUT   "--layout"
#define COMMAND_SPACE_LABEL    "--label"

#define ARGUMENT_SPACE_ROTATE_90    "90"
#define ARGUMENT_SPACE_ROTATE_180   "180"
#define ARGUMENT_SPACE_ROTATE_270   "270"
#define ARGUMENT_SPACE_PADDING      "%255[^:]:%d:%d:%d:%d"
#define ARGUMENT_SPACE_GAP          "%255[^:]:%d"
#define ARGUMENT_SPACE_TGL_PADDING  "padding"
#define ARGUMENT_SPACE_TGL_GAP      "gap"
#define ARGUMENT_SPACE_TGL_MC       "mission-control"
#define ARGUMENT_SPACE_TGL_SD       "show-desktop"
#define ARGUMENT_SPACE_LAYOUT_FLT   "float"
#define ARGUMENT_SPACE_LAYOUT_TREE  "tree"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN WINDOW-------------------------------- */
#define COMMAND_WINDOW_FOCUS      "--focus"
#define COMMAND_WINDOW_CLOSE      "--close"
#define COMMAND_WINDOW_MINIMIZE   "--minimize"
#define COMMAND_WINDOW_DEMINIMIZE "--deminimize"
#define COMMAND_WINDOW_DISPLAY    "--display"
#define COMMAND_WINDOW_SPACE      "--space"
#define COMMAND_WINDOW_SWAP       "--swap"
#define COMMAND_WINDOW_WARP       "--warp"
#define COMMAND_WINDOW_STACK      "--stack"
#define COMMAND_WINDOW_INSERT     "--insert"
#define COMMAND_WINDOW_GRID       "--grid"
#define COMMAND_WINDOW_MOVE       "--move"
#define COMMAND_WINDOW_RESIZE     "--resize"
#define COMMAND_WINDOW_RATIO      "--ratio"
#define COMMAND_WINDOW_SUB_LAYER  "--sub-layer"
#define COMMAND_WINDOW_OPACITY    "--opacity"
#define COMMAND_WINDOW_RAISE      "--raise"
#define COMMAND_WINDOW_LOWER      "--lower"
#define COMMAND_WINDOW_TOGGLE     "--toggle"
#define COMMAND_WINDOW_SCRATCHPAD "--scratchpad"
#define COMMAND_WINDOW_LAYOUT     "--layout"
#define COMMAND_WINDOW_SPLIT      "--split"

#define ARGUMENT_WINDOW_SEL_LARGEST     "largest"
#define ARGUMENT_WINDOW_SEL_SMALLEST    "smallest"
#define ARGUMENT_WINDOW_GRID            "%d:%d:%d:%d:%d:%d"
#define ARGUMENT_WINDOW_MOVE            "%255[^:]:%f:%f"
#define ARGUMENT_WINDOW_RESIZE          "%255[^:]:%f:%f"
#define ARGUMENT_WINDOW_RATIO           "%255[^:]:%f"
#define ARGUMENT_WINDOW_LAYER_BELOW     "below"
#define ARGUMENT_WINDOW_LAYER_NORMAL    "normal"
#define ARGUMENT_WINDOW_LAYER_ABOVE     "above"
#define ARGUMENT_WINDOW_LAYER_AUTO      "auto"
#define ARGUMENT_WINDOW_TOGGLE_FLOAT    "float"
#define ARGUMENT_WINDOW_TOGGLE_STICKY   "sticky"
#define ARGUMENT_WINDOW_TOGGLE_SHADOW   "shadow"
#define ARGUMENT_WINDOW_TOGGLE_SPLIT    "split"
#define ARGUMENT_WINDOW_TOGGLE_PARENT   "zoom-parent"
#define ARGUMENT_WINDOW_TOGGLE_FULLSC   "zoom-fullscreen"
#define ARGUMENT_WINDOW_TOGGLE_WINDOWED "windowed-fullscreen"
#define ARGUMENT_WINDOW_TOGGLE_NATIVE   "native-fullscreen"
#define ARGUMENT_WINDOW_TOGGLE_EXPOSE   "expose"
#define ARGUMENT_WINDOW_TOGGLE_PIP      "pip"
#define ARGUMENT_WINDOW_LAYOUT_TABBED   "tabbed"
#define ARGUMENT_WINDOW_LAYOUT_SPLIT    "split"
#define ARGUMENT_WINDOW_LAYOUT_TOGGLE   "toggle"
#define ARGUMENT_WINDOW_LAYOUT_SPLITH   "splith"
#define ARGUMENT_WINDOW_LAYOUT_SPLITV   "splitv"
#define ARGUMENT_WINDOW_LAYOUT_TGL_SPLIT "toggle-split"
#define ARGUMENT_WINDOW_SPLIT_H         "horizontal"
#define ARGUMENT_WINDOW_SPLIT_V         "vertical"
#define ARGUMENT_WINDOW_SPLIT_TOGGLE    "toggle"

#define ARGUMENT_WINDOW_SCRATCHPAD_RECOVER "recover"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN QUERY--------------------------------- */
#define COMMAND_QUERY_DISPLAYS "--displays"
#define COMMAND_QUERY_SPACES   "--spaces"
#define COMMAND_QUERY_WINDOWS  "--windows"
#define COMMAND_QUERY_TREE     "--tree"

#define ARGUMENT_QUERY_DISPLAY "--display"
#define ARGUMENT_QUERY_SPACE   "--space"
#define ARGUMENT_QUERY_WINDOW  "--window"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN RULE---------------------------------- */
#define COMMAND_RULE_ADD     "--add"
#define COMMAND_RULE_REM     "--remove"
#define COMMAND_RULE_APPLY   "--apply"
#define COMMAND_RULE_LS      "--list"

#define ARGUMENT_RULE_ONE_SHOT       "--one-shot"
#define ARGUMENT_RULE_KEY_APP        "app"
#define ARGUMENT_RULE_KEY_TITLE      "title"
#define ARGUMENT_RULE_KEY_ROLE       "role"
#define ARGUMENT_RULE_KEY_SUBROLE    "subrole"
#define ARGUMENT_RULE_KEY_DISPLAY    "display"
#define ARGUMENT_RULE_KEY_SPACE      "space"
#define ARGUMENT_RULE_KEY_OPACITY    "opacity"
#define ARGUMENT_RULE_KEY_MANAGE     "manage"
#define ARGUMENT_RULE_KEY_STICKY     "sticky"
#define ARGUMENT_RULE_KEY_MFF        "mouse_follows_focus"
#define ARGUMENT_RULE_KEY_SUB_LAYER  "sub-layer"
#define ARGUMENT_RULE_KEY_FULLSCR    "native-fullscreen"
#define ARGUMENT_RULE_KEY_GRID       "grid"
#define ARGUMENT_RULE_KEY_LABEL      "label"
#define ARGUMENT_RULE_KEY_SCRATCHPAD "scratchpad"

#define ARGUMENT_RULE_VALUE_SPACE '^'
#define ARGUMENT_RULE_VALUE_GRID  "%d:%d:%d:%d:%d:%d"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN SIGNAL-------------------------------- */
#define COMMAND_SIGNAL_ADD "--add"
#define COMMAND_SIGNAL_REM "--remove"
#define COMMAND_SIGNAL_LS  "--list"

#define ARGUMENT_SIGNAL_KEY_APP      "app"
#define ARGUMENT_SIGNAL_KEY_TITLE    "title"
#define ARGUMENT_SIGNAL_KEY_ACTIVE   "active"
#define ARGUMENT_SIGNAL_KEY_EVENT    "event"
#define ARGUMENT_SIGNAL_KEY_ACTION   "action"
#define ARGUMENT_SIGNAL_KEY_LABEL    "label"

#define ARGUMENT_SIGNAL_VALUE_YES    "yes"
#define ARGUMENT_SIGNAL_VALUE_NO     "no"
/* ----------------------------------------------------------------------------- */

/* --------------------------------COMMON ARGUMENTS----------------------------- */
#define ARGUMENT_COMMON_VAL_ON           "on"
#define ARGUMENT_COMMON_VAL_OFF          "off"
#define ARGUMENT_COMMON_SEL_PREV         "prev"
#define ARGUMENT_COMMON_SEL_NEXT         "next"
#define ARGUMENT_COMMON_SEL_FIRST        "first"
#define ARGUMENT_COMMON_SEL_LAST         "last"
#define ARGUMENT_COMMON_SEL_RECENT       "recent"
#define ARGUMENT_COMMON_SEL_NORTH        "north"
#define ARGUMENT_COMMON_SEL_EAST         "east"
#define ARGUMENT_COMMON_SEL_SOUTH        "south"
#define ARGUMENT_COMMON_SEL_WEST         "west"
#define ARGUMENT_WINDOW_SEL_PARENT       "parent"
#define ARGUMENT_WINDOW_SEL_CHILD        "child"
#define ARGUMENT_COMMON_SEL_MOUSE        "mouse"
#define ARGUMENT_COMMON_SEL_STACK        "stack"
#define ARGUMENT_COMMON_SEL_STACK_PREFIX "stack."
#define ARGUMENT_COMMON_VAL_AXIS_X       "x-axis"
#define ARGUMENT_COMMON_VAL_AXIS_Y       "y-axis"
/* ----------------------------------------------------------------------------- */

struct token get_token(char **message)
{
    struct token token;

    token.text = *message;
    while (**message) {
        ++(*message);
    }
    token.length = *message - token.text;

    if ((*message)[0] == '\0' && (*message)[1] != '\0') {
        ++(*message);
    } else {
        // NOTE(asmvik): don't go past the null-terminator
    }

    return token;
}

static bool token_equals(struct token token, const char *match)
{
    const char *at = match;
    for (int i = 0; i < token.length; ++i, ++at) {
        if ((*at == 0) || (token.text[i] != *at)) {
            return false;
        }
    }
    return *at == 0;
}

static inline bool token_is_valid(struct token token)
{
    return token.text && token.length > 0;
}

static inline void daemon_fail(FILE *rsp, char *fmt, ...)
{
    if (!rsp) return;

    va_list ap;
    va_start(ap, fmt);
    fprintf(rsp, FAILURE_MESSAGE);
    vfprintf(rsp, fmt, ap);
    va_end(ap);
}

//
// NOTE: reports the errors that every space operation can fail with, so callers only handle
// the errors specific to their operation.
//

static void daemon_fail_space_op(FILE *rsp, enum space_op_error result, char *action)
{
    switch (result) {
    case SPACE_OP_ERROR_IN_MISSION_CONTROL:   daemon_fail(rsp, "cannot %s because mission-control is active.\n", action);                  break;
    case SPACE_OP_ERROR_SCRIPTING_ADDITION:   daemon_fail(rsp, "cannot %s due to an error with the scripting-addition.\n", action);         break;
    default: break;
    }
}

static void daemon_fail_unmanaged_window(FILE *rsp, enum window_op_error result)
{
    if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW || result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
        daemon_fail(rsp, "the acting window is not managed.\n");
    } else if (result == WINDOW_OP_ERROR_INVALID_DST_VIEW || result == WINDOW_OP_ERROR_INVALID_DST_NODE) {
        daemon_fail(rsp, "the selected window is not managed.\n");
    }
}
