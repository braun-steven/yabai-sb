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

#define DOMAIN_CONFIG  "config"
#define DOMAIN_DISPLAY "display"
#define DOMAIN_SPACE   "space"
#define DOMAIN_WINDOW  "window"
#define DOMAIN_QUERY   "query"
#define DOMAIN_RULE    "rule"
#define DOMAIN_SIGNAL  "signal"

/* --------------------------------DOMAIN CONFIG-------------------------------- */
#define COMMAND_CONFIG_DEBUG_OUTPUT          "debug_output"
#define COMMAND_CONFIG_MFF                   "mouse_follows_focus"
#define COMMAND_CONFIG_FFM                   "focus_follows_mouse"
#define COMMAND_CONFIG_DISPLAY_ORDER         "display_arrangement_order"
#define COMMAND_CONFIG_BUILTIN_LAST          "builtin_display_last"
#define COMMAND_CONFIG_WINDOW_ORIGIN         "window_origin_display"
#define COMMAND_CONFIG_OPACITY               "window_opacity"
#define COMMAND_CONFIG_OPACITY_DURATION      "window_opacity_duration"
#define COMMAND_CONFIG_ANIMATION_DURATION    "window_animation_duration"
#define COMMAND_CONFIG_ANIMATION_EASING      "window_animation_easing"
#define COMMAND_CONFIG_SHADOW                "window_shadow"
#define COMMAND_CONFIG_MENUBAR_OPACITY       "menubar_opacity"
#define COMMAND_CONFIG_ACTIVE_WINDOW_OPACITY "active_window_opacity"
#define COMMAND_CONFIG_NORMAL_WINDOW_OPACITY "normal_window_opacity"
#define COMMAND_CONFIG_INSERT_FEEDBACK_COLOR "insert_feedback_color"
#define COMMAND_CONFIG_BORDER                "window_border"
#define COMMAND_CONFIG_BORDER_WIDTH          "window_border_width"
#define COMMAND_CONFIG_BORDER_HIDE_SINGLE    "window_border_hide_single"
#define COMMAND_CONFIG_ACTIVE_BORDER_COLOR   "active_window_border_color"
#define COMMAND_CONFIG_NORMAL_BORDER_COLOR   "normal_window_border_color"
#define COMMAND_CONFIG_TAB_BAR               "tab_bar"
#define COMMAND_CONFIG_TAB_BAR_HEIGHT        "tab_bar_height"
#define COMMAND_CONFIG_TAB_BAR_OFFSET        "tab_bar_offset"
#define COMMAND_CONFIG_TAB_BAR_FONT          "tab_bar_font"
#define COMMAND_CONFIG_TAB_BAR_ICONS         "tab_bar_icons"
#define COMMAND_CONFIG_TAB_BAR_STYLE         "tab_bar_style"
#define COMMAND_CONFIG_TAB_BAR_BACKDROP      "tab_bar_backdrop"
#define COMMAND_CONFIG_TAB_BAR_CARD_PADDING  "tab_bar_card_padding"
#define COMMAND_CONFIG_TAB_BAR_WINDOW_RADIUS "tab_bar_window_radius"
#define COMMAND_CONFIG_TAB_BAR_FOCUSED_COLOR          "tab_bar_focused_color"
#define COMMAND_CONFIG_TAB_BAR_FOCUSED_TEXT_COLOR     "tab_bar_focused_text_color"
#define COMMAND_CONFIG_TAB_BAR_INACTIVE_COLOR         "tab_bar_inactive_color"
#define COMMAND_CONFIG_TAB_BAR_INACTIVE_TEXT_COLOR    "tab_bar_inactive_text_color"
#define COMMAND_CONFIG_TAB_BAR_UNFOCUSED_COLOR        "tab_bar_unfocused_color"
#define COMMAND_CONFIG_TAB_BAR_UNFOCUSED_TEXT_COLOR   "tab_bar_unfocused_text_color"
#define COMMAND_CONFIG_TAB_BAR_BACKDROP_COLOR         "tab_bar_backdrop_color"
#define COMMAND_CONFIG_TOP_PADDING           "top_padding"
#define COMMAND_CONFIG_BOTTOM_PADDING        "bottom_padding"
#define COMMAND_CONFIG_LEFT_PADDING          "left_padding"
#define COMMAND_CONFIG_RIGHT_PADDING         "right_padding"
#define COMMAND_CONFIG_LAYOUT                "layout"
#define COMMAND_CONFIG_WINDOW_GAP            "window_gap"
#define COMMAND_CONFIG_AUTO_PADDING          "auto_padding"
#define COMMAND_CONFIG_TREE_ORIENTATION      "tree_default_orientation"
#define COMMAND_CONFIG_TREE_WORKSPACE_LAYOUT "tree_workspace_layout"
#define COMMAND_CONFIG_TREE_AUTOTILING       "tree_autotiling"
#define COMMAND_CONFIG_FOCUS_WRAPPING        "focus_wrapping"
#define COMMAND_CONFIG_MOUSE_MOD             "mouse_modifier"
#define COMMAND_CONFIG_MOUSE_ACTION1         "mouse_action1"
#define COMMAND_CONFIG_MOUSE_ACTION2         "mouse_action2"
#define COMMAND_CONFIG_MOUSE_DROP_ACTION     "mouse_drop_action"
#define COMMAND_CONFIG_EXTERNAL_BAR          "external_bar"
#define COMMAND_CONFIG_SKIP_SPACE_ANIMATION  "skip_window_focus_animation"
#define COMMAND_CONFIG_SPACE_LAYOUT          "space_layout"
#define COMMAND_CONFIG_SCRATCHPAD_EXCLUSIVE  "scratchpad_exclusive"
#define COMMAND_CONFIG_SCRATCHPAD_RAISE      "scratchpad_raise"
#define COMMAND_CONFIG_SCRATCHPAD_BELOW      "scratchpad_below"
#define COMMAND_CONFIG_SCRATCHPAD_GRID       "scratchpad_grid"

#define SELECTOR_CONFIG_SPACE                "--space"

#define ARGUMENT_CONFIG_FFM_AUTOFOCUS         "autofocus"
#define ARGUMENT_CONFIG_FFM_AUTORAISE         "autoraise"
#define ARGUMENT_CONFIG_DISPLAY_ORDER_DEFAULT "default"
#define ARGUMENT_CONFIG_DISPLAY_ORDER_X       "horizontal"
#define ARGUMENT_CONFIG_DISPLAY_ORDER_Y       "vertical"
#define ARGUMENT_CONFIG_WINDOW_ORIGIN_DEFAULT "default"
#define ARGUMENT_CONFIG_WINDOW_ORIGIN_FOCUSED "focused"
#define ARGUMENT_CONFIG_WINDOW_ORIGIN_CURSOR  "cursor"
#define ARGUMENT_CONFIG_SHADOW_FLT            "float"
#define ARGUMENT_CONFIG_LAYOUT_FLOAT          "float"
#define ARGUMENT_CONFIG_LAYOUT_TREE           "tree"
#define ARGUMENT_CONFIG_TREE_DEFAULT          "default"
#define ARGUMENT_CONFIG_TREE_TABBED           "tabbed"
#define ARGUMENT_CONFIG_FOCUS_WRAPPING_FORCE  "force"
#define ARGUMENT_CONFIG_TREE_VERTICAL         "vertical"
#define ARGUMENT_CONFIG_TREE_HORIZONTAL       "horizontal"
#define ARGUMENT_CONFIG_TREE_AUTO             "auto"
#define ARGUMENT_CONFIG_MOUSE_MOD_ALT         "alt"
#define ARGUMENT_CONFIG_MOUSE_MOD_SHIFT       "shift"
#define ARGUMENT_CONFIG_MOUSE_MOD_CMD         "cmd"
#define ARGUMENT_CONFIG_MOUSE_MOD_CTRL        "ctrl"
#define ARGUMENT_CONFIG_MOUSE_MOD_FN          "fn"
#define ARGUMENT_CONFIG_MOUSE_ACTION_MOVE     "move"
#define ARGUMENT_CONFIG_MOUSE_ACTION_RESIZE   "resize"
#define ARGUMENT_CONFIG_MOUSE_ACTION_SWAP     "swap"
#define ARGUMENT_CONFIG_MOUSE_ACTION_STACK    "stack"
#define ARGUMENT_CONFIG_EXTERNAL_BAR_MAIN     "main"
#define ARGUMENT_CONFIG_EXTERNAL_BAR_ALL      "all"
#define ARGUMENT_CONFIG_EXTERNAL_BAR          "%5[^:]:%d:%d"
/* ----------------------------------------------------------------------------- */

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

struct token
{
    char *text;
    int length;
};

enum token_type
{
    TOKEN_TYPE_INVALID,
    TOKEN_TYPE_UNKNOWN,
    TOKEN_TYPE_INT,
    TOKEN_TYPE_FLOAT,
    TOKEN_TYPE_U32,
    TOKEN_TYPE_STRING
};

struct token_value
{
    struct token token;
    enum token_type type;

    union {
        int int_value;
        float float_value;
        uint32_t u32_value;
        char *string_value;
    };
};

static const int token_char_int_table[] =
{
    ['0'] = 0x0, ['1'] = 0x1,
    ['2'] = 0x2, ['3'] = 0x3,
    ['4'] = 0x4, ['5'] = 0x5,
    ['6'] = 0x6, ['7'] = 0x7,
    ['8'] = 0x8, ['9'] = 0x9,
    ['a'] = 0xA, ['A'] = 0xA,
    ['b'] = 0xB, ['B'] = 0xB,
    ['c'] = 0xC, ['C'] = 0xC,
    ['d'] = 0xD, ['D'] = 0xD,
    ['e'] = 0xE, ['E'] = 0xE,
    ['f'] = 0xF, ['F'] = 0xF,
};

