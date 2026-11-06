//
// NOTE: What it takes to bring the desktop back to a commit of the ledger. Nothing here remembers a previous pass: every
// pass reads the desktop, gets the next step from `plan`, and performs it, so a step that macOS undid or that failed
// simply comes up again. The space steps are the ones of the space layout (SpaceLayout), with the slots saying which
// space goes where. SpaceManager+Topology.swift reads the desktop and performs the steps.
//

/// Which space stands on each slot of a commit.
public struct TopologyBinding: Equatable, Sendable {
  /// The space of each slot, nil when a space must be created for it.
  public var spaces: [String?]
  /// The spaces that have no slot. Their windows go to the slots, and then they can be destroyed.
  public var extras: [String]

  public init(spaces: [String?], extras: [String]) {
    self.spaces = spaces
    self.extras = extras
  }
}

/// The desktop now, with the displays in arrangement order.
public struct TopologyObserved: Equatable, Sendable {
  /// The uuids of the displays.
  public var displays: [String]
  /// The spaces of each display.
  public var spaces: [[SpaceID]]
  /// Whether each space of `spaces` is a user space.
  public var user: [[Bool]]
  /// The uuid of each user space.
  public var uuids: [SpaceID: String]
  /// The windows of each user space.
  public var windows: [SpaceID: [WindowID]]

  public init(
    displays: [String], spaces: [[SpaceID]], user: [[Bool]], uuids: [SpaceID: String],
    windows: [SpaceID: [WindowID]]
  ) {
    self.displays = displays
    self.spaces = spaces
    self.user = user
    self.uuids = uuids
    self.windows = windows
  }
}

/// The windows that go to one space.
public struct TopologyMove: Equatable, Sendable {
  public var windows: [WindowID]
  public var space: SpaceID

  public init(windows: [WindowID], space: SpaceID) {
    self.windows = windows
    self.space = space
  }
}

/// The state of a restore pass and what comes next.
public struct TopologyPlan: Equatable, Sendable {
  public var binding: TopologyBinding
  /// The next step for the spaces: `.done` or `.keep` when they are in place.
  public var step: SpaceLayoutStep
  /// The windows that are not on the space of their slot.
  public var moves: [TopologyMove]

  public init(binding: TopologyBinding, step: SpaceLayoutStep, moves: [TopologyMove]) {
    self.binding = binding
    self.step = step
    self.moves = moves
  }

  /// Whether no space has to change any more.
  public var spacesAreDone: Bool {
    switch step {
    case .done, .keep: true
    default: false
    }
  }
}

public enum TopologyRestore {
  //
  // NOTE: The oldest space of a slot wins: macOS pulls the windows of a returning space off the stand-in that held them,
  // so the stand-in is what ends up empty. A slot whose spaces are all gone takes a space no slot claims, because
  // macOS can also move the windows of a destroyed space to a new space with another uuid: first the space that holds
  // its windows, then one on its display, and one with windows before an empty one, which could be destroyed instead.
  //

  /// Puts the spaces of now on the slots of a commit. `spaces` lists the uuids of the user spaces of each display, in the
  /// order of `displays`, and `windows` the windows of a space.
  public static func bind(
    _ commit: TopologyCommit, displays: [String], spaces: [[String]],
    windows: (String) -> [WindowID]
  ) -> TopologyBinding {
    let present = Set(spaces.joined())
    let owned = Set(commit.slots.map(\.uuid))
    var claimed: Set<String> = []
    var bound: [String?] = commit.slots.map { _ in nil }

    for (index, slot) in commit.slots.enumerated() {
      let candidates = slot.formerUUIDs.reversed() + [slot.uuid]
      let found = candidates.first { uuid in
        present.contains(uuid) && !claimed.contains(uuid)
          && (uuid == slot.uuid || !owned.contains(uuid))
      }

      if let found {
        bound[index] = found
        claimed.insert(found)
      }
    }

    var strangers = zip(displays, spaces).flatMap { display, list in
      list.filter { !claimed.contains($0) }.map { (uuid: $0, display: display) }
    }

    /// Gives every slot without a space the best stranger for which `score` is not nil, the lowest score first.
    func assign(score: (TopologySlot, (uuid: String, display: String)) -> Int?) {
      for (index, slot) in commit.slots.enumerated() where bound[index] == nil {
        let best = strangers.indices
          .compactMap { i in score(slot, strangers[i]).map { (index: i, score: $0) } }
          .min { $0.score < $1.score }

        if let best {
          bound[index] = strangers.remove(at: best.index).uuid
        }
      }
    }

    assign { slot, stranger in
      let held = Set(windows(stranger.uuid)).intersection(slot.windows).count
      return held > 0 ? -held : nil
    }
    assign { slot, stranger in
      (stranger.display == slot.display ? 0 : 2) + (windows(stranger.uuid).isEmpty ? 1 : 0)
    }

    return TopologyBinding(spaces: bound, extras: strangers.map(\.uuid))
  }

