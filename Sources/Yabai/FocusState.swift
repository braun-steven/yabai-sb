import AppKit
import CPrivate
import YabaiCore

//
// NOTE: FocusState lives in the daemon, not in YabaiCore: it holds the process serial number of the focused window, a
// CPrivate type. Its clock is OSTimer, the event timers' clock, which the caller reads and passes in as `now`.
//

/// The focus of the window manager: the focused window and its process, the window that had focus before, a focus
/// request that the application has not reported yet, and the focus events that arrived before their window or
/// application was known.
struct FocusState {
  /// A focus request, made at `time` on the OSTimer clock. `warpsMouse` is false for the focus of a window a command
  /// moved, whose focus event does not move the cursor (`MouseFollowsFocus`).
  struct PendingFocus: Equatable {
    var windowID: WindowID
    var time: UInt64
    var warpsMouse = true
  }

  /// How long a pending focus stays valid, in milliseconds.
  static let pendingTimeoutMs: Float = 500.0

  /// The window that last received focus; nil when the front application has no focused window.
  private(set) var focused: WindowID?

  //
  // NOTE: The process is kept apart from the focused window. The front application can change without a focused
  // window (`focused` is nil then), and the window of the process can be removed from the window table while its
  // process is still the one that focus was last reported for. Both cases read this process, so it is stored.
  //
  private(set) var focusedPSN = ProcessSerialNumber()
  private(set) var pending: PendingFocus?
  private(set) var last: WindowID?
  private(set) var lostFocusedEvents = Set<WindowID>()
  private(set) var lostFrontSwitchedEvents = Set<pid_t>()

  /// A focus change reported for a window (`to` set) or for no window (`to` nil). A nil `psn` keeps the process.
  mutating func focusChanged(to windowID: WindowID?, psn: ProcessSerialNumber? = nil) {
    focused = windowID
    if let psn { focusedPSN = psn }
  }

  /// Records the focused window as the one that had focus before.
  mutating func markFocusedAsLast() {
    last = focused
  }

  /// Sets the last window without changing the focus.
  mutating func setLast(_ windowID: WindowID?) {
    last = windowID
  }

  /// The startup focus: the focused window is also the last one.
  mutating func focusRestored(to windowID: WindowID, psn: ProcessSerialNumber) {
    last = windowID
    focused = windowID
    focusedPSN = psn
  }

  mutating func setPending(_ windowID: WindowID, at time: UInt64, warpsMouse: Bool = true) {
    pending = PendingFocus(windowID: windowID, time: time, warpsMouse: warpsMouse)
  }

  /// Drops the pending focus, whatever its window.
  mutating func clearPending() {
    pending = nil
  }

  /// Drops the pending focus when it names this window, so a late focus event of another window keeps it.
  mutating func clearPending(ifFor windowID: WindowID) {
    if pending?.windowID == windowID { pending = nil }
  }

  //
  // NOTE: A pending focus stays valid while less than `pendingTimeoutMs` has passed since it was made. The
  // comparison is strict: at the timeout itself, the pending focus has expired.
  //

  /// The window of the pending focus, while it has not expired at `now`. An expired pending focus is dropped.
  mutating func consumePending(now: UInt64) -> WindowID? {
    guard let pending else { return nil }

    if OSTimer.milliseconds(from: pending.time, to: now) < Self.pendingTimeoutMs {
      return pending.windowID
    }

    self.pending = nil
    return nil
  }

  /// Whether this window has focus for a command at `now`: it is the window of a pending focus that has not expired (an
  /// earlier command focused it, and its application has not reported it yet), or, without one, the focused window.
  func hasFocus(_ windowID: WindowID, now: UInt64) -> Bool {
    if let pending, OSTimer.milliseconds(from: pending.time, to: now) < Self.pendingTimeoutMs {
      return pending.windowID == windowID
    }
    return focused == windowID
  }

  /// Whether the focus of this window, reported at `now`, leaves the cursor: a pending focus of it that has not expired
  /// and was made with `warpsMouse` false. An expired one no longer counts, so a later focus of the window can move the
  /// cursor again when the moved window reported no focus.
  func keepsMouse(for windowID: WindowID, now: UInt64) -> Bool {
    guard let pending, pending.windowID == windowID, !pending.warpsMouse else { return false }
    return OSTimer.milliseconds(from: pending.time, to: now) < Self.pendingTimeoutMs
  }

  func hasLostFocusedEvent(for windowID: WindowID) -> Bool {
    lostFocusedEvents.contains(windowID)
  }

  mutating func addLostFocusedEvent(for windowID: WindowID) {
    lostFocusedEvents.insert(windowID)
  }

  mutating func removeLostFocusedEvent(for windowID: WindowID) {
    lostFocusedEvents.remove(windowID)
  }

  func hasLostFrontSwitchedEvent(for pid: pid_t) -> Bool {
    lostFrontSwitchedEvents.contains(pid)
  }

  mutating func addLostFrontSwitchedEvent(for pid: pid_t) {
    lostFrontSwitchedEvents.insert(pid)
  }

  mutating func removeLostFrontSwitchedEvent(for pid: pid_t) {
    lostFrontSwitchedEvents.remove(pid)
  }

  /// Drops every lost event, as the daemon does when it initializes its tables.
  mutating func clearLostEvents() {
    lostFocusedEvents = []
    lostFrontSwitchedEvents = []
  }
}
