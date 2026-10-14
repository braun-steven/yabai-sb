extern struct window_manager g_window_manager;
extern int g_layer_normal_window_level;
extern int g_layer_below_window_level;
extern int g_layer_above_window_level;
extern int g_connection;

bool window_observe(struct window *window)
{
    for (int i = 0; i < array_count(ax_window_notification); ++i) {
        AXError result = AXObserverAddNotification(window->application->observer_ref, window->ref, ax_window_notification[i], window);
        if (result == kAXErrorSuccess || result == kAXErrorNotificationAlreadyRegistered) {
            window->notification |= 1 << i;
        } else {
            debug("%s: %s failed with error %s\n", __FUNCTION__, ax_window_notification_str[i], ax_error_str[-result]);
        }
    }

    return (window->notification & AX_WINDOW_ALL) == AX_WINDOW_ALL;
}

void window_unobserve(struct window *window)
{
    for (int i = 0; i < array_count(ax_window_notification); ++i) {
        if (!(window->notification & (1 << i))) continue;

        AXObserverRemoveNotification(window->application->observer_ref, window->ref, ax_window_notification[i]);
        window->notification &= ~(1 << i);
    }
}

CFStringRef window_display_uuid(uint32_t wid)
{
    CFStringRef uuid = SLSCopyManagedDisplayForWindow(g_connection, wid);
    if (!uuid) {
        CGRect frame;
        SLSGetWindowBounds(g_connection, wid, &frame);
        uuid = SLSCopyBestManagedDisplayForRect(g_connection, frame);
    }
    return uuid;
}

uint32_t window_display_id(uint32_t wid)
{
    CFStringRef uuid_string = window_display_uuid(wid);
    if (!uuid_string) return 0;

    CFUUIDRef uuid = CFUUIDCreateFromString(NULL, uuid_string);
    int id = CGDisplayGetDisplayIDFromUUID(uuid);

    CFRelease(uuid);
    CFRelease(uuid_string);

    return id;
}

static uint64_t window_display_space(uint32_t wid)
{
    CFStringRef uuid = window_display_uuid(wid);
    if (!uuid) return 0;

    uint64_t sid = SLSManagedDisplayGetCurrentSpace(g_connection, uuid);
    CFRelease(uuid);

    return sid;
}

uint64_t window_space(uint32_t wid)
{
    uint64_t sid = 0;

    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    CFArrayRef space_list_ref = SLSCopySpacesForWindows(g_connection, 0x7, window_list_ref);
    if (!space_list_ref) goto err;

    int count = CFArrayGetCount(space_list_ref);
    if (!count) goto free;

    CFNumberRef id_ref = CFArrayGetValueAtIndex(space_list_ref, 0);
    CFNumberGetValue(id_ref, CFNumberGetType(id_ref), &sid);

free:
    CFRelease(space_list_ref);
err:
    CFRelease(window_list_ref);

    return sid ? sid : window_display_space(wid);
}

uint64_t *window_space_list(uint32_t wid, int *count)
{
    uint64_t *space_list = NULL;
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    CFArrayRef space_list_ref = SLSCopySpacesForWindows(g_connection, 0x7, window_list_ref);
    if (!space_list_ref) goto err;

    *count = CFArrayGetCount(space_list_ref);
    if (!*count) goto out;

    space_list = ts_alloc_list(uint64_t, *count);

    for (int i = 0; i < *count; ++i) {
        CFNumberRef id_ref = CFArrayGetValueAtIndex(space_list_ref, i);
        CFNumberGetValue(id_ref, CFNumberGetType(id_ref), space_list + i);
    }

out:
    CFRelease(space_list_ref);
err:
    CFRelease(window_list_ref);
    return space_list;
}

static inline const char *window_layer(int level)
{
    if (level == g_layer_below_window_level)  return layer_str[LAYER_BELOW];
    if (level == g_layer_normal_window_level) return layer_str[LAYER_NORMAL];
    if (level == g_layer_above_window_level)  return layer_str[LAYER_ABOVE];
    return "unknown";
}

