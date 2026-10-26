import CPrivate
import Foundation
import SortedCollections
import YabaiCore
import YabaiTestSupport

@testable import Yabai

// NOTE: The tree fixtures of the former C tests (tree_test_leaf and tree_test_split of tests/src/tree.c), shared
// with the border tests. The calls name the Swift functions, which the C prototypes do not shadow here.

@discardableResult
@WM func treeTestLeaf(_ parent: Con, _ windowID: WindowID) -> Con {
  let node = Con(windowID: windowID)
  parent.attach(node, at: nil)
  return node
}

@discardableResult
@WM func treeTestSplit(_ parent: Con, _ layout: ConLayout) -> Con {
  let node = Con(layout: layout)
  parent.attach(node, at: nil)
  return node
}

/// The fake window ids of tree tests start above this value, so that no id is a real window of the session.
let treeTestWindowBase: UInt32 = 0xFFFF_0000

/// A text dump of a tree for comparisons: one line per container, indented by depth, with the layout (and the last
/// split of a tabbed container), the share of space, the focus order of the children when it differs from their order,
/// and `*` on the selected container. Windows print as `w<n>`, n counted from `treeTestWindowBase`.
@WM func treeDump(_ root: Con) -> String {
  var lines: [String] = []
  treeDump(root, depth: 0, into: &lines)
  return lines.joined(separator: "\n")
}

@WM private func treeDump(_ node: Con, depth: Int, into lines: inout [String]) {
  var line = String(repeating: "  ", count: depth)

  if let windowID = node.windowID {
    let raw = windowID.rawValue
    line += "w\(raw > treeTestWindowBase ? raw - treeTestWindowBase : raw)"
  } else {
    line += node.layout.rawValue
    if node.layout == .tabbed { line += "(\(node.lastSplit.rawValue))" }
  }

  if node.parent != nil { line += String(format: " %.4f", node.percent) }

  let focus = node.focusOrder.compactMap { node.children.firstIndex(of: $0) }
  if focus != Array(node.children.indices) {
    line += " focus=" + focus.map(String.init).joined(separator: ",")
  }

  if node.isSelected { line += " *" }
  lines.append(line)

  for child in node.children { treeDump(child, depth: depth + 1, into: &lines) }
}

func wid(_ n: UInt32) -> WindowID { WindowID(rawValue: treeTestWindowBase + n) }

/// A placement of a headless flush, with the window named like treeDump does.
struct PlacementLine: CustomStringConvertible {
  var placement: RecordedPlacement

  var description: String {
    let p = placement
    return
      "w\(p.windowID.rawValue - treeTestWindowBase): \(Int(p.x)),\(Int(p.y)) \(Int(p.w))x\(Int(p.h))"
  }
}

/// The placements recorded since the last drain.
@WM func drainPlacements() -> [PlacementLine] {
  Headless.drain().placements.map { PlacementLine(placement: $0) }
}

/// A tree view of a fake space with fake windows w<n>, registered in the window manager like managed windows (without
/// addManagedWindow, which reaches the window server and the scripting addition).
@WM final class Workspace {
  static let sid: SpaceID = 0xFFFF_0100

  let view = View(sid: Workspace.sid)
  let application = Application()

  init(area: Area = Area(x: 0, y: 0, w: 1200, h: 800)) {
    view.layout = .tree
    view.area = area
    SpaceManager.shared.views[Workspace.sid] = view
  }

  var dump: String { treeDump(view.root) }

  func node(_ n: UInt32) -> Con { view.findWindow(wid(n))! }

  /// Opens window n; it gets focus when focus is true, as when the application focuses its new window. insertByRule is
  /// the insert= effect of the rule that matched the new window, taken by the add. besideFocus adds it as a window that
  /// `window --display` or `window --space` moves here.
  @discardableResult
  func open(
    _ n: UInt32, insertionPoint: UInt32? = nil, focus: Bool = false,
    insertByRule: InsertDirection? = nil, besideFocus: Bool = false
  ) -> Window {
    let target = Window(id: wid(n))
    target.application = application
    target.insertionByRule = insertByRule
    WindowManager.shared.window[target.id] = target
    WindowManager.shared.managedWindows[target.id] = view
    if focus { WindowManager.shared.focus.focusChanged(to: target.id) }

    view.add(target, insertionPoint: insertionPoint.map(wid), besideFocus: besideFocus)
    return target
  }

  func focus(_ n: UInt32) {
    WindowManager.shared.focus.focusChanged(to: wid(n))
    view.tree?.select(nil)
    node(n).focus()
  }

  @discardableResult
  func close(_ n: UInt32) -> Bool {
    let target = WindowManager.shared.window[wid(n)]!
    let result = view.remove(target)
    WindowManager.shared.managedWindows[target.id] = nil
    WindowManager.shared.window[target.id] = nil
    return result
  }
}