  /// The next step towards a commit, nil when `target` does not have the number of slots of the commit: the layout has
  /// changed since. `pinned` spaces stay where they are, and `skipping` lists the windows that were moved on purpose
  /// since the disturbance.
  public static func plan(
    _ commit: TopologyCommit, observed: TopologyObserved, target: [Int], pinned: Set<SpaceID>,
    skipping: Set<WindowID> = [], visible: (Int) -> SpaceID?
  ) -> TopologyPlan? {
    guard target.reduce(0, +) == commit.slots.count else { return nil }

    let sids = Dictionary(
      observed.uuids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    let userSpaces = zip(observed.spaces, observed.user).map { list, user in
      zip(list, user).filter(\.1).compactMap { observed.uuids[$0.0] }
    }

    let binding = bind(
      commit, displays: observed.displays, spaces: userSpaces,
      windows: { sids[$0].flatMap { observed.windows[$0] } ?? [] })

    var home: [SpaceID: Int] = [:]
    var rank: [SpaceID: Int] = [:]
    var slot = 0
    for (display, count) in target.enumerated() {
      for place in 0..<count {
        if let uuid = binding.spaces[slot], let sid = sids[uuid] {
          home[sid] = display
          rank[sid] = place
        }
        slot += 1
      }
    }

    var step = SpaceLayout.reconcileStep(
      target: target, spaces: observed.spaces, user: observed.user, pinned: pinned, home: home,
      visible: visible,
      isEmpty: { home[$0] == nil && (observed.windows[$0]?.isEmpty ?? true) })

    switch step {
    case .done, .keep:
      let arrangement = SpaceLayout.arrangementStep(
        spaces: observed.spaces, user: observed.user, pinned: pinned, home: home, rank: rank,
        visible: visible)
      if arrangement != .done { step = arrangement }
    default: break
    }

    return TopologyPlan(
      binding: binding, step: step,
      moves: moves(commit, binding: binding, sids: sids, observed: observed, skipping: skipping))
  }

  /// The windows of the slots that are on another space. A window that is on no user space is closed or in native
  /// fullscreen, and stays out of it.
  private static func moves(
    _ commit: TopologyCommit, binding: TopologyBinding, sids: [String: SpaceID],
    observed: TopologyObserved, skipping: Set<WindowID>
  ) -> [TopologyMove] {
    var located: [WindowID: Set<SpaceID>] = [:]
    for (sid, windows) in observed.windows {
      for window in windows { located[window, default: []].insert(sid) }
    }

    var result: [TopologyMove] = []
    for (slot, bound) in zip(commit.slots, binding.spaces) {
      guard let bound, let sid = sids[bound] else { continue }

      let strays = slot.windows.filter { window in
        !skipping.contains(window) && located[window].map { !$0.contains(sid) } ?? false
      }
      if !strays.isEmpty { result.append(TopologyMove(windows: strays, space: sid)) }
    }
    return result
  }

  //
  // NOTE: The active space comes first: its display has to show it, or the focus would go elsewhere. The others show what
  // they showed last, which for a display that returned is from before it went away.
  //

  /// The space each display should show, by the index of the display, once the spaces are in place.
  public static func shown(
    _ commit: TopologyCommit, binding: TopologyBinding, observed: TopologyObserved
  ) -> [Int: SpaceID] {
    let sids = Dictionary(
      observed.uuids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

    /// The space of now that stands on the slot of a space of the commit.
    func current(of uuid: String?) -> SpaceID? {
      guard let uuid else { return nil }

      let index = commit.slots.firstIndex { $0.uuid == uuid || $0.formerUUIDs.contains(uuid) }
      return index.flatMap { binding.spaces[$0] }.flatMap { sids[$0] }
    }

    let active = current(of: commit.active)
    var result: [Int: SpaceID] = [:]

    for (index, display) in observed.displays.enumerated() {
      let list = observed.spaces[index]
      if let active, list.contains(active) {
        result[index] = active
      } else if let last = current(of: commit.shown[display]), list.contains(last) {
        result[index] = last
      }
    }
    return result
  }
}
