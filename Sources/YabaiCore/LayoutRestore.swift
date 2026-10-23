import Foundation

//
// NOTE: space --restore-layout, without the window server. A layout file is read and checked (validated). Each leaf of
// the file, in pre-order, is a slot with the matcher of its window. The slots are matched with the windows of the space,
// and the tree is rebuilt from the matched slots: a slot without a window is dropped, a container left empty is dropped,
// a container left with one child gives the child its place, and the shares of each container are normalized again. The
// daemon applies the result (Sources/Yabai/LayoutRestore.swift).
//

/// The version alone, read before the rest of a file, so that a file of another version is reported as one.
private struct LayoutVersionHeader: Decodable {
  let version: Int
}

/// The text of a decoding failure, with the coding path of the value that failed.
private func layoutDecodingProblem(_ error: any Error) -> String {
  guard let decoding = error as? DecodingError else { return error.localizedDescription }

  let context: DecodingError.Context
  switch decoding {
  case .dataCorrupted(let found), .keyNotFound(_, let found), .valueNotFound(_, let found),
    .typeMismatch(_, let found):
    context = found
  @unknown default:
    return error.localizedDescription
  }

  var location = ""
  for key in context.codingPath {
    if let index = key.intValue {
      location += "[\(index)]"
    } else {
      location += location.isEmpty ? key.stringValue : "." + key.stringValue
    }
  }
  return location.isEmpty ? context.debugDescription : "\(location): \(context.debugDescription)"
}

extension LayoutFile {
  /// Reads a layout file: its version first, then its contents and structure. Every failure names `path`. The
  /// structure is checked here, so the daemon can rely on it: each share of a child is a number above 0 (the root has
  /// no share in use, so only a finite one), a leaf has no children, a container with children has a focus order that
  /// is a permutation of its children, and a childless node has no focus order.
  public static func validated(_ data: Data, path: String) throws(CommandError) -> LayoutFile {
    let version: Int
    do {
      version = try JSONDecoder().decode(LayoutVersionHeader.self, from: data).version
    } catch {
      throw CommandError("'\(path)' is not a layout file: \(layoutDecodingProblem(error))\n")
    }
    guard version == currentVersion else {
      throw CommandError(
        "'\(path)' has layout version \(version); this yabai reads version \(currentVersion)\n")
    }

    let file: LayoutFile
    do {
      file = try decode(data)
    } catch {
      throw CommandError("'\(path)' is not a layout file: \(layoutDecodingProblem(error))\n")
    }

    if let problem = file.tree.structureProblem(at: "tree", isRoot: true) {
      throw CommandError("'\(path)' is not a layout file: \(problem)\n")
    }
    return file
  }

  /// The matchers of the leaves of the tree in pre-order: one slot per leaf, nil for a leaf that had no matcher at save
  /// time (its window was unknown then).
  public var slots: [LayoutMatcher?] { tree.slotMatchers }

  /// The tree the matched slots make. `assignment` gives the index into `windowIDs` of the window of each slot (see
  /// LayoutMatching.assign, and `windowIDs` must be the windows that were matched, in the same order). Nil when no slot
  /// matched. The root keeps its container, even with one child, so that the daemon has a split to add windows to; a
  /// root that is itself a leaf gets the container of one window.
  public func restoredTree(assignment: [Int?], windowIDs: [WindowID]) -> TreeSnapshot? {
    guard assignment.contains(where: { $0 != nil }) else { return nil }

    var slot = 0
    guard
      let built = tree.restored(
        assignment: assignment, windowIDs: windowIDs, slot: &slot, isRoot: true)
    else { return nil }
    guard built.windowID != nil else { return built }

    let layout: ConLayout = tree.layout == .tabbed ? .splitH : tree.layout
    var leaf = built
    leaf.percent = 1
    return TreeSnapshot(
      layout: layout, lastSplit: layout, percent: 0, zoom: .none, isSelected: false, windowID: nil,
      children: [leaf], focusOrder: [0])
  }
}

extension LayoutFile.Node {
  fileprivate var slotMatchers: [LayoutMatcher?] {
    if children.isEmpty { return [window] }
    return children.flatMap(\.slotMatchers)
  }

  /// The first structural problem of this node and its descendants, named by `location`; nil when there is none.
  fileprivate func structureProblem(at location: String, isRoot: Bool) -> String? {
    if isRoot {
      if !percent.isFinite { return "\(location) has a percent that is not a number" }
    } else if !(percent.isFinite && percent > 0) {
      return "\(location) has percent \(percent); a share must be a number above 0"
    }

    if window != nil && !children.isEmpty {
      return "\(location) has a window and children; a leaf has no children"
    }

    if children.isEmpty {
      if !focusOrder.isEmpty { return "\(location) has a focus order but no children" }
    } else if focusOrder.sorted() != Array(children.indices) {
      return "\(location) has a focus order that is not a permutation of its children"
    }

    for (index, child) in children.enumerated() {
      if let problem = child.structureProblem(at: "\(location).children[\(index)]", isRoot: false) {
        return problem
      }
    }
    return nil
  }

