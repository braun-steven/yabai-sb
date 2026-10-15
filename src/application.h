#ifndef APPLICATION_H
#define APPLICATION_H

// the bits of application->notification, in the order of the notifications of application_observe (Application.swift)
#define AX_APPLICATION_WINDOW_CREATED_INDEX       0
#define AX_APPLICATION_WINDOW_FOCUSED_INDEX       1
#define AX_APPLICATION_WINDOW_MOVED_INDEX         2
#define AX_APPLICATION_WINDOW_RESIZED_INDEX       3
#define AX_APPLICATION_WINDOW_TITLE_CHANGED_INDEX 4
#define AX_APPLICATION_WINDOW_MENU_OPENED_INDEX   5
#define AX_APPLICATION_WINDOW_MENU_CLOSED_INDEX   6

#define AX_APPLICATION_WINDOW_CREATED       (1 << AX_APPLICATION_WINDOW_CREATED_INDEX)
#define AX_APPLICATION_WINDOW_FOCUSED       (1 << AX_APPLICATION_WINDOW_FOCUSED_INDEX)
#define AX_APPLICATION_WINDOW_MOVED         (1 << AX_APPLICATION_WINDOW_MOVED_INDEX)
#define AX_APPLICATION_WINDOW_RESIZED       (1 << AX_APPLICATION_WINDOW_RESIZED_INDEX)
#define AX_APPLICATION_WINDOW_TITLE_CHANGED (1 << AX_APPLICATION_WINDOW_TITLE_CHANGED_INDEX)
#define AX_APPLICATION_ALL                  (AX_APPLICATION_WINDOW_CREATED |\
                                             AX_APPLICATION_WINDOW_FOCUSED |\
                                             AX_APPLICATION_WINDOW_MOVED |\
                                             AX_APPLICATION_WINDOW_RESIZED |\
                                             AX_APPLICATION_WINDOW_TITLE_CHANGED)

//
// NOTE: The functions of struct application are Swift (Sources/Yabai/Application.swift). The struct stays C until
// P14 converts the window/process tables and the model bridges together.
//

struct application
{
    AXUIElementRef ref;
    int connection;
    ProcessSerialNumber psn;
    pid_t pid;
    char *name;
    CGImageRef icon;
    AXObserverRef observer_ref;
    uint8_t notification;
    bool is_observing;
    bool is_hidden;
    bool ax_retry;
};

#endif
