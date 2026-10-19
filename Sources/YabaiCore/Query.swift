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
/// window server alone. Only the selected properties are encoded; a string that is nil is written as "".
public struct WindowInfo: Sendable
{
    /// The properties of `query --windows`: the names that select them and their json keys, in the documented order.
    public enum Key: String, CodingKey, CaseIterable, Sendable
    {
        case id, pid, app, title, scratchpad, frame, role, subrole
        case rootWindow = "root-window"
        case display, space, level
        case subLevel = "sub-level"
        case layer
        case subLayer = "sub-layer"
        case opacity
        case splitType = "split-type"
        case stackIndex = "stack-index"
        case canMove = "can-move"
        case canResize = "can-resize"
        case hasFocus = "has-focus"
        case hasShadow = "has-shadow"
        case hasParentZoom = "has-parent-zoom"
        case hasFullscreenZoom = "has-fullscreen-zoom"
        case hasAXReference = "has-ax-reference"
        case isFullscreen = "is-native-fullscreen"
        case isVisible = "is-visible"
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
        case isFloating = "is-floating"
        case isSticky = "is-sticky"
        case isGrabbed = "is-grabbed"
    }

    /// The keys that encode(to:) writes.
    public var properties: Set<Key>
    public var id: WindowID
    public var pid: Int32 = 0
    public var app: String?
    public var title: String?
    public var scratchpad: String?
    public var frame = CGRect.zero
    public var role: String?
    public var subrole: String?
    public var isRoot = false
    public var display = 0
    public var space = 0
    public var level: Int32 = 0
    public var subLevel: Int32 = 0
    /// The names of level and subLevel (window_layer).
    public var layer = ""
    public var subLayer = ""
    public var opacity: Float = 0
    public var split = WindowSplit.none
    public var stackIndex = 0
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

    public init(id: WindowID, properties: Set<Key> = Set(Key.allCases))
    {
        self.id = id
        self.properties = properties
    }

    /// `window_info_serialize`: layer names a window level (`window_layer`). Unlike the serializers of displays and
    /// spaces, flags 0 selects nothing here; the callers turn it into every property first.
    public func serialize(_ flags: UInt64, layer: (Int32) -> String) -> String
    {
        var json = JSONWriter(flags: flags)

        json.property(WindowProperty.id,                "\"id\":\(Int32(bitPattern: id.rawValue))")
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

//
// NOTE: The json of `query --displays`, `--spaces`, `--windows` and `--tree`. The `Key` of a response type is both the
// property name that `query` selects and the json key; encode(to:) writes only the selected keys, and the daemon only
// fills the values of selected keys, because some of them are slow (AX) queries. JSON.encode sorts the keys.
//

extension KeyedEncodingContainer where Key: Hashable
{
    /// Encodes the value when its key is selected.
    mutating func encode(_ value: some Encodable, forKey key: Key, in selection: Set<Key>) throws
    {
        if selection.contains(key) { try encode(value, forKey: key) }
    }
}

/// A frame of a display or window in query json.
public struct QueryFrame: Encodable, Equatable, Sendable
{
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(_ rect: CGRect)
    {
        x = rect.origin.x
        y = rect.origin.y
        w = rect.size.width
        h = rect.size.height
    }
}

/// A display in `query --displays`.
public struct DisplayInfo: Encodable, Sendable
{
    public enum Key: String, CodingKey, CaseIterable, Sendable
    {
        case id, uuid, index, label, frame, spaces
        case hasFocus = "has-focus"
    }

    /// The keys that encode(to:) writes.
    public var properties: Set<Key>
    public var id: DisplayID
    public var uuid = ""
    public var index = 0
    public var label = ""
    public var frame = QueryFrame(.zero)
    /// The Mission Control indices of the spaces of the display.
    public var spaces: [Int] = []
    public var hasFocus = false

    public init(id: DisplayID, properties: Set<Key> = Set(Key.allCases))
    {
        self.id = id
        self.properties = properties
    }

    public func encode(to encoder: any Encoder) throws
    {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Int32(bitPattern: id.rawValue), forKey: .id, in: properties)
        try container.encode(uuid, forKey: .uuid, in: properties)
        try container.encode(index, forKey: .index, in: properties)
        try container.encode(label, forKey: .label, in: properties)
        try container.encode(frame, forKey: .frame, in: properties)
        try container.encode(spaces, forKey: .spaces, in: properties)
        try container.encode(hasFocus, forKey: .hasFocus, in: properties)
    }
}

/// A space in `query --spaces`. A window id that is nil is written as 0.
public struct SpaceInfo: Encodable, Sendable
{
    public enum Key: String, CodingKey, CaseIterable, Sendable
    {
        case id, uuid, index, label, type, display, windows
        case firstWindow = "first-window"
        case lastWindow = "last-window"
        case hasFocus = "has-focus"
        case isVisible = "is-visible"
        case isFullscreen = "is-native-fullscreen"
    }

    /// The keys that encode(to:) writes.
    public var properties: Set<Key>
    public var id: SpaceID
    public var uuid = ""
    public var index = 0
    public var label = ""
    public var type = ""
    /// The arrangement index of the display of the space, 0 without one.
    public var display = 0
    public var windows: [WindowID] = []
    public var firstWindow: WindowID?
    public var lastWindow: WindowID?
    public var hasFocus = false
    public var isVisible = false
    public var isFullscreen = false