static struct token get_token(char **message)
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

static bool token_prefix(struct token token, const char *match)
{
    const char *at = match;
    for (int i = 0; i < token.length; ++i, ++at) {
        if (*at == 0)             return true;
        if (token.text[i] != *at) return false;
    }
    return *at == 0;
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

static bool token_is_positive_integer(struct token token, int *value)
{
    *value = 0;

    for (int i = 0; i < token.length; ++i) {
        char c = token.text[i];
        if (!(c >= '0' && c <= '9')) {
            return false;
        }
        *value = *value * 10 + token_char_int_table[(int)c];
    }

    return true;
}

static bool token_is_hexadecimal(struct token token, uint32_t *value)
{
    *value = 0;

    if (token.length <= 2) return false;

    if (!(token.text[0] == '0' &&
         (token.text[1] == 'x' ||
          token.text[1] == 'X'))) {
        return false;
    }

    for (int i = 2; i < token.length; ++i) {
        char c = token.text[i];
        if (!((c >= '0' && c <= '9') ||
              (c >= 'a' && c <= 'f') ||
              (c >= 'A' && c <= 'F'))) {
            return false;
        }
        *value = *value * 16 + (uint32_t)token_char_int_table[(int)c];
    }

    return true;
}

static bool token_is_float(struct token token, float *value)
{
    char *end = NULL;
    float v = strtof(token.text, &end);

    if (!end || *end) {
        *value = 0.0f;
        return false;
    } else {
        *value = v;
        return true;
    }
}

static struct token_value token_to_value(struct token token)
{
    struct token_value value = { .token = token, .type = TOKEN_TYPE_INVALID };

    if (token_is_valid(token)) {
        if (token_is_positive_integer(token, &value.int_value)) {
            value.type = TOKEN_TYPE_INT;
        } else if (token_is_hexadecimal(token, &value.u32_value)) {
            value.type = TOKEN_TYPE_U32;
        } else if (token_is_float(token, &value.float_value)) {
            value.type = TOKEN_TYPE_FLOAT;
        } else if ((value.string_value = token.text)) {
            value.type = TOKEN_TYPE_STRING;
        } else {
            value.type = TOKEN_TYPE_UNKNOWN;
        }
    }

    return value;
}

//
// NOTE: Float options also accept integers, which token_to_value reports as TOKEN_TYPE_INT.
//

static inline bool token_value_float(struct token_value value, float *result)
{
    if (value.type == TOKEN_TYPE_FLOAT) {
        *result = value.float_value;
    } else if (value.type == TOKEN_TYPE_INT) {
        *result = (float) value.int_value;
    } else {
        return false;
    }

    return true;
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

static inline void daemon_fail_unknown_command(FILE *rsp, struct token domain, struct token command)
{
    daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
}

static inline void daemon_fail_unknown_option(FILE *rsp, struct token domain, struct token command, struct token option)
{
    daemon_fail(rsp, "unknown option '%.*s' given to command '%.*s' for domain '%.*s'\n", option.length, option.text, command.length, command.text, domain.length, domain.text);
}

static inline void daemon_fail_unknown_value(FILE *rsp, struct token domain, struct token command, struct token value)
{
    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
}

//
// NOTE: config options print their current value when no value is given. These return true when
// the next token of the message is a valid new value, so the caller can apply it.
//

static bool parse_config_bool(FILE *rsp, struct token domain, struct token command, char **message, bool *flag)
{
    struct token value = get_token(message);
    if (!token_is_valid(value)) {
        fprintf(rsp, "%s\n", bool_str[*flag]);
    } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        *flag = false;
        return true;
    } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
        *flag = true;
        return true;
    } else {
        daemon_fail_unknown_value(rsp, domain, command, value);
    }

    return false;
}

//
// NOTE: names[i] is the value that selects choice i. Only names[first..last] are accepted,
// NULL entries (gaps in a bitmask enum) are skipped.
//

static bool parse_config_choice(FILE *rsp, struct token domain, struct token command, char **message, const char **names, int first, int last, int current, int *choice)
{
    struct token value = get_token(message);
    if (!token_is_valid(value)) {
        fprintf(rsp, "%s\n", names[current]);
        return false;
    }

    for (int i = first; i <= last; ++i) {
        if (names[i] && token_equals(value, names[i])) {
            *choice = i;
            return true;
        }
    }

    daemon_fail_unknown_value(rsp, domain, command, value);
    return false;
}

//
// NOTE: reports the errors that every space operation can fail with, so callers only handle
// the errors specific to their operation.
//

