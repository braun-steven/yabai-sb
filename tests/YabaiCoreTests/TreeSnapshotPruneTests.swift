import Testing
import YabaiCore

private func leaf(_ id: UInt32, _ percent: Float = 0.5) -> TreeSnapshot {
  TreeSnapshot(
    layout: .splitH, lastSplit: .splitH, percent: percent, zoom: .none, isSelected: false,
    windowID: WindowID(rawValue: id), children: [], focusOrder: [])
}

private func container(
  _ layout: ConLayout, _ children: [TreeSnapshot], percent: Float = 1, focusOrder: [Int]
) -> TreeSnapshot {
  TreeSnapshot(
    layout: layout, lastSplit: .splitH, percent: percent, zoom: .none, isSelected: false,
    windowID: nil, children: children, focusOrder: focusOrder)
}

private func ids(_ values: UInt32...) -> Set<WindowID> {
  Set(values.map { WindowID(rawValue: $0) })
}

@Test func treeSnapshotListsItsWindowsInTreeOrder() {
  let tree = container(
    .splitH, [container(.tabbed, [leaf(2), leaf(1)], focusOrder: [0, 1]), leaf(3)],
    focusOrder: [0, 1])

  #expect(tree.windowIDs.map(\.rawValue) == [2, 1, 3])
}

@Test func treeSnapshotShapeShowsLayoutsAndWindows() {
  let tree = container(
    .splitH, [container(.tabbed, [leaf(2), leaf(1)], focusOrder: [0, 1]), leaf(3)],
    focusOrder: [0, 1])

  #expect(tree.shape == "splith[tabbed[2 1] 3]")
}

@Test func prunedTreeWithAllWindowsIsTheTree() {
  let tree = container(
    .splitH,
    [container(.tabbed, [leaf(1), leaf(2)], percent: 0.6, focusOrder: [1, 0]), leaf(3, 0.4)],
    focusOrder: [1, 0])

  #expect(tree.pruned(keeping: ids(1, 2, 3)) == tree)
}

@Test func prunedTreeDropsEmptyContainersAndKeepsTheFocusOrder() throws {
  let tree = container(
    .splitH,
    [
      container(.tabbed, [leaf(1), leaf(2)], percent: 0.5, focusOrder: [0, 1]),
      leaf(3, 0.25), leaf(4, 0.25),
    ],
    focusOrder: [2, 0, 1])

  let pruned = try #require(tree.pruned(keeping: ids(3, 4)))

  #expect(pruned.windowIDs.map(\.rawValue) == [3, 4])
  #expect(pruned.focusOrder == [1, 0])
  #expect(pruned.children.map(\.percent) == [0.5, 0.5])
}

@Test func prunedTreeKeepsAContainerWithOneWindow() throws {
  let tree = container(
    .splitH,
    [container(.tabbed, [leaf(1), leaf(2)], percent: 0.5, focusOrder: [1, 0]), leaf(3)],
    focusOrder: [0, 1])

  let pruned = try #require(tree.pruned(keeping: ids(1, 3)))

  #expect(pruned.children[0].layout == .tabbed)
  #expect(pruned.children[0].windowIDs.map(\.rawValue) == [1])
  #expect(pruned.children[0].focusOrder == [0])
}

@Test func prunedTreeWithoutWindowsIsNil() {
  let tree = container(.splitH, [leaf(1), leaf(2)], focusOrder: [0, 1])

  #expect(tree.pruned(keeping: ids(9)) == nil)
  #expect(leaf(1).pruned(keeping: []) == nil)
}
