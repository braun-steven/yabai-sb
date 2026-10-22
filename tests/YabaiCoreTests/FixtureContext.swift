import YabaiCore

/// The lookups of the selectors, on fixtures. Windows are their ids.
struct FixtureContext: SelectorContext {
  var activeDisplay: DisplayID? = nil
  var activeSpace: SpaceID? = nil
  var acting: WindowID? = nil
  var displays: [DisplayID] = []
  var spaces: [SpaceID] = []
  var recentSpace: SpaceID? = nil
  var displayLabels: [String: DisplayID] = [:]
  var spaceLabels: [String: SpaceID] = [:]
  var windows: [WindowID] = []
  var stack: [WindowID] = []

  func actingWindow() -> WindowID? { acting }

  func display(_ query: DisplayQuery) -> DisplayID? {
    switch query {
    case .arrangement(let index):
      index >= 1 && Int(index) <= displays.count ? displays[Int(index) - 1] : nil
    case .first: displays.first
    case .last: displays.last
    default: nil
    }
  }

  func displayLabel(_ label: Token) -> DisplayID? { displayLabels[label.string] }

  func space(_ query: SpaceQuery) -> SpaceID? {
    switch query {
    case .missionControl(let index):
      index >= 1 && Int(index) <= spaces.count ? spaces[Int(index) - 1] : nil
    case .recent: recentSpace
    default: nil
    }
  }

  func spaceLabel(_ label: Token) -> SpaceID? { spaceLabels[label.string] }

  func window(_ query: WindowQuery<WindowID>) -> WindowID? {
    switch query {
    case .id(let id): windows.contains(id) ? id : nil
    case .first: windows.first
    case .stackPosition(_, let position):
      position >= 1 && position <= stack.count ? stack[position - 1] : nil
    default: nil
    }
  }
}
