/// A rule in `rule --list`. Text that is nil is written as "", a property the rule leaves alone as null.
public struct RuleInfo: Encodable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case index, label, app, title, role, subrole, display, space
    case followSpace = "follow_space"
    case manage, sticky
    case mouseFollowsFocus = "mouse_follows_focus"
    case subLayer = "sub-layer"
    case fullscreen = "native-fullscreen"
    case grid, scratchpad, insert
    case oneShot = "one-shot"
    case flags
  }

  public var index: Int
  public var label: String
  public var app: String
  public var title: String
  public var role: String
  public var subrole: String
  /// The arrangement index of the display of the rule, 0 without one.
  public var display: Int
  /// The Mission Control index of the space of the rule, 0 without one.
  public var space: Int
  public var followSpace: Bool
  public var manage: Bool?
  public var sticky: Bool?
  public var mouseFollowsFocus: Bool?
  public var subLayer: String
  public var fullscreen: Bool?
  public var grid: String
  public var scratchpad: String
  /// The side of `insert=`, "" without one ("north", "east", "south", "west" or "stack").
  public var insert: String
  public var oneShot: Bool
  public var flags: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(index, forKey: .index)
    try container.encode(label, forKey: .label)
    try container.encode(app, forKey: .app)
    try container.encode(title, forKey: .title)
    try container.encode(role, forKey: .role)
    try container.encode(subrole, forKey: .subrole)
    try container.encode(display, forKey: .display)
    try container.encode(space, forKey: .space)
    try container.encode(followSpace, forKey: .followSpace)
    // NOTE: nil is written as null.
    try container.encode(manage, forKey: .manage)
    try container.encode(sticky, forKey: .sticky)
    try container.encode(mouseFollowsFocus, forKey: .mouseFollowsFocus)
    try container.encode(subLayer, forKey: .subLayer)
    try container.encode(fullscreen, forKey: .fullscreen)
    try container.encode(grid, forKey: .grid)
    try container.encode(scratchpad, forKey: .scratchpad)
    try container.encode(insert, forKey: .insert)
    try container.encode(oneShot, forKey: .oneShot)
    try container.encode(flags, forKey: .flags)
  }
}

extension Rule {
  // Preserve the historical wire bits independently of the internal model.
  public func listFlags(matched: Bool = false) -> UInt32 {
    var flags: UInt32 = 0
    for (bit, pattern) in [app, title, role, subrole].enumerated() {
      guard let pattern else { continue }
      if pattern.regex != nil { flags |= 0x01 << bit }
      if pattern.exclude { flags |= 0x10 << bit }
    }
    if oneShot { flags |= 0x100 }
    if matched { flags |= 0x200 }
    if effects.followSpace { flags |= 0x0001_0000 }
    // 0x0002_0000 belonged to the removed opacity effect.
    if effects.layer != nil { flags |= 0x0004_0000 }
    return flags
  }

  /// The rule for `rule --list`, at index in the rule list; display and space are the indices of its effects.
  public func info(index: Int, display: Int, space: Int, matched: Bool = false) -> RuleInfo {
    let grid = effects.grid
    let gridText = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height].map {
      String(Int32(bitPattern: $0))
    }.joined(separator: ":")

    return RuleInfo(
      index: index,
      label: label ?? "",
      app: app?.text ?? "",
      title: title?.text ?? "",
      role: role?.text ?? "",
      subrole: subrole?.text ?? "",
      display: display,
      space: space,
      followSpace: effects.followSpace,
      manage: effects.manage,
      sticky: effects.sticky,
      mouseFollowsFocus: effects.mouseFollowsFocus,
      subLayer: effects.layer?.rawValue ?? "",
      fullscreen: effects.fullscreen,
      grid: gridText,
      scratchpad: effects.scratchpad ?? "",
      insert: effects.insert?.argument ?? "",
      oneShot: oneShot,
      flags: "0x" + String(listFlags(matched: matched), radix: 16))
  }
}