    public init(id: SpaceID, properties: Set<Key> = Set(Key.allCases))
    {
        self.id = id
        self.properties = properties
    }

    public func encode(to encoder: any Encoder) throws
    {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Int64(bitPattern: id.rawValue), forKey: .id, in: properties)
        try container.encode(uuid, forKey: .uuid, in: properties)
        try container.encode(index, forKey: .index, in: properties)
        try container.encode(label, forKey: .label, in: properties)
        try container.encode(type, forKey: .type, in: properties)
        try container.encode(display, forKey: .display, in: properties)
        try container.encode(windows.map { Int32(bitPattern: $0.rawValue) }, forKey: .windows, in: properties)
        try container.encode(Int32(bitPattern: firstWindow?.rawValue ?? 0), forKey: .firstWindow, in: properties)
        try container.encode(Int32(bitPattern: lastWindow?.rawValue ?? 0), forKey: .lastWindow, in: properties)
        try container.encode(hasFocus, forKey: .hasFocus, in: properties)
        try container.encode(isVisible, forKey: .isVisible, in: properties)
        try container.encode(isFullscreen, forKey: .isFullscreen, in: properties)
    }
}

extension WindowInfo: Encodable
{
    public func encode(to encoder: any Encoder) throws
    {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Int32(bitPattern: id.rawValue), forKey: .id, in: properties)
        try container.encode(pid, forKey: .pid, in: properties)
        try container.encode(app ?? "", forKey: .app, in: properties)
        try container.encode(title ?? "", forKey: .title, in: properties)
        try container.encode(scratchpad ?? "", forKey: .scratchpad, in: properties)
        try container.encode(QueryFrame(frame), forKey: .frame, in: properties)
        try container.encode(role ?? "", forKey: .role, in: properties)
        try container.encode(subrole ?? "", forKey: .subrole, in: properties)
        try container.encode(isRoot, forKey: .rootWindow, in: properties)
        try container.encode(display, forKey: .display, in: properties)
        try container.encode(space, forKey: .space, in: properties)
        try container.encode(level, forKey: .level, in: properties)
        try container.encode(subLevel, forKey: .subLevel, in: properties)
        try container.encode(layer, forKey: .layer, in: properties)
        try container.encode(subLayer, forKey: .subLayer, in: properties)
        try container.encode(opacity, forKey: .opacity, in: properties)
        try container.encode(split.name, forKey: .splitType, in: properties)
        try container.encode(stackIndex, forKey: .stackIndex, in: properties)
        try container.encode(canMove, forKey: .canMove, in: properties)
        try container.encode(canResize, forKey: .canResize, in: properties)
        try container.encode(hasFocus, forKey: .hasFocus, in: properties)
        try container.encode(hasShadow, forKey: .hasShadow, in: properties)
        try container.encode(hasParentZoom, forKey: .hasParentZoom, in: properties)
        try container.encode(hasFullscreenZoom, forKey: .hasFullscreenZoom, in: properties)
        try container.encode(hasAXReference, forKey: .hasAXReference, in: properties)
        try container.encode(isFullscreen, forKey: .isFullscreen, in: properties)
        try container.encode(isVisible, forKey: .isVisible, in: properties)
        try container.encode(isMinimized, forKey: .isMinimized, in: properties)
        try container.encode(isHidden, forKey: .isHidden, in: properties)
        try container.encode(isFloating, forKey: .isFloating, in: properties)
        try container.encode(isSticky, forKey: .isSticky, in: properties)
        try container.encode(isGrabbed, forKey: .isGrabbed, in: properties)
    }
}

/// A container of `query --tree`, similar to a node of i3's get_tree.
public struct TreeNode: Encodable, Sendable
{
    public enum Kind: String, Encodable, Sendable
    {
        case workspace, container, window
    }

    private enum CodingKeys: String, CodingKey
    {
        case type, layout, percent, window, frame, focused, selected, visible, nodes
    }

    public var type: Kind
    /// The layout of a container, written as null for a window.
    public var layout: String?
    public var percent: Float
    /// The window of a leaf, written as 0 for a container.
    public var window: WindowID?
    public var frame: Area
    public var focused: Bool
    public var selected: Bool
    public var visible: Bool
    public var nodes: [TreeNode]

    public init(type: Kind, layout: String?, percent: Float, window: WindowID?, frame: Area, focused: Bool, selected: Bool, visible: Bool, nodes: [TreeNode])
    {
        self.type = type
        self.layout = layout
        self.percent = percent
        self.window = window
        self.frame = frame
        self.focused = focused
        self.selected = selected
        self.visible = visible
        self.nodes = nodes
    }

    public func encode(to encoder: any Encoder) throws
    {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(layout, forKey: .layout)
        try container.encode(percent, forKey: .percent)
        try container.encode(Int32(bitPattern: window?.rawValue ?? 0), forKey: .window)
        try container.encode(frame, forKey: .frame)
        try container.encode(focused, forKey: .focused)
        try container.encode(selected, forKey: .selected)
        try container.encode(visible, forKey: .visible)
        try container.encode(nodes, forKey: .nodes)
    }
}
