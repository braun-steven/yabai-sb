import CPrivate
import Foundation
import YabaiCore
@testable import Yabai

// NOTE: The tree fixtures of the former C tests (tree_test_leaf and tree_test_split of tests/src/tree.c), shared
// with the border tests. The calls name the Swift functions, which the C prototypes do not shadow here.

@discardableResult
@WM func treeTestLeaf(_ parent: Con, _ windowID: WindowID) -> Con
{
    let node = Con(windowID: windowID)
    parent.attach(node, at: nil)
    return node
}

@discardableResult
@WM func treeTestSplit(_ parent: Con, _ layout: ConLayout) -> Con
{
    let node = Con(layout: layout)
    parent.attach(node, at: nil)
    return node
}

/// The fake window ids of tree tests start above this value, so that no id is a real window of the session.
let treeTestWindowBase: UInt32 = 0xFFFF_0000

/// A text dump of a tree for comparisons: one line per container, indented by depth, with the layout (and the last
/// split of a tabbed container), the share of space, the focus order of the children when it differs from their order,
/// and `*` on the selected container. Windows print as `w<n>`, n counted from `treeTestWindowBase`.
@WM func treeDump(_ root: Con) -> String
{
    var lines: [String] = []
    treeDump(root, depth: 0, into: &lines)
    return lines.joined(separator: "\n")
}

@WM private func treeDump(_ node: Con, depth: Int, into lines: inout [String])
{
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
    if focus != Array(node.children.indices) { line += " focus=" + focus.map(String.init).joined(separator: ",") }

    if node.isSelected { line += " *" }
    lines.append(line)

    for child in node.children { treeDump(child, depth: depth + 1, into: &lines) }
}
