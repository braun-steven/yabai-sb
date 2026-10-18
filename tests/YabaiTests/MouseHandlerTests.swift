import ApplicationServices
import Testing
import CPrivate
@testable import Yabai

@Test("mouse_drop_action_regions")
func mouseDropActionRegions()
{
    let target = Window()
    target.frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let ms = MouseState()
    ms.drop_action = .swap
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 150)) == .swap)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 105)) == .warpTop)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 295, y: 150)) == .warpRight)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 195)) == .warpBottom)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 105, y: 150)) == .warpLeft)
    // NOTE: mouse_drop_action stack makes the center a tab of the window instead
    ms.drop_action = .stack
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 150)) == .stack)
}