static void daemon_fail_space_op(FILE *rsp, enum space_op_error result, char *action)
{
    switch (result) {
    case SPACE_OP_ERROR_DISPLAY_IS_ANIMATING: daemon_fail(rsp, "cannot %s because the display is in the middle of an animation.\n", action); break;
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

static void parse_key_value_pair(char *token, char **key, char **value, bool *exclusion)
{
    *key = token;

    while (*token) {
        char fst = token[0];
        char snd = token[1];

        if (fst == '!' && snd == '=') {
            break;
        } else if (fst == '=') {
            break;
        }

        ++token;
    }

    int index = (token[0] == '!' && token[1] == '=') ? 2 : 1;
    char check = (index == 2) ? '!' : '=';

    if (*token != check) {
        *key = NULL;
        *value = NULL;
    } else if (token[index]) {
        *token = '\0';
        *value = token+index;
        *exclusion = index == 2;
    } else {
        *value = NULL;
    }
}

static int parse_layer(char *value)
{
    if (string_equals(value, ARGUMENT_WINDOW_LAYER_BELOW))  return LAYER_BELOW;
    if (string_equals(value, ARGUMENT_WINDOW_LAYER_NORMAL)) return LAYER_NORMAL;
    if (string_equals(value, ARGUMENT_WINDOW_LAYER_ABOVE))  return LAYER_ABOVE;
    if (string_equals(value, ARGUMENT_WINDOW_LAYER_AUTO))   return LAYER_AUTO;
    return -1;
}

static uint8_t parse_value_type(char *type)
{
    if (string_equals(type, "abs")) {
        return TYPE_ABS;
    } else if (string_equals(type, "rel")) {
        return TYPE_REL;
    } else {
        return 0;
    }
}

static uint8_t parse_resize_handle(char *handle)
{
    if (string_equals(handle, "top")) {
        return HANDLE_TOP;
    } else if (string_equals(handle, "bottom")) {
        return HANDLE_BOTTOM;
    } else if (string_equals(handle, "left")) {
        return HANDLE_LEFT;
    } else if (string_equals(handle, "right")) {
        return HANDLE_RIGHT;
    } else if (string_equals(handle, "top_left")) {
        return HANDLE_TOP | HANDLE_LEFT;
    } else if (string_equals(handle, "top_right")) {
        return HANDLE_TOP | HANDLE_RIGHT;
    } else if (string_equals(handle, "bottom_left")) {
        return HANDLE_BOTTOM | HANDLE_LEFT;
    } else if (string_equals(handle, "bottom_right")) {
        return HANDLE_BOTTOM | HANDLE_RIGHT;
    } else if (string_equals(handle, "abs")) {
        return HANDLE_ABS;
    } else {
        return 0;
    }
}

enum label_type
{
    LABEL_DISPLAY,
    LABEL_SPACE,
    LABEL_WINDOW
};

static char *reserved_display_identifiers[] =
{
    ARGUMENT_COMMON_SEL_NORTH,
    ARGUMENT_COMMON_SEL_EAST,
    ARGUMENT_COMMON_SEL_SOUTH,
    ARGUMENT_COMMON_SEL_WEST,
    ARGUMENT_COMMON_SEL_PREV,
    ARGUMENT_COMMON_SEL_NEXT,
    ARGUMENT_COMMON_SEL_FIRST,
    ARGUMENT_COMMON_SEL_LAST,
    ARGUMENT_COMMON_SEL_RECENT,
    ARGUMENT_COMMON_SEL_MOUSE
};

static char *reserved_space_identifiers[] =
{
    ARGUMENT_COMMON_SEL_PREV,
    ARGUMENT_COMMON_SEL_NEXT,
    ARGUMENT_COMMON_SEL_FIRST,
    ARGUMENT_COMMON_SEL_LAST,
    ARGUMENT_COMMON_SEL_RECENT,
    ARGUMENT_COMMON_SEL_MOUSE
};

static char *reserved_window_identifiers[] =
{
    ARGUMENT_WINDOW_TOGGLE_FLOAT,
    ARGUMENT_WINDOW_TOGGLE_STICKY,
    ARGUMENT_WINDOW_TOGGLE_SHADOW,
    ARGUMENT_WINDOW_TOGGLE_SPLIT,
    ARGUMENT_WINDOW_TOGGLE_PARENT,
    ARGUMENT_WINDOW_TOGGLE_FULLSC,
    ARGUMENT_WINDOW_TOGGLE_WINDOWED,
    ARGUMENT_WINDOW_TOGGLE_NATIVE,
    ARGUMENT_WINDOW_TOGGLE_EXPOSE,
    ARGUMENT_WINDOW_TOGGLE_PIP,
    ARGUMENT_WINDOW_SCRATCHPAD_RECOVER
};

static bool parse_label(FILE *rsp, struct token token, enum label_type type, char **label)
{
    struct token_value value = token_to_value(token);

    if (value.type == TOKEN_TYPE_INVALID) {
        *label = NULL;
        return true;
    }

    if (value.type != TOKEN_TYPE_STRING) {
        daemon_fail(rsp, "'%.*s' cannot be used as a label.\n", token.length, token.text);
        return false;
    }

    switch (type) {
    default: break;
    case LABEL_DISPLAY: {
        for (int i = 0; i < array_count(reserved_display_identifiers); ++i) {
            if (token_equals(token, reserved_display_identifiers[i])) {
                daemon_fail(rsp, "'%.*s' is a reserved keyword and cannot be used as a label.\n", token.length, token.text);
                return false;
            }
        }
    } break;
    case LABEL_SPACE: {
        for (int i = 0; i < array_count(reserved_space_identifiers); ++i) {
            if (token_equals(token, reserved_space_identifiers[i])) {
                daemon_fail(rsp, "'%.*s' is a reserved keyword and cannot be used as a label.\n", token.length, token.text);
                return false;
            }
        }
    } break;
    case LABEL_WINDOW: {
        for (int i = 0; i < array_count(reserved_window_identifiers); ++i) {
            if (token_equals(token, reserved_window_identifiers[i])) {
                daemon_fail(rsp, "'%.*s' is a reserved keyword and cannot be used as a scratchpad.\n", token.length, token.text);
                return false;
            }
        }
    } break;
    }

    *label = malloc(token.length + 1);
    if (!(*label)) return false;

    memcpy(*label, token.text, token.length);
    (*label)[token.length] = '\0';

    return true;
}

struct properties
{
    struct token token;
    bool did_parse;
    bool did_error;
    uint64_t flags;
};

static inline bool parse_property(struct properties *properties, char *property, uint64_t *property_val, char **property_str, int property_count)
{
    for (int i = 0; i < property_count; ++i) {
        if (string_equals(property, property_str[i])) {
            properties->flags |= property_val[i];
            return true;
        }
    }

    return false;
}

static struct properties parse_properties(FILE *rsp, struct token token, uint64_t *property_val, char **property_str, int property_count)
{
    struct properties result = { .token = token, .did_error = false };

    if ((result.did_parse = token_is_valid(token) && !token_prefix(token, "--"))) {
        for (int i = 0, cursor = 0; i < token.length; ++i) {
            if (i+1 == token.length) {
                if (!parse_property(&result, token.text+cursor, property_val, property_str, property_count)) {
                    daemon_fail(rsp, "'%.*s' is not a valid property.\n", i-cursor+1, token.text+cursor);
                    result.did_error = true;
                }
            } else if (token.text[i] == ',') {
                token.text[i] = '\0';

                if (!parse_property(&result, token.text+cursor, property_val, property_str, property_count)) {
                    daemon_fail(rsp, "'%.*s' is not a valid property.\n", i-cursor+1, token.text+cursor);
                    result.did_error = true;
                }

                cursor = i+1;
            }
        }
    }

    return result;
}

struct selector
{
    struct token token;
    bool did_parse;

    union {
        int dir;
        uint32_t did;
        uint64_t sid;
        struct window *window;
    };
};

static int parse_direction(struct token token)
{
    if (token_equals(token, ARGUMENT_COMMON_SEL_NORTH)) return DIR_NORTH;
    if (token_equals(token, ARGUMENT_COMMON_SEL_EAST))  return DIR_EAST;
    if (token_equals(token, ARGUMENT_COMMON_SEL_SOUTH)) return DIR_SOUTH;
    if (token_equals(token, ARGUMENT_COMMON_SEL_WEST))  return DIR_WEST;
    return 0;
}

static char *direction_str(int direction)
{
    switch (direction) {
    case DIR_NORTH: return "a northward";
    case DIR_EAST:  return "an eastward";
    case DIR_SOUTH: return "a southward";
    default:        return "a westward";
    }
}

//
// NOTE: Reports that a selector found no window, described by what, and passes the window through.
//

static struct window *window_selector_require(FILE *rsp, struct window *window, char *what)
{
    if (!window) daemon_fail(rsp, "could not locate %s.\n", what);
    return window;
}

static uint32_t display_selector_require(FILE *rsp, uint32_t did, char *what)
{
    if (!did) daemon_fail(rsp, "could not locate %s.\n", what);
    return did;
}

static struct selector parse_display_selector(FILE *rsp, char **message, uint32_t acting_did, bool optional)
{
    TIME_FUNCTION;

    struct selector result = { .token = get_token(message), .did_parse = true };
    struct token_value value = token_to_value(result.token);

    if (value.type == TOKEN_TYPE_INT) {
        result.did = display_manager_arrangement_display_id(value.int_value);
        if (!result.did) daemon_fail(rsp, "could not locate display with arrangement index '%d'.\n", value.int_value);
    } else if (value.type == TOKEN_TYPE_STRING) {
        struct token token = result.token;
        int direction = parse_direction(token);
        bool relative = direction || token_equals(token, ARGUMENT_COMMON_SEL_PREV) || token_equals(token, ARGUMENT_COMMON_SEL_NEXT);

        if (relative && !acting_did) {
            daemon_fail(rsp, "could not locate the selected display.\n");
        } else if (direction) {
            char what[64];
            snprintf(what, sizeof(what), "%s display", direction_str(direction));
            result.did = display_selector_require(rsp, display_manager_find_closest_display_in_direction(acting_did, direction), what);
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_PREV)) {
            result.did = display_selector_require(rsp, display_manager_prev_display_id(acting_did), "the previous display");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_NEXT)) {
            result.did = display_selector_require(rsp, display_manager_next_display_id(acting_did), "the next display");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_FIRST)) {
            result.did = display_selector_require(rsp, display_manager_first_display_id(), "the first display");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_LAST)) {
            result.did = display_selector_require(rsp, display_manager_last_display_id(), "the last display");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_RECENT)) {
            result.did = g_display_manager.last_display_id;
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_MOUSE)) {
            result.did = display_selector_require(rsp, display_manager_cursor_display_id(), "display containing cursor");
        } else {
            struct display_label *display_label = display_manager_get_display_for_label(&g_display_manager, value.string_value);
            if (display_label) {
                result.did = display_label->did;
            } else {
                result.did_parse = false;
                daemon_fail(rsp, "value '%.*s' is not a valid option for DISPLAY_SEL\n", token.length, token.text);
            }
        }
    } else {
        result.did_parse = false;
        if (value.type != TOKEN_TYPE_INVALID || !optional) {
            daemon_fail(rsp, "value '%.*s' is not a valid option for DISPLAY_SEL\n", result.token.length, result.token.text);
        }
    }

    return result;
}

static uint64_t space_selector_require(FILE *rsp, uint64_t sid, char *what)
{
    if (!sid) daemon_fail(rsp, "could not locate %s.\n", what);
    return sid;
}

static struct selector parse_space_selector(FILE *rsp, char **message, uint64_t acting_sid, bool optional)
{
    TIME_FUNCTION;

    struct selector result = { .token = get_token(message), .did_parse = true };
    struct token_value value = token_to_value(result.token);

    if (value.type == TOKEN_TYPE_INT) {
        result.sid = space_manager_mission_control_space(value.int_value);
        if (!result.sid) daemon_fail(rsp, "could not locate space with mission-control index '%d'.\n", value.int_value);
    } else if (value.type == TOKEN_TYPE_STRING) {
        struct token token = result.token;
        bool relative = token_equals(token, ARGUMENT_COMMON_SEL_PREV) || token_equals(token, ARGUMENT_COMMON_SEL_NEXT);

        if (relative && !acting_sid) {
            daemon_fail(rsp, "could not locate the selected space.\n");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_PREV)) {
            result.sid = space_selector_require(rsp, space_manager_prev_space(acting_sid), "the previous space");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_NEXT)) {
            result.sid = space_selector_require(rsp, space_manager_next_space(acting_sid), "the next space");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_FIRST)) {
            result.sid = space_selector_require(rsp, space_manager_first_space(), "the first space");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_LAST)) {
            result.sid = space_selector_require(rsp, space_manager_last_space(), "the last space");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_RECENT)) {
            result.sid = g_space_manager.last_space_id;
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_MOUSE)) {
            result.sid = space_selector_require(rsp, space_manager_cursor_space(), "space containing cursor");
        } else {
            struct space_label *space_label = space_manager_get_space_for_label(&g_space_manager, value.string_value);
            if (space_label) {
                result.sid = space_label->sid;
            } else {
                result.did_parse = false;
                daemon_fail(rsp, "value '%.*s' is not a valid option for SPACE_SEL\n", token.length, token.text);
            }
        }
    } else {
        result.did_parse = false;
        if (value.type != TOKEN_TYPE_INVALID || !optional) {
            daemon_fail(rsp, "value '%.*s' is not a valid option for SPACE_SEL\n", result.token.length, result.token.text);
        }
    }

    return result;
}

static struct window *parse_stack_window_selector(FILE *rsp, struct token token, struct window *acting_window, bool *did_parse)
{
    struct space_manager *sm = &g_space_manager;
    struct window_manager *wm = &g_window_manager;

