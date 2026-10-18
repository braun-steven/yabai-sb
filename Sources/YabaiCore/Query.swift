import CoreGraphics

//
// NOTE: The properties that `query --displays`, `--spaces` and `--windows` can select, and the json of a window. The
// values are the flags of parse_properties; flags 0 selects every property. Ported from the *_PROPERTY_LIST tables of
// src/display.h, src/view.h and src/window.h, and from window_info_serialize in src/window.c.
//

public typealias PropertyList = [(name: String, value: UInt64)]

/// `DISPLAY_PROPERTY_LIST`
public enum DisplayProperty
{
    public static let id: UInt64       = 0x01
    public static let uuid: UInt64     = 0x02
    public static let index: UInt64    = 0x04
    public static let label: UInt64    = 0x08
    public static let frame: UInt64    = 0x10
    public static let spaces: UInt64   = 0x20
    public static let hasFocus: UInt64 = 0x40

    public static let list: PropertyList = [
        ("id", id), ("uuid", uuid), ("index", index), ("label", label), ("frame", frame), ("spaces", spaces), ("has-focus", hasFocus)
    ]
}

/// `SPACE_PROPERTY_LIST`
public enum SpaceProperty
{
    public static let id: UInt64           = 0x001
    public static let uuid: UInt64         = 0x002
    public static let index: UInt64        = 0x004
    public static let label: UInt64        = 0x008
    public static let type: UInt64         = 0x010
    public static let display: UInt64      = 0x020
    public static let windows: UInt64      = 0x040
    public static let firstWindow: UInt64  = 0x080
    public static let lastWindow: UInt64   = 0x100
    public static let hasFocus: UInt64     = 0x200
    public static let isVisible: UInt64    = 0x400
    public static let isFullscreen: UInt64 = 0x800

    public static let list: PropertyList = [
        ("id", id), ("uuid", uuid), ("index", index), ("label", label), ("type", type), ("display", display), ("windows", windows),
        ("first-window", firstWindow), ("last-window", lastWindow), ("has-focus", hasFocus), ("is-visible", isVisible),
        ("is-native-fullscreen", isFullscreen)
    ]
}

/// `WINDOW_PROPERTY_LIST`
public enum WindowProperty
{
    public static let id: UInt64                = 0x000000001
    public static let pid: UInt64               = 0x000000002
    public static let app: UInt64               = 0x000000004
    public static let title: UInt64             = 0x000000008
    public static let scratchpad: UInt64        = 0x000000010
    public static let frame: UInt64             = 0x000000020
    public static let role: UInt64              = 0x000000040
    public static let subrole: UInt64           = 0x000000080
    public static let rootWindow: UInt64        = 0x000000100
    public static let display: UInt64           = 0x000000200
    public static let space: UInt64             = 0x000000400
    public static let level: UInt64             = 0x000000800
    public static let subLevel: UInt64          = 0x000001000
    public static let layer: UInt64             = 0x000002000
    public static let subLayer: UInt64          = 0x000004000
    public static let opacity: UInt64           = 0x000008000
    public static let splitType: UInt64         = 0x000010000
    public static let stackIndex: UInt64        = 0x000040000
    public static let canMove: UInt64           = 0x000080000
    public static let canResize: UInt64         = 0x000100000
    public static let hasFocus: UInt64          = 0x000200000
    public static let hasShadow: UInt64         = 0x000400000
    public static let hasParentZoom: UInt64     = 0x000800000
    public static let hasFullscreenZoom: UInt64 = 0x001000000
    public static let hasAXReference: UInt64    = 0x002000000
    public static let isFullscreen: UInt64      = 0x004000000
    public static let isVisible: UInt64         = 0x008000000
    public static let isMinimized: UInt64       = 0x010000000
    public static let isHidden: UInt64          = 0x020000000
    public static let isFloating: UInt64        = 0x040000000
    public static let isSticky: UInt64          = 0x080000000
    public static let isGrabbed: UInt64         = 0x100000000

    public static let list: PropertyList = [
        ("id", id), ("pid", pid), ("app", app), ("title", title), ("scratchpad", scratchpad), ("frame", frame), ("role", role),
        ("subrole", subrole), ("root-window", rootWindow), ("display", display), ("space", space), ("level", level),
        ("sub-level", subLevel), ("layer", layer), ("sub-layer", subLayer), ("opacity", opacity), ("split-type", splitType),
        ("stack-index", stackIndex), ("can-move", canMove), ("can-resize", canResize), ("has-focus", hasFocus),
        ("has-shadow", hasShadow), ("has-parent-zoom", hasParentZoom), ("has-fullscreen-zoom", hasFullscreenZoom),
        ("has-ax-reference", hasAXReference), ("is-native-fullscreen", isFullscreen), ("is-visible", isVisible),
        ("is-minimized", isMinimized), ("is-hidden", isHidden), ("is-floating", isFloating), ("is-sticky", isSticky),
        ("is-grabbed", isGrabbed)
    ]
}

