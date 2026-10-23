/// A container tree at one point, without the window server: the layout and share of every container, its focus order and
/// selection, and the window of every leaf. The daemon rebuilds the tree from it, so it holds nothing of a view's frames.
public struct TreeSnapshot: Codable, Equatable, Sendable {
  public var layout: ConLayout
  public var lastSplit: ConLayout
  public var percent: Float
  public var zoom: ConZoom
  public var isSelected: Bool
  /// The window of a leaf; nil for a container.
  public var windowID: WindowID?
  public var children: [TreeSnapshot]
  /// The indices of the children in focus order, the most recently focused first.
  public var focusOrder: [Int]

  public init(
    layout: ConLayout, lastSplit: ConLayout, percent: Float, zoom: ConZoom, isSelected: Bool,
    windowID: WindowID?, children: [TreeSnapshot], focusOrder: [Int]
  ) {
    self.layout = layout
    self.lastSplit = lastSplit
    self.percent = percent
    self.zoom = zoom
    self.isSelected = isSelected
    self.windowID = windowID
    self.children = children
    self.focusOrder = focusOrder
  }
}

/// The trees a space had before its last tree commands, newest last, with the windows the space had then. space --undo
/// restores the newest one when the space still has the same windows, and the history keeps the last `capacity` of them.
public struct TreeHistory: Sendable {
  public struct Entry: Equatable, Sendable {
    public var tree: TreeSnapshot
    public var windows: Set<WindowID>

    public init(tree: TreeSnapshot, windows: Set<WindowID>) {
      self.tree = tree
      self.windows = windows
    }
  }

  public static let capacity = 10

  public private(set) var entries: [Entry] = []

  public init() {}

  /// The newest entry, the one space --undo restores.
  public var newest: Entry? { entries.last }

  public mutating func push(_ entry: Entry) {
    entries.append(entry)
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
  }

  @discardableResult
  public mutating func pop() -> Entry? { entries.popLast() }

  public mutating func clear() { entries.removeAll() }

  /// Drops every entry when the windows of the space are not the ones of the newest entry: undo does not cross window
  /// changes, so the older entries could not be restored either.
  public mutating func clearIfWindowsChanged(to windows: Set<WindowID>) {
    if let newest, newest.windows != windows { clear() }
  }
}
