import CustomDump
import Foundation
import PropertyBased
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: Property tests of the container model. TreeModel applies random operations to a tree the way the window
// manager does (the acting container is the selection, else a window), and checks the structural invariants after
// every step. Nothing here reaches the window server; the window ids start at treeTestWindowBase all the same.
//

/// A step of the tree property tests. A pick selects a window of the tree by index, modulo the window count.
enum TreeOperation: Sendable {
  case open(pick: Int, autotile: Bool)
  case close(pick: Int)
  case insert(pick: Int, InsertDirection)
  case arrive(from: Direction)
  case split(pick: Int, ConOrientation)
  case setLayout(pick: Int, ConLayout)
  case toggleLayout(pick: Int, splitOnly: Bool)
  case move(pick: Int, Direction, hasOutput: Bool)
  case swap(pick: Int, with: Int)
  case rotate(degrees: Int)
  case mirror(ConOrientation)
  case balance
  case resize(pick: Int, Direction, by: Int)
  case flatten
  case focus(pick: Int)
  case focusParent(pick: Int)

  static let layouts: [ConLayout] = [.splitH, .splitV, .tabbed]
  static let degrees = [90, 180, 270]

  init(
    _ input: (
      kind: Int, pick: Int, other: Int, Direction, InsertDirection, ConOrientation, choice: Int,
      flag: Bool
    )
  ) {
    let (kind, pick, other, direction, insertion, orientation, choice, flag) = input
    switch kind {
    case 0: self = .open(pick: pick, autotile: flag)
    case 1: self = .close(pick: pick)
    case 2: self = .insert(pick: pick, insertion)
    case 3: self = .arrive(from: direction)
    case 4: self = .split(pick: pick, orientation)
    case 5: self = .setLayout(pick: pick, Self.layouts[choice])
    case 6: self = .toggleLayout(pick: pick, splitOnly: flag)
    case 7: self = .move(pick: pick, direction, hasOutput: flag)
    case 8: self = .swap(pick: pick, with: other)
    case 9: self = .rotate(degrees: Self.degrees[choice])
    case 10: self = .mirror(orientation)
    case 11: self = .balance
    case 12: self = .resize(pick: pick, direction, by: (other - 6) * 50)
    case 13: self = .flatten
    case 14: self = .focus(pick: pick)
    default: self = .focusParent(pick: pick)
    }
  }

  static var generator: Generator<TreeOperation, some SendableSequenceType> {
    zip(
      Gen.int(in: 0...15), Gen.int(in: 0...11), Gen.int(in: 0...11), Gen<Direction>.direction,
      Gen<InsertDirection>.insertDirection, Gen<ConOrientation>.orientation, Gen.int(in: 0...2),
      Gen.bool
    )
    .map { TreeOperation($0) }
  }
}

/// A tree of 1 to 12 windows that applies TreeOperations like the window manager does.
@WM final class TreeModel {
  static let maxWindows = 12

  let root = Con(layout: .splitH)
  private(set) var windows: Set<WindowID> = []
  private var nextID: UInt32 = 1

  init(windowCount: Int) {
    for _ in 0..<windowCount { apply(.open(pick: 0, autotile: false)) }
  }

  private func leaf(_ pick: Int) -> Con? {
    let ids = root.windowIDs
    return ids.isEmpty ? nil : root.find(ids[pick % ids.count])
  }

  /// The container an operation acts on, like `treeActingCon` for the focused window.
  private func acting(_ pick: Int) -> Con? {
    return root.findSelected() ?? leaf(pick)
  }

  private func newLeaf() -> Con? {
    if windows.count >= Self.maxWindows { return nil }

    let windowID = WindowID(rawValue: treeTestWindowBase + nextID)
    nextID += 1
    windows.insert(windowID)
    return Con(windowID: windowID)
  }

  private func layOut() {
    root.layOut(Area(x: 0, y: 0, w: 1200, h: 900), gap: 10, barHeight: 0, barOffset: 0, barInset: 0)
  }

