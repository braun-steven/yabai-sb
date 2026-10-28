import CoreGraphics

/// `struct window_info`: the values reported by `query --windows`, collected from a window yabai tracks or from the
/// window server alone. Only the selected properties are encoded; a string that is nil is written as "".
public struct WindowInfo: Sendable {
  /// The properties of `query --windows`: the names that select them and their json keys, in the documented order.
  public enum Key: String, CodingKey, CaseIterable, Sendable {
    case id, pid, app, title, scratchpad, label, frame, role, subrole
    case rootWindow = "root-window"
    case display, space, level
    case subLevel = "sub-level"
    case layer
    case subLayer = "sub-layer"
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
  public let properties: Set<Key>
  public var id: WindowID
  public var pid: Int32 = 0
  public var app: String?
  public var title: String?
  public var scratchpad: String?
  /// The window label of `window --label`.
  public var label: String?
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

  public init(id: WindowID, properties: Set<Key> = Set(Key.allCases)) {
    self.id = id
    self.properties = properties
  }
}

extension WindowInfo: Encodable {
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    for key in Key.allCases where properties.contains(key) {
      switch key {
      case .id: try container.encode(Int32(bitPattern: id.rawValue), forKey: key)
      case .pid: try container.encode(pid, forKey: key)
      case .app: try container.encode(app ?? "", forKey: key)
      case .title: try container.encode(title ?? "", forKey: key)
      case .scratchpad: try container.encode(scratchpad ?? "", forKey: key)
      case .label: try container.encode(label ?? "", forKey: key)
      case .frame: try container.encode(QueryFrame(frame), forKey: key)
      case .role: try container.encode(role ?? "", forKey: key)
      case .subrole: try container.encode(subrole ?? "", forKey: key)
      case .rootWindow: try container.encode(isRoot, forKey: key)
      case .display: try container.encode(display, forKey: key)
      case .space: try container.encode(space, forKey: key)
      case .level: try container.encode(level, forKey: key)
      case .subLevel: try container.encode(subLevel, forKey: key)
      case .layer: try container.encode(layer, forKey: key)
      case .subLayer: try container.encode(subLayer, forKey: key)
      case .splitType: try container.encode(split.name, forKey: key)
      case .stackIndex: try container.encode(stackIndex, forKey: key)
      case .canMove: try container.encode(canMove, forKey: key)
      case .canResize: try container.encode(canResize, forKey: key)
      case .hasFocus: try container.encode(hasFocus, forKey: key)
      case .hasShadow: try container.encode(hasShadow, forKey: key)
      case .hasParentZoom: try container.encode(hasParentZoom, forKey: key)
      case .hasFullscreenZoom: try container.encode(hasFullscreenZoom, forKey: key)
      case .hasAXReference: try container.encode(hasAXReference, forKey: key)
      case .isFullscreen: try container.encode(isFullscreen, forKey: key)
      case .isVisible: try container.encode(isVisible, forKey: key)
      case .isMinimized: try container.encode(isMinimized, forKey: key)
      case .isHidden: try container.encode(isHidden, forKey: key)
      case .isFloating: try container.encode(isFloating, forKey: key)
      case .isSticky: try container.encode(isSticky, forKey: key)
      case .isGrabbed: try container.encode(isGrabbed, forKey: key)
      }
    }
  }
}
