import CoreGraphics
import YabaiCore

//
// NOTE: The handlers of a split drag (P13.2). The event tap consumes the mouse events of a drag that starts on a split gap
// and posts them as split events, so the window manager's mouse handlers never see them. The tap posts splitDragBegan
// first, then splitDragMoved for each drag event and splitDragEnded for the mouse up.
//

extension EventHandler {
  /// Starts a split drag at the point, on the tree of the space under the cursor.
  func splitDragBegan(_ point: CGPoint) {
    MouseState.shared.splitDrag = nil

    guard let sid = DisplayID(containing: point).flatMap({ $0.currentSpace }) else { return }
    beginSplitDrag(at: point, in: SpaceManager.shared.view(for: sid))
  }

  /// Records the split under the point of the view as the drag in progress, when there is a gap of a split there. The
  /// containers come from the live tree, the tap only knew that a gap was there.
  func beginSplitDrag(at point: CGPoint, in view: View) {
    let ms = MouseState.shared
    guard !MissionControl.shared.isActive, ms.currentAction == .none else { return }
    guard view.layout == .tree, let root = view.tree, let path = splitDragPath(of: root) else {
      return
    }
    guard
      let handle = SplitHitTest.handle(
        nodes: path.nodes, areas: path.areas, gap: view.windowGapValue, at: point)
    else { return }

    let split = path.elements[handle.container]
    let boundary = handle.boundary
    guard boundary + 1 < split.children.count else { return }

    let horizontal = handle.orientation == .splitH
    let size = horizontal ? split.area.w : split.area.h
    guard size > 0 else { return }

    ms.splitDrag = SplitDrag(
      view: view, split: split, first: split.children[boundary],
      second: split.children[boundary + 1], horizontal: horizontal, boundary: boundary,
      start: point, size: size)
  }

  //
  // NOTE: Split drag events are coalesced like the mouse drags: a move that a newer one has already overtaken is skipped.
  // Frames are written at most once per dragResizeInterval, as the window resize drag does. The mouse up is never skipped
  // and writes the final position.
  //

  func splitDragMoved(_ point: CGPoint) {
    if EventHandler.isStale(pendingSplitDragged) { return }

    let ms = MouseState.shared
    guard let drag = ms.splitDrag else { return }

    let eventTime = OSTimer.now
    if OSTimer.milliseconds(from: drag.lastFrameTime, to: eventTime) < dragResizeInterval { return }

    if drag.apply(to: point) {
      drag.lastFrameTime = eventTime
    } else {
      ms.splitDrag = nil
    }
  }

  func splitDragEnded(_ point: CGPoint) {
    let ms = MouseState.shared
    guard let drag = ms.splitDrag else { return }

    ms.splitDrag = nil
    drag.apply(to: point)
  }
}