    if (token_equals(token, ARGUMENT_COMMON_SEL_PREV))   return window_selector_require(rsp, window_manager_find_prev_window_in_stack(sm, wm, acting_window), "the prev stacked window");
    if (token_equals(token, ARGUMENT_COMMON_SEL_NEXT))   return window_selector_require(rsp, window_manager_find_next_window_in_stack(sm, wm, acting_window), "the next stacked window");
    if (token_equals(token, ARGUMENT_COMMON_SEL_FIRST))  return window_selector_require(rsp, window_manager_find_first_window_in_stack(sm, wm, acting_window), "the first stacked window");
    if (token_equals(token, ARGUMENT_COMMON_SEL_LAST))   return window_selector_require(rsp, window_manager_find_last_window_in_stack(sm, wm, acting_window), "the last stacked window");
    if (token_equals(token, ARGUMENT_COMMON_SEL_RECENT)) return window_selector_require(rsp, window_manager_find_recent_window_in_stack(sm, wm, acting_window), "the recent stacked window");

    int index;
    if (token_is_valid(token) && token_is_positive_integer(token, &index) && index > 0) {
        struct window *window = window_manager_find_window_in_stack(sm, wm, acting_window, index);
        if (!window) daemon_fail(rsp, "could not locate the stacked window in position %d.\n", index);
        return window;
    }

    *did_parse = false;
    daemon_fail(rsp, "value '%s%.*s' is not a valid option for WINDOW_SEL\n", ARGUMENT_COMMON_SEL_STACK_PREFIX, token.length, token.text);
    return NULL;
}

static struct selector parse_window_selector(FILE *rsp, char **message, struct window *acting_window, bool optional)
{
    TIME_FUNCTION;

    struct space_manager *sm = &g_space_manager;
    struct window_manager *wm = &g_window_manager;
    struct selector result = { .token = get_token(message), .did_parse = true };
    struct token_value value = token_to_value(result.token);

    if (value.type == TOKEN_TYPE_INT) {
        result.window = window_manager_find_window(wm, value.int_value);
        if (!result.window) daemon_fail(rsp, "could not locate window with the specified id '%d'.\n", value.int_value);
    } else if (value.type == TOKEN_TYPE_STRING) {
        struct token token = result.token;
        int direction = parse_direction(token);
        bool stack = token_prefix(token, ARGUMENT_COMMON_SEL_STACK_PREFIX);
        bool relative = direction || stack || token_equals(token, ARGUMENT_COMMON_SEL_PREV) || token_equals(token, ARGUMENT_COMMON_SEL_NEXT);

        if (relative && !acting_window) {
            daemon_fail(rsp, "could not locate the selected window.\n");
        } else if (direction) {
            char what[64];
            snprintf(what, sizeof(what), "%s managed window", direction_str(direction));
            result.window = window_selector_require(rsp, window_manager_find_closest_managed_window_in_direction(wm, acting_window, direction), what);
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_MOUSE)) {
            result.window = window_selector_require(rsp, window_manager_find_window_below_cursor(wm), "a window below the cursor");
        } else if (token_equals(token, ARGUMENT_WINDOW_SEL_LARGEST)) {
            result.window = window_selector_require(rsp, window_manager_find_largest_managed_window(sm, wm), "window with the largest area");
        } else if (token_equals(token, ARGUMENT_WINDOW_SEL_SMALLEST)) {
            result.window = window_selector_require(rsp, window_manager_find_smallest_managed_window(sm, wm), "window with the smallest area");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_PREV)) {
            result.window = window_selector_require(rsp, window_manager_find_prev_managed_window(sm, wm, acting_window), "the prev managed window");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_NEXT)) {
            result.window = window_selector_require(rsp, window_manager_find_next_managed_window(sm, wm, acting_window), "the next managed window");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_FIRST)) {
            result.window = window_selector_require(rsp, window_manager_find_first_managed_window(sm, wm), "the first managed window");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_LAST)) {
            result.window = window_selector_require(rsp, window_manager_find_last_managed_window(sm, wm), "the last managed window");
        } else if (token_equals(token, ARGUMENT_COMMON_SEL_RECENT)) {
            result.window = window_selector_require(rsp, window_manager_find_recent_managed_window(wm), "the most recently focused window");
        } else if (stack) {
            token.text   += strlen(ARGUMENT_COMMON_SEL_STACK_PREFIX);
            token.length -= strlen(ARGUMENT_COMMON_SEL_STACK_PREFIX);
            result.window = parse_stack_window_selector(rsp, token, acting_window, &result.did_parse);
        } else {
            result.did_parse = false;
            daemon_fail(rsp, "value '%.*s' is not a valid option for WINDOW_SEL\n", token.length, token.text);
        }
    } else {
        result.did_parse = false;
        if (value.type != TOKEN_TYPE_INVALID || !optional) {
            daemon_fail(rsp, "value '%.*s' is not a valid option for WINDOW_SEL\n", result.token.length, result.token.text);
        }
    }

    return result;
}

//
// NOTE: An optional selector replaces the acting display, space or window when one is given. These
// return false when the given selector does not select anything (the parser has reported why).
//

static bool parse_optional_display_selector(FILE *rsp, char **message, uint32_t *did)
{
    struct selector selector = parse_display_selector(rsp, message, *did, true);
    if (!token_is_valid(selector.token)) return true;
    if (!selector.did_parse || !selector.did) return false;

    *did = selector.did;
    return true;
}

static bool parse_optional_space_selector(FILE *rsp, char **message, uint64_t *sid)
{
    struct selector selector = parse_space_selector(rsp, message, *sid, true);
    if (!token_is_valid(selector.token)) return true;
    if (!selector.did_parse || !selector.sid) return false;

    *sid = selector.sid;
    return true;
}

static bool parse_optional_window_selector(FILE *rsp, char **message, struct window **window)
{
    struct selector selector = parse_window_selector(rsp, message, *window, true);
    if (!token_is_valid(selector.token)) return true;
    if (!selector.did_parse || !selector.window) return false;

    *window = selector.window;
    return true;
}

static struct selector parse_insert_selector(FILE *rsp, char **message)
{
    struct selector result = { .token = get_token(message), .did_parse = true };

    if (token_equals(result.token, ARGUMENT_COMMON_SEL_NORTH)) {
        result.dir = DIR_NORTH;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_EAST)) {
        result.dir = DIR_EAST;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_SOUTH)) {
        result.dir = DIR_SOUTH;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_WEST)) {
        result.dir = DIR_WEST;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_STACK)) {
        result.dir = STACK;
    } else {
        result.did_parse = false;
        daemon_fail(rsp, "value '%.*s' is not a valid option for DIR_SEL\n", result.token.length, result.token.text);
    }

    return result;
}

#define TREE_FOCUS_PARENT 1
#define TREE_FOCUS_CHILD  2

static int peek_tree_direction(char *message)
{
    struct token token = get_token(&message);
    int direction = parse_direction(token);
    if (direction) return direction;
    if (token_equals(token, ARGUMENT_WINDOW_SEL_PARENT)) return TREE_FOCUS_PARENT;
    if (token_equals(token, ARGUMENT_WINDOW_SEL_CHILD))  return TREE_FOCUS_CHILD;
    return 0;
}

static struct rgba_color *tab_bar_color_for_command(struct token command)
{
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FOCUSED_COLOR))        return &g_window_manager.tab_bar_focused_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FOCUSED_TEXT_COLOR))   return &g_window_manager.tab_bar_focused_text_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_INACTIVE_COLOR))       return &g_window_manager.tab_bar_inactive_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_INACTIVE_TEXT_COLOR))  return &g_window_manager.tab_bar_inactive_text_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_UNFOCUSED_COLOR))      return &g_window_manager.tab_bar_unfocused_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_UNFOCUSED_TEXT_COLOR)) return &g_window_manager.tab_bar_unfocused_text_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_BACKDROP_COLOR))       return &g_window_manager.tab_bar_backdrop_color;
    return NULL;
}

static bool *tab_bar_color_custom_for_command(struct token command)
{
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FOCUSED_COLOR))   return &g_window_manager.tab_bar_focused_color_custom;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_INACTIVE_COLOR))  return &g_window_manager.tab_bar_inactive_color_custom;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_UNFOCUSED_COLOR)) return &g_window_manager.tab_bar_unfocused_color_custom;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_BACKDROP_COLOR))  return &g_window_manager.tab_bar_backdrop_color_custom;
    return NULL;
}

static void config_scratchpad_grid(FILE *rsp, struct token domain, struct token command, char **message)
{
    unsigned *grid = g_window_manager.scratchpad_grid;
    unsigned r, c, x, y, w, h;
    struct token value = get_token(message);

    if (!token_is_valid(value)) {
        if (grid[0] == 0 || grid[1] == 0) {
            fprintf(rsp, "%s\n", ARGUMENT_COMMON_VAL_OFF);
        } else {
            fprintf(rsp, "%u:%u:%u:%u:%u:%u\n", grid[0], grid[1], grid[2], grid[3], grid[4], grid[5]);
        }
    } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        memset(grid, 0, sizeof(g_window_manager.scratchpad_grid));
    } else if ((sscanf(value.text, ARGUMENT_WINDOW_GRID, &r, &c, &x, &y, &w, &h) == 6) && r > 0 && c > 0) {
        grid[0] = r; grid[1] = c; grid[2] = x; grid[3] = y; grid[4] = w; grid[5] = h;
    } else {
        daemon_fail_unknown_value(rsp, domain, command, value);
    }
}

//
// NOTE: space_layout takes one layout per display count, e.g. '15 10:5 10:5:1b'. The layouts are the
// tokens that start with a digit, so the next command can follow them. Returns false when the message
// is invalid and the remaining commands must not be run.
//

