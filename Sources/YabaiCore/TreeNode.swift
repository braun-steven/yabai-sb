/// A container of `query --tree`, similar to a node of i3's get_tree.
public struct TreeNode: Encodable, Sendable {
  public enum Kind: String, Encodable, Sendable {
    case workspace, container, window
  }

  private enum CodingKeys: String, CodingKey {
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

  public init(
    type: Kind, layout: String?, percent: Float, window: WindowID?, frame: Area, focused: Bool,
    selected: Bool, visible: Bool, nodes: [TreeNode]
  ) {
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

  public func encode(to encoder: any Encoder) throws {
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
