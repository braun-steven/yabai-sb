import CPrivate
import Testing
import YabaiTestSupport

@testable import Yabai

private func knownFocusPSN(_ low: UInt32) -> ProcessSerialNumber {
  var psn = ProcessSerialNumber()
  psn.lowLongOfPSN = low
  return psn
}

@Test("space_known_focus") @WM func spaceKnownFocus() {
  let wm = WindowManager()

  let owner = knownFocusPSN(0x1234)
  let other = knownFocusPSN(0x5678)
  wm.focus.focusChanged(to: 42, psn: owner)

  //
  // NOTE: The known focus is used only while the front process owns it and no focus change is pending.
  //

  #expect(wm.canUseKnownFocus(front: owner, pendingFocus: false) == true)
  #expect(wm.canUseKnownFocus(front: other, pendingFocus: false) == false)
  #expect(wm.canUseKnownFocus(front: owner, pendingFocus: true) == false)

  wm.focus.focusChanged(to: nil)
  #expect(wm.canUseKnownFocus(front: owner, pendingFocus: false) == false)

  //
  // NOTE: A focused window without a known process is never a known focus.
  //

  wm.focus.focusChanged(to: 42, psn: ProcessSerialNumber())
  #expect(wm.canUseKnownFocus(front: owner, pendingFocus: false) == false)
}