  /// The subtree with the matched slots, in pre-order. `slot` counts the leaves; a leaf is consumed even when it is
  /// dropped. Nil when the subtree keeps nothing.
  fileprivate func restored(
    assignment: [Int?], windowIDs: [WindowID], slot: inout Int, isRoot: Bool
  ) -> TreeSnapshot? {
    if children.isEmpty {
      let index = slot
      slot += 1
      guard assignment.indices.contains(index), let window = assignment[index],
        windowIDs.indices.contains(window)
      else { return nil }

      return TreeSnapshot(
        layout: layout, lastSplit: lastSplit, percent: percent, zoom: zoom, isSelected: false,
        windowID: windowIDs[window], children: [], focusOrder: [])
    }

    var kept: [(snapshot: TreeSnapshot, index: Int)] = []
    for (index, child) in children.enumerated() {
      if let snapshot = child.restored(
        assignment: assignment, windowIDs: windowIDs, slot: &slot, isRoot: false)
      {
        kept.append((snapshot, index))
      }
    }
    guard !kept.isEmpty else { return nil }

    // NOTE: A container left with one child gives the child its place, and the child takes its share.
    if kept.count == 1 && !isRoot {
      var only = kept[0].snapshot
      only.percent = percent
      return only
    }

    // NOTE: The shares of the kept children are normalized to add up to 1, keeping their proportions.
    let total = kept.reduce(Float(0)) { $0 + $1.snapshot.percent }
    var newIndex = [Int?](repeating: nil, count: children.count)
    var snapshots: [TreeSnapshot] = []
    for (position, entry) in kept.enumerated() {
      var snapshot = entry.snapshot
      snapshot.percent = total > 0 ? snapshot.percent / total : 1 / Float(kept.count)
      snapshots.append(snapshot)
      newIndex[entry.index] = position
    }

    // NOTE: The focus order keeps the relative order of the kept children; a child missing from it goes last.
    var order = focusOrder.compactMap { index in
      newIndex.indices.contains(index) ? newIndex[index] : nil
    }
    for position in snapshots.indices where !order.contains(position) { order.append(position) }

    return TreeSnapshot(
      layout: layout, lastSplit: lastSplit, percent: percent, zoom: zoom, isSelected: false,
      windowID: nil, children: snapshots, focusOrder: order)
  }
}

/// Matches the slots of a saved layout with the windows of a space.
public enum LayoutMatching {
  /// The index of the window of each slot, nil for a slot without one.
  ///
  /// A window is a candidate for a slot when both are the same application: the same bundle id when both have one, else
  /// the same application name. Candidates are taken best first, comparing the exact title (equal titles, nil included,
  /// rank first), then the length of the common title prefix, then the role and the subrole (equal ones rank first).
  /// Ties go to the lower slot index, then to the lower window index. A pair is taken when its slot and its window are
  /// both still free, so each window is used at most once.
  public static func assign(slots: [LayoutMatcher?], windows: [LayoutMatcher]) -> [Int?] {
    struct Candidate {
      let slot: Int
      let window: Int
      let score: MatchScore
    }

    var candidates: [Candidate] = []
    for (slot, slotMatcher) in slots.enumerated() {
      guard let slotMatcher else { continue }
      for (window, windowMatcher) in windows.enumerated() {
        if let score = matchScore(slotMatcher, windowMatcher) {
          candidates.append(Candidate(slot: slot, window: window, score: score))
        }
      }
    }

    candidates.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
      return lhs.window < rhs.window
    }

    var assigned = [Int?](repeating: nil, count: slots.count)
    var taken = [Bool](repeating: false, count: windows.count)
    for candidate in candidates where assigned[candidate.slot] == nil && !taken[candidate.window] {
      assigned[candidate.slot] = candidate.window
      taken[candidate.window] = true
    }
    return assigned
  }

  /// How well a window matches a slot; a larger score is a better match.
  private struct MatchScore: Equatable, Comparable {
    var exactTitle: Bool
    var titlePrefix: Int
    var role: Bool
    var subrole: Bool

    static func < (lhs: MatchScore, rhs: MatchScore) -> Bool {
      if lhs.exactTitle != rhs.exactTitle { return !lhs.exactTitle }
      if lhs.titlePrefix != rhs.titlePrefix { return lhs.titlePrefix < rhs.titlePrefix }
      if lhs.role != rhs.role { return !lhs.role }
      return !lhs.subrole && rhs.subrole
    }
  }

  /// The score of a window for a slot, nil when they are not the same application.
  private static func matchScore(_ slot: LayoutMatcher, _ window: LayoutMatcher) -> MatchScore? {
    if let slotBundleID = slot.bundleID, let windowBundleID = window.bundleID {
      guard slotBundleID == windowBundleID else { return nil }
    } else {
      guard slot.app == window.app else { return nil }
    }

    return MatchScore(
      exactTitle: slot.title == window.title,
      titlePrefix: (slot.title ?? "").commonPrefix(with: window.title ?? "").count,
      role: slot.role == window.role,
      subrole: slot.subrole == window.subrole)
  }
}
