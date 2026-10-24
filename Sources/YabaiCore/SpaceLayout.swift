//
// NOTE: The space layout keeps a number of user spaces per display, chosen by the number of displays. When the
// displays change, reconcile passes move, create or destroy one space each until the counts match.
// This is the pure part; the reconcile passes are Sources/Yabai/SpaceManager+SpaceLayout.swift.
//

/// The number of user spaces per display, for one display count (`count`). builtinIndex is the entry for the
/// builtin display ('b' suffix).
public struct SpaceLayout: Equatable, Sendable {
  /// The most layouts `space_layout` takes, and the most displays it lays out.
  public static let max = 8

  public var target: [Int]
  public var builtinIndex: Int?

  public var count: Int { target.count }

  public init(target: [Int], builtinIndex: Int? = nil) {
    self.target = target
    self.builtinIndex = builtinIndex
  }

  /// `space_layout_parse`: a spec like "10:5:1b".
  public init?(parsing text: some Collection<UInt8>) {
    let text = Array(text)
    let length = text.count
    let zero = UInt8(ascii: "0")
    let nine = UInt8(ascii: "9")

    target = []
    builtinIndex = nil

    var i = 0
    while i < length {
      if count == SpaceLayout.max { return nil }

      var value = 0
      var digits = 0
      while i < length && text[i] >= zero && text[i] <= nine {
        value = value * 10 + Int(text[i] - zero)
        if value > 1000 { return nil }
        digits += 1
        i += 1
      }
      if digits == 0 || value < 1 { return nil }

      if i < length && text[i] == UInt8(ascii: "b") {
        if builtinIndex != nil { return nil }
        builtinIndex = count
        i += 1
      }

      target.append(value)

      if i < length {
        if text[i] != UInt8(ascii: ":") || i + 1 == length { return nil }
        i += 1
      }
    }

    if count == 0 { return nil }
  }

  public init?(parsing text: String) {
    self.init(parsing: text.utf8)
  }

  /// `space_layout_targets`: the target of each display in arrangement order, where builtin is the index of
  /// the builtin display. The builtin entry goes to the builtin display, the others keep their order.
  public func targets(builtin: Int?) -> [Int] {
    guard let builtinIndex, let builtin else { return target }

    var result = [Int](repeating: 0, count: count)
    result[builtin] = target[builtinIndex]

    var j = 0
    for i in 0..<count {
      if i == builtin { continue }
      if j == builtinIndex { j += 1 }
      result[i] = target[j]
      j += 1
    }

    return result
  }

  /// `space_layout_move_candidate`: the space a reconcile pass moves off a display with too many spaces. It is
  /// the first user space from the given edge that is not visible, else the visible space when it is the only
  /// user space, else nil. A pinned space is never a candidate (see SpacePinning.pinnedSpaces), so the pin keeps it.
  public static func moveCandidate(
    spaces: [SpaceID], user: [Bool], visible: SpaceID?, fromEnd: Bool, pinned: Set<SpaceID> = []
  ) -> SpaceID? {
    let count = spaces.count

    for k in 0..<count {
      let i = fromEnd ? count - 1 - k : k
      if user[i] && spaces[i] != visible && !pinned.contains(spaces[i]) { return spaces[i] }
    }

    for i in 0..<count {
      if user[i] && spaces[i] == visible && !pinned.contains(spaces[i]) { return visible }
    }

    return nil
  }

  /// The next step of a reconcile pass, for the space lists of the displays in arrangement order (`spaces`, with `user`
  /// marking the user spaces) and their targets. `visible` and `isEmpty` query the window server, so they are only
  /// called for the display and the spaces the step looks at. A pinned space is never moved or destroyed.
  public static func reconcileStep(
    target: [Int], spaces: [[SpaceID]], user: [[Bool]], pinned: Set<SpaceID>,
    visible: (Int) -> SpaceID?, isEmpty: (SpaceID) -> Bool
  ) -> SpaceLayoutStep {
    let actual = user.map { $0.count(where: { $0 }) }
    let surplus = actual.indices.first { actual[$0] > target[$0] }
    let deficit = actual.indices.first { actual[$0] < target[$0] }

    switch (surplus, deficit) {
    case (let surplus?, let deficit?):
      guard
        let sid = moveCandidate(
          spaces: spaces[surplus], user: user[surplus], visible: visible(surplus),
          fromEnd: deficit > surplus, pinned: pinned)
      else { return .create(on: deficit, pinnedDisplay: surplus) }

      return .move(sid, from: surplus, to: deficit)
    case (nil, let deficit?):
      return .create(on: deficit, pinnedDisplay: nil)
    case (let surplus?, nil):
      guard
        let sid = destroyCandidate(
          spaces: spaces[surplus], user: user[surplus], visible: visible(surplus), pinned: pinned,
          isEmpty: isEmpty)
      else { return .keep(display: surplus) }

      return .destroy(sid, on: surplus)
    case (nil, nil):
      return .done
    }
  }

  /// An empty user space of a display to destroy, preferring the last one that is not visible; the visible space is
  /// only asked for when no other one is empty. The last user space of the display is kept.
  static func destroyCandidate(
    spaces: [SpaceID], user: [Bool], visible: SpaceID?, pinned: Set<SpaceID>,
    isEmpty: (SpaceID) -> Bool
  ) -> SpaceID? {
    guard user.count(where: { $0 }) > 1 else { return nil }

    var visibleCandidate: SpaceID? = nil
    for i in spaces.indices.reversed() where user[i] && !pinned.contains(spaces[i]) {
      if spaces[i] == visible {
        visibleCandidate = spaces[i]
      } else if isEmpty(spaces[i]) {
        return spaces[i]
      }
    }

    if let visibleCandidate, isEmpty(visibleCandidate) { return visibleCandidate }
    return nil
  }
}

/// One step of a space layout reconcile pass. The displays are indices in arrangement order.
public enum SpaceLayoutStep: Equatable, Sendable {
  /// Every display has its target.
  case done
  /// The display has too many user spaces, but none of them is empty, unpinned and not its last user space.
  case keep(display: Int)
  /// Move the space from the first display with too many user spaces to the first one with too few.
  case move(SpaceID, from: Int, to: Int)
  /// Create a space on the first display with too few user spaces. `pinnedDisplay` is the display with too many when all
  /// of its user spaces are pinned.
  case create(on: Int, pinnedDisplay: Int?)
  /// Destroy the empty space of the display with too many user spaces.
  case destroy(SpaceID, on: Int)
}
