//
// NOTE: The ledger remembers the desktop as a list of slots: the place of a space in the order of all spaces, what space
// stands there, and its windows and tree. A slot outlives its space, because macOS destroys the first space of a display
// that goes away and creates it again later: the windows of slot 11 belong on slot 11, whatever space stands there by
// then. The slots run over all displays, so the same list serves every set of displays, and the space layout says which
// slots each display gets.
//
// macOS changes spaces up to 200 ms before the first display callback, and the event loop can run seconds behind, so
// what is on screen when the change is noticed is too late to record. The ledger therefore keeps a few commits with
// their times, and a restore takes the newest one from before the first disturbance (`commit(before:)`).
//
// This is the pure part; SpaceManager+Topology.swift makes the commits.
//

/// One place in the order of all spaces, at a commit.
public struct TopologySlot: Equatable, Sendable {
  /// The space that stands on the slot.
  public var uuid: String
  /// The spaces that stood on the slot before and may return, the newest first.
  public var formerUUIDs: [String]
  /// The display of the space.
  public var display: String
  /// Every window of the space, also the ones yabai has no AX reference for.
  public var windows: [WindowID]
  /// The tree of the view of the space.
  public var tree: TreeSnapshot?

  public init(
    uuid: String, formerUUIDs: [String] = [], display: String, windows: [WindowID],
    tree: TreeSnapshot?
  ) {
    self.uuid = uuid
    self.formerUUIDs = formerUUIDs
    self.display = display
    self.windows = windows
    self.tree = tree
  }
}

/// The desktop at one moment.
public struct TopologyCommit: Equatable, Sendable {
  /// When it was read, in seconds on the clock of the disturbances.
  public var time: Double
  /// The slots, in the order of the space indices.
  public var slots: [TopologySlot]
  /// The space each display shows (uuids). A commit also holds the last one of the displays that are gone.
  public var shown: [String: String]
  /// The active space.
  public var active: String?
  /// The focused window.
  public var focused: WindowID?

  public init(
    time: Double, slots: [TopologySlot], shown: [String: String], active: String?,
    focused: WindowID?
  ) {
    self.time = time
    self.slots = slots
    self.shown = shown
    self.active = active
    self.focused = focused
  }
}

/// The last commits, and what is known about the slots across them.
public struct TopologyLedger: Equatable, Sendable {
  /// How many different commits are kept.
  public static let capacity = 8

  /// How many former spaces a slot remembers.
  public static let formerLimit = 4

  /// The commits, the oldest first.
  public private(set) var commits: [TopologyCommit] = []
  private var formers: [String: [String]] = [:]
  private var shown: [String: String] = [:]

  public init() {}

  /// Adds a commit, with the former spaces of its slots and the spaces the displays that are gone showed. A commit
  /// that only repeats the newest one keeps the older time, so it still counts as from before a disturbance.
  public mutating func add(_ commit: TopologyCommit) {
    var commit = commit
    for index in commit.slots.indices {
      commit.slots[index].formerUUIDs = formers[commit.slots[index].uuid] ?? []
    }
    shown.merge(commit.shown) { $1 }
    commit.shown = shown

    if var newest = commits.last {
      newest.time = commit.time
      if newest == commit { return }
    }

    commits.append(commit)
    if commits.count > Self.capacity { commits.removeFirst(commits.count - Self.capacity) }
  }

  /// The newest commit from before `time`.
  public func commit(before time: Double) -> TopologyCommit? {
    commits.last { $0.time < time }
  }

  //
  // NOTE: A stand-in remembers the space it replaced, so the original wins when macOS brings it back. An original that
  // came back forgets the stand-ins after it, which are about to be destroyed.
  //

  /// Records which space stands on each slot of a commit after a restore.
  public mutating func adopt(_ binding: TopologyBinding, of commit: TopologyCommit) {
    for (slot, bound) in zip(commit.slots, binding.spaces) {
      guard let bound, bound != slot.uuid else { continue }

      let chain = [slot.uuid] + slot.formerUUIDs
      let older = chain.firstIndex(of: bound).map { Array(chain[($0 + 1)...]) } ?? chain
      formers[slot.uuid] = nil
      formers[bound] = Array(older.prefix(Self.formerLimit))
    }
  }
}
