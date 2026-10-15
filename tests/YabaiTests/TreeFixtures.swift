import YabaiC
@testable import Yabai

// NOTE: The tree fixtures of the C tests (tree_test_leaf and tree_test_split of the former tests/src/tree.c; the C
// test of border.c keeps a copy). The calls name the Swift functions, which the C prototypes do not shadow here.

@discardableResult
func treeTestLeaf(_ parent: Con, _ windowID: UInt32) -> Con
{
    let node = Yabai.con_create(CON_SPLITH)!
    node.pointee.window_id = windowID
    Yabai.tree_attach(parent, node, -1)
    return node
}

@discardableResult
func treeTestSplit(_ parent: Con, _ layout: con_layout) -> Con
{
    let node = Yabai.con_create(layout)!
    Yabai.tree_attach(parent, node, -1)
    return node
}
