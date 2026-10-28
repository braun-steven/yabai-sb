import CoreGraphics
import Synchronization
import YabaiCore

//
// NOTE: Dragging the gap between two children of a split (P13.2). The event tap never walks the live tree: every flush
// of a view stores the visible path of its tree per space (the nodes and areas that SplitHitTest reads, and the tiled
// windows), and the tap hit-tests that copy. Only @WM maps a hit back to its containers, when the drag begins.
//

/// The visible path of a space at its last flush, with the windows tiled on the space.
struct SplitDragLayout: Sendable {
  var nodes: [LayoutNode]
  var areas: [Area]
  var gap: Int
  var tiledWindowIDs: Set<WindowID>
}

private let splitDragLayouts = Mutex<[SpaceID: SplitDragLayout]>([:])

enum SplitDragCache {
  /// The layout stored for the space, as of its last flush; nil when the space has no split to drag.
  static func layout(for sid: SpaceID) -> SplitDragLayout? {
    splitDragLayouts.withLock { $0[sid] }
  }

  /// Stores the layout of the space, or removes its entry when layout is nil.
  static func store(_ layout: SplitDragLayout?, for sid: SpaceID) {
    splitDragLayouts.withLock { $0[sid] = layout }
  }

  static func reset() {
    splitDragLayouts.withLock { $0.removeAll() }
  }

  //
  // NOTE: Called from the event tap, so nothing here touches @WM state. The click starts a drag only when a visible space
  // has a gap under it, and the window server has no window there but a tiled one of that space, the desktop or nothing.
  // Windows of yabai's own connection (borders, tab bars) do not count, as in WindowManager.window(at:). A floating window,
  // a menu or any other window over the gap takes the click.
  //

  nonisolated static func startsSplitDrag(at point: CGPoint) -> Bool {
    guard let tiledWindowIDs = gapTiledWindowIDs(at: point) else { return false }

    let found = SLS.topWindow(at: point, skipping: SLS.connection)
    return startsDrag(windowUnderPoint: found, level: found?.level, tiledWindowIDs: tiledWindowIDs)
  }

  //
  // NOTE: The decision after the window server lookup, without window server access. The level is an autoclosure, so it is
  // only queried for a window that is neither nil nor tiled. A level that could not be read (nil) passes the click through.
  //

  nonisolated static func startsDrag(
    windowUnderPoint wid: WindowID?, level: @autoclosure () -> Int32?, tiledWindowIDs: Set<WindowID>
  ) -> Bool {
    guard let wid else { return true }
    if tiledWindowIDs.contains(wid) { return true }
    guard let level = level() else { return false }
    return level < CGWindowLevelForKey(.normalWindow)
  }

  /// The tiled windows of the first visible space whose split has a gap at point, or nil when no visible space has one.
  private nonisolated static func gapTiledWindowIDs(at point: CGPoint) -> Set<WindowID>? {
    splitDragLayouts.withLock { layouts in
      for (sid, layout) in layouts where sid.isVisible {
        if SplitHitTest.handle(nodes: layout.nodes, areas: layout.areas, gap: layout.gap, at: point)
          != nil
        {
          return layout.tiledWindowIDs
        }
      }
      return nil
    }
  }
}

/// The visible path of a tree, as SplitHitTest reads it, with the container of every node. A tabbed container lists only
/// its visible child (focusOrder[0]), which shares its area with the other tabs. Nil when a container on the path is zoomed.
@WM func splitDragPath(of root: Con) -> SplitLayoutPath<Con>? {
  SplitLayoutWalk.visiblePath(
    root,
    info: { con in
      SplitLayoutInfo(
        layout: con.layout, percent: con.percent, area: con.area, isZoomed: con.zoom != ConZoom.none
      )
    },
    children: { con in
      if con.isLeaf { return [] }
      if con.layout == .tabbed { return con.focusOrder.first.map { [$0] } ?? [] }
      return con.children
    })
}

@WM private func collectTiledWindowIDs(_ con: Con, into ids: inout Set<WindowID>) {
  if let windowID = con.windowID {
    ids.insert(windowID)
    return
  }
  for child in con.children { collectTiledWindowIDs(child, into: &ids) }
}

extension View {
  /// Stores the split layout of this view for the event tap at every flush. The entry is removed when the view has no
  /// tree to drag, is not a tree, or has a zoomed container on its visible path.
  @WM func updateSplitDragLayout() {
    guard layout == .tree, let root = tree, let path = splitDragPath(of: root) else {
      SplitDragCache.store(nil, for: sid)
      return
    }

    var tiledWindowIDs = Set<WindowID>()
    collectTiledWindowIDs(root, into: &tiledWindowIDs)
    SplitDragCache.store(
      SplitDragLayout(
        nodes: path.nodes, areas: path.areas, gap: windowGapValue, tiledWindowIDs: tiledWindowIDs),
      for: sid)
  }
}

/// A split drag in progress, on @WM. It keeps the two children next to the gap and the percents they had when the drag
/// began: every move is computed from those, so a move that is skipped loses nothing.
@WM final class SplitDrag {
  weak var view: View?
  weak var split: Con?
  weak var first: Con?
  weak var second: Con?
  let horizontal: Bool
  let boundary: Int
  let start: CGPoint
  let startFirst: Float
  let startSecond: Float
  /// The length of the split along its axis, the size that Con.resize divides the change by.
  let size: Float
  /// When the frames were last written (OSTimer), zero before the first frame of the drag.
  var lastFrameTime: UInt64 = 0

  init(
    view: View, split: Con, first: Con, second: Con, horizontal: Bool, boundary: Int,
    start: CGPoint, size: Float
  ) {
    self.view = view
    self.split = split
    self.first = first
    self.second = second
    self.horizontal = horizontal
    self.boundary = boundary
    self.start = start
    self.startFirst = first.percent
    self.startSecond = second.percent
    self.size = size
  }

  /// Whether the two children are still next to each other in the split, and the split is still in the tree of the view.
  var isValid: Bool {
    guard let view, view.layout == .tree, let root = view.tree else { return false }
    guard let split, let first, let second else { return false }
    guard split.children.count > boundary + 1 else { return false }
    guard split.children[boundary] === first, split.children[boundary + 1] === second else {
      return false
    }

    var node: Con? = split
    while let current = node, current !== root { node = current.parent }
    return node != nil
  }

  /// Moves the gap to the point and flushes the view. Returns false when the drag no longer applies.
  @discardableResult
  func apply(to point: CGPoint) -> Bool {
    guard isValid, let view, let split, let first, let second else { return false }

    let along = horizontal ? point.x - start.x : point.y - start.y
    guard
      let percents = SplitRatio.resized(
        first: startFirst, second: startSecond, delta: Float(along), size: size,
        minPercent: Con.minPercent)
    else { return true }

    first.percent = percents.first
    second.percent = percents.second
    split.fixPercent()
    view.updateTree()
    view.flush()
    return true
  }
}
