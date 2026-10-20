import Testing
import CPrivate
@testable import Yabai
import YabaiTestSupport

private func knownFocusPSN(_ low: UInt32) -> ProcessSerialNumber
{
    var psn = ProcessSerialNumber()
    psn.lowLongOfPSN = low
    return psn
}

@Test("space_known_focus") @WM func spaceKnownFocus()
{
    let wm = WindowManager()

    let owner = knownFocusPSN(0x1234)
    let other = knownFocusPSN(0x5678)
    wm.focusedWindowID = 42
    wm.focusedWindowPSN = owner

    //
    // NOTE: The known focus is used only while the front process owns it and no focus change is pending.
    //

    #expect(wm.canUseKnownFocus(front: owner, pendingFocus: false) == true)
    #expect(wm.canUseKnownFocus(front: other, pendingFocus: false) == false)
    #expect(wm.canUseKnownFocus(front: owner, pendingFocus: true) == false)

    wm.focusedWindowID = nil
    #expect(wm.canUseKnownFocus(front: owner, pendingFocus: false) == false)
}