static inline bool window_property_wanted(uint64_t flags, uint64_t properties)
{
    return (flags & properties) != 0;
}

static void window_info_set_space(struct window_info *info, uint64_t sid, uint64_t flags)
{
    if (flags & WINDOW_PROPERTY_DISPLAY) info->display = display_manager_display_id_arrangement(space_display_id(sid));
    if (flags & WINDOW_PROPERTY_SPACE)   info->space   = space_manager_mission_control_index(sid);
}

static void window_info_set_levels(struct window_info *info, uint32_t wid, uint64_t flags)
{
    if (window_property_wanted(flags, WINDOW_PROPERTY_LEVEL | WINDOW_PROPERTY_LAYER))         info->level     = window_level(wid);
    if (window_property_wanted(flags, WINDOW_PROPERTY_SUB_LEVEL | WINDOW_PROPERTY_SUB_LAYER)) info->sub_level = window_sub_level(wid);
    if (flags & WINDOW_PROPERTY_OPACITY)    info->opacity    = window_opacity(wid);
    if (flags & WINDOW_PROPERTY_HAS_SHADOW) info->has_shadow = window_shadow(wid);
}

static void window_info_set_tree(struct window_info *info, struct con *con)
{
    if (!con) return;

    if (con->parent) {
        if (con->parent->layout == CON_SPLITH) info->split = SPLIT_Y;
        if (con->parent->layout == CON_SPLITV) info->split = SPLIT_X;
    }

    struct con *tab = con;
    while (tab->parent && tab->parent->layout != CON_TABBED) tab = tab->parent;
    info->stack_index = tab->parent ? con_index(tab)+1 : 0;

    info->has_parent_zoom = con->zoom == CON_ZOOM_PARENT;
    info->has_fullscreen_zoom = con->zoom == CON_ZOOM_FULLSCREEN;
}

//
// NOTE: Only the properties selected by flags are queried, because some of them are slow (AX) calls.
//

struct window_info window_info_for_window(struct window *window, uint64_t flags)
{
    struct window_info info = {
        .id               = window->id,
        .pid              = window->application->pid,
        .app              = window->application->name,
        .scratchpad       = window->scratchpad ? window->scratchpad : "",
        .frame            = window->frame,
        .is_root          = window->is_root,
        .has_focus        = window->id == g_window_manager.focused_window_id,
        .has_ax_reference = true,
        .is_fullscreen    = window_check_flag(window, WINDOW_FULLSCREEN),
        .is_minimized     = window_check_flag(window, WINDOW_MINIMIZE),
        .is_hidden        = window->application->is_hidden,
        .is_floating      = window_check_flag(window, WINDOW_FLOAT),
        .is_grabbed       = window == g_mouse_state.window
    };

    if (flags & WINDOW_PROPERTY_TITLE)      info.title      = window_title_ts(window);
    if (flags & WINDOW_PROPERTY_ROLE)       info.role       = window_role_ts(window);
    if (flags & WINDOW_PROPERTY_SUBROLE)    info.subrole    = window_subrole_ts(window);
    if (flags & WINDOW_PROPERTY_CAN_MOVE)   info.can_move   = window_can_move(window);
    if (flags & WINDOW_PROPERTY_CAN_RESIZE) info.can_resize = window_can_resize(window);
    window_info_set_levels(&info, window->id, flags);

    uint64_t sid = 0;
    if (window_property_wanted(flags, WINDOW_PROPERTY_DISPLAY | WINDOW_PROPERTY_SPACE | WINDOW_PROPERTY_IS_VISIBLE)) {
        sid = window_space(window->id);
        window_info_set_space(&info, sid, flags);
    }

    if (window_property_wanted(flags, WINDOW_PROPERTY_SPLIT_TYPE | WINDOW_PROPERTY_STACK_INDEX | WINDOW_PROPERTY_HAS_PARENT_ZOOM | WINDOW_PROPERTY_HAS_FULLSCREEN_ZOOM)) {
        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        window_info_set_tree(&info, view ? tree_view_find_window(view, window->id) : NULL);
    }

