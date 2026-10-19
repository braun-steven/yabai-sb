import ApplicationServices
import Testing
import CPrivate
@testable import Yabai

@Test("mouse_drop_action_regions")
@WM func mouseDropActionRegions()
{
    let target = Window(id: 0)
    target.frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let dropAction = Config.current.mouse.dropAction
    defer { Config.current.mouse.dropAction = dropAction }
    let ms = MouseState()
    Config.current.mouse.dropAction = .swap
    #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 150)) == .swap)
    #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 105)) == .warpTop)
    #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 295, y: 150)) == .warpRight)
    #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 195)) == .warpBottom)
    #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 105, y: 150)) == .warpLeft)
    // NOTE: mouse_drop_action stack makes the center a tab of the window instead
    Config.current.mouse.dropAction = .stack
    #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 150)) == .stack)
}
