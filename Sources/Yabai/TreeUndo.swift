import SortedCollections
import YabaiCore

//
// NOTE: space --undo. A tree command that changes the tree of a space keeps the tree as it was before, in the history of
// the view (TreeHistory, at most 10 entries). The commands are not changed: the handlers run them through
// recordingTreeUndo, which takes the snapshot before and after, so a failed or no-op command leaves no entry.
//

/// Runs a tree command on the view it acts on, and records the tree before it when the command succeeded and changed the
/// tree. A nil view, or one without a tree, runs the command unrecorded.
@WM func recordingTreeUndo<E: Error>(on view: View?, _ body: () throws(E) -> Void) throws(E) {
  guard let view, let tree = view.tree else {
    try body()
    return
  }

  //
  // NOTE: Entries from before a window change are dropped here, before the command. Inside the command, warp and stack
  // remove and add windows of the space, so the history is not touched there.
  //

  let windows = Set(view.windowIDs)
  view.history.clearIfWindowsChanged(to: windows)

  let before = tree.snapshot
  try body()

  guard let after = view.tree?.snapshot, after != before else { return }
  view.history.push(TreeHistory.Entry(tree: before, windows: windows))
}

//
// NOTE: The tree is rebuilt from the snapshot with the same windows, so the containers are new objects. The focused
// window is focused again by treeApply, as after the other tree commands, and the view is laid out and flushed.
//

/// Restores the tree of the space before its last recorded tree command. The windows of the space must be the ones of
/// that tree: otherwise the whole history is dropped, since the older entries predate the same window change, and the
/// tree stays as it is.
@WM func undoTreeCommand(on sid: SpaceID) throws(CommandError) {
  guard let view = SpaceManager.shared.views[sid], let entry = view.history.pop() else {
    throw CommandError("nothing to undo on this space.\n")
  }

  guard Set(view.windowIDs) == entry.windows else {
    view.history.clear()
    throw CommandError("cannot undo: the windows on this space changed.\n")
  }

  // NOTE: A pending window --insert marks a node of the old tree, which is destroyed with its feedback, so it is dropped.
  let old = view.tree
  let root = Con(snapshot: entry.tree)
  root.area = view.area
  view.tree = root
  view.insertionPoint = nil
  old?.destroy()

  WindowManager.shared.treeApply(view)
}
