#ifndef MOUSE_H
#define MOUSE_H

//
// NOTE: Private event type and fields of the dock swipe gesture that switches spaces.
//

enum
{
    kCGSEventDockControl          = 30,
    kCGSEventTypeField            = 55,
    kCGEventGestureHIDType        = 110,
    kCGEventGestureSwipeMotion    = 123,
    kCGEventGestureSwipeProgress  = 124,
    kCGEventGestureSwipeVelocityX = 129,
    kCGEventGesturePhase          = 132,
    kIOHIDEventTypeDockSwipe      = 23,
    kCGGestureMotionHorizontal    = 1,
    kCGSGesturePhaseBegan         = 1,
    kCGSGesturePhaseEnded         = 4,
    kCGSGesturePhaseCancelled     = 8
};

#define MOUSE_EVENT_MASK_FFM (1 << kCGEventMouseMoved) | \
                             (1 << kCGEventLeftMouseDown) | \
                             (1 << kCGEventLeftMouseUp) | \
                             (1 << kCGEventLeftMouseDragged) | \
                             (1 << kCGEventRightMouseDown) | \
                             (1 << kCGEventRightMouseUp) | \
                             (1 << kCGEventRightMouseDragged) | \
                             (1 << kCGSEventDockControl)

#define MOUSE_EVENT_MASK     (1 << kCGEventLeftMouseDown) | \
                             (1 << kCGEventLeftMouseUp) | \
                             (1 << kCGEventLeftMouseDragged) | \
                             (1 << kCGEventRightMouseDown) | \
                             (1 << kCGEventRightMouseUp) | \
                             (1 << kCGEventRightMouseDragged) | \
                             (1 << kCGSEventDockControl)

#define MOUSE_HANDLER(name) CGEventRef name(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context)

enum mouse_drop_action
{
    MOUSE_DROP_ACTION_NONE,
    MOUSE_DROP_ACTION_STACK,
    MOUSE_DROP_ACTION_SWAP,
    MOUSE_DROP_ACTION_WARP_TOP,
    MOUSE_DROP_ACTION_WARP_RIGHT,
    MOUSE_DROP_ACTION_WARP_BOTTOM,
    MOUSE_DROP_ACTION_WARP_LEFT
};

enum mouse_mod
{
    MOUSE_MOD_NONE  = 0x01,
    MOUSE_MOD_ALT   = 0x02,
    MOUSE_MOD_SHIFT = 0x04,
    MOUSE_MOD_CMD   = 0x08,
    MOUSE_MOD_CTRL  = 0x10,
    MOUSE_MOD_FN    = 0x20
};

enum mouse_mode
{
    MOUSE_MODE_NONE,
    MOUSE_MODE_MOVE,
    MOUSE_MODE_RESIZE,
    MOUSE_MODE_SWAP,
    MOUSE_MODE_STACK
};

struct mouse_window_info
{
    float dx, dy, dw, dh;
    bool changed_x, changed_y;
    bool changed_w, changed_h;
    bool changed_position;
    bool changed_size;
};

static const char *mouse_mod_str[] =
{
    [MOUSE_MOD_NONE]  = "none",
    [MOUSE_MOD_ALT]   = "alt",
    [MOUSE_MOD_SHIFT] = "shift",
    [MOUSE_MOD_CMD]   = "cmd",
    [MOUSE_MOD_CTRL]  = "ctrl",
    [MOUSE_MOD_FN]    = "fn",
};

static const char *mouse_mode_str[] =
{
    [MOUSE_MODE_NONE]   = "none",
    [MOUSE_MODE_MOVE]   = "move",
    [MOUSE_MODE_RESIZE] = "resize",
    [MOUSE_MODE_SWAP]   = "swap",
    [MOUSE_MODE_STACK]  = "stack"
};

#endif