    if (window_property_wanted(flags, WINDOW_PROPERTY_IS_VISIBLE | WINDOW_PROPERTY_IS_STICKY)) {
        info.is_sticky = window_check_flag(window, WINDOW_STICKY) || window_is_sticky(window->id);
    }

    if (flags & WINDOW_PROPERTY_IS_VISIBLE) {
        uint8_t ordered_in = 0;
        SLSWindowIsOrderedIn(g_connection, window->id, &ordered_in);
        info.is_visible = ordered_in && !info.is_minimized && !info.is_hidden && (info.is_sticky || space_is_visible(sid));
    }

    return info;
}

//
// NOTE: Windows that yabai has no AX reference for only report what the window server knows.
//

struct window_info window_info_for_window_id(uint32_t wid, uint64_t flags)
{
    static char process_name[PROC_PIDPATHINFO_MAXSIZE];

    struct window_info info = {
        .id         = wid,
        .app        = process_name,
        .scratchpad = "",
        .role       = "",
        .subrole    = ""
    };

    if (window_property_wanted(flags, WINDOW_PROPERTY_PID | WINDOW_PROPERTY_APP)) {
        int connection;
        SLSGetWindowOwner(g_connection, wid, &connection);
        SLSConnectionGetPID(connection, &info.pid);
        if (flags & WINDOW_PROPERTY_APP) proc_name(info.pid, process_name, sizeof(process_name));
    }

    if (flags & WINDOW_PROPERTY_TITLE)       info.title     = window_property_title_ts(wid);
    if (flags & WINDOW_PROPERTY_FRAME)       SLSGetWindowBounds(g_connection, wid, &info.frame);
    if (flags & WINDOW_PROPERTY_ROOT_WINDOW) info.is_root   = window_parent(wid) == 0;
    if (flags & WINDOW_PROPERTY_IS_STICKY)   info.is_sticky = window_is_sticky(wid);
    window_info_set_levels(&info, wid, flags);

    if (window_property_wanted(flags, WINDOW_PROPERTY_DISPLAY | WINDOW_PROPERTY_SPACE | WINDOW_PROPERTY_IS_FULLSCREEN)) {
        uint64_t sid = window_space(wid);
        window_info_set_space(&info, sid, flags);
        if (flags & WINDOW_PROPERTY_IS_FULLSCREEN) info.is_fullscreen = space_is_fullscreen(sid);
    }

    return info;
}