  func apply(_ operation: TreeOperation) {
    switch operation {
    case .open(_, let autotile):
      // like View.add: next to the selected container, else the focused window
      guard let node = newLeaf() else { return }
      var anchor = root.findSelected()
      if anchor?.isLeaf ?? true { anchor = root.focusedDescendant }
      if autotile { layOut() }
      root.open(node, after: anchor, autotile: autotile)
      node.focus()
      root.select(nil)
    case .close(let pick):
      // like View.remove
      guard windows.count > 1, let node = leaf(pick) else { return }
      windows.remove(node.windowID!)
      node.detach()
      node.destroy()
      root.flatten()
    case .insert(let pick, let direction):
      guard let anchor = leaf(pick), let node = newLeaf() else { return }
      anchor.insert(node, toward: direction)
      node.focus()
    case .arrive(let direction):
      guard let node = newLeaf() else { return }
      root.attach(node, from: direction)
    case .split(let pick, let orientation):
      acting(pick)?.split(orientation)
    case .setLayout(let pick, let layout):
      acting(pick)?.setLayout(layout)
    case .toggleLayout(let pick, let splitOnly):
      acting(pick)?.toggleLayout(splitOnly: splitOnly)
    case .move(let pick, let direction, let hasOutput):
      _ = acting(pick)?.move(direction, in: root, hasOutput: hasOutput)
    case .swap(let pick, let other):
      guard let a = leaf(pick), let b = leaf(other) else { return }
      a.swap(with: b)
    case .rotate(let degrees):
      root.rotate(by: degrees)
    case .mirror(let orientation):
      root.mirror(orientation)
    case .balance:
      root.balance()
    case .resize(let pick, let direction, let delta):
      layOut()
      acting(pick)?.resize(direction, by: Float(delta))
    case .flatten:
      root.flatten()
    case .focus(let pick):
      leaf(pick)?.focus()
      root.select(nil)
    case .focusParent(let pick):
      if let parent = acting(pick)?.parent { root.select(parent) }
    }
  }

  /// The broken invariants of the tree, empty when it is consistent.
  var violations: [String] {
    var result: [String] = []

    if root.parent != nil { result.append("the root has a parent") }

    let ids = root.windowIDs
    if Set(ids) != windows || ids.count != windows.count {
      result.append("windows \(ids.map(\.rawValue)) instead of \(windows.map(\.rawValue).sorted())")
    }

    var selected = 0
    check(root, &selected, &result)
    if selected > 1 { result.append("\(selected) selected containers") }

    if !root.focusedDescendant.isLeaf { result.append("the focused descendant is not a window") }

    return result
  }

  private func check(_ node: Con, _ selected: inout Int, _ result: inout [String]) {
    if node.isSelected { selected += 1 }

    if node.isLeaf {
      if !node.children.isEmpty { result.append("a window has children") }
      return
    }

    if node.children.isEmpty && node.parent != nil {
      result.append("an empty container below the root")
    }
    if node.lastSplit == .tabbed { result.append("a last split is tabbed") }

    if node.focusOrder.count != node.children.count
      || !node.focusOrder.allSatisfy({ node.children.contains($0) })
    {
      result.append("the focus order is not a permutation of the children")
    }

    if !node.children.isEmpty {
      let total = node.children.reduce(Float(0)) { $0 + $1.percent }
      if abs(total - 1) > 1e-4 { result.append("the shares add up to \(total)") }
      if node.children.contains(where: { $0.percent <= 0 }) {
        result.append("a share is not positive")
      }
    }

    for child in node.children {
      if child.parent !== node { result.append("a child links to another parent") }
      check(child, &selected, &result)
    }
  }
}

extension DaemonState {
  @Suite
  @WM struct TreePropertyTests {
    @Test(arguments: [false, true])
    func operationsKeepInvariants(workspaceTabbed: Bool) async {
      Config.current.space.treeWorkspaceTabbed = workspaceTabbed

      await propertyCheck(
        count: 300, input: Gen.int(in: 1...12), TreeOperation.generator.array(of: 1...40)
      ) { count, operations in
        let model = TreeModel(windowCount: count)
        try #require(model.violations.isEmpty, "\(model.violations)\n\(treeDump(model.root))")

        for (step, operation) in operations.enumerated() {
          let before = treeDump(model.root)
          model.apply(operation)
          let violations = model.violations
          try #require(
            violations.isEmpty,
            "step \(step), \(operation): \(violations)\n\(before)\n->\n\(treeDump(model.root))")
        }
      }
    }

    @Test func roundTripsRestoreTree() async {
      await propertyCheck(
        count: 200, input: Gen.int(in: 1...12), TreeOperation.generator.array(of: 0...30),
        Gen.int(in: 0...11), Gen.int(in: 0...11)
      ) { count, operations, a, b in
        let model = TreeModel(windowCount: count)
        for operation in operations { model.apply(operation) }
        let root = model.root
        let before = treeDump(root)

        for _ in 0..<4 { root.rotate(by: 90) }
        expectNoDifference(treeDump(root), before, "rotate 90 four times")

        root.rotate(by: 90)
        root.rotate(by: 270)
        expectNoDifference(treeDump(root), before, "rotate 90 then 270")

        root.rotate(by: 180)
        root.rotate(by: 180)
        expectNoDifference(treeDump(root), before, "rotate 180 twice")

        for orientation in [ConOrientation.horizontal, .vertical] {
          root.mirror(orientation)
          root.mirror(orientation)
          expectNoDifference(treeDump(root), before, "mirror \(orientation) twice")
        }

        let ids = root.windowIDs
        let first = root.find(ids[a % ids.count])!
        let second = root.find(ids[b % ids.count])!
        first.swap(with: second)
        first.swap(with: second)
        expectNoDifference(treeDump(root), before, "swap twice")
      }
    }