static bool config_space_layout(FILE *rsp, struct token domain, struct token command, char **message, uint64_t sel_sid)
{
    if (sel_sid) {
        daemon_fail(rsp, "command '%.*s' for domain '%.*s' does not support the '%s' selector\n", command.length, command.text, domain.length, domain.text, SELECTOR_CONFIG_SPACE);
        return false;
    }

    char *cursor = *message;
    struct token value = get_token(message);

    if (!token_is_valid(value)) {
        fprintf(rsp, "%s\n", g_space_manager.space_layout_spec ? g_space_manager.space_layout_spec : ARGUMENT_COMMON_VAL_OFF);
        return true;
    }

    if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        if (g_space_manager.space_layout_spec) free(g_space_manager.space_layout_spec);
        g_space_manager.space_layout_spec = NULL;
        g_space_manager.space_layout_count = 0;
        return true;
    }

    struct space_layout layout_list[SPACE_LAYOUT_MAX];
    int layout_count = 0;
    char spec[256] = {0};
    int spec_length = 0;

    while (token_is_valid(value) && value.text[0] >= '0' && value.text[0] <= '9') {
        if (layout_count == SPACE_LAYOUT_MAX || !space_manager_parse_space_layout(value.text, value.length, &layout_list[layout_count])) {
            daemon_fail(rsp, "invalid value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            return false;
        }

        for (int i = 0; i < layout_count; ++i) {
            if (layout_list[i].count == layout_list[layout_count].count) {
                daemon_fail(rsp, "value '%.*s' given to command '%.*s' for domain '%.*s' repeats a layout for %d display(s)\n", value.length, value.text, command.length, command.text, domain.length, domain.text, layout_list[i].count);
                return false;
            }
        }

        spec_length += snprintf(spec + spec_length, sizeof(spec) - spec_length, "%s%.*s", layout_count ? " " : "", value.length, value.text);
        if (spec_length >= (int) sizeof(spec)) {
            daemon_fail(rsp, "value given to command '%.*s' for domain '%.*s' is too long\n", command.length, command.text, domain.length, domain.text);
            return false;
        }

        ++layout_count;
        cursor = *message;
        value = get_token(message);
    }

    if (!layout_count) {
        daemon_fail_unknown_value(rsp, domain, command, value);
        return false;
    }

    *message = cursor;

    memcpy(g_space_manager.space_layout, layout_list, sizeof(struct space_layout) * layout_count);
    g_space_manager.space_layout_count = layout_count;
    if (g_space_manager.space_layout_spec) free(g_space_manager.space_layout_spec);
    g_space_manager.space_layout_spec = string_copy(spec);
    space_layout_schedule(0.0, true);
    return true;
}

//
// NOTE: Animations need the scripting addition and Screen Recording permission; 0 turns them off.
//

static void config_animation_duration(FILE *rsp, struct token domain, struct token command, char **message)
{
    struct token_value value = token_to_value(get_token(message));
    float duration;

    if (value.type == TOKEN_TYPE_INVALID) {
        fprintf(rsp, "%f\n", g_window_manager.window_animation_duration);
    } else if (!token_value_float(value, &duration)) {
        daemon_fail_unknown_value(rsp, domain, command, value.token);
    } else if (duration == 0.0f) {
        g_window_manager.window_animation_duration = duration;
    } else if (!scripting_addition_is_sip_friendly()) {
        daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires System Integrity Protection to be partially disabled! ignoring request..\n", command.length, command.text, domain.length, domain.text);
    } else if (CGPreflightScreenCaptureAccess()) {
        g_window_manager.window_animation_duration = duration;
    } else {
        daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires Screen Recording permissions! ignoring request..\n", command.length, command.text, domain.length, domain.text);
        CGRequestScreenCaptureAccess();
    }
}

static void config_layout(FILE *rsp, struct token domain, struct token command, char **message, uint64_t sel_sid)
{
    struct token value = get_token(message);

    if (!token_is_valid(value)) {
        enum view_type layout = sel_sid ? space_manager_find_view(&g_space_manager, sel_sid)->layout : g_space_manager.layout;
        fprintf(rsp, "%s\n", view_type_str[layout]);
        return;
    }

    enum view_type layout = token_equals(value, ARGUMENT_CONFIG_LAYOUT_FLOAT) ? VIEW_FLOAT
                          : token_equals(value, ARGUMENT_CONFIG_LAYOUT_TREE)  ? VIEW_TREE
                          : VIEW_DEFAULT;

    if (layout == VIEW_DEFAULT) {
        daemon_fail_unknown_value(rsp, domain, command, value);
    } else if (!sel_sid) {
        space_manager_set_layout_for_all_spaces(&g_space_manager, layout);
    } else if (!space_is_user(sel_sid)) {
        daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
    } else {
        view_set_flag(space_manager_find_view(&g_space_manager, sel_sid), VIEW_LAYOUT);
        space_manager_set_layout_for_space(&g_space_manager, sel_sid, layout);
    }
}

static void config_external_bar(FILE *rsp, struct token domain, struct token command, char **message)
{
    int top, bottom;
    char mode[6];
    struct token value = get_token(message);

    if (sscanf(value.text, ARGUMENT_CONFIG_EXTERNAL_BAR, mode, &top, &bottom) != 3) {
        fprintf(rsp, "%s:%d:%d\n", external_bar_mode_str[g_display_manager.mode], g_display_manager.top_padding, g_display_manager.bottom_padding);
        return;
    }

    for (int i = 0; i < array_count(external_bar_mode_str); ++i) {
        if (string_equals(mode, external_bar_mode_str[i])) {
            g_display_manager.mode = i;
            g_display_manager.top_padding = top;
            g_display_manager.bottom_padding = bottom;
            space_manager_mark_spaces_invalid(&g_space_manager);
            return;
        }
    }

    daemon_fail(rsp, "unknown mode '%s' specified in value '%.*s' given to command '%.*s' for domain '%.*s'\n", mode, value.length, value.text, command.length, command.text, domain.length, domain.text);
}

static enum view_flag spacing_for_command(struct token command)
{
    if (token_equals(command, COMMAND_CONFIG_TOP_PADDING))    return VIEW_TOP_PADDING;
    if (token_equals(command, COMMAND_CONFIG_BOTTOM_PADDING)) return VIEW_BOTTOM_PADDING;
    if (token_equals(command, COMMAND_CONFIG_LEFT_PADDING))   return VIEW_LEFT_PADDING;
    if (token_equals(command, COMMAND_CONFIG_RIGHT_PADDING))  return VIEW_RIGHT_PADDING;
    if (token_equals(command, COMMAND_CONFIG_WINDOW_GAP))     return VIEW_WINDOW_GAP;
    return 0;
}

