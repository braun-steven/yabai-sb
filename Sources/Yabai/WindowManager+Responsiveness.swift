import ApplicationServices
import Logging
import YabaiCore

//
// NOTE: The AX calls of an application that does not answer each wait for the messaging timeout, and the event loop makes
// them one after another. The breaker (`axBreaker`, AXBreaker.swift) skips the non-essential calls to that application for
// a cooldown. Each non-essential call names this choice at its site: it runs through `ifResponsive`, and it is skipped
// while the breaker is open. Essential calls (an explicit command on the window, destroy handling) call AX directly and
// do not consult the breaker. Layout frame writes (`setWindowFrames`) record their outcome for either kind of call.
//

extension WindowManager {
  /// Runs `call`, a non-essential AX call to the application of pid, unless its breaker is open. Returns nil when the call
  /// is skipped. The error of the call is recorded, so a call that times out opens the breaker.
  func ifResponsive<T>(pid: pid_t, _ call: () -> (value: T, error: AXError)) -> T? {
    let now = ContinuousClock.now
    if axBreaker.isOpen(pid: pid, now: now) { return nil }

    let result = call()
    recordAXResult(result.error, pid: pid, now: now)
    return result.value
  }

  /// Records the outcome of an AX call to the application of pid. A call that could not complete opens its breaker (or
  /// extends it); any other outcome shows that the application answered, and closes it. Logs the transitions.
  func recordAXResult(
    _ error: AXError, pid: pid_t, now: ContinuousClock.Instant = ContinuousClock.now
  ) {
    if error == .cannotComplete {
      if axBreaker.recordTimeout(pid: pid, now: now) == .opened {
        Logger.windows.notice(
          "process \(pid) did not respond, its non-essential AX calls are skipped for \(AXBreaker.cooldown)"
        )
      }
    } else if axBreaker.recordSuccess(pid: pid) == .closed {
      Logger.windows.notice("process \(pid) responds again, its AX calls are no longer skipped")
    }
  }
}
