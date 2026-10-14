extern struct signal *g_signal_event[SIGNAL_TYPE_COUNT];
extern struct memory_pool g_signal_storage;
extern struct process_manager g_process_manager;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;

static inline bool event_signal_regex_mismatch(bool valid, regex_t *regex, bool exclude, char *text)
{
    return regex_match(valid, regex, text) == (exclude ? REGEX_MATCH_YES : REGEX_MATCH_NO);
}

static inline bool event_signal_active_mismatch(struct event_signal *es, struct signal *signal)
{
    return signal->active != SIGNAL_PROP_UD && es->active != (signal->active == SIGNAL_PROP_YES);
}

//
// NOTE: Returns true when the signal does not apply to the event. Each event type only reports the
// properties (app, title, active) that its signals can filter on.
//

static bool event_signal_filter(struct event_signal *es, struct signal *signal)
{
    bool app = false;
    bool title = false;
    bool active = false;

    switch (es->type) {
    default: return false;

    case SIGNAL_APPLICATION_LAUNCHED:
    case SIGNAL_APPLICATION_ACTIVATED:
    case SIGNAL_APPLICATION_DEACTIVATED:
    case SIGNAL_APPLICATION_VISIBLE: {
        app = true;
    } break;
    case SIGNAL_APPLICATION_TERMINATED:
    case SIGNAL_APPLICATION_HIDDEN:
    case SIGNAL_WINDOW_DESTROYED: {
        app = active = true;
    } break;
    case SIGNAL_WINDOW_CREATED:
    case SIGNAL_WINDOW_FOCUSED:
    case SIGNAL_WINDOW_DEMINIMIZED: {
        app = title = true;
    } break;
    case SIGNAL_WINDOW_MOVED:
    case SIGNAL_WINDOW_RESIZED:
    case SIGNAL_WINDOW_MINIMIZED:
    case SIGNAL_WINDOW_TITLE_CHANGED: {
        app = title = active = true;
    } break;
    }

    if (app && event_signal_regex_mismatch(signal->app_regex_valid, &signal->app_regex, signal->app_regex_exclude, es->app))             return true;
    if (title && event_signal_regex_mismatch(signal->title_regex_valid, &signal->title_regex, signal->title_regex_exclude, es->title)) return true;
    if (active && event_signal_active_mismatch(es, signal))                                                                          return true;

    return false;
}

void event_signal_flush(void)
{
    if (!g_signal_storage.used) return;

    pid_t pid = fork();
    if (pid) {
        g_signal_storage.used = 0;
        return;
    }

    int size  = sizeof(struct event_signal);
    int count = g_signal_storage.used / size;

    for (int i = 0; i < count; ++i) {
        struct event_signal *es = g_signal_storage.memory + (i * size);

        int signal_count = buf_len(g_signal_event[es->type]);
        debug("%s: transmitting %s to %d subscriber(s)\n", __FUNCTION__, signal_type_str[es->type], signal_count);

        for (int j = 0; j < signal_count; ++j) {
            struct signal *signal = &g_signal_event[es->type][j];
            if (event_signal_filter(es, signal)) continue;

            int pid = fork();
            if (pid) continue;

            for (int k = 0; k < es->arg_count; ++k) {
                setenv(es->arg_name[k], es->arg_value[k], 1);
            }

            char *exec[] = { "/usr/bin/env", "sh", "-c", signal->command, NULL};
            execvp(exec[0], exec);
            _exit(EXIT_FAILURE);
        }
    }

    //
    // NOTE: This is a forked copy of a multithreaded process. exit() would run the atexit handlers and
    // finalizers of the frameworks (e.g. CoreSpotlight flushing to PowerLog), which are not safe to run
    // after fork and crash; _exit() skips them.
    //

    _exit(EXIT_SUCCESS);
}

//
// NOTE: The values of the environment variables of a signal command live in temporary storage.
//

__attribute__((format(printf, 3, 4)))
static void event_signal_add_arg(struct event_signal *es, const char *name, const char *format, ...)
{
    assert(es->arg_count < (int) array_count(es->arg_name));

    char *value = ts_alloc_unaligned(EVENT_SIGNAL_ARG_SIZE);
    va_list ap;
    va_start(ap, format);
    vsnprintf(value, EVENT_SIGNAL_ARG_SIZE, format, ap);
    va_end(ap);

    es->arg_name[es->arg_count] = name;
    es->arg_value[es->arg_count] = value;
    ++es->arg_count;
}

