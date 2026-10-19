import CPrivate
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
