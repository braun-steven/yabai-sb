//
// NOTE: What the window server and yabai report about the displays, spaces and windows at one moment, for the topology
// log (Sources/Yabai/TopologyLog.swift). The displays and their spaces are in the order of the space indices.
//

/// The displays, spaces and windows at one moment.
public struct TopologyObservation: Codable, Equatable, Sendable {
  /// One space of a display.
  public struct Space: Codable, Equatable, Sendable {
    public var id: UInt64
    public var uuid: String
    /// The window server's type: 0 for a user space, 4 for a fullscreen space.
    public var type: Int
    /// The windows of the user on the space, as the window server reports them.
    public var windows: [UInt32]
    /// The windows in the tree of the view of the space, nil without a view.
    public var tree: [UInt32]?
    /// The tree of the view of the space (`TreeSnapshot.shape`), nil without a tree.
    public var shape: String?

    public init(
      id: UInt64, uuid: String, type: Int, windows: [UInt32], tree: [UInt32]?, shape: String? = nil
    ) {
      self.id = id
      self.uuid = uuid
      self.type = type
      self.windows = windows
      self.tree = tree
      self.shape = shape
    }
  }

  /// One display with its spaces.
  public struct Display: Codable, Equatable, Sendable {
    public var uuid: String
    /// The id of the space the display shows.
    public var current: UInt64?
    public var spaces: [Space]

    public init(uuid: String, current: UInt64?, spaces: [Space]) {
      self.uuid = uuid
      self.current = current
      self.spaces = spaces
    }
  }

  public var displays: [Display]
  /// The focused window.
  public var focused: UInt32?

  public init(displays: [Display], focused: UInt32? = nil) {
    self.displays = displays
    self.focused = focused
  }
}

/// Why the topology log records an observation. Each one schedules the next: a change is observed once it has been
/// quiet (`settle`) and again later, because macOS still moves single windows about 10 s after a display returns
/// (`late`); after that the observations are only `periodic`, so a change that gives no warning, like an unplugged
/// display, has an observation from before it.
public enum TopologySnapshotReason: String, Sendable {
  case start
  case sleep
  case settle
  case late
  case periodic

  /// How long after the last change of the topology the `settle` observation comes, in seconds.
  public static let settleSeconds = 5

  /// The observation that follows this one, and its delay in seconds.
  public var next: (reason: TopologySnapshotReason, seconds: Int) {
    switch self {
    case .settle: (.late, 15)
    case .start, .sleep, .late, .periodic: (.periodic, 300)
    }
  }
}