void window_info_serialize(FILE *rsp, struct window_info *info, uint64_t flags)
{
    TIME_FUNCTION;

    char *separator = "";
    fprintf(rsp, "{\n");

    JSON_PROPERTY(WINDOW_PROPERTY_ID,                  "\"id\":%d", info->id);
    JSON_PROPERTY(WINDOW_PROPERTY_PID,                 "\"pid\":%d", info->pid);
    JSON_PROPERTY(WINDOW_PROPERTY_APP,                 "\"app\":\"%s\"", json_string(info->app));
    JSON_PROPERTY(WINDOW_PROPERTY_TITLE,               "\"title\":\"%s\"", json_string(info->title));
    JSON_PROPERTY(WINDOW_PROPERTY_SCRATCHPAD,          "\"scratchpad\":\"%s\"", json_string(info->scratchpad));
    JSON_PROPERTY(WINDOW_PROPERTY_FRAME,               "\"frame\":" JSON_FRAME_FORMAT, JSON_FRAME_VALUES(info->frame));
    JSON_PROPERTY(WINDOW_PROPERTY_ROLE,                "\"role\":\"%s\"", json_string(info->role));
    JSON_PROPERTY(WINDOW_PROPERTY_SUBROLE,             "\"subrole\":\"%s\"", json_string(info->subrole));
    JSON_PROPERTY(WINDOW_PROPERTY_ROOT_WINDOW,         "\"root-window\":%s", json_bool(info->is_root));
    JSON_PROPERTY(WINDOW_PROPERTY_DISPLAY,             "\"display\":%d", info->display);
    JSON_PROPERTY(WINDOW_PROPERTY_SPACE,               "\"space\":%d", info->space);
    JSON_PROPERTY(WINDOW_PROPERTY_LEVEL,               "\"level\":%d", info->level);
    JSON_PROPERTY(WINDOW_PROPERTY_SUB_LEVEL,           "\"sub-level\":%d", info->sub_level);
    JSON_PROPERTY(WINDOW_PROPERTY_LAYER,               "\"layer\":\"%s\"", window_layer(info->level));
    JSON_PROPERTY(WINDOW_PROPERTY_SUB_LAYER,           "\"sub-layer\":\"%s\"", window_layer(info->sub_level));
    JSON_PROPERTY(WINDOW_PROPERTY_OPACITY,             "\"opacity\":%.4f", info->opacity);
    JSON_PROPERTY(WINDOW_PROPERTY_SPLIT_TYPE,          "\"split-type\":\"%s\"", window_split_str[info->split]);
    JSON_PROPERTY(WINDOW_PROPERTY_STACK_INDEX,         "\"stack-index\":%d", info->stack_index);
    JSON_PROPERTY(WINDOW_PROPERTY_CAN_MOVE,            "\"can-move\":%s", json_bool(info->can_move));
    JSON_PROPERTY(WINDOW_PROPERTY_CAN_RESIZE,          "\"can-resize\":%s", json_bool(info->can_resize));
    JSON_PROPERTY(WINDOW_PROPERTY_HAS_FOCUS,           "\"has-focus\":%s", json_bool(info->has_focus));
    JSON_PROPERTY(WINDOW_PROPERTY_HAS_SHADOW,          "\"has-shadow\":%s", json_bool(info->has_shadow));
    JSON_PROPERTY(WINDOW_PROPERTY_HAS_PARENT_ZOOM,     "\"has-parent-zoom\":%s", json_bool(info->has_parent_zoom));
    JSON_PROPERTY(WINDOW_PROPERTY_HAS_FULLSCREEN_ZOOM, "\"has-fullscreen-zoom\":%s", json_bool(info->has_fullscreen_zoom));
    JSON_PROPERTY(WINDOW_PROPERTY_HAS_AX_REFERENCE,    "\"has-ax-reference\":%s", json_bool(info->has_ax_reference));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_FULLSCREEN,       "\"is-native-fullscreen\":%s", json_bool(info->is_fullscreen));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_VISIBLE,          "\"is-visible\":%s", json_bool(info->is_visible));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_MINIMIZED,        "\"is-minimized\":%s", json_bool(info->is_minimized));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_HIDDEN,           "\"is-hidden\":%s", json_bool(info->is_hidden));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_FLOATING,         "\"is-floating\":%s", json_bool(info->is_floating));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_STICKY,           "\"is-sticky\":%s", json_bool(info->is_sticky));
    JSON_PROPERTY(WINDOW_PROPERTY_IS_GRABBED,          "\"is-grabbed\":%s", json_bool(info->is_grabbed));

    fprintf(rsp, "\n}");
}

void window_serialize(FILE *rsp, struct window *window, uint64_t flags)
{
    if (flags == 0x0) flags |= ~flags;

    struct window_info info = window_info_for_window(window, flags);
    window_info_serialize(rsp, &info, flags);
}

void window_nonax_serialize(FILE *rsp, uint32_t wid, uint64_t flags)
{
    if (flags == 0x0) flags |= ~flags;

    struct window_info info = window_info_for_window_id(wid, flags);
    window_info_serialize(rsp, &info, flags);
}

char *window_property_title_ts(uint32_t wid)
{
    CFTypeRef value = NULL;
    SLSCopyWindowProperty(g_connection, wid, CFSTR("kCGSWindowTitle"), &value);
    if (!value) return ts_string_copy("");

    char *result = ts_cfstring_copy(value);
    CFRelease(value);
    return result;
}

char *window_title_ts(struct window *window)
{
    return window->title ? ts_cfstring_copy(window->title) : ts_string_copy("");
}

CFStringRef window_title(struct window *window)
{
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(window->ref, kAXTitleAttribute, &value);
    return value;
}

