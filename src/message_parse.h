#ifndef MESSAGE_PARSE_H
#define MESSAGE_PARSE_H

//
// NOTE: The types of the message parsers that the handlers of message*.c share with the Swift port. The parsers are
// Swift (Sources/YabaiCore/Message.swift, MessageParse.swift and Rule.swift); the shims that keep the C signatures are
// in Sources/Yabai/Shims/MessageShims.swift. get_token, the token comparisons, daemon_fail and the failures of space
// and window operations stay in message_parse.c until the handlers are Swift (P6); Message.next() is get_token's twin.
//

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

enum label_type
{
    LABEL_DISPLAY,
    LABEL_SPACE,
    LABEL_WINDOW
};

struct properties
{
    struct token token;
    bool did_parse;
    bool did_error;
    uint64_t flags;
};

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

#define TREE_FOCUS_PARENT 1
#define TREE_FOCUS_CHILD  2

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
// NOTE: The global singletons of yabai.c, which the Swift shims use while the managers are C. Swift 6 rejects references
// to mutable C globals, so the shims take their addresses through these functions.
//

extern struct event_loop g_event_loop;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern bool g_verbose;

static inline struct display_manager *display_manager_global(void) { return &g_display_manager; }
static inline struct space_manager *space_manager_global(void) { return &g_space_manager; }
static inline struct window_manager *window_manager_global(void) { return &g_window_manager; }
static inline struct event_loop *event_loop_global(void) { return &g_event_loop; }
static inline struct mouse_state *mouse_state_global(void) { return &g_mouse_state; }
static inline bool *verbose_global(void) { return &g_verbose; }

struct token get_token(char **message);

// implemented in Sources/Yabai/Shims/MessageShims.swift
struct token_value token_to_value(struct token token);
bool token_value_float(struct token_value value, float *result);
void daemon_fail_unknown_command(FILE *rsp, struct token domain, struct token command);
void daemon_fail_unknown_option(FILE *rsp, struct token domain, struct token command, struct token option);
void daemon_fail_unknown_value(FILE *rsp, struct token domain, struct token command, struct token value);
int parse_layer(char *value);
uint8_t parse_value_type(char *type);
uint8_t parse_resize_handle(char *handle);
int window_toggle_index(struct token value);
bool parse_label(FILE *rsp, struct token token, enum label_type type, char **label);
struct properties parse_properties(FILE *rsp, struct token token, uint64_t *property_val, char **property_str, int property_count);
struct selector parse_display_selector(FILE *rsp, char **message, uint32_t acting_did, bool optional);
struct selector parse_space_selector(FILE *rsp, char **message, uint64_t acting_sid, bool optional);
struct selector parse_window_selector(FILE *rsp, char **message, struct window *acting_window, bool optional);
bool parse_optional_display_selector(FILE *rsp, char **message, uint32_t *did);
bool parse_optional_space_selector(FILE *rsp, char **message, uint64_t *sid);
bool parse_optional_window_selector(FILE *rsp, char **message, struct window **window);
struct selector parse_insert_selector(FILE *rsp, char **message);
int peek_tree_direction(char *message);
bool parse_query_target(FILE *rsp, struct token domain, struct token command, char **message, struct properties properties, struct query_target *target);
bool parse_rule(FILE *rsp, char **message, struct rule *rule, struct token token);
bool parse_signal(FILE *rsp, char **message, struct signal *signal, enum signal_type *signal_type);

#endif
