import Testing
import YabaiC
@testable import Yabai

// NOTE: Ported from tests/src/window_frame.c (space_known_focus).

private func knownFocusPSN(_ low: UInt32) -> ProcessSerialNumber
{
    var psn = ProcessSerialNumber()
    psn.lowLongOfPSN = low
    return psn
}

@Test("space_known_focus") func spaceKnownFocus()
{
    var wm = window_manager()

    var owner = knownFocusPSN(0x1234)
    var other = knownFocusPSN(0x5678)
    wm.focused_window_id = 42
    wm.focused_window_psn = owner

    //
    // NOTE: The known focus is used only while the front process owns it and no focus change is pending.
    //

    #expect(space_manager_can_use_known_focus(&owner, &wm, false) == true)
    #expect(space_manager_can_use_known_focus(&other, &wm, false) == false)
    #expect(space_manager_can_use_known_focus(&owner, &wm, true) == false)

    wm.focused_window_id = 0
    #expect(space_manager_can_use_known_focus(&owner, &wm, false) == false)
}
