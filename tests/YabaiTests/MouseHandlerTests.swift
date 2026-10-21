import ApplicationServices
import Testing
import CPrivate
@testable import Yabai
import YabaiCore
import YabaiTestSupport

extension DaemonState
{
    @Suite
    @WM struct MouseHandlerTests
    {
        @Test("mouse_drop_action_regions")
        func mouseDropActionRegions()
        {
            let target = Window(id: 1)
            target.frame = CGRect(x: 100, y: 100, width: 200, height: 100)
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
    }
}

@Suite struct MouseValueTests
{
    static let dropDirections: [(MouseDropAction, InsertDirection?)] = [
        (.none, nil),
        (.stack, .stack),
        (.swap, .stack),
        (.warpTop, .north),
        (.warpRight, .east),
        (.warpBottom, .south),
        (.warpLeft, .west),
    ]

    @Test(arguments: dropDirections)
    func dropActionInsertsTowardItsSide(_ action: MouseDropAction, _ direction: InsertDirection?)
    {
        #expect(action.insertDirection == direction)
    }

    static let eventFlags: [(CGEventFlags, MouseModifiers)] = [
        ([], []),
        (.maskAlternate, .alt),
        (.maskShift, .shift),
        (.maskCommand, .cmd),
        (.maskControl, .ctrl),
        (.maskSecondaryFn, .fn),
        ([.maskAlternate, .maskShift], [.alt, .shift]),
        ([.maskCommand, .maskControl, .maskSecondaryFn], [.cmd, .ctrl, .fn]),
        // the other flags, and the device-dependent bits of a key, do not count
        ([.maskAlphaShift, .maskNumericPad, .maskHelp, .maskNonCoalesced], []),
        (CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08), .cmd),
    ]

    @Test(arguments: eventFlags)
    func modifiersOfEventFlags(_ flags: CGEventFlags, _ modifiers: MouseModifiers)
    {
        #expect(MouseModifiers(flags) == modifiers)
    }

    @Test func eachModifierKeyIsItsOwnModifier()
    {
        let modifiers = MouseModifierKey.allCases.map(\.modifiers)
        #expect(modifiers == [.alt, .shift, .cmd, .ctrl, .fn])
        #expect(modifiers.map(\.rawValue).reduce(0, |).nonzeroBitCount == modifiers.count)
    }
}