static void handle_domain_config(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    uint64_t sel_sid = 0;
    struct token selector = get_token(&message);
    struct token command  = selector;

    bool found_selector = token_equals(selector, SELECTOR_CONFIG_SPACE);
    if (found_selector) {
        struct selector space_selector = parse_space_selector(rsp, &message, 0, false);
        if (!space_selector.did_parse || !space_selector.sid) return;

        sel_sid = space_selector.sid;
        command = get_token(&message);
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (token_equals(command, COMMAND_CONFIG_DEBUG_OUTPUT)) {
            parse_config_bool(rsp, domain, command, &message, &g_verbose);
        } else if (token_equals(command, COMMAND_CONFIG_MFF)) {
            parse_config_bool(rsp, domain, command, &message, &g_window_manager.enable_mff);
        } else if (token_equals(command, COMMAND_CONFIG_FFM)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", ffm_mode_str[g_window_manager.ffm_mode]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_DISABLED);
            } else if (token_equals(value, ARGUMENT_CONFIG_FFM_AUTOFOCUS)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_AUTOFOCUS);
            } else if (token_equals(value, ARGUMENT_CONFIG_FFM_AUTORAISE)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_AUTORAISE);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_DISPLAY_ORDER)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, display_arrangement_order_str, DISPLAY_ARRANGEMENT_ORDER_DEFAULT, DISPLAY_ARRANGEMENT_ORDER_Y, g_display_manager.order, &choice)) g_display_manager.order = choice;
        } else if (token_equals(command, COMMAND_CONFIG_BUILTIN_LAST)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_display_manager.builtin_last)) space_layout_schedule(0.0, true);
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_ORIGIN)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, window_origin_mode_str, WINDOW_ORIGIN_DEFAULT, WINDOW_ORIGIN_CURSOR, g_window_manager.window_origin_mode, &choice)) g_window_manager.window_origin_mode = choice;
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_EXCLUSIVE)) {
            parse_config_bool(rsp, domain, command, &message, &g_window_manager.scratchpad_exclusive);
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_RAISE)) {
            parse_config_bool(rsp, domain, command, &message, &g_window_manager.scratchpad_raise);
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_BELOW)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_window_manager.scratchpad_below)) window_manager_set_scratchpad_layers(&g_window_manager);
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_GRID)) {
            config_scratchpad_grid(rsp, domain, command, &message);
        } else if (token_equals(command, COMMAND_CONFIG_SKIP_SPACE_ANIMATION)) {
            parse_config_bool(rsp, domain, command, &message, &g_space_manager.skip_window_focus_animation);
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_LAYOUT)) {
            if (!config_space_layout(rsp, domain, command, &message, sel_sid)) return;
        } else if (token_equals(command, COMMAND_CONFIG_OPACITY)) {
            bool enabled = g_window_manager.enable_window_opacity;
            if (parse_config_bool(rsp, domain, command, &message, &enabled)) window_manager_set_window_opacity_enabled(&g_window_manager, enabled);
        } else if (token_equals(command, COMMAND_CONFIG_OPACITY_DURATION)) {
            struct token_value value = token_to_value(get_token(&message));
            float duration;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_opacity_duration);
            } else if (token_value_float(value, &duration)) {
                g_window_manager.window_opacity_duration = duration;
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_DURATION)) {
            config_animation_duration(rsp, domain, command, &message);
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_EASING)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, animation_easing_type_str, 0, EASING_TYPE_COUNT-1, g_window_manager.window_animation_easing, &choice)) g_window_manager.window_animation_easing = choice;
        } else if (token_equals(command, COMMAND_CONFIG_SHADOW)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, purify_mode_str, PURIFY_DISABLED, PURIFY_ALWAYS, g_window_manager.purify_mode, &choice)) window_manager_set_purify_mode(&g_window_manager, choice);
        } else if (token_equals(command, COMMAND_CONFIG_MENUBAR_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.menubar_opacity);
            } else if (token_value_float(value, &opacity) && in_range_ii(opacity, 0.0f, 1.0f)) {
                window_manager_set_menubar_opacity(&g_window_manager, opacity);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ACTIVE_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.active_window_opacity);
            } else if (token_value_float(value, &opacity) && in_range_ei(opacity, 0.0f, 1.0f)) {
                window_manager_set_active_window_opacity(&g_window_manager, opacity);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_NORMAL_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.normal_window_opacity);
            } else if (token_value_float(value, &opacity) && in_range_ei(opacity, 0.0f, 1.0f)) {
                window_manager_set_normal_window_opacity(&g_window_manager, opacity);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_INSERT_FEEDBACK_COLOR)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "0x%x\n", g_window_manager.insert_feedback_color.p);
            } else if (value.type == TOKEN_TYPE_U32 && value.u32_value) {
                g_window_manager.insert_feedback_color = rgba_color_from_hex(value.u32_value);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_BORDER)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_window_manager.enable_window_border)) border_refresh_all();
        } else if (token_equals(command, COMMAND_CONFIG_BORDER_HIDE_SINGLE)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_window_manager.window_border_hide_single)) border_refresh_all();
        } else if (token_equals(command, COMMAND_CONFIG_BORDER_WIDTH)) {
            struct token_value value = token_to_value(get_token(&message));
            float width;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.window_border_width);
            } else if (token_value_float(value, &width) && width > 0.0f) {
                g_window_manager.window_border_width = width;
                border_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ACTIVE_BORDER_COLOR) || token_equals(command, COMMAND_CONFIG_NORMAL_BORDER_COLOR)) {
            struct rgba_color *color = token_equals(command, COMMAND_CONFIG_ACTIVE_BORDER_COLOR)
                                     ? &g_window_manager.active_window_border_color
                                     : &g_window_manager.normal_window_border_color;
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "0x%x\n", color->p);
            } else if (value.type == TOKEN_TYPE_U32) {
                *color = rgba_color_from_hex(value.u32_value);
                border_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_window_manager.enable_tab_bar)) tab_bar_refresh_all();
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_HEIGHT)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%d\n", g_window_manager.tab_bar_height);
            } else if (value.type == TOKEN_TYPE_INT && value.int_value > 0) {
                g_window_manager.tab_bar_height = value.int_value;
                tab_bar_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_OFFSET)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%d\n", g_window_manager.tab_bar_offset);
            } else if (value.type == TOKEN_TYPE_INT) {
                g_window_manager.tab_bar_offset = value.int_value;
                tab_bar_refresh_all();
            } else if (value.type == TOKEN_TYPE_FLOAT && value.float_value == (int) value.float_value) {
                g_window_manager.tab_bar_offset = (int) value.float_value;
                tab_bar_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_ICONS)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_window_manager.tab_bar_icons)) tab_bar_redraw_all();
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_STYLE)) {
            struct token value = get_token(&message);
            enum tab_bar_style style;
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", tab_bar_style_str[g_window_manager.tab_bar_style]);
            } else if (tab_bar_parse_style(value.text, &style)) {
                g_window_manager.tab_bar_style = style;
                tab_bar_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_BACKDROP)) {
            struct token value = get_token(&message);
            enum tab_bar_backdrop backdrop;
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", tab_bar_backdrop_str[g_window_manager.tab_bar_backdrop]);
            } else if (tab_bar_parse_backdrop(value.text, &backdrop)) {
                g_window_manager.tab_bar_backdrop = backdrop;
                tab_bar_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_CARD_PADDING)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%d\n", g_window_manager.tab_bar_card_padding);
            } else if (value.type == TOKEN_TYPE_INT && value.int_value >= 0) {
                g_window_manager.tab_bar_card_padding = value.int_value;
                tab_bar_refresh_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_WINDOW_RADIUS)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%d\n", g_window_manager.tab_bar_window_radius);
            } else if (value.type == TOKEN_TYPE_INT && value.int_value >= 0) {
                g_window_manager.tab_bar_window_radius = value.int_value;
                tab_bar_redraw_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FONT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", g_window_manager.tab_bar_font_name ? g_window_manager.tab_bar_font_name : "");
            } else if (tab_bar_set_font(value.text)) {
                tab_bar_redraw_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (tab_bar_color_for_command(command)) {
            struct rgba_color *color = tab_bar_color_for_command(command);
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "0x%x\n", color->p);
            } else if (value.type == TOKEN_TYPE_U32) {
                *color = rgba_color_from_hex(value.u32_value);
                bool *custom = tab_bar_color_custom_for_command(command);
                if (custom) *custom = true;
                tab_bar_redraw_all();
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (spacing_for_command(command)) {
            enum view_flag flag = spacing_for_command(command);
            struct view *view = sel_sid ? space_manager_find_view(&g_space_manager, sel_sid) : NULL;
            int *spacing = view ? view_spacing(view, flag) : space_manager_spacing(&g_space_manager, flag);
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%d\n", *spacing);
            } else if (value.type != TOKEN_TYPE_INT) {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            } else if (view) {
                view_set_flag(view, flag);
                *spacing = value.int_value;
                view_update_and_flush(view);
            } else {
                space_manager_set_spacing_for_all_spaces(&g_space_manager, flag, value.int_value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_LAYOUT)) {
            config_layout(rsp, domain, command, &message, sel_sid);
        } else if (token_equals(command, COMMAND_CONFIG_TREE_ORIENTATION)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, tree_orientation_str, TREE_ORIENTATION_AUTO, TREE_ORIENTATION_VERTICAL, g_space_manager.tree_default_orientation, &choice)) g_space_manager.tree_default_orientation = choice;
        } else if (token_equals(command, COMMAND_CONFIG_TREE_WORKSPACE_LAYOUT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", g_space_manager.tree_workspace_tabbed ? ARGUMENT_CONFIG_TREE_TABBED : ARGUMENT_CONFIG_TREE_DEFAULT);
            } else if (token_equals(value, ARGUMENT_CONFIG_TREE_DEFAULT)) {
                g_space_manager.tree_workspace_tabbed = false;
            } else if (token_equals(value, ARGUMENT_CONFIG_TREE_TABBED)) {
                g_space_manager.tree_workspace_tabbed = true;
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TREE_AUTOTILING)) {
            parse_config_bool(rsp, domain, command, &message, &g_space_manager.tree_autotiling);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_WRAPPING)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, focus_wrapping_str, FOCUS_WRAPPING_OFF, FOCUS_WRAPPING_FORCE, g_window_manager.focus_wrapping, &choice)) g_window_manager.focus_wrapping = choice;
        } else if (token_equals(command, COMMAND_CONFIG_AUTO_PADDING)) {
            if (sel_sid) {
                bool enabled = space_manager_find_view(&g_space_manager, sel_sid)->auto_padding;
                if (parse_config_bool(rsp, domain, command, &message, &enabled)) space_manager_set_auto_padding_for_space(&g_space_manager, sel_sid, enabled);
            } else {
                bool enabled = g_space_manager.auto_padding;
                if (parse_config_bool(rsp, domain, command, &message, &enabled)) space_manager_set_auto_padding_for_all_spaces(&g_space_manager, enabled);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_MOD)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mod_str, MOUSE_MOD_ALT, MOUSE_MOD_FN, g_mouse_state.modifier, &choice)) g_mouse_state.modifier = choice;
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_ACTION1)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mode_str, MOUSE_MODE_MOVE, MOUSE_MODE_RESIZE, g_mouse_state.action1, &choice)) g_mouse_state.action1 = choice;
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_ACTION2)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mode_str, MOUSE_MODE_MOVE, MOUSE_MODE_RESIZE, g_mouse_state.action2, &choice)) g_mouse_state.action2 = choice;
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_DROP_ACTION)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mode_str, MOUSE_MODE_SWAP, MOUSE_MODE_STACK, g_mouse_state.drop_action, &choice)) g_mouse_state.drop_action = choice;
        } else if (token_equals(command, COMMAND_CONFIG_EXTERNAL_BAR)) {
            config_external_bar(rsp, domain, command, &message);
        } else {
            daemon_fail_unknown_command(rsp, domain, command);
        }
    }
}

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
                display_manager_set_label_for_display(&g_display_manager, acting_did, label);
            } else {
                if (!display_manager_remove_label_for_display(&g_display_manager, acting_did)) {
                    daemon_fail(rsp, "the selected display was not associated with a label!\n");
                }
            }
        }
    } else {
        daemon_fail_unknown_command(rsp, domain, command);
    }
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
        if (token_equals(command, COMMAND_SPACE_FOCUS) || token_equals(command, COMMAND_SPACE_SWITCH)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
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
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_move_space_to_space(acting_sid, selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot move space to itself.\n");
                } else if (result == SPACE_OP_ERROR_SAME_DISPLAY) {
                    daemon_fail(rsp, "cannot move space across display boundaries. use --display instead.\n");
                } else {
                    daemon_fail_space_op(rsp, result, "move space");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_SWAP)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_swap_space_with_space(acting_sid, selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot swap space with itself.\n");
                } else {
                    daemon_fail_space_op(rsp, result, "swap space");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_DISPLAY)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                enum space_op_error result = space_manager_move_space_to_display(&g_space_manager, acting_sid, selector.did);
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
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.did) {
                    acting_sid = display_space_id(selector.did);
                } else {
                    return;
                }
            }

            enum space_op_error result = space_manager_add_space(acting_sid);
            if (result == SPACE_OP_ERROR_MISSING_SRC) {
                daemon_fail(rsp, "could not locate the space to act on.\n");
            } else {
                daemon_fail_space_op(rsp, result, "create space");
            }
        } else if (token_equals(command, COMMAND_SPACE_DESTROY)) {
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            enum space_op_error result = space_manager_destroy_space(acting_sid);
            if (result == SPACE_OP_ERROR_MISSING_SRC) {
                daemon_fail(rsp, "could not locate the space to act on.\n");
            } else if (result == SPACE_OP_ERROR_INVALID_SRC) {
                daemon_fail(rsp, "acting space is the last user-space on the source display and cannot be destroyed.\n");
            } else if (result == SPACE_OP_ERROR_INVALID_TYPE) {
                daemon_fail(rsp, "cannot destroy a macOS fullscreen space.\n");
            } else {
                daemon_fail_space_op(rsp, result, "destroy space");
            }
        } else if (token_equals(command, COMMAND_SPACE_EQUALIZE) || token_equals(command, COMMAND_SPACE_BALANCE)) {
            //
            // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
            //

            struct token value = get_token(&message);
            if (token_is_valid(value) && !token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X) && !token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!space_manager_balance_space(&g_space_manager, acting_sid)) {
                daemon_fail(rsp, "cannot %s a non-managed space.\n", token_equals(command, COMMAND_SPACE_EQUALIZE) ? "equalize" : "balance");
            }
        } else if (token_equals(command, COMMAND_SPACE_MIRROR)) {
            struct token value = get_token(&message);
            enum window_split axis = token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X) ? SPLIT_X
                                   : token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y) ? SPLIT_Y
                                   : SPLIT_NONE;
            if (axis == SPLIT_NONE) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!space_manager_mirror_space(&g_space_manager, acting_sid, axis)) {
                daemon_fail(rsp, "cannot mirror a non-managed space.\n");
            }
        } else if (token_equals(command, COMMAND_SPACE_ROTATE)) {
            struct token value = get_token(&message);
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
            struct token value = get_token(&message);
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
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_SPACE_GAP, type, &gap) == 2)) {
                if (!space_manager_set_gap_for_space(&g_space_manager, acting_sid, parse_value_type(type), gap)) {
                    daemon_fail(rsp, "cannot set gap for a non-managed space.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_SPACE_TOGGLE)) {
            struct token value = get_token(&message);
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
            struct token value = get_token(&message);
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
            if (parse_label(rsp, get_token(&message), LABEL_SPACE, &label)) {
                if (label) {
                    space_manager_set_label_for_space(&g_space_manager, acting_sid, label);
                } else {
                    if (!space_manager_remove_label_for_space(&g_space_manager, acting_sid)) {
                        daemon_fail(rsp, "the selected space was not associated with a label!\n");
                    }
                }
            }
        } else {
            daemon_fail_unknown_command(rsp, domain, command);
        }
    }
}

