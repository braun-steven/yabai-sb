import CoreGraphics
import Darwin
import YabaiCore

//
// NOTE: The constants and enums of the C headers that the daemon uses, with the names and types under which Swift
// imported them: an int macro is an Int32, a C enum is a RawRepresentable struct with a UInt32 rawValue and a global
// constant per case. Ported from src/misc/macros.h and the headers named in each section.
//

// MARK: src/misc/macros.h

let TYPE_ABS: Int32 = 0x1
let TYPE_REL: Int32 = 0x2

let HANDLE_TOP: Int32    = 0x01
let HANDLE_BOTTOM: Int32 = 0x02
let HANDLE_LEFT: Int32   = 0x04
let HANDLE_RIGHT: Int32  = 0x08
let HANDLE_ABS: Int32    = 0x10

let LAYER_AUTO: Int32 = 0

//
// NOTE: The window levels of the sub-layers (LAYER_* in the C version). LAYER_AUTO is 0; the others are
// CGWindowLevelKey values, which Swift does not import from the C macros that named them.
//

func layerValue(_ layer: WindowLayer) -> Int32
{
    switch layer {
    case .auto:   Int32(LAYER_AUTO)
    case .below:  CGWindowLevelKey.backstopMenu.rawValue
    case .normal: CGWindowLevelKey.normalWindow.rawValue
    case .above:  CGWindowLevelKey.floatingWindow.rawValue
    }
}

// MARK: src/view.h

let TAB_BAR_MAX_ENTRY_COUNT: Int32 = 64

/// `enum view_flag`
struct view_flag: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let VIEW_LAYOUT         = view_flag(rawValue: 0x001)
let VIEW_TOP_PADDING    = view_flag(rawValue: 0x002)
let VIEW_BOTTOM_PADDING = view_flag(rawValue: 0x004)
let VIEW_LEFT_PADDING   = view_flag(rawValue: 0x008)
let VIEW_RIGHT_PADDING  = view_flag(rawValue: 0x010)
let VIEW_WINDOW_GAP     = view_flag(rawValue: 0x020)
let VIEW_ENABLE_PADDING = view_flag(rawValue: 0x080)
let VIEW_ENABLE_GAP     = view_flag(rawValue: 0x100)
let VIEW_IS_VALID       = view_flag(rawValue: 0x200)
let VIEW_IS_DIRTY       = view_flag(rawValue: 0x400)
let VIEW_AUTO_PADDING   = view_flag(rawValue: 0x1000)
let VIEW_IS_UNPADDED    = view_flag(rawValue: 0x2000)

// MARK: src/tab_bar.h, src/tab_bar_glass.h

let TAB_BAR_DEFAULT_FONT = "system:12"
let TAB_BAR_SYSTEM_FONT  = "system"

/// `enum tab_bar_style`
struct tab_bar_style: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let TAB_BAR_STYLE_GLASS = tab_bar_style(rawValue: 0)
let TAB_BAR_STYLE_I3    = tab_bar_style(rawValue: 1)
let TAB_BAR_STYLE_COUNT = tab_bar_style(rawValue: 2)

/// `enum tab_bar_state`
struct tab_bar_state: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let TAB_BAR_UNFOCUSED = tab_bar_state(rawValue: 0)
let TAB_BAR_INACTIVE  = tab_bar_state(rawValue: 1)
let TAB_BAR_FOCUSED   = tab_bar_state(rawValue: 2)

/// `enum tab_bar_backdrop`
struct tab_bar_backdrop: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let TAB_BAR_BACKDROP_OFF   = tab_bar_backdrop(rawValue: 0)
let TAB_BAR_BACKDROP_GLASS = tab_bar_backdrop(rawValue: 1)
let TAB_BAR_BACKDROP_BLUR  = tab_bar_backdrop(rawValue: 2)
let TAB_BAR_BACKDROP_COUNT = tab_bar_backdrop(rawValue: 3)

let TAB_BAR_GLASS_TRACK_MARGIN: Float = 2.0
let TAB_BAR_GLASS_PILL_INSET: Float = 2.0
let TAB_BAR_GLASS_ANIMATION_DURATION: Double = 0.2

enum TabBarAppearance: String, Sendable, CaseIterable
{
    case dark, system
}

/// `tab_bar_slot`: the tab at the index among count tabs of the area, with the C rounding (float widths, int offsets).
func tab_bar_slot(_ area: CGRect, _ index: Int32, _ count: Int32) -> CGRect
{
    let width = Float(area.size.width / CGFloat(count))
    let x0 = Float(area.origin.x + CGFloat(Int32(Float(index) * width)))
    let x1 = index == count - 1 ? Float(area.origin.x + area.size.width) : Float(area.origin.x + CGFloat(Int32(Float(index + 1) * width)))
    return CGRect(x: CGFloat(x0), y: area.origin.y, width: CGFloat(x1 - x0), height: area.size.height)
}

// MARK: src/border.h

