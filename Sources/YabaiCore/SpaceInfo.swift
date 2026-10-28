/// A space in `query --spaces`. A window id that is nil is written as 0.
public struct SpaceInfo: Encodable, Sendable {
  public enum Key: String, CodingKey, CaseIterable, Sendable {
    case id, uuid, index, label, type, display, windows
    case pinnedDisplay = "pinned-display"
    case firstWindow = "first-window"
    case lastWindow = "last-window"
    case hasFocus = "has-focus"
    case isVisible = "is-visible"
    case isFullscreen = "is-native-fullscreen"
  }

  /// The keys that encode(to:) writes.
  public let properties: Set<Key>
  public var id: SpaceID
  public var uuid = ""
  public var index = 0
  public var label = ""
  public var type = ""
  /// The arrangement index of the display of the space, 0 without one.
  public var display = 0
  /// The arrangement index of the display that the space is pinned to, 0 without a pin or while that display is not
  /// connected.
  public var pinnedDisplay = 0
  public var windows: [WindowID] = []
  public var firstWindow: WindowID?
  public var lastWindow: WindowID?
  public var hasFocus = false
  public var isVisible = false
  public var isFullscreen = false

  public init(id: SpaceID, properties: Set<Key> = Set(Key.allCases)) {
    self.id = id
    self.properties = properties
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    for key in Key.allCases where properties.contains(key) {
      switch key {
      case .id: try container.encode(Int64(bitPattern: id.rawValue), forKey: key)
      case .uuid: try container.encode(uuid, forKey: key)
      case .index: try container.encode(index, forKey: key)
      case .label: try container.encode(label, forKey: key)
      case .type: try container.encode(type, forKey: key)
      case .display: try container.encode(display, forKey: key)
      case .pinnedDisplay: try container.encode(pinnedDisplay, forKey: key)
      case .windows:
        try container.encode(windows.map { Int32(bitPattern: $0.rawValue) }, forKey: key)
      case .firstWindow:
        try container.encode(Int32(bitPattern: firstWindow?.rawValue ?? 0), forKey: key)
      case .lastWindow:
        try container.encode(Int32(bitPattern: lastWindow?.rawValue ?? 0), forKey: key)
      case .hasFocus: try container.encode(hasFocus, forKey: key)
      case .isVisible: try container.encode(isVisible, forKey: key)
      case .isFullscreen: try container.encode(isFullscreen, forKey: key)
      }
    }
  }
}
