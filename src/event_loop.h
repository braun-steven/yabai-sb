#ifndef EVENT_LOOP_H
#define EVENT_LOOP_H

#define EVENT_TYPE_LIST \
    EVENT_TYPE_ENTRY(APPLICATION_LAUNCHED) \
    EVENT_TYPE_ENTRY(APPLICATION_TERMINATED) \
    EVENT_TYPE_ENTRY(APPLICATION_FRONT_SWITCHED) \
    EVENT_TYPE_ENTRY(APPLICATION_VISIBLE) \
    EVENT_TYPE_ENTRY(APPLICATION_HIDDEN) \
    EVENT_TYPE_ENTRY(WINDOW_CREATED) \
    EVENT_TYPE_ENTRY(WINDOW_DESTROYED) \
    EVENT_TYPE_ENTRY(WINDOW_FOCUSED) \
    EVENT_TYPE_ENTRY(WINDOW_FOCUS_DEFERRED) \
    EVENT_TYPE_ENTRY(WINDOW_MOVED) \
    EVENT_TYPE_ENTRY(WINDOW_RESIZED) \
    EVENT_TYPE_ENTRY(WINDOW_MINIMIZED) \
    EVENT_TYPE_ENTRY(WINDOW_DEMINIMIZED) \
    EVENT_TYPE_ENTRY(WINDOW_TITLE_CHANGED) \
    EVENT_TYPE_ENTRY(SLS_WINDOW_ORDERED) \
    EVENT_TYPE_ENTRY(SLS_WINDOW_DESTROYED) \
    EVENT_TYPE_ENTRY(SLS_SPACE_CREATED) \
    EVENT_TYPE_ENTRY(SLS_SPACE_DESTROYED) \
    EVENT_TYPE_ENTRY(SPACE_CHANGED) \
    EVENT_TYPE_ENTRY(DISPLAY_ADDED) \
    EVENT_TYPE_ENTRY(DISPLAY_REMOVED) \
    EVENT_TYPE_ENTRY(DISPLAY_MOVED) \
    EVENT_TYPE_ENTRY(DISPLAY_RESIZED) \
    EVENT_TYPE_ENTRY(DISPLAY_CHANGED) \
    EVENT_TYPE_ENTRY(MOUSE_DOWN) \
    EVENT_TYPE_ENTRY(MOUSE_UP) \
    EVENT_TYPE_ENTRY(MOUSE_DRAGGED) \
    EVENT_TYPE_ENTRY(MOUSE_MOVED) \
    EVENT_TYPE_ENTRY(TAB_BAR_CLICKED) \
    EVENT_TYPE_ENTRY(MISSION_CONTROL_SHOW_ALL_WINDOWS) \
    EVENT_TYPE_ENTRY(MISSION_CONTROL_SHOW_FRONT_WINDOWS) \
    EVENT_TYPE_ENTRY(MISSION_CONTROL_SHOW_DESKTOP) \
    EVENT_TYPE_ENTRY(MISSION_CONTROL_ENTER) \
    EVENT_TYPE_ENTRY(MISSION_CONTROL_CHECK_FOR_EXIT) \
    EVENT_TYPE_ENTRY(MISSION_CONTROL_EXIT) \
    EVENT_TYPE_ENTRY(DOCK_DID_RESTART) \
    EVENT_TYPE_ENTRY(MENU_OPENED) \
    EVENT_TYPE_ENTRY(MENU_CLOSED) \
    EVENT_TYPE_ENTRY(MENU_BAR_HIDDEN_CHANGED) \
    EVENT_TYPE_ENTRY(DOCK_DID_CHANGE_PREF) \
    EVENT_TYPE_ENTRY(SYSTEM_WOKE) \
    EVENT_TYPE_ENTRY(SPACE_LAYOUT_RECONCILE) \
    EVENT_TYPE_ENTRY(DAEMON_MESSAGE)

enum event_type
{
#define EVENT_TYPE_ENTRY(value) value,
    EVENT_TYPE_LIST
#undef EVENT_TYPE_ENTRY
};

//
// NOTE: The event loop and the handlers are Swift (Sources/Yabai/EventLoop.swift, EventHandlers*.swift): event_loop_post
// maps an event to the Event enum and queues it on the serial queue of the @WM actor. Any thread may post an event.
//

void event_loop_post(enum event_type type, void *context, int param1);

//
// NOTE: The flags that producers on other threads set for the handlers, Swift Atomics in EventHandlers.swift. The C code
// that sets or reads them calls these until it is Swift.
//

void pending_window_focus_set(bool value);
bool pending_window_focus(void);
void pending_gesture_set(bool value);
void last_gesture_time_set(uint64_t time);
void pending_mouse_dragged_add(void);
void pending_mouse_moved_add(void);

void update_window_notifications(void);

#endif
