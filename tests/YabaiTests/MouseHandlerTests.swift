import ApplicationServices
import Testing
import YabaiC
@testable import Yabai

@Test("mouse_drop_action_regions")
func mouseDropActionRegions()
{
    let target = Window()
    target.frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let ms = MouseState()
    ms.drop_action = MOUSE_MODE_SWAP
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 150)) == MOUSE_DROP_ACTION_SWAP)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 105)) == MOUSE_DROP_ACTION_WARP_TOP)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 295, y: 150)) == MOUSE_DROP_ACTION_WARP_RIGHT)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 195)) == MOUSE_DROP_ACTION_WARP_BOTTOM)
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 105, y: 150)) == MOUSE_DROP_ACTION_WARP_LEFT)
    // NOTE: mouse_drop_action stack makes the center a tab of the window instead
    ms.drop_action = MOUSE_MODE_STACK
    #expect(mouse_determine_drop_action(ms, target,CGPoint(x: 200, y: 150)) == MOUSE_DROP_ACTION_STACK)
}