let BORDER_EDGE_TOP: Int32    = 0
let BORDER_EDGE_BOTTOM: Int32 = 1
let BORDER_EDGE_LEFT: Int32   = 2
let BORDER_EDGE_RIGHT: Int32  = 3
let BORDER_EDGE_COUNT: Int32  = 4

let BORDER_DEFAULT_RADIUS: Float = 9.0

// MARK: src/window.h

/// `enum window_flag`
struct window_flag: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_SHADOW     = window_flag(rawValue: 0x01)
let WINDOW_FULLSCREEN = window_flag(rawValue: 0x02)
let WINDOW_MINIMIZE   = window_flag(rawValue: 0x04)
let WINDOW_FLOAT      = window_flag(rawValue: 0x08)
let WINDOW_STICKY     = window_flag(rawValue: 0x10)
let WINDOW_WINDOWED   = window_flag(rawValue: 0x20)
let WINDOW_MOVABLE    = window_flag(rawValue: 0x40)
let WINDOW_RESIZABLE  = window_flag(rawValue: 0x80)

/// `enum window_rule_flag`
struct window_rule_flag: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_RULE_MANAGED    = window_rule_flag(rawValue: 0x01)
let WINDOW_RULE_FULLSCREEN = window_rule_flag(rawValue: 0x02)
let WINDOW_RULE_MFF        = window_rule_flag(rawValue: 0x04)
let WINDOW_RULE_MFF_VALUE  = window_rule_flag(rawValue: 0x08)

// MARK: src/window_manager.h

let kCPSAllWindows: Int32    = 0x100
let kCPSUserGenerated: Int32 = 0x200
let kCPSNoWindows: Int32     = 0x400

/// `enum window_layout`
struct window_layout: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_LAYOUT_TABBED       = window_layout(rawValue: 0)
let WINDOW_LAYOUT_SPLIT        = window_layout(rawValue: 1)
let WINDOW_LAYOUT_TOGGLE       = window_layout(rawValue: 2)
let WINDOW_LAYOUT_SPLITH       = window_layout(rawValue: 3)
let WINDOW_LAYOUT_SPLITV       = window_layout(rawValue: 4)
let WINDOW_LAYOUT_TOGGLE_SPLIT = window_layout(rawValue: 5)

/// `enum window_op_error`
struct window_op_error: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_OP_ERROR_SUCCESS           = window_op_error(rawValue: 0)
let WINDOW_OP_ERROR_INVALID_SRC_VIEW  = window_op_error(rawValue: 1)
let WINDOW_OP_ERROR_INVALID_SRC_NODE  = window_op_error(rawValue: 2)
let WINDOW_OP_ERROR_INVALID_DST_VIEW  = window_op_error(rawValue: 3)
let WINDOW_OP_ERROR_INVALID_DST_NODE  = window_op_error(rawValue: 4)
let WINDOW_OP_ERROR_INVALID_OPERATION = window_op_error(rawValue: 5)
let WINDOW_OP_ERROR_SAME_WINDOW       = window_op_error(rawValue: 6)
let WINDOW_OP_ERROR_CANT_MINIMIZE     = window_op_error(rawValue: 7)
let WINDOW_OP_ERROR_ALREADY_MINIMIZED = window_op_error(rawValue: 8)
let WINDOW_OP_ERROR_MINIMIZE_FAILED   = window_op_error(rawValue: 9)
let WINDOW_OP_ERROR_NOT_MINIMIZED     = window_op_error(rawValue: 10)
let WINDOW_OP_ERROR_DEMINIMIZE_FAILED = window_op_error(rawValue: 11)

/// `enum purify_mode`
struct purify_mode: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let PURIFY_DISABLED = purify_mode(rawValue: 0)
let PURIFY_MANAGED  = purify_mode(rawValue: 1)
let PURIFY_ALWAYS   = purify_mode(rawValue: 2)

/// `enum ffm_mode`
struct ffm_mode: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let FFM_DISABLED  = ffm_mode(rawValue: 0)
let FFM_AUTOFOCUS = ffm_mode(rawValue: 1)
let FFM_AUTORAISE = ffm_mode(rawValue: 2)

/// `enum window_origin_mode`
struct window_origin_mode: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_ORIGIN_DEFAULT = window_origin_mode(rawValue: 0)
let WINDOW_ORIGIN_FOCUSED = window_origin_mode(rawValue: 1)
let WINDOW_ORIGIN_CURSOR  = window_origin_mode(rawValue: 2)

// MARK: src/space_manager.h, src/space_layout.h

