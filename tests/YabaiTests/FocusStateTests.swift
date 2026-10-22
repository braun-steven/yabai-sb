import CPrivate
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The focus transitions of FocusState, on plain values: the clock is passed in, so nothing reads OSTimer and no
// window exists. The window manager reaches the same transitions through its focus handlers.
//

private func focusStatePSN(_ low: UInt32) -> ProcessSerialNumber {
  var psn = ProcessSerialNumber()
  psn.lowLongOfPSN = low
  return psn
}

private func focusStateID(_ n: UInt32) -> WindowID {
  WindowID(rawValue: 0xFFFF_0000 + n)
}

@Suite struct FocusStateTests {
  private let start: UInt64 = 5_000_000_000_000

  @Test func pendingFocusWithinTimeoutIsKept() {
    var focus = FocusState()
    #expect(focus.consumePending(now: start) == nil)

    focus.setPending(focusStateID(1), at: start)
    #expect(focus.consumePending(now: start + 499_000_000) == focusStateID(1))
    #expect(focus.pending?.windowID == focusStateID(1))
  }

  @Test func pendingFocusExpiresAndIsDropped() {
    var focus = FocusState()
    focus.setPending(focusStateID(1), at: start)
    #expect(focus.consumePending(now: start + 500_000_000) == nil)
    #expect(focus.pending == nil)

    focus.setPending(focusStateID(1), at: start)
    #expect(focus.consumePending(now: start + 600_000_000) == nil)
    #expect(focus.pending == nil)
  }

  @Test func clearPendingForOtherWindowKeepsIt() {
    var focus = FocusState()
    focus.setPending(focusStateID(5), at: start)

    focus.clearPending(ifFor: focusStateID(6))
    #expect(focus.pending?.windowID == focusStateID(5))

    focus.clearPending(ifFor: focusStateID(5))
    #expect(focus.pending == nil)

    focus.setPending(focusStateID(7), at: start)
    focus.clearPending()
    #expect(focus.pending == nil)
  }

  @Test func focusChangeKeepsProcessWhenNotGiven() {
    var focus = FocusState()
    focus.focusChanged(to: focusStateID(1), psn: focusStatePSN(0x11))
    #expect(focus.focused == focusStateID(1))
    #expect(focus.focusedPSN.isSame(as: focusStatePSN(0x11)))

    // NOTE: The front application without a focused window: no window, and its process is the new one.
    focus.focusChanged(to: nil, psn: focusStatePSN(0x22))
    #expect(focus.focused == nil)
    #expect(focus.focusedPSN.isSame(as: focusStatePSN(0x22)))

    focus.focusChanged(to: focusStateID(2))
    #expect(focus.focused == focusStateID(2))
    #expect(focus.focusedPSN.isSame(as: focusStatePSN(0x22)))
  }

  @Test func lastWindowIsTheFocusedOneBeforeTheChange() {
    var focus = FocusState()
    focus.focusChanged(to: focusStateID(1))
    focus.markFocusedAsLast()
    #expect(focus.last == focusStateID(1))

    focus.focusChanged(to: focusStateID(2))
    #expect(focus.last == focusStateID(1))

    focus.setLast(nil)
    #expect(focus.last == nil)
    #expect(focus.focused == focusStateID(2))
  }

  @Test func startupFocusIsAlsoTheLastWindow() {
    var focus = FocusState()
    focus.focusRestored(to: focusStateID(9), psn: focusStatePSN(0x99))
    #expect(focus.focused == focusStateID(9))
    #expect(focus.last == focusStateID(9))
    #expect(focus.focusedPSN.isSame(as: focusStatePSN(0x99)))
  }

  @Test func lostFocusEventsAreKeyedByWindow() {
    var focus = FocusState()
    #expect(!focus.hasLostFocusedEvent(for: focusStateID(1)))

    focus.addLostFocusedEvent(for: focusStateID(1))
    focus.addLostFocusedEvent(for: focusStateID(2))
    #expect(focus.hasLostFocusedEvent(for: focusStateID(1)))

    focus.removeLostFocusedEvent(for: focusStateID(1))
    #expect(!focus.hasLostFocusedEvent(for: focusStateID(1)))
    #expect(focus.hasLostFocusedEvent(for: focusStateID(2)))
  }

  @Test func lostFrontSwitchedEventsAreKeyedByProcess() {
    var focus = FocusState()
    focus.addLostFrontSwitchedEvent(for: 77)
    #expect(focus.hasLostFrontSwitchedEvent(for: 77))
    #expect(!focus.hasLostFrontSwitchedEvent(for: 78))

    focus.removeLostFrontSwitchedEvent(for: 77)
    #expect(!focus.hasLostFrontSwitchedEvent(for: 77))
  }

  @Test func clearLostEventsEmptiesBothTables() {
    var focus = FocusState()
    focus.addLostFocusedEvent(for: focusStateID(3))
    focus.addLostFrontSwitchedEvent(for: 4)

    focus.clearLostEvents()
    #expect(!focus.hasLostFocusedEvent(for: focusStateID(3)))
    #expect(!focus.hasLostFrontSwitchedEvent(for: 4))
  }

  @Test func copiesAreIndependent() {
    var focus = FocusState()
    focus.focusChanged(to: focusStateID(1))

    var copy = focus
    copy.focusChanged(to: focusStateID(2))
    copy.addLostFocusedEvent(for: focusStateID(3))

    #expect(focus.focused == focusStateID(1))
    #expect(!focus.hasLostFocusedEvent(for: focusStateID(3)))
  }
}
