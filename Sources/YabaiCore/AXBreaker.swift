import Darwin

//
// NOTE: The breaker of the Accessibility calls to an application that does not answer. Each AX call to a frozen
// application waits for the messaging timeout, and the event loop makes them one after another, so one frozen
// application would stall every event. A timeout opens the breaker for its pid for `cooldown`; non-essential calls
// to that pid are then skipped (`isOpen`), and the first successful call closes it. Essential calls (explicit commands
// on the window, destroy handling) do not consult it. Pure: the caller passes the pid and the instant, and logs the
// returned transitions, so the tests don't sleep.
//

/// A change of the breaker state for one pid, for the log.
public enum AXBreakerTransition: Equatable, Sendable {
  case opened
  case closed
}

public struct AXBreaker: Sendable {
  /// How long the calls to an application are skipped after one of them timed out.
  public static let cooldown: ContinuousClock.Duration = .seconds(2)

  /// The instant until which the breaker of each pid is open. An entry past its instant is closed, and it is removed
  /// by the next success of its pid.
  private var openUntil: [pid_t: ContinuousClock.Instant] = [:]

  public init() {}

  /// Whether the calls to the pid are skipped at `now`.
  public func isOpen(pid: pid_t, now: ContinuousClock.Instant) -> Bool {
    guard let until = openUntil[pid] else { return false }
    return now < until
  }

  /// Records a call that could not complete. Opens the breaker, or extends it when it is open already (then nil is
  /// returned). Returns `.opened` when the pid was closed, including when its cooldown has passed.
  @discardableResult
  public mutating func recordTimeout(pid: pid_t, now: ContinuousClock.Instant)
    -> AXBreakerTransition?
  {
    let wasOpen = isOpen(pid: pid, now: now)
    openUntil[pid] = now.advanced(by: Self.cooldown)
    return wasOpen ? nil : .opened
  }

  /// Records a successful call. Closes the breaker of the pid and returns `.closed` when it had an entry (open, or
  /// expired and not yet cleared); nil when the pid had none.
  @discardableResult
  public mutating func recordSuccess(pid: pid_t) -> AXBreakerTransition? {
    guard openUntil.removeValue(forKey: pid) != nil else { return nil }
    return .closed
  }
}