static void window_toggle_float(struct window *window)           { window_manager_make_window_floating(&g_space_manager, &g_window_manager, window, !window_check_flag(window, WINDOW_FLOAT), false); }
static void window_toggle_sticky(struct window *window)          { window_manager_make_window_sticky(&g_space_manager, &g_window_manager, window, !window_check_flag(window, WINDOW_STICKY)); }
static void window_toggle_split(struct window *window)           { space_manager_toggle_window_split(&g_space_manager, window); }
static void window_toggle_zoom_parent(struct window *window)     { window_manager_toggle_window_zoom_parent(&g_window_manager, window); }
static void window_toggle_zoom_fullscreen(struct window *window) { window_manager_toggle_window_zoom_fullscreen(&g_window_manager, window); }
static void window_toggle_pip(struct window *window)             { window_manager_toggle_window_pip(&g_space_manager, window); }

typedef void window_toggle_func(struct window *window);

static const struct {
    char *value;
    window_toggle_func *toggle;
} window_toggle_list[] = {
    { ARGUMENT_WINDOW_TOGGLE_FLOAT,    window_toggle_float },
    { ARGUMENT_WINDOW_TOGGLE_STICKY,   window_toggle_sticky },
    { ARGUMENT_WINDOW_TOGGLE_SHADOW,   window_manager_toggle_window_shadow },
    { ARGUMENT_WINDOW_TOGGLE_SPLIT,    window_toggle_split },
    { ARGUMENT_WINDOW_TOGGLE_PARENT,   window_toggle_zoom_parent },
    { ARGUMENT_WINDOW_TOGGLE_FULLSC,   window_toggle_zoom_fullscreen },
    { ARGUMENT_WINDOW_TOGGLE_WINDOWED, window_manager_toggle_window_windowed_fullscreen },
    { ARGUMENT_WINDOW_TOGGLE_NATIVE,   window_manager_toggle_window_native_fullscreen },
    { ARGUMENT_WINDOW_TOGGLE_EXPOSE,   window_manager_toggle_window_expose },
    { ARGUMENT_WINDOW_TOGGLE_PIP,      window_toggle_pip }
};

//
// NOTE: Returns NULL when value is not a window property, so that it can be a scratchpad label.
//

static window_toggle_func *window_toggle_for_value(struct token value)
{
    for (int i = 0; i < array_count(window_toggle_list); ++i) {
        if (token_equals(value, window_toggle_list[i].value)) {
            return window_toggle_list[i].toggle;
        }
    }

    return NULL;
}