//
// NOTE: The signals of an event are stored until event_signal_flush runs their commands. A signal that
// does not fit is dropped.
//

static struct event_signal *event_signal_reserve(enum signal_type type)
{
    uint64_t size = sizeof(struct event_signal);

    uint64_t used = __sync_fetch_and_add(&g_signal_storage.used, size);
    if (used + size > g_signal_storage.size) {
        __sync_fetch_and_sub(&g_signal_storage.used, size);
        debug("%s: too many signals in one event, dropping %s\n", __FUNCTION__, signal_type_str[type]);
        return NULL;
    }

    struct event_signal *es = g_signal_storage.memory + used;
    memset(es, 0, size);
    es->type = type;
    return es;
}

static void event_signal_describe_application(struct event_signal *es, enum signal_type type, void *context)
{
    switch (type) {
    default: break;

    case SIGNAL_APPLICATION_LAUNCHED:
    case SIGNAL_APPLICATION_ACTIVATED:
    case SIGNAL_APPLICATION_DEACTIVATED:
    case SIGNAL_APPLICATION_VISIBLE: {
        struct application *application = context;

        event_signal_add_arg(es, "YABAI_PROCESS_ID", "%d", application->pid);

        es->app = application->name;
    } break;
    case SIGNAL_APPLICATION_TERMINATED: {
        struct application *application = context;

        event_signal_add_arg(es, "YABAI_PROCESS_ID", "%d", application->pid);

        es->app = ts_string_copy(application->name);

        //
        // NOTE(asmvik): We always receive an application_front_switched event *before* an application_terminated
        // event. We need to know the difference between a front_switched + application_terminated sequence and a regular
        // application switch followed by a user-initiated termination of the previously focused application. The system
        // events are triggered within an interval that appear to be impossible to match even with a user automated sequence.
        // The dt threshold below is triple the average interval computed, to allow for some leeway.
        //

        EventTime dt = GetCurrentEventTime() - g_process_manager.switch_event_time;
        if (dt >= 0.05f) {
            es->active = g_process_manager.front_pid == application->pid;
        } else {
            es->active = g_process_manager.last_front_pid == application->pid;
        }
    } break;
    case SIGNAL_APPLICATION_FRONT_SWITCHED: {
        event_signal_add_arg(es, "YABAI_PROCESS_ID", "%d", g_process_manager.front_pid);
        event_signal_add_arg(es, "YABAI_RECENT_PROCESS_ID", "%d", g_process_manager.last_front_pid);
    } break;
    case SIGNAL_APPLICATION_HIDDEN: {
        struct application *application = context;

        event_signal_add_arg(es, "YABAI_PROCESS_ID", "%d", application->pid);

        es->app = application->name;
        es->active = g_process_manager.front_pid == application->pid;
    } break;
    }
}

static void event_signal_describe_window(struct event_signal *es, enum signal_type type, void *context)
{
    switch (type) {
    default: break;

    case SIGNAL_WINDOW_CREATED:
    case SIGNAL_WINDOW_FOCUSED:
    case SIGNAL_WINDOW_DEMINIMIZED: {
        struct window *window = context;

        event_signal_add_arg(es, "YABAI_WINDOW_ID", "%d", window->id);

        es->app   = window->application->name;
        es->title = window_title_ts(window);
    } break;
    case SIGNAL_WINDOW_DESTROYED: {
        struct window *window = context;

        event_signal_add_arg(es, "YABAI_WINDOW_ID", "%d", window->id);

        es->app = window->application ? ts_string_copy(window->application->name) : "<unknown>";
        es->active = g_window_manager.focused_window_id == window->id;
    } break;
    case SIGNAL_WINDOW_MOVED:
    case SIGNAL_WINDOW_RESIZED:
    case SIGNAL_WINDOW_MINIMIZED:
    case SIGNAL_WINDOW_TITLE_CHANGED: {
        struct window *window = context;

        event_signal_add_arg(es, "YABAI_WINDOW_ID", "%d", window->id);

        es->app   = window->application->name;
        es->title = window_title_ts(window);
        es->active = g_window_manager.focused_window_id == window->id;
    } break;
    }
}