/// The split a window's container makes with its sibling, by its parent's layout; also the axis of `space --mirror`.
public enum WindowSplit: Sendable
{
    case none
    case y
    case x

    /// The name in `query --windows`.
    public var name: String
    {
        switch self {
        case .none: "none"
        case .y:    "vertical"
        case .x:    "horizontal"
        }
    }
}

/// `struct window_info`: the values reported by `query --windows`, collected from a window yabai tracks or from the
/// window server alone. A string that is nil is written as "", like json_string(NULL).
public struct WindowInfo: Sendable
{
    public var id: UInt32 = 0
    public var pid: Int32 = 0
    public var app: String?
    public var title: String?
    public var scratchpad: String?
    public var frame = CGRect.zero
    public var role: String?
    public var subrole: String?
    public var isRoot = false
    public var display: Int32 = 0
    public var space: Int32 = 0
    public var level: Int32 = 0
    public var subLevel: Int32 = 0
    public var opacity: Float = 0
    public var split = WindowSplit.none
    public var stackIndex: Int32 = 0
    public var canMove = false
    public var canResize = false
    public var hasFocus = false
    public var hasShadow = false
    public var hasParentZoom = false
    public var hasFullscreenZoom = false
    public var hasAXReference = false
    public var isFullscreen = false
    public var isVisible = false
    public var isMinimized = false
    public var isHidden = false
    public var isFloating = false
    public var isSticky = false
    public var isGrabbed = false

    public init() {}

    /// `window_info_serialize`: layer names a window level (`window_layer`). Unlike the serializers of displays and
    /// spaces, flags 0 selects nothing here; the callers turn it into every property first.
    public func serialize(_ flags: UInt64, layer: (Int32) -> String) -> String
    {
        var json = JSONWriter(flags: flags)

        json.property(WindowProperty.id,                "\"id\":\(Int32(bitPattern: id))")
        json.property(WindowProperty.pid,               "\"pid\":\(pid)")
        json.property(WindowProperty.app,               "\"app\":\"\(JSON.string(app))\"")
        json.property(WindowProperty.title,             "\"title\":\"\(JSON.string(title))\"")
        json.property(WindowProperty.scratchpad,        "\"scratchpad\":\"\(JSON.string(scratchpad))\"")
        json.property(WindowProperty.frame,             "\"frame\":" + JSON.frame(frame))
        json.property(WindowProperty.role,              "\"role\":\"\(JSON.string(role))\"")
        json.property(WindowProperty.subrole,           "\"subrole\":\"\(JSON.string(subrole))\"")
        json.property(WindowProperty.rootWindow,        "\"root-window\":\(JSON.bool(isRoot))")
        json.property(WindowProperty.display,           "\"display\":\(display)")
        json.property(WindowProperty.space,             "\"space\":\(space)")
        json.property(WindowProperty.level,             "\"level\":\(level)")
        json.property(WindowProperty.subLevel,          "\"sub-level\":\(subLevel)")
        json.property(WindowProperty.layer,             "\"layer\":\"\(layer(level))\"")
        json.property(WindowProperty.subLayer,          "\"sub-layer\":\"\(layer(subLevel))\"")
        json.property(WindowProperty.opacity,           "\"opacity\":\(JSON.number(Double(opacity)))")
        json.property(WindowProperty.splitType,         "\"split-type\":\"\(split.name)\"")
        json.property(WindowProperty.stackIndex,        "\"stack-index\":\(stackIndex)")
        json.property(WindowProperty.canMove,           "\"can-move\":\(JSON.bool(canMove))")
        json.property(WindowProperty.canResize,         "\"can-resize\":\(JSON.bool(canResize))")
        json.property(WindowProperty.hasFocus,          "\"has-focus\":\(JSON.bool(hasFocus))")
        json.property(WindowProperty.hasShadow,         "\"has-shadow\":\(JSON.bool(hasShadow))")
        json.property(WindowProperty.hasParentZoom,     "\"has-parent-zoom\":\(JSON.bool(hasParentZoom))")
        json.property(WindowProperty.hasFullscreenZoom, "\"has-fullscreen-zoom\":\(JSON.bool(hasFullscreenZoom))")
        json.property(WindowProperty.hasAXReference,    "\"has-ax-reference\":\(JSON.bool(hasAXReference))")
        json.property(WindowProperty.isFullscreen,      "\"is-native-fullscreen\":\(JSON.bool(isFullscreen))")
        json.property(WindowProperty.isVisible,         "\"is-visible\":\(JSON.bool(isVisible))")
        json.property(WindowProperty.isMinimized,       "\"is-minimized\":\(JSON.bool(isMinimized))")
        json.property(WindowProperty.isHidden,          "\"is-hidden\":\(JSON.bool(isHidden))")
        json.property(WindowProperty.isFloating,        "\"is-floating\":\(JSON.bool(isFloating))")
        json.property(WindowProperty.isSticky,          "\"is-sticky\":\(JSON.bool(isSticky))")
        json.property(WindowProperty.isGrabbed,         "\"is-grabbed\":\(JSON.bool(isGrabbed))")

        return json.finish()
    }
}
