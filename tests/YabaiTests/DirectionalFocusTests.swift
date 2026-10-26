import Testing

@testable import Yabai

//
// NOTE: How `window --focus <direction>` moves from an acting window outside a tree
// (`WindowManager.directionalFocus(window:layout:)`). The tree path and the crossing itself ask the window server.
//

@Suite struct DirectionalFocusTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let window: (isEligible: Bool, isFloating: Bool)?
    let layout: ViewType?
    let route: WindowManager.DirectionalFocus?
    let testDescription: String
  }

  static let rows: [Row] = [
    Row(window: nil, layout: nil, route: .display, testDescription: "no acting window"),
    Row(
      window: nil, layout: .float, route: .display, testDescription: "no acting window, float space"
    ),
    Row(
      window: (false, true), layout: .tree, route: .display,
      testDescription: "system dialog on a tree space"),
    Row(
      window: (false, true), layout: .float, route: .display,
      testDescription: "system dialog on a float space"),
    Row(
      window: (true, false), layout: .float, route: .space,
      testDescription: "window on a float space"),
    Row(
      window: (true, true), layout: .float, route: .space,
      testDescription: "floating window on a float space"),
    Row(
      window: (true, true), layout: .tree, route: nil,
      testDescription: "floating window on a tree space"),
    Row(
      window: (true, false), layout: .tree, route: .display,
      testDescription: "untiled window on a tree space"),
    Row(
      window: (true, true), layout: nil, route: nil, testDescription: "floating window, no space"),
  ]

  @Test(arguments: rows)
  func routeOutsideTree(_ row: Row) {
    #expect(WindowManager.directionalFocus(window: row.window, layout: row.layout) == row.route)
  }
}
