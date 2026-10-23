import YabaiCore

//
// NOTE: A tree of a saved layout for the encoding tests: nested splits and a tabbed container, four windows, of which
// window 3 has no matcher (the window manager did not know it at save time).
//

public enum LayoutFixtures {
  /// The matchers of windows 1, 2 and 4. Window 2's title has a slash, which the file keeps unescaped.
  public static let matchers: [UInt32: LayoutMatcher] = [
    1: LayoutMatcher(
      bundleID: "com.apple.Notes", app: "Notes", title: "Draft", role: "AXWindow",
      subrole: "AXStandardWindow"),
    2: LayoutMatcher(
      bundleID: "com.apple.Safari", app: "Safari", title: "Work/Inbox", role: "AXWindow",
      subrole: "AXStandardWindow"),
    4: LayoutMatcher(bundleID: nil, app: "Terminal", title: nil, role: "AXWindow", subrole: nil),
  ]

  /// The matcher lookup of the fixture: window 3 has none.
  public static func matcher(_ windowID: WindowID) -> LayoutMatcher? {
    matchers[windowID.rawValue]
  }

  private static func leaf(_ id: UInt32, percent: Float, isSelected: Bool = false) -> TreeSnapshot {
    TreeSnapshot(
      layout: .splitH, lastSplit: .splitH, percent: percent, zoom: .none, isSelected: isSelected,
      windowID: WindowID(rawValue: id), children: [], focusOrder: [])
  }

  /// splith [ w1, tabbed [ splitv [ w2, w3 ], w4 ] ]: the root and the tabbed container focus their second child first.
  public static let tree = TreeSnapshot(
    layout: .splitH, lastSplit: .splitH, percent: 1, zoom: .none, isSelected: false, windowID: nil,
    children: [
      leaf(1, percent: 0.4, isSelected: true),
      TreeSnapshot(
        layout: .tabbed, lastSplit: .splitV, percent: 0.6, zoom: .parent, isSelected: false,
        windowID: nil,
        children: [
          TreeSnapshot(
            layout: .splitV, lastSplit: .splitH, percent: 0.5, zoom: .none, isSelected: false,
            windowID: nil,
            children: [leaf(2, percent: 0.5), leaf(3, percent: 0.5)], focusOrder: [1, 0]),
          leaf(4, percent: 0.5),
        ], focusOrder: [1, 0]),
    ], focusOrder: [1, 0])
}
