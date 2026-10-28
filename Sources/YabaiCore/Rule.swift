/// The effects of a rule on the windows it matches. manage, sticky, mouseFollowsFocus and fullscreen are nil when the
/// rule leaves them alone.
public struct RuleEffects: Sendable, Equatable {
  public var did: DisplayID?
  public var sid: SpaceID?
  public var manage: Bool?
  public var sticky: Bool?
  public var mouseFollowsFocus: Bool?
  public var layer: WindowLayer?
  public var fullscreen: Bool?
  public var grid = Grid()
  public var scratchpad: String?
  public var insert: InsertDirection?
  public var followSpace = false

  public init() {}

  /// The insertion a window gets when a rule matches it as a new window: none when the rule sets manage=off, as the
  /// window is then not tiled.
  public var insertionForNewWindow: InsertDirection? { manage == false ? nil : insert }

  /// Merge a later matching rule, preserving properties it leaves unspecified.
  public mutating func combine(_ effects: RuleEffects) {
    if let did = effects.did { self.did = did }
    if let sid = effects.sid { self.sid = sid }

    if effects.did != nil || effects.sid != nil {
      followSpace = effects.followSpace
    }

    if let layer = effects.layer { self.layer = layer }

    if let scratchpad = effects.scratchpad {
      self.scratchpad = scratchpad
    }

    if let insert = effects.insert { self.insert = insert }

    if let manage = effects.manage { self.manage = manage }
    if let sticky = effects.sticky { self.sticky = sticky }
    if let mouseFollowsFocus = effects.mouseFollowsFocus {
      self.mouseFollowsFocus = mouseFollowsFocus
    }
    if let fullscreen = effects.fullscreen { self.fullscreen = fullscreen }

    if effects.grid.rows != 0 && effects.grid.columns != 0 {
      grid = effects.grid
    }
  }
}

/// A rule: its filters and effects. A one-shot rule applies only to windows created after it was added, and is
/// removed at the end of the discovery batch in which it matches.
public struct Rule: Equatable {
  public var label: String?
  public var app: RulePattern?
  public var title: RulePattern?
  public var role: RulePattern?
  public var subrole: RulePattern?
  public var effects = RuleEffects()
  public var oneShot = false

  public init() {}

  /// Whether the rule has a valid role or subrole pattern.
  public var hasRole: Bool { role?.regex != nil }
  public var hasSubrole: Bool { subrole?.regex != nil }

  /// Whether a window with these properties passes every filter of the rule.
  public func matches(
    app appName: String, title windowTitle: String, role windowRole: String,
    subrole windowSubrole: String
  ) -> Bool {
    (app?.admits(appName) ?? true) && (title?.admits(windowTitle) ?? true)
      && (role?.admits(windowRole) ?? true) && (subrole?.admits(windowSubrole) ?? true)
  }

}