CGPoint window_ax_origin(struct window *window)
{
    CGPoint origin = {0};
    CFTypeRef position_ref = NULL;

    AXUIElementCopyAttributeValue(window->ref, kAXPositionAttribute, &position_ref);

    if (position_ref) {
        AXValueGetValue(position_ref, kAXValueTypeCGPoint, &origin);
        CFRelease(position_ref);
    }

    return origin;
}

CGRect window_ax_frame(struct window *window)
{
    CGRect frame = {0};
    CFTypeRef position_ref = NULL;
    CFTypeRef size_ref = NULL;

    AXUIElementCopyAttributeValue(window->ref, kAXPositionAttribute, &position_ref);
    AXUIElementCopyAttributeValue(window->ref, kAXSizeAttribute, &size_ref);

    if (position_ref) {
        AXValueGetValue(position_ref, kAXValueTypeCGPoint, &frame.origin);
        CFRelease(position_ref);
    }

    if (size_ref) {
        AXValueGetValue(size_ref, kAXValueTypeCGSize, &frame.size);
        CFRelease(size_ref);
    }

    return frame;
}

bool window_ax_can_move(struct window *window)
{
    Boolean result;
    if (AXUIElementIsAttributeSettable(window->ref, kAXPositionAttribute, &result) != kAXErrorSuccess) {
        result = 0;
    }
    return result;
}

bool window_can_move(struct window *window)
{
    return window_check_flag(window, WINDOW_MOVABLE);
}

bool window_ax_can_resize(struct window *window)
{
    Boolean result;
    if (AXUIElementIsAttributeSettable(window->ref, kAXSizeAttribute, &result) != kAXErrorSuccess) {
        result = 0;
    }
    return result;
}

bool window_can_resize(struct window *window)
{
    return window_check_flag(window, WINDOW_RESIZABLE);
}

bool window_can_minimize(struct window *window)
{
    Boolean result;
    if (AXUIElementIsAttributeSettable(window->ref, kAXMinimizedAttribute, &result) != kAXErrorSuccess) {
        result = 0;
    }
    return result;
}

bool window_is_undersized(struct window *window)
{
    if (window->frame.size.width  <= 500.0f) return true;
    if (window->frame.size.height <= 500.0f) return true;
    return false;
}

static bool window_is_minimized(struct window *window)
{
    Boolean result = 0;
    CFTypeRef value;

    if (AXUIElementCopyAttributeValue(window->ref, kAXMinimizedAttribute, &value) == kAXErrorSuccess) {
        result = CFBooleanGetValue(value);
        CFRelease(value);
    }

    return result;
}

bool window_is_fullscreen(struct window *window)
{
    Boolean result = 0;
    CFTypeRef value;

    if (AXUIElementCopyAttributeValue(window->ref, kAXFullscreenAttribute, &value) == kAXErrorSuccess) {
        result = CFBooleanGetValue(value);
        CFRelease(value);
    }

    return result;
}

bool window_is_sticky(uint32_t wid)
{
    bool result = false;

    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    CFArrayRef space_list_ref = SLSCopySpacesForWindows(g_connection, 0x7, window_list_ref);
    if (!space_list_ref) goto err;

    result = CFArrayGetCount(space_list_ref) > 1;
    CFRelease(space_list_ref);

err:
    CFRelease(window_list_ref);
    return result;
}

bool window_shadow(uint32_t wid)
{
    uint64_t tags = window_tags(wid);
    return !(tags & 0x8);
}

float window_opacity(uint32_t wid)
{
    float alpha = 0.0f;
    SLSGetWindowAlpha(g_connection, wid, &alpha);
    return alpha;
}

uint32_t window_parent(uint32_t wid)
{
    uint32_t parent_wid = 0;

    CFArrayRef window_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);

    CFTypeRef query = SLSWindowQueryWindows(g_connection, window_ref, 1);
    if (!query) goto err2;

    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
    if (!iterator) goto err1;

    if (SLSWindowIteratorGetCount(iterator) == 1) {
        if (SLSWindowIteratorAdvance(iterator)) {
            parent_wid = SLSWindowIteratorGetParentID(iterator);
        }
    }

    CFRelease(iterator);