static void event_signal_describe_space(struct event_signal *es, enum signal_type type, void *context)
{
    switch (type) {
    default: break;

    case SIGNAL_SPACE_CREATED: {
        uint64_t sid = (uint64_t)(uintptr_t) context;
        int index    = space_manager_mission_control_index(sid);

        event_signal_add_arg(es, "YABAI_SPACE_ID", "%lld", sid);
        event_signal_add_arg(es, "YABAI_SPACE_INDEX", "%d", index);
    } break;
    case SIGNAL_SPACE_DESTROYED: {
        uint64_t sid = (uint64_t)(uintptr_t) context;

        event_signal_add_arg(es, "YABAI_SPACE_ID", "%lld", sid);
    } break;
    case SIGNAL_SPACE_CHANGED: {
        uint64_t sid        = g_space_manager.current_space_id;
        uint64_t recent_sid = g_space_manager.last_space_id;

        int index        = space_manager_mission_control_index(sid);
        int recent_index = space_manager_mission_control_index(recent_sid);

        event_signal_add_arg(es, "YABAI_SPACE_ID", "%lld", sid);
        event_signal_add_arg(es, "YABAI_RECENT_SPACE_ID", "%lld", recent_sid);

        event_signal_add_arg(es, "YABAI_SPACE_INDEX", "%d", index);
        event_signal_add_arg(es, "YABAI_RECENT_SPACE_INDEX", "%d", recent_index);
    } break;
    }
}

static void event_signal_describe_display(struct event_signal *es, enum signal_type type, void *context)
{
    switch (type) {
    default: break;

    case SIGNAL_DISPLAY_ADDED:
    case SIGNAL_DISPLAY_MOVED:
    case SIGNAL_DISPLAY_RESIZED: {
        uint32_t did = (uint32_t)(uintptr_t) context;
        int index    = display_manager_display_id_arrangement(did);

        event_signal_add_arg(es, "YABAI_DISPLAY_ID", "%d", did);
        event_signal_add_arg(es, "YABAI_DISPLAY_INDEX", "%d", index);
    } break;
    case SIGNAL_DISPLAY_REMOVED: {
        uint32_t did = (uint32_t)(uintptr_t) context;

        event_signal_add_arg(es, "YABAI_DISPLAY_ID", "%d", did);
    } break;
    case SIGNAL_DISPLAY_CHANGED: {
        uint32_t did        = g_display_manager.current_display_id;
        uint32_t recent_did = g_display_manager.last_display_id;

        int index        = display_manager_display_id_arrangement(did);
        int recent_index = display_manager_display_id_arrangement(recent_did);

        event_signal_add_arg(es, "YABAI_DISPLAY_ID", "%d", did);
        event_signal_add_arg(es, "YABAI_RECENT_DISPLAY_ID", "%d", recent_did);

        event_signal_add_arg(es, "YABAI_DISPLAY_INDEX", "%d", index);
        event_signal_add_arg(es, "YABAI_RECENT_DISPLAY_INDEX", "%d", recent_index);
    } break;
    }
}

static void event_signal_describe_mission_control(struct event_signal *es, void *context)
{
    enum mission_control_mode mode = (enum mission_control_mode)(uintptr_t) context;
    event_signal_add_arg(es, "YABAI_MISSION_CONTROL_MODE", "%s", mission_control_mode_str[mode]);
}

void event_signal_push(enum signal_type type, void *context)
{
    if (!buf_len(g_signal_event[type])) return;

    struct event_signal *es = event_signal_reserve(type);
    if (!es) return;

    switch (type) {
    default: break;

    case SIGNAL_APPLICATION_LAUNCHED:
    case SIGNAL_APPLICATION_ACTIVATED:
    case SIGNAL_APPLICATION_DEACTIVATED:
    case SIGNAL_APPLICATION_VISIBLE:
    case SIGNAL_APPLICATION_TERMINATED:
    case SIGNAL_APPLICATION_FRONT_SWITCHED:
    case SIGNAL_APPLICATION_HIDDEN: {
        event_signal_describe_application(es, type, context);
    } break;
    case SIGNAL_WINDOW_CREATED:
    case SIGNAL_WINDOW_FOCUSED:
    case SIGNAL_WINDOW_DEMINIMIZED:
    case SIGNAL_WINDOW_DESTROYED:
    case SIGNAL_WINDOW_MOVED:
    case SIGNAL_WINDOW_RESIZED:
    case SIGNAL_WINDOW_MINIMIZED:
    case SIGNAL_WINDOW_TITLE_CHANGED: {
        event_signal_describe_window(es, type, context);
    } break;
    case SIGNAL_SPACE_CREATED:
    case SIGNAL_SPACE_DESTROYED:
    case SIGNAL_SPACE_CHANGED: {
        event_signal_describe_space(es, type, context);
    } break;
    case SIGNAL_DISPLAY_ADDED:
    case SIGNAL_DISPLAY_MOVED:
    case SIGNAL_DISPLAY_RESIZED:
    case SIGNAL_DISPLAY_REMOVED:
    case SIGNAL_DISPLAY_CHANGED: {
        event_signal_describe_display(es, type, context);
    } break;
    case SIGNAL_MISSION_CONTROL_ENTER:
    case SIGNAL_MISSION_CONTROL_EXIT: {
        event_signal_describe_mission_control(es, context);
    } break;
    }
}

