import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: How `window --focus <direction>` moves from an acting window outside a tree
// (`WindowManager.directionalFocus(window:layout:)`). The tree path and the crossing itself ask the window server.
//

@Suite struct DirectionalFocusTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let window: (isEligible: Bool, isFloating: Bool)?
    let layout: ViewType?
    let route: WindowManager.DirectionalFocus
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
      window: (true, true), layout: .tree, route: .floating,
      testDescription: "floating window on a tree space"),
    Row(
      window: (true, true), layout: .default, route: .floating,
      testDescription: "floating window on a default space"),
    Row(
      window: (true, false), layout: .tree, route: .display,
      testDescription: "untiled window on a tree space"),
    Row(
      window: (true, true), layout: nil, route: .floating,
      testDescription: "floating window, no space"),
  ]

  @Test(arguments: rows)
  func routeOutsideTree(_ row: Row) {
    #expect(WindowManager.directionalFocus(window: row.window, layout: row.layout) == row.route)
  }
}

//
// NOTE: Which display a directional command crosses to (`DisplayID.crossingDisplay(_:showsFullscreenSpace:)`): tree
// focus and moves, `window --focus <direction>` and `window --warp <direction>` outside a tree all refuse a display
// showing a fullscreen space, and none looks past it.
//

@Suite struct CrossingDisplayTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let closest: DisplayID?
    let fullscreen: Set<DisplayID>
    let crossing: DisplayID?
    let testDescription: String
  }

  static let rows: [Row] = [
    Row(closest: nil, fullscreen: [], crossing: nil, testDescription: "no display that way"),
    Row(
      closest: 0xFFFF_0002, fullscreen: [], crossing: 0xFFFF_0002,
      testDescription: "display with a user space"),
    Row(
      closest: 0xFFFF_0002, fullscreen: [0xFFFF_0002], crossing: nil,
      testDescription: "display showing a fullscreen space"),
    Row(
      closest: 0xFFFF_0002, fullscreen: [0xFFFF_0003], crossing: 0xFFFF_0002,
      testDescription: "a farther display shows a fullscreen space"),
  ]

  @Test(arguments: rows)
  func crossingDisplay(_ row: Row) {
    let crossing = DisplayID.crossingDisplay(row.closest) { row.fullscreen.contains($0) }
    #expect(crossing == row.crossing)
  }
}
