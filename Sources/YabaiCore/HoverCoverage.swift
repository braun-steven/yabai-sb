//
// NOTE: The tab bar hover asks the window server which window is ordered over the bar. Windows of other applications
// send yabai no order notification, so an answer about them goes stale without any signal. The lifetime bounds that
// staleness in time; the generation covers the orders that yabai does hear about (its own windows).
//

/// How long a window list above a tab bar, or a coverage check, is trusted without a window server notification.
public let hoverCoverageLifetime: ContinuousClock.Duration = .milliseconds(100)

/// The bar that a window list or a coverage check was taken for, the order generation at that time and the instant.
public struct HoverCoverageStamp: Sendable, Equatable {
  public let aboveWid: WindowID
  public let generation: UInt64
  public let taken: ContinuousClock.Instant

  public init(aboveWid: WindowID, generation: UInt64, taken: ContinuousClock.Instant) {
    self.aboveWid = aboveWid
    self.generation = generation
    self.taken = taken
  }

  /// Whether the stamp still describes the bar above `aboveWid` at `generation`, at `now`.
  public func isFresh(
    aboveWid: WindowID, generation: UInt64, at now: ContinuousClock.Instant
  ) -> Bool {
    self.aboveWid == aboveWid && self.generation == generation
      && now < taken.advanced(by: hoverCoverageLifetime)
  }
}

/// What the hover does for a pointer over a glass bar before it trusts the target.
public enum HoverCoverageCheck: Equatable, Sendable {
  /// The pointer is still at the same point over the same entry, and the last check is fresh: nothing to ask.
  case skip
  /// Ask the window server which window is at the point, and reuse the list of windows above the bar.
  case checkWithCachedList
  /// Ask the window server for the window at the point and for the list of windows above the bar.
  case checkFresh
}

public enum HoverCoverageCache {
  /// Chooses the work for one pointer update over a glass bar.
  ///
  /// `repeatsLastCheck` is true when the point, the entry and the pressed state equal those of the last update. A
  /// skip needs that and a fresh last check. A different point always asks the window server for the window at
  /// that point, so a window that moved onto one tab is seen at once. Only the list above the bar is reused.
  public static func decide(
    repeatsLastCheck: Bool,
    lastCheck: HoverCoverageStamp?,
    list: HoverCoverageStamp?,
    aboveWid: WindowID,
    generation: UInt64,
    now: ContinuousClock.Instant
  ) -> HoverCoverageCheck {
    if repeatsLastCheck, let lastCheck,
      lastCheck.isFresh(aboveWid: aboveWid, generation: generation, at: now)
    {
      return .skip
    }
    if let list, list.isFresh(aboveWid: aboveWid, generation: generation, at: now) {
      return .checkWithCachedList
    }
    return .checkFresh
  }
}
