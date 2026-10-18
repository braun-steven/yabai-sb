import CPrivate
@testable import Yabai

// NOTE: The tree fixtures of the former C tests (tree_test_leaf and tree_test_split of tests/src/tree.c), shared
// with the border tests. The calls name the Swift functions, which the C prototypes do not shadow here.

@discardableResult
func treeTestLeaf(_ parent: Con, _ windowID: UInt32) -> Con
{
    let node = Yabai.con_create(.splitH)!
    node.window_id = windowID
    Yabai.tree_attach(parent, node, -1)
    return node
}

@discardableResult
func treeTestSplit(_ parent: Con, _ layout: ConLayout) -> Con
{
    let node = Yabai.con_create(layout)!
    Yabai.tree_attach(parent, node, -1)
    return node
}
