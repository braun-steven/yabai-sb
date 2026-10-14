//
// NOTE: The protocol of the messages of the client: the domains, commands and arguments, the tokens a
// message is made of, the selectors of displays, spaces and windows, and the failure responses.
// The handlers of the domains are in message_config.c and message.c.
//

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
            struct label *display_label = label_find_name(g_display_manager.labels, value.string_value);
            if (display_label) {
                result.did = display_label->id;
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
            struct label *space_label = label_find_name(g_space_manager.labels, value.string_value);
            if (space_label) {
                result.sid = space_label->id;
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