/// `enum space_op_error`
struct space_op_error: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let SPACE_OP_ERROR_SUCCESS            = space_op_error(rawValue: 0)
let SPACE_OP_ERROR_MISSING_SRC        = space_op_error(rawValue: 1)
let SPACE_OP_ERROR_MISSING_DST        = space_op_error(rawValue: 2)
let SPACE_OP_ERROR_INVALID_SRC        = space_op_error(rawValue: 3)
let SPACE_OP_ERROR_INVALID_DST        = space_op_error(rawValue: 4)
let SPACE_OP_ERROR_INVALID_TYPE       = space_op_error(rawValue: 5)
let SPACE_OP_ERROR_SAME_SPACE         = space_op_error(rawValue: 6)
let SPACE_OP_ERROR_SAME_DISPLAY       = space_op_error(rawValue: 7)
let SPACE_OP_ERROR_IN_MISSION_CONTROL = space_op_error(rawValue: 9)
let SPACE_OP_ERROR_SCRIPTING_ADDITION = space_op_error(rawValue: 10)

/// `enum space_layout_result`
struct space_layout_result: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let SPACE_LAYOUT_RESULT_DONE      = space_layout_result(rawValue: 0)
let SPACE_LAYOUT_RESULT_PERFORMED = space_layout_result(rawValue: 1)
let SPACE_LAYOUT_RESULT_FAILED    = space_layout_result(rawValue: 2)

// MARK: src/display_manager.h

let DOCK_ORIENTATION_BOTTOM: Int32 = 2
let DOCK_ORIENTATION_LEFT: Int32   = 3
let DOCK_ORIENTATION_RIGHT: Int32  = 4

/// `enum display_arrangement_order`
struct display_arrangement_order: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let DISPLAY_ARRANGEMENT_ORDER_DEFAULT = display_arrangement_order(rawValue: 0)
let DISPLAY_ARRANGEMENT_ORDER_X       = display_arrangement_order(rawValue: 1)
let DISPLAY_ARRANGEMENT_ORDER_Y       = display_arrangement_order(rawValue: 2)

/// `enum external_bar_mode`
struct external_bar_mode: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let EXTERNAL_BAR_OFF  = external_bar_mode(rawValue: 0)
let EXTERNAL_BAR_MAIN = external_bar_mode(rawValue: 1)
let EXTERNAL_BAR_ALL  = external_bar_mode(rawValue: 2)

// MARK: src/mouse_handler.h

//
// NOTE: The private event type and fields of the dock swipe gesture that switches spaces (an anonymous C enum, which
// Swift imported as Int).
//

let kCGSEventDockControl          = 30
let kCGSEventTypeField            = 55
let kCGEventGestureHIDType        = 110
let kCGEventGestureSwipeMotion    = 123
let kCGEventGestureSwipeProgress  = 124
let kCGEventGestureSwipeVelocityX = 129
let kCGEventGesturePhase          = 132
let kIOHIDEventTypeDockSwipe      = 23
let kCGGestureMotionHorizontal    = 1
let kCGSGesturePhaseBegan         = 1
let kCGSGesturePhaseEnded         = 4
let kCGSGesturePhaseCancelled     = 8

/// `enum mouse_drop_action`
struct mouse_drop_action: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let MOUSE_DROP_ACTION_NONE        = mouse_drop_action(rawValue: 0)
let MOUSE_DROP_ACTION_STACK       = mouse_drop_action(rawValue: 1)
let MOUSE_DROP_ACTION_SWAP        = mouse_drop_action(rawValue: 2)
let MOUSE_DROP_ACTION_WARP_TOP    = mouse_drop_action(rawValue: 3)
let MOUSE_DROP_ACTION_WARP_RIGHT  = mouse_drop_action(rawValue: 4)
let MOUSE_DROP_ACTION_WARP_BOTTOM = mouse_drop_action(rawValue: 5)
let MOUSE_DROP_ACTION_WARP_LEFT   = mouse_drop_action(rawValue: 6)

/// `enum mouse_mod`
struct mouse_mod: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let MOUSE_MOD_NONE  = mouse_mod(rawValue: 0x01)
let MOUSE_MOD_ALT   = mouse_mod(rawValue: 0x02)
let MOUSE_MOD_SHIFT = mouse_mod(rawValue: 0x04)
let MOUSE_MOD_CMD   = mouse_mod(rawValue: 0x08)
let MOUSE_MOD_CTRL  = mouse_mod(rawValue: 0x10)
let MOUSE_MOD_FN    = mouse_mod(rawValue: 0x20)

/// `enum mouse_mode`
struct mouse_mode: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let MOUSE_MODE_NONE   = mouse_mode(rawValue: 0)
let MOUSE_MODE_MOVE   = mouse_mode(rawValue: 1)
let MOUSE_MODE_RESIZE = mouse_mode(rawValue: 2)
let MOUSE_MODE_SWAP   = mouse_mode(rawValue: 3)
let MOUSE_MODE_STACK  = mouse_mode(rawValue: 4)

/// `struct mouse_window_info`: how a dragged window changed.
struct mouse_window_info: Sendable
{
    var dx: Float = 0, dy: Float = 0, dw: Float = 0, dh: Float = 0
    var changed_x = false, changed_y = false
    var changed_w = false, changed_h = false
    var changed_position = false
    var changed_size = false
}