    // NOTE: space --undo rebuilds a tree from its snapshot: the rebuilt tree must look and encode the same.
    @Test func snapshotsRebuildTheTree() async {
      await propertyCheck(
        count: 200, input: Gen.int(in: 1...12), TreeOperation.generator.array(of: 0...30)
      ) { count, operations in
        let model = TreeModel(windowCount: count)
        for operation in operations { model.apply(operation) }
        let snapshot = model.root.snapshot

        let rebuilt = Con(snapshot: snapshot)
        expectNoDifference(treeDump(rebuilt), treeDump(model.root))
        #expect(rebuilt.snapshot == snapshot)

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TreeSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
      }
    }
  }
}

/// A fake window id of the tree tests, counted from treeTestWindowBase.
private func w(_ n: UInt32) -> WindowID { WindowID(rawValue: treeTestWindowBase + n) }

/// H[ w1 V[ w2 w3 ] ], with every focus order in the order of the children.
@WM private func treeExample() -> (root: Con, w1: Con, v: Con, w2: Con, w3: Con) {
  let root = Con(layout: .splitH)
  let w1 = treeTestLeaf(root, w(1))
  let v = treeTestSplit(root, .splitV)
  let w2 = treeTestLeaf(v, w(2))
  let w3 = treeTestLeaf(v, w(3))
  return (root, w1, v, w2, w3)
}

/// One row of the neighbor table: from a window of treeExample in a direction.
struct NeighborCase: Sendable, CustomTestStringConvertible {
  let from: UInt32
  let direction: Direction
  let wrapping: FocusWrapping
  let hasOutput: Bool
  let expected: String

  var testDescription: String {
    "w\(from) \(direction) wrapping \(wrapping.rawValue)\(hasOutput ? " output" : ""): \(expected)"
  }

  /// The rows of all wrapping modes, each with the result without and with a display in the direction.
  static func rows(
    _ from: UInt32, _ direction: Direction, off: (String, String), on: (String, String),
    force: (String, String)
  ) -> [NeighborCase] {
    [(FocusWrapping.off, off), (.on, on), (.force, force)].flatMap { wrapping, expected in
      [
        NeighborCase(
          from: from, direction: direction, wrapping: wrapping, hasOutput: false,
          expected: expected.0),
        NeighborCase(
          from: from, direction: direction, wrapping: wrapping, hasOutput: true,
          expected: expected.1),
      ]
    }
  }

  static let all: [NeighborCase] =
    rows(1, .east, off: ("w2", "w2"), on: ("w2", "w2"), force: ("w2", "w2"))
    + rows(1, .west, off: ("none", "output"), on: ("w2", "output"), force: ("w2", "w2"))
    + rows(1, .north, off: ("none", "output"), on: ("none", "output"), force: ("none", "output"))
    + rows(2, .east, off: ("none", "output"), on: ("w1", "output"), force: ("w1", "w1"))
    + rows(3, .north, off: ("w2", "w2"), on: ("w2", "w2"), force: ("w2", "w2"))
    + rows(3, .south, off: ("none", "output"), on: ("w2", "output"), force: ("w2", "w2"))
    + rows(3, .west, off: ("w1", "w1"), on: ("w1", "w1"), force: ("w1", "w1"))
}

extension DaemonState {
  @Suite
  @WM struct TreeExampleTests {
    @Test func forceOrientationWrapsWorkspace() {
      let tree = treeExample()

      let split = tree.root.forceOrientation(.vertical)

      #expect(split == tree.root.children[0])
      #expect(tree.root.lastSplit == .splitV)
      expectNoDifference(
        treeDump(tree.root),
        """
        splitv
          splith 1.0000
            w1 0.5000
            splitv 0.5000
              w2 0.5000
              w3 0.5000
        """)
    }

    @Test func descendEntersFromDirection() {
      let tree = treeExample()
      #expect(tree.root.descend(.east) == tree.w1)
      #expect(tree.root.descend(.west) == tree.w2)
      #expect(tree.root.descend(.north) == tree.w1)

      // across the orientation it follows the focus, along it it takes the near side
      tree.w3.focus()
      #expect(tree.root.descend(.north) == tree.w3)
      #expect(tree.root.descend(.south) == tree.w2)
      #expect(tree.root.descend(.east) == tree.w1)
      #expect(tree.root.descend(.west) == tree.w3)
      #expect(tree.w1.descend(.west) == tree.w1)
    }

