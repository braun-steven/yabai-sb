import CoreGraphics
import Logging
import SortedCollections
import YabaiCore

//
// NOTE: The scroll layout of a view (`layout scroll`), after niri. The view keeps its container tree, whose root is a
// horizontal split: each child of the root is a column, a window or a container laid out like any subtree. The root
// does not share its width among the columns: each column is its own share of the view wide (`Con.columnWidth`, else
// `scroll_column_width`), and the strip scrolls (`ScrollState.offset`) to keep the column focused in the root's focus
// order in view. The math is `ScrollStrip` in YabaiCore.
//
// A window scrolled out of view keeps its frame in the tree (`Con.area`, the strip's coordinates on the display), and
// is placed parked at the edge of the display (`frame(for:)`), the frame that the flush writes and the window moved
// handlers compare with. Its column is marked scrolled out, which hides its tab bars and border.
//

/// How far the strip of a scroll view is scrolled, and the display that it is laid out on.
struct ScrollState {
  /// The distance of the view's left edge from the start of the strip; negative when a strip that fits is centered.
  var offset: Float = 0
  /// The frame of the whole display, where windows scrolled out of view are parked.
  var display = Area.zero
  /// The edges of the display with another display beyond them.
  var walls: ScrollWalls = []
  /// Where the windows out of view are parked on the display.
  var edges = ScrollEdges(left: 0, right: 0)
}

extension View {
  /// The share of the view that a column of the strip is wide.
  func columnShare(of column: Con) -> Float {
    column.columnWidth > 0 ? column.columnWidth : Config.current.space.scrollColumnWidth
  }

  /// The index in the strip of the column that holds the container: the child of the root that it belongs to.
  func columnIndex(of node: Con) -> Int? {
    var column = node
    while let parent = column.parent, parent.parent != nil { column = parent }
    return column.parent == nil ? nil : column.index
  }

  /// The index of the column that the root focuses, the one the strip keeps in view.
  var focusedColumnIndex: Int? {
    tree?.focusOrder.first?.index
  }

  /// The room the strip keeps at each edge for the strips of parked windows (`scroll_peek`).
  var scrollInsets: ScrollInsets {
    ScrollStrip.insets(
      peek: Float(Config.current.space.scrollPeek), gap: windowGapValue, view: area,
      display: scroll.display)
  }

  /// The length that the columns of the strip are shares of (`ScrollStrip.spans`).
  var sharedColumnLength: Float {
    let insets = scrollInsets
    return area.w - (insets.left + insets.right) / 2
  }

  /// The columns of the strip, starting at 0.
  private func columnSpans(_ root: Con, gap: Int) -> [ColumnSpan] {
    ScrollStrip.spans(
      shares: root.children.map { columnShare(of: $0) }, length: area.w, gap: gap,
      insets: scrollInsets)
  }

  /// Gives every column the default width (`space --balance`).
  func resetColumnWidths() {
    for column in tree?.children ?? [] { column.columnWidth = 0 }
  }

  //
  // NOTE: Windows park against the whole display, not the area that the Dock and the menu bar leave (`frame`): parked
  // against a Dock on the left, a window would keep the Dock's width on screen under it.
  //

  /// Records the display that the strip is laid out on, and its walls (`update`). frame is the area of the display
  /// that the view is laid out in, which headless mode takes as the display.
  func updateScrollDisplay(_ frame: CGRect) {
    if Headless.isEnabled {
      scroll.display = Area(frame)
      scroll.walls = []
      return
    }

    let displays = DisplayID.all.map { Area(CGDisplayBounds($0.rawValue)) }
    let own = sid.display.map { Area(CGDisplayBounds($0.rawValue)) } ?? Area(frame)
    scroll.display = own
    scroll.walls = ScrollStrip.walls(of: own, among: displays)
  }

  //
  // NOTE: Every command keeps the root of a scroll view a horizontal split, but a tree operation that re-orients the
  // root (an i3 move across it, a layout of a window whose parent is the root) would turn the strip into one column of
  // its own. Such a root is put back: its children go into one column with the root's layout, the strip's only one.
  //

  /// Puts the root back to a strip after a tree operation re-oriented it.
  private func restoreStrip(_ root: Con) {
    if root.layout == .splitH { return }

    Logger.tree.debug("scroll: the root was re-oriented; its children become one column")
    root.wrapChildrenInColumn()
  }

