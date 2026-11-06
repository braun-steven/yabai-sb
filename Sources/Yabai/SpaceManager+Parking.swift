import CoreFoundation
import Logging
import OrderedCollections
import SortedCollections
import YabaiCore

//
// NOTE: macOS destroys the first space of a display that goes away, and when the display returns it creates that space
// again with the same uuid and a new id, and returns its windows. So a view of a destroyed space waits here under its
// uuid, with its settings, label and the snapshot of its tree (its windows are unmanaged, because they are on another
// space now). When the uuid comes back the view takes the new id, and the tree is installed after the display change
// has been quiet for a moment, as far as its windows have arrived. A destroyed space that never returns is dropped
// once `parkedViewLimit` others have been parked after it.
//

extension SpaceManager {
  /// A view of a destroyed space, with its label and the tree it had.
  struct ParkedView {
    var view: View
    var label: String?
    var tree: TreeSnapshot?
  }

  /// The tree of a view that came back, until its windows are in it.
  struct ReturningTree {
    var tree: TreeSnapshot
    var attempts = 0
  }

  /// The most views that wait for their space to return.
  static let parkedViewLimit = 32

  /// How many times a returning tree is installed while windows are missing: macOS returned some windows about 10 s
  /// after the last add.
  static let returningTreeAttempts = 4

  /// How long after the last display change the windows are looked at (`displayWindowCheck`): the displays of a dock
  /// return about 3 s apart, and what is on a space before that is not final.
  static let displayWindowCheckDelay: Duration = .seconds(4)

  /// Schedules the check of the windows after a display change; a newer change replaces the pending one.
  func scheduleDisplayWindowCheck() {
    EventLoop.post(
      .displayWindowCheck, after: Self.displayWindowCheckDelay, key: .displayWindowCheck)
  }

  /// Takes the view of a destroyed space out of the views. It is kept for its uuid when it has something to give back.
  func parkView(_ view: View) {
    let sid = view.sid
    let label = labels.name(of: sid)
    _ = labels.remove(id: sid)
    views[sid] = nil

    let tree = returningTrees.removeValue(forKey: sid)?.tree ?? view.tree?.snapshot
    guard let uuid = view.uuid as String?, tree != nil || label != nil || !view.overrides.isEmpty
    else {
      view.destroy()
      return
    }

    view.clearTree()
    parkedViews.removeValue(forKey: uuid)
    parkedViews[uuid] = ParkedView(view: view, label: label, tree: tree)
    if parkedViews.count > Self.parkedViewLimit { parkedViews.removeFirst() }
  }

  /// Gives a new space the view that waits for `uuid`, instead of a new view. `newUUID` is the uuid of the space when it
  /// takes the place of another space.
  func attachParkedView(uuid: String, to sid: SpaceID, as newUUID: String? = nil) {
    guard let parked = parkedViews.removeValue(forKey: uuid) else { return }

    Logger.spaces.debug("space \(Int64(bitPattern: sid.rawValue)) takes its view back")
    TopologyLog.record("view-returned", "\(sid.rawValue) \(uuid)")

    views[sid]?.destroy()
    views[sid] = parked.view
    parked.view.sid = sid
    parked.view.isValid = false
    if let newUUID { parked.view.uuid = newUUID as CFString }

    if let label = parked.label, labels.id(named: label) == nil {
      labels.set(id: sid, name: label)
    }
    if let tree = parked.tree {
      returningTrees[sid] = ReturningTree(tree: tree)
      scheduleDisplayWindowCheck()
    }
  }

  /// Installs the trees of the views that came back (`windows` lists the windows on a space). A tree whose windows have
  /// not all arrived stays for another attempt; returns whether one did.
  func installReturningTrees(windows: (SpaceID) -> [WindowID]?) -> Bool {
    for (sid, returning) in returningTrees {
      guard let view = views[sid] else {
        returningTrees[sid] = nil
        continue
      }

      let complete = WindowManager.shared.installTree(
        returning.tree, on: view, windows: windows(sid) ?? [])
      TopologyLog.record("tree-returned", "\(sid.rawValue) complete=\(complete)")

      if complete || returning.attempts + 1 >= Self.returningTreeAttempts {
        returningTrees[sid] = nil
      } else {
        returningTrees[sid]?.attempts += 1
      }
    }

    return !returningTrees.isEmpty
  }
}

extension WindowManager {
  /// Gives a view the tree of a snapshot, with the windows of the snapshot that are on its space (`windows`), and
  /// the other windows of the view added to it. Returns whether every window of the snapshot that still exists was
  /// there. The windows are taken from the views that hold them, as a tree command would, and the view is laid out.
  @discardableResult
  func installTree(_ snapshot: TreeSnapshot, on view: View, windows: [WindowID]) -> Bool {
    if view.layout == .float { return true }

    let wanted = Set(snapshot.windowIDs)
    let existing = wanted.filter { window(for: $0)?.shouldBeManaged ?? false }
    let present = existing.intersection(windows)
    guard let tree = snapshot.pruned(keeping: present) else { return existing.isEmpty }

    var sources: [View] = []
    for windowID in present {
      guard let target = window(for: windowID), let owner = managedView(for: target),
        owner !== view
      else { continue }

      unmanage(target, from: owner, options: .purify)
      owner.isDirty = true
      if !sources.contains(where: { $0 === owner }) { sources.append(owner) }
    }

    let others = view.windowIDs.filter { !wanted.contains($0) }
    view.clearTree()
    view.update()

    let root = Con(snapshot: tree)
    root.area = view.area
    view.tree = root
    view.insertionPoint = nil

    for windowID in tree.windowIDs {
      guard let target = window(for: windowID) else { continue }
      addManagedWindow(target, to: view)
      target.adjustLayer(to: .below)
    }
    for windowID in others {
      guard let target = window(for: windowID) else { continue }
      view.add(target, insertionPoint: nil)
      addManagedWindow(target, to: view)
      target.adjustLayer(to: .below)
    }

    treeApply(view)
    for source in sources where source.isDirty { source.flush() }

    return present.count == existing.count
  }
}