err1:
    CFRelease(query);
err2:
    CFRelease(window_ref);

    return parent_wid;
}

int window_level(uint32_t wid)
{
    int level = 0;

    if (workspace_is_macos_ventura_or_newer()) {
        CFArrayRef window_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);

        CFTypeRef query = SLSWindowQueryWindows(g_connection, window_ref, 1);
        if (!query) goto err2;

        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
        if (!iterator) goto err1;

        if (SLSWindowIteratorGetCount(iterator) == 1) {
            if (SLSWindowIteratorAdvance(iterator)) {
                level = SLSWindowIteratorGetLevel(iterator);
            }
        }

        CFRelease(iterator);
    err1:
        CFRelease(query);
    err2:
        CFRelease(window_ref);
    } else {
        SLSGetWindowLevel(g_connection, wid, &level);
    }

    return level;
}

static bool SLSGetWindowSubLevel__Internal(int cid, uint32_t wid, int *sub_level)
{
    #pragma pack(push,4)
    struct {
        mach_msg_header_t header;
        NDR_record_t NDR_record;
        uint32_t window_id;
        int32_t sub_level;
        int32_t padding1;
        int32_t padding2;
    } msg = {0};
    #pragma pack(pop)

    msg.NDR_record = NDR_record;
    msg.window_id = wid;
    msg.header.msgh_bits = 0x1513;
    msg.header.msgh_remote_port = CGSGetConnectionPortById(cid);
    msg.header.msgh_local_port = mig_get_special_reply_port();
    msg.header.msgh_id = workspace_is_macos_tahoe() ? 0x76E3 : 0x73C3;

    //
    // NOTE: Bound the wait for the reply, so that a message the window server does not answer (e.g. an
    // unknown msgh_id on a new macOS release) can not block the event loop forever. Like MIG-generated
    // code, the special reply port is destroyed on failure so that a late reply can not be received by
    // the next call on this thread.
    //

    mach_port_t reply_port = msg.header.msgh_local_port;
    kern_return_t kr = mach_msg(&msg.header, MACH_SEND_MSG|MACH_RCV_MSG|MACH_RCV_TIMEOUT, 0x24, 0x30, reply_port, 100, 0);
    if (kr != MACH_MSG_SUCCESS) {
        mig_dealloc_special_reply_port(reply_port);
        return false;
    }

    *sub_level = msg.sub_level;
    return true;
}

int window_sub_level(uint32_t wid)
{
    int sub_level;
    if (CGSGetConnectionPortById && SLSGetWindowSubLevel__Internal(g_connection, wid, &sub_level)) {
        return sub_level;
    }

    return SLSGetWindowSubLevel(g_connection, wid);
}

uint64_t window_tags(uint32_t wid)
{
    uint64_t tags = 0;
    CFArrayRef window_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);

    CFTypeRef query = SLSWindowQueryWindows(g_connection, window_ref, 1);
    if (!query) goto err2;

    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
    if (!iterator) goto err1;

    if (SLSWindowIteratorGetCount(iterator) == 1) {
        if (SLSWindowIteratorAdvance(iterator)) {
            tags = SLSWindowIteratorGetTags(iterator);
        }
    }

    CFRelease(iterator);
err1:
    CFRelease(query);
err2:
    CFRelease(window_ref);

    return tags;
}

CFStringRef window_ax_role(struct window *window)
{
    const void *role = NULL;
    AXUIElementCopyAttributeValue(window->ref, kAXRoleAttribute, &role);
    return role;
}

CFStringRef window_role(struct window *window)
{
    return window->role;
}

char *window_role_ts(struct window *window)
{
    CFStringRef role = window_role(window);
    if (!role) return ts_string_copy("");

    char *result = ts_cfstring_copy(role);
    return result;
}

CFStringRef window_ax_subrole(struct window *window)
{
    const void *srole = NULL;
    AXUIElementCopyAttributeValue(window->ref, kAXSubroleAttribute, &srole);
    return srole;
}