enum signal_type signal_type_from_string(const char *str)
{
    for (int i = SIGNAL_APPLICATION_LAUNCHED; i < SIGNAL_TYPE_COUNT; ++i) {
        if (string_equals(str, signal_type_str[i])) return i;
    }

    return SIGNAL_TYPE_UNKNOWN;
}

void event_signal_add(enum signal_type type, struct signal *signal)
{
    if (signal->label) event_signal_remove(signal->label);
    buf_push(g_signal_event[type], *signal);
}

void event_signal_destroy(struct signal *signal)
{
    if (signal->app_regex_valid)   regfree(&signal->app_regex);
    if (signal->title_regex_valid) regfree(&signal->title_regex);
    if (signal->command) free(signal->command);
    if (signal->label)   free(signal->label);
    if (signal->app)     free(signal->app);
    if (signal->title)   free(signal->title);
}

bool event_signal_remove_by_index(int index)
{
    int signal_index = 0;
    for (int i = SIGNAL_APPLICATION_LAUNCHED; i < SIGNAL_TYPE_COUNT; ++i) {
        for (int j = 0; j < buf_len(g_signal_event[i]); ++j) {
            if (signal_index == index) {
                event_signal_destroy(&g_signal_event[i][j]);
                buf_del(g_signal_event[i], j);
                return true;
            }
            ++signal_index;
        }
    }

    return false;
}

bool event_signal_remove(char *label)
{
    for (int i = SIGNAL_APPLICATION_LAUNCHED; i < SIGNAL_TYPE_COUNT; ++i) {
        for (int j = 0; j < buf_len(g_signal_event[i]); ++j) {
            if (string_equals(label, g_signal_event[i][j].label)) {
                event_signal_destroy(&g_signal_event[i][j]);
                buf_del(g_signal_event[i], j);
                return true;
            }
        }
    }

    return false;
}

static void event_signal_serialize(FILE *rsp, struct signal *signal, enum signal_type type, int index)
{
    TIME_FUNCTION;

    fprintf(rsp,
            "{\n"
            "\t\"index\":%d,\n"
            "\t\"label\":\"%s\",\n"
            "\t\"app\":\"%s\",\n"
            "\t\"title\":\"%s\",\n"
            "\t\"active\":%s,\n"
            "\t\"event\":\"%s\",\n"
            "\t\"action\":\"%s\"\n"
            "}",
            index,
            json_string(signal->label),
            json_string(signal->app),
            json_string(signal->title),
            json_optional_bool(signal->active),
            signal_type_str[type],
            json_string(signal->command));
}

void event_signal_list(FILE *rsp)
{
    TIME_FUNCTION;

    fprintf(rsp, "[");
    int signal_index = 0;
    bool event_did_output = false;
    for (int i = SIGNAL_APPLICATION_LAUNCHED; i < SIGNAL_TYPE_COUNT; ++i) {
        int count = buf_len(g_signal_event[i]);

        if (count > 0 && event_did_output) {
            fprintf(rsp, ",");
        }

        for (int j = 0; j < count; ++j) {
            event_signal_serialize(rsp, &g_signal_event[i][j], i, signal_index);
            if (j < buf_len(g_signal_event[i]) - 1) fprintf(rsp, ",");
            ++signal_index;
        }

        if (!event_did_output) event_did_output = count > 0;
    }
    fprintf(rsp, "]\n");
}