  /// Lays the strip out: each column at its span, scrolled to show the focused column. previous is the index of the
  /// column focused before a focus change, which `scroll_center overflow` reads.
  func layOutStrip(
    _ root: Con, gap: Int, barHeight: Int, barOffset: Int, barInset: Int, previous: Int?
  ) {
    root.isStrip = true
    restoreStrip(root)
    root.area = area

    let spans = columnSpans(root, gap: gap)
    scroll.offset = ScrollStrip.offset(
      revealing: focusedColumnIndex, previous: previous, current: scroll.offset, spans: spans,
      length: area.w, insets: scrollInsets, center: Config.current.space.scrollCenter)

    let columnAreas = spans.map { span in
      Area(x: area.x + span.start - scroll.offset, y: area.y, w: span.width, h: area.h)
    }
    scroll.edges = ScrollStrip.edges(
      of: columnAreas, display: scroll.display, peek: Float(Config.current.space.scrollPeek),
      gap: gap)

    for (column, columnArea) in zip(root.children, columnAreas) {
      column.layOut(
        columnArea, gap: gap, barHeight: barHeight, barOffset: barOffset, barInset: barInset)
      column.setScrolledOut(
        ScrollStrip.isScrolledOut(
          columnArea, display: scroll.display, walls: scroll.walls, edges: scroll.edges))
    }
  }

  /// The frame that a window of the strip is placed at: where the strip puts it, parked at the edge of the display
  /// when that is out of view.
  func parkedFrame(_ area: Area) -> Area {
    ScrollStrip.park(area, display: scroll.display, walls: scroll.walls, edges: scroll.edges)
  }

  //
  // NOTE: A window parked at a wall stays wholly on its display (`ScrollStrip.park`), over the columns in view where
  // they overlap unless it is ordered below them. The window list of a space is front to back, so the parked windows
  // are ordered right below the lowest window in view, in one message to the scripting addition. Away from walls a
  // parked window shows only a strip at the edge, which the columns in view do not cover, so it is left alone.
  //

  /// Orders the windows of a scroll view that are parked at a wall below its windows in view.
  func orderParkedWindows() {
    guard layout == .scroll, !scroll.walls.isEmpty, let root = tree else { return }

    var parked: [WindowID] = []
    var inView: Set<WindowID> = []
    for column in root.children {
      if column.isScrolledOut {
        parked += column.windowIDs
      } else {
        inView.formUnion(column.windowIDs)
      }
    }
    guard !parked.isEmpty, let windowList = sid.windows(includingMinimized: false),
      let lowest = windowList.last(where: { inView.contains($0) })
    else { return }

    ScriptingAddition.shared.orderWindows(
      parked.map { WindowOrder(window: $0, order: -1, relativeTo: lowest) })
  }

  //
  // NOTE: A window parked at the edge shows only a strip, so it would be lost once the strip no longer places it: when
  // it leaves the view (floating, another space or display, unmanaged) or the view leaves the scroll layout. It is put
  // back wholly on the display, where the strip has it, first.
  //

  /// Puts the windows of the view that are scrolled out back on the display, or only target's when it is given.
  func unparkWindows(_ target: WindowID? = nil) {
    guard layout == .scroll, let root = tree else { return }

    var placements: [WindowPlacement] = []
    for column in root.children where column.isScrolledOut {
      for windowID in column.windowIDs where target == nil || windowID == target {
        guard let node = findWindow(windowID),
          let window = WindowManager.shared.window(for: windowID), window.isValid
        else { continue }
        let frame = ScrollStrip.park(
          node.area, display: scroll.display, walls: [.left, .right], edges: scroll.edges)
        placements.append(WindowPlacement(window: window, x: frame.x, y: frame.y, w: frame.w, h: frame.h))
      }
    }
    if !placements.isEmpty { WindowManager.shared.placeWindows(placements) }
  }

  /// Whether the strip shows the whole window now; always true outside a scroll view.
  func isWhollyInView(_ windowID: WindowID) -> Bool {
    guard layout == .scroll, let node = findWindow(windowID) else { return true }
    // NOTE: A window parked at a wall is wholly on the display, behind the columns in view; it is not in view.
    return !node.isScrolledOut && ScrollStrip.isInView(node.area, display: scroll.display)
  }

  /// Scrolls the strip so that the column at index is centered (`window --center`). The strip still stops at its ends
  /// unless `scroll_center` is `always`, and keeps the focused column in view.
  func centerColumn(at index: Int) {
    guard let root = tree else { return }
    let spans = columnSpans(root, gap: windowGapValue)
    guard spans.indices.contains(index) else { return }

    scroll.offset = ScrollStrip.offset(
      revealing: index, current: scroll.offset, spans: spans, length: area.w, insets: scrollInsets,
      center: .always)
    updateTree()
    flush()
  }

  /// Scrolls the strip to the column that the root focuses now, after a focus change from the column at previous, and
  /// applies it when the strip moved.
  func scrollToFocusedColumn(from previous: Int?) {
    let before = scroll.offset
    updateTree(revealingFrom: previous)
    if scroll.offset != before { flush() }
  }
}

extension Con {
  /// Marks the container and its descendants as scrolled out of view, or back in view.
  fileprivate func setScrolledOut(_ scrolledOut: Bool) {
    isScrolledOut = scrolledOut
    for child in children { child.setScrolledOut(scrolledOut) }
  }
}

extension SpaceManager {
  /// Lays out every scroll view again, after a setting of the strip changed (`scroll_column_width`, `scroll_center`,
  /// `scroll_peek`).
  func relayOutScrollViews() {
    for target in views.values where target.layout == .scroll {
      target.updateAndFlush()
    }
  }
}
