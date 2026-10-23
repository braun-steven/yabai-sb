import Foundation
import SortedCollections
import YabaiCore

//
// NOTE: space --restore-layout. The file is read and checked, its slots are matched with the windows of the space, and
// the view gets a tree rebuilt from the matched slots. The tree is replaced as undoTreeCommand replaces it, so that
// `space --undo` brings back the tree from before the restore (the dispatcher records it, since the command changes the
// tree). The windows of the space that match no slot are added after the focused window, in tree order, without
// focusing them. v1 places no window that opens later.
//

/// Restores the tree of `sid` from the layout `name` in `directory`, and returns the reply, e.g.
/// "restored 3 of 4 windows\n": the number of slots of the file (with a matcher) whose window is on the space, and the
/// number of such slots. Nothing changes when no window matches.
@WM func restoreSpaceLayout(name: String, on sid: SpaceID, directory: String) throws(CommandError)
  -> String
{
  guard LayoutStore.isValidName(name) else {
    throw SpaceCommand.unknownValue(
      .restoreLayout, Token(name), expected: LayoutStore.nameDescription)
  }

  let path = LayoutStore.path(name: name, directory: directory)
  guard let data = try? Data(contentsOf: URL(filePath: path)) else {
    throw CommandError("could not read layout '\(path)'.\n")
  }
  let file = try LayoutFile.validated(data, path: path)

  guard let view = SpaceManager.shared.views[sid] else {
    throw CommandError("cannot restore a layout on a non-managed space.\n")
  }
  guard view.layout == .tree else {
    throw CommandError("cannot restore a layout on a space that is not in tree layout.\n")
  }

  // NOTE: A window the window manager does not know has no facts to match, so it is added like an unmatched window.
  let known = view.windowIDs.compactMap { windowID in
    layoutMatcher(for: windowID).map { (id: windowID, matcher: $0) }
  }
  let assignment = LayoutMatching.assign(slots: file.slots, windows: known.map(\.matcher))
  guard let snapshot = file.restoredTree(assignment: assignment, windowIDs: known.map(\.id)) else {
    throw CommandError("no window of layout '\(name)' is on this space.\n")
  }

  let matched = assignment.compactMap { $0 }
  let matchedIDs = Set(matched.map { known[$0].id })
  let unmatched = view.windowIDs.filter { !matchedIDs.contains($0) }
  let slotCount = file.slots.compactMap { $0 }.count

  // NOTE: As in undoTreeCommand: the old tree is destroyed after the new one is in place, and a pending window --insert
  // marks a node of the old tree, so it is dropped.
  let old = view.tree
  let root = Con(snapshot: snapshot)
  root.area = view.area
  view.tree = root
  view.insertionPoint = nil
  old?.destroy()

  //
  // NOTE: Unlike View.add, the new windows do not take focus: each one opens after the focused window, or after the
  // window opened before it, so they keep their order.
  //

  var anchor = root.find(WindowManager.shared.focus.focused) ?? root.focusedDescendant
  for windowID in unmatched {
    let node = Con(windowID: windowID)
    root.open(node, after: anchor, autotile: Config.current.space.treeAutotiling)
    anchor = node
  }

  WindowManager.shared.treeApply(view)
  return "restored \(matched.count) of \(slotCount) windows\n"
}