    @Test func leavesInTreeOrder() {
      let tree = treeExample()
      #expect(tree.root.firstLeaf == tree.w1)
      #expect(tree.root.lastLeaf == tree.w3)
      #expect(tree.w1.nextLeaf == tree.w2)
      #expect(tree.w2.nextLeaf == tree.w3)
      #expect(tree.w3.nextLeaf == nil)
      #expect(tree.w3.previousLeaf == tree.w2)
      #expect(tree.w2.previousLeaf == tree.w1)
      #expect(tree.w1.previousLeaf == nil)
      #expect(tree.root.windowCount == 3)
      #expect(tree.v.windowCount == 2)

      let empty = Con()
      #expect(empty.firstLeaf == nil)
      #expect(empty.lastLeaf == nil)
      #expect(empty.windowCount == 0)
    }

    @Test func focusCandidateIsMostRecentSibling() {
      let tree = treeExample()
      #expect(tree.w1.focusCandidate == tree.w2)
      #expect(tree.w2.focusCandidate == tree.w3)
      tree.w3.focus()
      #expect(tree.w1.focusCandidate == tree.w3)

      // the only window has no candidate
      let root = Con()
      #expect(treeTestLeaf(root, w(1)).focusCandidate == nil)
    }

    @Test func tabbedAncestorSkipsSplits() {
      // H[ w1 T[ w2 V[ w3 ] ] ]
      let root = Con(layout: .splitH)
      let w1 = treeTestLeaf(root, w(1))
      let tabbed = treeTestSplit(root, .tabbed)
      treeTestLeaf(tabbed, w(2))
      let w3 = treeTestLeaf(treeTestSplit(tabbed, .splitV), w(3))

      #expect(w3.tabbedAncestor == tabbed)
      #expect(w1.tabbedAncestor == nil)
      #expect(tabbed.tabbedAncestor == nil)
    }

    @Test(arguments: NeighborCase.all)
    func neighbor(_ row: NeighborCase) {
      let tree = treeExample()
      let from = tree.root.find(w(row.from))!

      let result: String
      switch from.neighbor(row.direction, wrapping: row.wrapping, hasOutput: row.hasOutput) {
      case .focus(let node): result = treeDump(node)
      case .output: result = "output"
      case .none: result = "none"
      }

      #expect(result.split(separator: " ").first.map(String.init) == row.expected)
      #expect(TreeNeighbor.output.target == nil)
    }

    @Test(arguments: [TreePosition.before, .after])
    func placeNewWindow(_ position: TreePosition) {
      let tree = treeExample()

      // a window from outside the tree gets an average share and the focus
      Con(windowID: w(4)).place(position, of: tree.w2)

      expectNoDifference(
        treeDump(tree.root),
        position == .before
          ? """
          splith
            w1 0.5000
            splitv 0.5000
              w4 0.3333
              w2 0.3333
              w3 0.3333
          """
          : """
          splith
            w1 0.5000
            splitv 0.5000 focus=1,0,2
              w2 0.3333
              w4 0.3333
              w3 0.3333
          """)
    }

    @Test(arguments: [TreePosition.before, .after])
    func placeWindowOfTree(_ position: TreePosition) {
      let tree = treeExample()

      // the focused window keeps the focus in the container it moves into
      tree.w1.place(position, of: tree.w3)

      expectNoDifference(
        treeDump(tree.root),
        position == .before
          ? """
          splith
            splitv 1.0000 focus=1,0,2
              w2 0.3333
              w1 0.3333
              w3 0.3333
          """
          : """
          splith
            splitv 1.0000 focus=2,0,1
              w2 0.3333
              w3 0.3333
              w1 0.3333
          """)
    }

    @Test func placeIgnoresTargetOfAnotherTree() {
      let tree = treeExample()
      let other = Con()
      let target = treeTestLeaf(other, w(4))

      tree.w1.place(.after, of: target)

      #expect(tree.w1.parent == tree.root)
      #expect(other.children == [target])
    }

    @Test func workspaceTabbedWrapsWindowsOfWorkspace() {
      Config.current.space.treeWorkspaceTabbed = true
      let root = Con(layout: .splitH)
      let w1 = Con(windowID: w(1))
      root.open(w1, after: nil, autotile: false)
      root.open(Con(windowID: w(2)), after: w1, autotile: false)

      // placed next to the tabbed container on the workspace, a window gets a tabbed container of its own
      Con(windowID: w(3)).place(.after, of: root.children[0])

      // arriving from another display along the workspace, too
      root.attach(Con(windowID: w(4)), from: .west)

      // inserted beside a tab, it stays in that tabbed container's split
      let w5 = Con(windowID: w(5))
      w1.insert(w5, toward: .south)

      expectNoDifference(
        treeDump(root),
        """
        splith focus=2,1,0
          tabbed(splith) 0.3333
            splitv 0.5000
              w1 0.5000
              w5 0.5000
            w2 0.5000
          tabbed(splith) 0.3333
            w3 1.0000
          tabbed(splith) 0.3333
            w4 1.0000
        """)
    }
  }
}
