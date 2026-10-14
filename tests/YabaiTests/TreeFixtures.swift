import YabaiC

// NOTE: The tree fixtures of the C tests (tree_test_leaf and tree_test_split in tests/src/tree.c).

typealias Con = UnsafeMutablePointer<con>

@discardableResult
func treeTestLeaf(_ parent: Con, _ windowID: UInt32) -> Con
{
    let node = con_create(CON_SPLITH)!
    node.pointee.window_id = windowID
    tree_attach(parent, node, -1)
    return node
}

@discardableResult
func treeTestSplit(_ parent: Con, _ layout: con_layout) -> Con
{
    let node = con_create(layout)!
    tree_attach(parent, node, -1)
    return node
}
