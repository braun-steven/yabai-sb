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

CF_RETURNS_RETAINED CFStringRef window_display_uuid(uint32_t wid)
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

char *window_title_ts(struct window *window)
{
    return window->title ? ts_cfstring_copy(window->title) : ts_string_copy("");
}

CF_RETURNS_RETAINED CFStringRef window_title(struct window *window)
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
    msg.header.msgh_id = 0x76E3;

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

CF_RETURNS_RETAINED CFStringRef window_ax_role(struct window *window)
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

CF_RETURNS_RETAINED CFStringRef window_ax_subrole(struct window *window)
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

struct window *window_create(struct application *application, CF_CONSUMED AXUIElementRef window_ref, uint32_t window_id)
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