CFStringRef window_subrole(struct window *window)
{
    return window->subrole;
}

char *window_subrole_ts(struct window *window)
{
    CFStringRef subrole = window_subrole(window);
    if (!subrole) return ts_string_copy("");

    char *result = ts_cfstring_copy(subrole);
    return result;
}

static bool window_is_root(struct window *window)
{
    bool result = false;
    CFTypeRef value = NULL;

    if (AXUIElementCopyAttributeValue(window->ref, kAXParentAttribute, &value) == kAXErrorSuccess) {
        result = !(value && !CFEqual(value, window->application->ref));
    }

    if (value) CFRelease(value);
    return result;
}

bool window_is_real(struct window *window)
{
    bool win = false;
    CFStringRef role  = NULL;
    CFStringRef srole = NULL;

    if (!(role  = window_role(window)))    goto out;
    if (!(srole = window_subrole(window))) goto out;

    win = CFEqual(role, kAXWindowRole) &&
          (CFEqual(srole, kAXStandardWindowSubrole) ||
           CFEqual(srole, kAXFloatingWindowSubrole) ||
           CFEqual(srole, kAXDialogSubrole));

out:
    return win;
}

bool window_is_standard(struct window *window)
{
    bool standard_win = false;
    CFStringRef role  = NULL;
    CFStringRef srole = NULL;

    if (!(role  = window_role(window)))    goto out;
    if (!(srole = window_subrole(window))) goto out;

    standard_win = CFEqual(role, kAXWindowRole) &&
                   CFEqual(srole, kAXStandardWindowSubrole);

out:
    return standard_win;
}

bool window_level_is_standard(struct window *window)
{
    int level = window_level(window->id);
    return level == g_layer_normal_window_level;
}

bool window_is_unknown(struct window *window)
{
    CFStringRef subrole = window_subrole(window);
    if (!subrole) return false;

    bool result = CFEqual(subrole, kAXUnknownSubrole);
    return result;
}

//
// NOTE: Windows report other roles and capabilities while they are minimized or in native fullscreen,
// so these cached properties are read again whenever that state changes.
//

void window_refresh_ax_properties(struct window *window)
{
    if (window_ax_can_move(window)) {
        window_set_flag(window, WINDOW_MOVABLE);
    } else {
        window_clear_flag(window, WINDOW_MOVABLE);
    }

    if (window_ax_can_resize(window)) {
        window_set_flag(window, WINDOW_RESIZABLE);
    } else {
        window_clear_flag(window, WINDOW_RESIZABLE);
    }

    if (window->role) CFRelease(window->role);
    window->role = window_ax_role(window);

    if (window->subrole) CFRelease(window->subrole);
    window->subrole = window_ax_subrole(window);
}

struct window *window_create(struct application *application, AXUIElementRef window_ref, uint32_t window_id)
{
    struct window *window = malloc(sizeof(struct window));
    memset(window, 0, sizeof(struct window));

    window->application = application;
    window->ref = window_ref;
    window->id = window_id;
    window->id_ptr = &window->id;
    window->frame = window_ax_frame(window);
    window->title = window_title(window);
    window->is_root = !window_parent(window->id) || window_is_root(window);

    if (window_shadow(window->id)) {
        window_set_flag(window, WINDOW_SHADOW);
    }

    if (window_is_minimized(window)) {
        window_set_flag(window, WINDOW_MINIMIZE);
    }

    window_refresh_ax_properties(window);

    if ((window_is_fullscreen(window)) ||
        (space_is_fullscreen(window_space(window->id)))) {
        window_set_flag(window, WINDOW_FULLSCREEN);
    }

    if (window_is_sticky(window->id)) {
        window_set_flag(window, WINDOW_STICKY);
    }

    return window;
}

void window_destroy(struct window *window)
{
    window->id = 0;
    if (window->role) CFRelease(window->role);
    if (window->subrole) CFRelease(window->subrole);
    if (window->title) CFRelease(window->title);
    CFRelease(window->ref);
    free(window);
}
