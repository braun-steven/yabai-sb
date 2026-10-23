import Foundation

//
// NOTE: The file of a saved layout (`space --save-layout <name>`). It holds the tree of a TreeSnapshot, with a window
// matcher on each leaf in place of the window id: window ids mean nothing after a restart, so `space --restore-layout`
// finds the windows again by their application and their accessibility title, role and subrole.
//

/// How a saved window is found again: its application (the bundle id, with the application name as the fallback), and
/// its accessibility title, role and subrole at save time.
public struct LayoutMatcher: Codable, Equatable, Sendable {
  public var bundleID: String?
  public var app: String
  public var title: String?
  public var role: String?
  public var subrole: String?

  public init(bundleID: String?, app: String, title: String?, role: String?, subrole: String?) {
    self.bundleID = bundleID
    self.app = app
    self.title = title
    self.role = role
    self.subrole = subrole
  }
}

/// A saved layout: the tree of a space, with a window matcher on each leaf.
public struct LayoutFile: Codable, Equatable, Sendable {
  /// The format version written by this build.
  public static let currentVersion = 1

  public var version: Int
  public var tree: Node

  /// A container (with children) or a leaf (none). A leaf whose window had no matcher at save time has `window` nil.
  public struct Node: Codable, Equatable, Sendable {
    public var layout: ConLayout
    public var lastSplit: ConLayout
    public var percent: Float
    public var zoom: ConZoom
    public var focusOrder: [Int]
    /// The matcher of a leaf; nil for a container.
    public var window: LayoutMatcher?
    public var children: [Node]

    public init(
      layout: ConLayout, lastSplit: ConLayout, percent: Float, zoom: ConZoom, focusOrder: [Int],
      window: LayoutMatcher?, children: [Node]
    ) {
      self.layout = layout
      self.lastSplit = lastSplit
      self.percent = percent
      self.zoom = zoom
      self.focusOrder = focusOrder
      self.window = window
      self.children = children
    }

    fileprivate init(snapshot: TreeSnapshot, matcher: (WindowID) -> LayoutMatcher?) {
      layout = snapshot.layout
      lastSplit = snapshot.lastSplit
      percent = snapshot.percent
      zoom = snapshot.zoom
      focusOrder = snapshot.focusOrder
      if let windowID = snapshot.windowID {
        window = matcher(windowID)
      } else {
        window = nil
      }
      children = snapshot.children.map { Node(snapshot: $0, matcher: matcher) }
    }
  }

  public init(tree: Node) {
    version = Self.currentVersion
    self.tree = tree
  }

  /// The layout file of a tree. `matcher` gives the matcher of a window; the selection of the snapshot is left out.
  public init(snapshot: TreeSnapshot, matcher: (WindowID) -> LayoutMatcher?) {
    self.init(tree: Node(snapshot: snapshot, matcher: matcher))
  }

  /// The file contents: pretty-printed JSON with sorted keys, so one tree always gives the same bytes, and a newline at
  /// the end.
  public static func encode(_ file: LayoutFile) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(file) + Data("\n".utf8)
  }

  /// Reads a file written by `encode`. Its version and contents are not checked here.
  public static func decode(_ data: Data) throws -> LayoutFile {
    try JSONDecoder().decode(LayoutFile.self, from: data)
  }
}

/// The files of saved layouts: the names they may have, and where they are kept.
public enum LayoutStore {
  /// What a layout name may be, for the failure messages.
  public static let nameDescription =
    "a layout name of the characters A-Z, a-z, 0-9, '.', '_' and '-'"

  /// A name of one or more of `[A-Za-z0-9._-]`, which is not `.` or `..`, so that it names one file in the directory.
  public static func isValidName(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != ".." else { return false }
    return name.utf8.allSatisfy { byte in
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "."), UInt8(ascii: "_"),
        UInt8(ascii: "-"):
        true
      default: false
      }
    }
  }

  /// The directory of the layout files: $XDG_CONFIG_HOME/yabai/layouts when the variable is set and not empty, else
  /// $HOME/.config/yabai/layouts. Nil when neither gives a directory. An empty HOME counts as unset.
  public static func directory(xdgConfigHome: String?, home: String?) -> String? {
    if let xdgConfigHome, !xdgConfigHome.isEmpty { return "\(xdgConfigHome)/yabai/layouts" }
    guard let home, !home.isEmpty else { return nil }
    return "\(home)/.config/yabai/layouts"
  }

  /// The file of the layout `name` in `directory`.
  public static func path(name: String, directory: String) -> String {
    "\(directory)/\(name).json"
  }
}