static void handle_domain_window(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    struct window *acting_window = window_manager_acting_window(&g_window_manager);
    struct selector selector = parse_window_selector(NULL, &message, acting_window, true);

    if (selector.did_parse) {
        acting_window = selector.window;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (!acting_window &&
            !token_equals(command, COMMAND_WINDOW_FOCUS) &&
            !token_equals(command, COMMAND_WINDOW_CLOSE) &&
            !token_equals(command, COMMAND_WINDOW_MINIMIZE) &&
            !token_equals(command, COMMAND_WINDOW_DEMINIMIZE) &&
            !token_equals(command, COMMAND_WINDOW_TOGGLE)) {
            daemon_fail(rsp, "could not locate the window to act on!\n");
            return;
        }

        if (token_equals(command, COMMAND_WINDOW_FOCUS)) {
            int tree_direction = window_manager_find_tree_view(&g_window_manager, acting_window) ? peek_tree_direction(message) : 0;
            if (tree_direction) {
                get_token(&message);

                enum window_op_error result;
                if (tree_direction == TREE_FOCUS_PARENT) {
                    result = window_manager_tree_focus_parent(&g_window_manager, acting_window);
                } else if (tree_direction == TREE_FOCUS_CHILD) {
                    result = window_manager_tree_focus_child(&g_window_manager, acting_window);
                } else {
                    result = window_manager_tree_focus_direction(&g_window_manager, acting_window, tree_direction);
                }

                if (result != WINDOW_OP_ERROR_SUCCESS) {
                    daemon_fail(rsp, "could not locate a container to focus.\n");
                    return;
                }

                continue;
            }

            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                window_manager_focus_window_with_raise(&acting_window->application->psn, acting_window->id, acting_window->ref);
                window_manager_set_pending_focus(&g_window_manager, acting_window->id);
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_CLOSE)) {
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                if (!window_manager_close_window(acting_window)) {
                    daemon_fail(rsp, "could not close window with id '%d'.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_MINIMIZE)) {
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                enum window_op_error result = window_manager_minimize_window(acting_window);
                if (result == WINDOW_OP_ERROR_CANT_MINIMIZE) {
                    daemon_fail(rsp, "window with id '%d' does not support the minimize operation.\n", acting_window->id);
                } else if (result == WINDOW_OP_ERROR_ALREADY_MINIMIZED) {
                    daemon_fail(rsp, "window with id '%d' is already minimized.\n", acting_window->id);
                } else if (result == WINDOW_OP_ERROR_MINIMIZE_FAILED) {
                    daemon_fail(rsp, "could not minimize window with id '%d'.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_DEMINIMIZE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_deminimize_window(selector.window);
                if (result == WINDOW_OP_ERROR_NOT_MINIMIZED) {
                    daemon_fail(rsp, "window with id '%d' is not minimized.\n", selector.window->id);
                } else if (result == WINDOW_OP_ERROR_DEMINIMIZE_FAILED) {
                    daemon_fail(rsp, "could not deminimize window with id '%d'.\n", selector.window->id);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_DISPLAY)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                uint64_t sid = display_space_id(selector.did);
                if (space_is_fullscreen(sid)) {
                    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
                } else {
                    window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, sid, false);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_SPACE)) {
            struct selector selector = parse_space_selector(rsp, &message, space_manager_active_space(), false);
            if (selector.did_parse && selector.sid) {
                if (space_is_fullscreen(selector.sid)) {
                    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
                } else {
                    window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, selector.sid, false);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_SWAP)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_swap_window(&g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot swap a window with itself.\n");
                } else {
                    daemon_fail_unmanaged_window(rsp, result);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_WARP)) {
            int tree_direction = window_manager_find_tree_view(&g_window_manager, acting_window) ? peek_tree_direction(message) : 0;
            if (tree_direction > TREE_FOCUS_CHILD) {
                get_token(&message);

                if (window_manager_tree_move_direction(&g_space_manager, &g_window_manager, acting_window, tree_direction) != WINDOW_OP_ERROR_SUCCESS) {
                    daemon_fail(rsp, "could not move the container in that direction.\n");
                    return;
                }

                continue;
            }

            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_warp_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot warp a window onto itself.\n");
                } else {
                    daemon_fail_unmanaged_window(rsp, result);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_STACK)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_stack_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot stack a window onto itself.\n");
                } else {
                    daemon_fail_unmanaged_window(rsp, result);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_LAYOUT)) {
            struct token value = get_token(&message);
            enum window_layout layout;

            if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_TABBED)) {
                layout = WINDOW_LAYOUT_TABBED;
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_SPLIT)) {
                layout = WINDOW_LAYOUT_SPLIT;
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_TOGGLE)) {
                layout = WINDOW_LAYOUT_TOGGLE;
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_SPLITH)) {
                layout = WINDOW_LAYOUT_SPLITH;
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_SPLITV)) {
                layout = WINDOW_LAYOUT_SPLITV;
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYOUT_TGL_SPLIT)) {
                layout = WINDOW_LAYOUT_TOGGLE_SPLIT;
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
                return;
            }

            daemon_fail_unmanaged_window(rsp, window_manager_set_window_layout(&g_window_manager, acting_window, layout));
        } else if (token_equals(command, COMMAND_WINDOW_SPLIT)) {
            struct token value = get_token(&message);
            int orientation;

            if (token_equals(value, ARGUMENT_WINDOW_SPLIT_H)) {
                orientation = CON_HORIZONTAL;
            } else if (token_equals(value, ARGUMENT_WINDOW_SPLIT_V)) {
                orientation = CON_VERTICAL;
            } else if (token_equals(value, ARGUMENT_WINDOW_SPLIT_TOGGLE)) {
                orientation = -1;
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
                return;
            }

            daemon_fail_unmanaged_window(rsp, window_manager_tree_split(&g_window_manager, acting_window, orientation));
        } else if (token_equals(command, COMMAND_WINDOW_INSERT)) {
            struct selector selector = parse_insert_selector(rsp, &message);
            if (selector.did_parse && selector.dir) {
                daemon_fail_unmanaged_window(rsp, window_manager_set_window_insertion(&g_space_manager, acting_window, selector.dir));
            }
        } else if (token_equals(command, COMMAND_WINDOW_GRID)) {
            unsigned r, c, x, y, w, h;
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_GRID, &r, &c, &x, &y, &w, &h) == 6)) {
                enum window_op_error result = window_manager_apply_grid(&g_space_manager, &g_window_manager, acting_window, r, c, x, y, w, h);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot apply grid layout to a managed window.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_MOVE)) {
            float x, y;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_MOVE, type, &x, &y) == 3)) {
                enum window_op_error result = window_manager_move_window_relative(&g_window_manager, acting_window, parse_value_type(type), x, y);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot move a managed window.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RESIZE)) {
            float w, h;
            char handle[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_RESIZE, handle, &w, &h) == 3)) {
                enum window_op_error result = window_manager_resize_window_relative(&g_window_manager, acting_window, parse_resize_handle(handle), w, h, true);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "cannot locate the container of the managed window.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_NODE) {
                    daemon_fail(rsp, "cannot resize the container in that direction.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_OPERATION) {
                    daemon_fail(rsp, "cannot use absolute resizing on a managed window.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RATIO)) {
            float r;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_RATIO, type, &r) == 2)) {
                enum window_op_error result = window_manager_adjust_window_ratio(&g_window_manager, acting_window, parse_value_type(type), r);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot adjust ratio of a non-managed window.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "cannot adjust ratio of a root node.\n");
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_WINDOW_TOGGLE)) {
            struct token value = get_token(&message);
            window_toggle_func *toggle = window_toggle_for_value(value);
            if (!toggle) {
                if (!window_manager_toggle_scratchpad_window_by_label(&g_window_manager, value.text)) {
                    daemon_fail_unknown_value(rsp, domain, command, value);
                }
            } else if (acting_window) {
                toggle(acting_window);
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_SUB_LAYER)) {
            struct token value = get_token(&message);
            int layer = parse_layer(value.text);
            if (layer == -1) {
                daemon_fail_unknown_value(rsp, domain, command, value);
            } else if (!window_manager_set_window_layer(acting_window, layer)) {
                daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (token_value_float(value, &opacity) && in_range_ii(opacity, 0.0f, 1.0f)) {
                if (window_manager_set_opacity(&g_window_manager, acting_window, opacity)) {
                    acting_window->opacity = opacity;
                } else {
                    daemon_fail(rsp, "could not change opacity of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RAISE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);
            uint32_t selector_wid = 0;

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    selector_wid = selector.window->id;
                } else {
                    return;
                }
            }

            if (!scripting_addition_order_window(acting_window->id, 1, selector_wid)) {
                daemon_fail(rsp, "could not raise window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_LOWER)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);
            uint32_t selector_wid = 0;

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    selector_wid = selector.window->id;
                } else {
                    return;
                }
            }

            if (!scripting_addition_order_window(acting_window->id, -1, selector_wid)) {
                daemon_fail(rsp, "could not lower window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_SCRATCHPAD)) {
            char *label;
            struct token token = get_token(&message);
            if (token_is_valid(token) && token_equals(token, ARGUMENT_WINDOW_SCRATCHPAD_RECOVER)) {
                window_manager_scratchpad_recover_windows();
            } else if (parse_label(rsp, token, LABEL_WINDOW, &label)) {
                if (label) {
                    if (!window_manager_set_scratchpad_for_window(&g_window_manager, acting_window, label)) {
                        daemon_fail(rsp, "the given scratchpad is already assigned to a different window!\n");
                    }
                } else {
                    if (!window_manager_remove_scratchpad_for_window(&g_window_manager, acting_window, true)) {
                        daemon_fail(rsp, "the selected window was not assigned to a scratchpad!\n");
                    }
                }
            }
        } else {
            daemon_fail_unknown_command(rsp, domain, command);
        }
    }
}

static void handle_domain_query(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_QUERY_DISPLAYS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), display_property_val, display_property_str, array_count(display_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            if (!parse_optional_display_selector(rsp, &message, &acting_did)) return;

            display_serialize(rsp, acting_did, properties.flags);
            fprintf(rsp, "\n");
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            display_serialize(rsp, space_display_id(acting_sid), properties.flags);
            fprintf(rsp, "\n");
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_acting_window(&g_window_manager);
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                display_serialize(rsp, window_display_id(acting_window->id), properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not find window to retrieve display details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
        } else {
            display_manager_query_displays(rsp, properties.flags);
        }
    } else if (token_equals(command, COMMAND_QUERY_SPACES)) {
        struct properties properties = parse_properties(rsp, get_token(&message), space_property_val, space_property_str, array_count(space_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            if (!parse_optional_display_selector(rsp, &message, &acting_did)) return;

            if (!space_manager_query_spaces_for_display(rsp, acting_did, properties.flags)) {
                daemon_fail(rsp, "could not retrieve spaces for display.\n");
            }
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            if (!space_manager_query_space(rsp, acting_sid, properties.flags)) {
                daemon_fail(rsp, "could not retrieve space details.\n");
            }
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_acting_window(&g_window_manager);
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                space_manager_query_spaces_for_window(rsp, acting_window, properties.flags);
            } else {
                daemon_fail(rsp, "could not find window to retrieve space details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
        } else if (!space_manager_query_spaces_for_displays(rsp, properties.flags)) {
            daemon_fail(rsp, "could not retrieve spaces for displays.\n");
        }
    } else if (token_equals(command, COMMAND_QUERY_WINDOWS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), window_property_val, window_property_str, array_count(window_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            if (!parse_optional_display_selector(rsp, &message, &acting_did)) return;

            window_manager_query_windows_for_display(rsp, acting_did, properties.flags);
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            if (!parse_optional_space_selector(rsp, &message, &acting_sid)) return;

            window_manager_query_windows_for_spaces(rsp, &acting_sid, 1, properties.flags);
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_acting_window(&g_window_manager);
            if (!parse_optional_window_selector(rsp, &message, &acting_window)) return;

            if (acting_window) {
                window_serialize(rsp, acting_window, properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not retrieve window details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail_unknown_option(rsp, domain, command, option);
        } else {
            window_manager_query_windows_for_displays(rsp, properties.flags);
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

static bool parse_rule_pattern(struct rule *rule, char *value, bool exclusion, char **pattern, regex_t *regex, enum rule_flag valid_flag, enum rule_flag exclude_flag)
{
    *pattern = string_copy(value);
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
            rule->label = string_copy(value);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SCRATCHPAD)) {
            for (int i = 0; i < array_count(reserved_window_identifiers); ++i) {
                if (string_equals(value, reserved_window_identifiers[i])) {
                    valid_value = false;
                    break;
                }
            }

            if (valid_value) {
                rule->effects.scratchpad = string_copy(value);
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
            if (value[0] == ARGUMENT_RULE_VALUE_SPACE) {
                ++value;
                rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
            }

            struct selector selector = parse_display_selector(rsp, &value, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                rule->effects.did = selector.did;
            } else {
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SPACE)) {
            if (value[0] == ARGUMENT_RULE_VALUE_SPACE) {
                ++value;
                rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
            }

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
